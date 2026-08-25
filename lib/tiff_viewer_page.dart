import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_image_adapter.dart';
import 'package:tiff/tiff_io.dart';

/// Cap on the longest side of the decoded preview. Above this, the image is
/// decoded band-by-band (via [TiffImage.decodeRegionRgba8]) and downsampled
/// on the fly, so a multi-gigapixel file never needs a full-resolution RGBA
/// buffer (width*height*4 bytes) in memory just to be looked at.
const _maxPreviewDim = 4096;

/// Roughly how much memory one decode band is allowed to use. This bounds
/// the *raw* decoded band, not just its RGBA conversion — see
/// [_bandBytesPerPixel].
const _maxBandBytes = 32 * 1024 * 1024;

/// A tiled page above this many tiles has no business being decoded whole
/// (even banded) just to build a small overview — see [_decodeSparsePreview].
const _sparseSamplingTileThreshold = 4000;

/// The round-trip write test decodes raw (non-RGBA) samples for the *whole*
/// image at full resolution and re-encodes them — above this pixel count
/// that's disabled rather than risking an out-of-memory crash.
const _maxSafeFullDecodePixels = 64 * 1000 * 1000;

class TiffViewerPage extends StatefulWidget {
  final String filePath;
  const TiffViewerPage({super.key, required this.filePath});

  @override
  State<TiffViewerPage> createState() => _TiffViewerPageState();
}

/// Entry point for a manually spawned [Isolate]. A plain [compute] call
/// can't report progress mid-flight (it's one request, one response), so
/// this streams fractional progress over [SendPort] as each band decodes
/// and sends the final `(rgba, width, height)` result last. Must be a
/// top-level function (no captured state); every message sent over the
/// port must be safe to copy across the isolate boundary, so progress is
/// a plain `double` and failure is reported as a plain `String` message
/// rather than the original exception object.
///
/// Used only for pages that aren't tiled (see [TiffImageMetadata.isTiled]):
/// a tiled page gets the viewport-driven [_TileEngine] instead, which never
/// needs a single "decode everything, once" pass at all.
void _decodePreviewIsolateEntry((SendPort, String) args) {
  final (sendPort, filePath) = args;
  try {
    // Runs in its own isolate, which does not share the main isolate's
    // static state — so JPEG support must be (re-)enabled here too, even
    // though main() already called this once at startup.
    TiffImageAdapter.enableJpegSupport();
    final document = decodeTiffFile(File(filePath));
    try {
      final page = _choosePreviewPage(document);
      final result = _decodePreviewRgba(page, onProgress: (p) => sendPort.send(p));
      sendPort.send(result);
    } finally {
      document.close();
    }
  } catch (e) {
    sendPort.send('$e');
  }
}

/// Picks which page/IFD to decode the preview from. A multi-page file is
/// often a resolution *pyramid* (e.g. whole-slide-image scanners like
/// Philips's), where later pages are pre-downsampled versions of page 0 —
/// sometimes by a huge factor (seen in practice: a 131072x100352 base page
/// next to a 4096x3584 one). Decoding page 0 and downsampling it ourselves
/// for a capped-size preview would mean decompressing the entire base
/// image — potentially tens of thousands of JPEG tiles — just to throw
/// almost all of it away. Picking the smallest pyramid page that still
/// meets [_maxPreviewDim] does the same downsampling work the scanner
/// already did, for a small fraction of the decode cost.
///
/// A multi-page TIFF can also carry unrelated extra images (label/macro
/// shots, fixed-size thumbnails) that aren't pyramid levels of page 0 at
/// all, so a page only counts as a candidate if its aspect ratio is close
/// to page 0's — full pyramid levels match closely; unrelated images
/// generally don't.
TiffImage _choosePreviewPage(TiffDocument document) {
  final images = document.images;
  final baseAspect = images.first.metadata.width / images.first.metadata.height;

  TiffImage? smallestSufficient;
  TiffImage? largestInsufficient;
  for (final img in images) {
    final m = img.metadata;
    final aspect = m.width / m.height;
    if ((aspect - baseAspect).abs() / baseAspect > 0.2) continue;

    final longest = math.max(m.width, m.height);
    if (longest >= _maxPreviewDim) {
      if (smallestSufficient == null || longest < math.max(smallestSufficient.metadata.width, smallestSufficient.metadata.height)) {
        smallestSufficient = img;
      }
    } else {
      if (largestInsufficient == null || longest > math.max(largestInsufficient.metadata.width, largestInsufficient.metadata.height)) {
        largestInsufficient = img;
      }
    }
  }
  return smallestSufficient ?? largestInsufficient ?? images.first;
}

/// One resolution rung of a page pyramid, largest (most detailed) first —
/// see [_buildPyramidLevels]. [tileWidth]/[tileLength] default to the
/// whole level's dimensions when the underlying page isn't itself tiled,
/// so callers can always treat a level as "decode by tile" without a
/// separate strip-layout code path.
class _PyramidLevel {
  final TiffImage image;
  final int width;
  final int height;
  final int tileWidth;
  final int tileLength;
  final bool isTiled;

  const _PyramidLevel({
    required this.image,
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileLength,
    required this.isTiled,
  });
}

/// Same aspect-ratio pyramid-level filter as [_choosePreviewPage], but
/// returns the whole ladder (largest/native first) instead of picking one
/// rung — [_TileEngine] needs every level so it can switch rungs as the
/// user zooms in and out.
List<_PyramidLevel> _buildPyramidLevels(TiffDocument document) {
  final images = document.images;
  final baseAspect = images.first.metadata.width / images.first.metadata.height;
  final levels = <_PyramidLevel>[];
  for (final img in images) {
    final m = img.metadata;
    final aspect = m.width / m.height;
    if ((aspect - baseAspect).abs() / baseAspect > 0.2) continue;
    levels.add(
      _PyramidLevel(
        image: img,
        width: m.width,
        height: m.height,
        tileWidth: m.isTiled ? m.tileWidth! : m.width,
        tileLength: m.isTiled ? m.tileLength! : m.height,
        isTiled: m.isTiled,
      ),
    );
  }
  levels.sort((a, b) => b.width.compareTo(a.width));
  return levels;
}

/// Raw per-pixel memory a decode band actually costs while it's alive:
/// the underlying [TiffRasterBuffer.samples] is a `List<int>`, which the
/// Dart VM stores as one machine word (8 bytes) per element regardless of
/// the sample's actual bit depth — not [TiffImageMetadata.bitsPerSample]
/// bits per sample as the on-disk encoding would suggest. Plus the RGBA8
/// conversion of that same band (4 bytes/pixel), which is briefly alive
/// alongside it.
int _bandBytesPerPixel(TiffImageMetadata metadata) => metadata.samplesPerPixel * 8 + 4;

int _tileGridArea(TiffImageMetadata m) {
  final tw = m.tileWidth!;
  final tl = m.tileLength!;
  return ((m.width + tw - 1) ~/ tw) * ((m.height + tl - 1) ~/ tl);
}

/// Decodes [page] to RGBA8, downsampling to at most [_maxPreviewDim] on
/// the longest side. For an oversized image this never holds more than
/// one horizontal band (capped at [_maxBandBytes], sized using the raw
/// decode buffer's real per-pixel cost — see [_bandBytesPerPixel]) plus
/// the (much smaller) output buffer at once — never the full-resolution
/// image. A tiled page with an impractical number of tiles (no smaller
/// pyramid rung to fall back on) instead goes through [_decodeSparsePreview].
/// [onProgress], if given, is called with a fraction from 0 to 1 as each
/// band/tile completes.
(Uint8List, int, int) _decodePreviewRgba(TiffImage page, {void Function(double)? onProgress}) {
  final metadata = page.metadata;
  final srcWidth = metadata.width;
  final srcHeight = metadata.height;
  final longest = math.max(srcWidth, srcHeight);
  if (longest <= _maxPreviewDim) {
    onProgress?.call(0);
    final rgba = page.decodeRegionRgba8(TiffRegion.fullImage(metadata));
    onProgress?.call(1);
    return (rgba, srcWidth, srcHeight);
  }

  if (metadata.isTiled && _tileGridArea(metadata) > _sparseSamplingTileThreshold) {
    return _decodeSparsePreview(page, onProgress: onProgress);
  }

  final scale = _maxPreviewDim / longest;
  final outWidth = (srcWidth * scale).round().clamp(1, srcWidth);
  final outHeight = (srcHeight * scale).round().clamp(1, srcHeight);
  final output = Uint8List(outWidth * outHeight * 4);

  final bytesPerPixel = _bandBytesPerPixel(metadata);
  final bandHeight = math.max(1, _maxBandBytes ~/ (srcWidth * bytesPerPixel));
  for (var bandStart = 0; bandStart < srcHeight; bandStart += bandHeight) {
    final bh = math.min(bandHeight, srcHeight - bandStart);
    final band = page.decodeRegionRgba8(TiffRegion(x: 0, y: bandStart, width: srcWidth, height: bh));
    for (var oy = 0; oy < outHeight; oy++) {
      final srcY = (oy / scale).floor();
      if (srcY < bandStart || srcY >= bandStart + bh) continue;
      final bandRowBase = (srcY - bandStart) * srcWidth * 4;
      final outRowBase = oy * outWidth * 4;
      for (var ox = 0; ox < outWidth; ox++) {
        final s = bandRowBase + (ox / scale).floor() * 4;
        final d = outRowBase + ox * 4;
        output[d] = band[s];
        output[d + 1] = band[s + 1];
        output[d + 2] = band[s + 2];
        output[d + 3] = band[s + 3];
      }
    }
    onProgress?.call((bandStart + bh) / srcHeight);
  }
  return (output, outWidth, outHeight);
}

/// A cheap, approximate overview for a huge tiled page that has no smaller
/// pyramid level to fall back on: decoding every tile just to build a small
/// preview would mean decompressing the whole multi-gigapixel image, tile
/// by tile, compression block by compression block (a tile can't be
/// partially decoded). Instead this decodes only a sparse, evenly-spaced
/// sample of tiles across the grid and stretches each one across the block
/// of output pixels it stands in for — a blocky, approximate stand-in that
/// appears almost instantly. Exact detail then fills in per-viewport as the
/// user zooms in (see [_TileEngine]), so the approximation only has to hold
/// up at a glance, not under close inspection.
(Uint8List, int, int) _decodeSparsePreview(TiffImage page, {void Function(double)? onProgress}) {
  const sampleTarget = 24;
  final m = page.metadata;
  final tileWidth = m.tileWidth!;
  final tileLength = m.tileLength!;
  final tileCols = (m.width + tileWidth - 1) ~/ tileWidth;
  final tileRows = (m.height + tileLength - 1) ~/ tileLength;

  final scale = _maxPreviewDim / math.max(m.width, m.height);
  final outWidth = (m.width * scale).round().clamp(1, m.width);
  final outHeight = (m.height * scale).round().clamp(1, m.height);
  final output = Uint8List(outWidth * outHeight * 4);

  final sampleCols = math.min(tileCols, sampleTarget);
  final sampleRows = math.min(tileRows, sampleTarget);

  for (var sy = 0; sy < sampleRows; sy++) {
    final tileRow = (sy * tileRows / sampleRows).floor();
    final srcY = tileRow * tileLength;
    final th = math.min(tileLength, m.height - srcY);
    final outY0 = (sy * outHeight / sampleRows).floor();
    final outY1 = ((sy + 1) * outHeight / sampleRows).floor().clamp(outY0 + 1, outHeight);

    for (var sx = 0; sx < sampleCols; sx++) {
      final tileCol = (sx * tileCols / sampleCols).floor();
      final srcX = tileCol * tileWidth;
      final tw = math.min(tileWidth, m.width - srcX);
      final outX0 = (sx * outWidth / sampleCols).floor();
      final outX1 = ((sx + 1) * outWidth / sampleCols).floor().clamp(outX0 + 1, outWidth);

      final tile = page.decodeRegionRgba8(TiffRegion(x: srcX, y: srcY, width: tw, height: th));
      for (var oy = outY0; oy < outY1; oy++) {
        final ty = ((oy - outY0) * th / (outY1 - outY0)).floor().clamp(0, th - 1);
        final tileRowBase = ty * tw * 4;
        final outRowBase = oy * outWidth * 4;
        for (var ox = outX0; ox < outX1; ox++) {
          final tx = ((ox - outX0) * tw / (outX1 - outX0)).floor().clamp(0, tw - 1);
          final s = tileRowBase + tx * 4;
          final d = outRowBase + ox * 4;
          output[d] = tile[s];
          output[d + 1] = tile[s + 1];
          output[d + 2] = tile[s + 2];
          output[d + 3] = tile[s + 3];
        }
      }
      onProgress?.call((sy * sampleCols + sx + 1) / (sampleRows * sampleCols));
    }
  }
  return (output, outWidth, outHeight);
}

/// Entry point for the long-lived tile-serving isolate behind [_TileEngine].
/// Unlike [_decodePreviewIsolateEntry] (one request, one response, then the
/// isolate is discarded), this isolate stays alive for as long as the
/// viewer is open and answers a stream of tile-decode requests, so panning
/// and zooming never has to pay isolate-spawn cost per tile.
///
/// Handshake: sends its own [SendPort] back over [mainSendPort] first (or a
/// `String` error if the file can't even be opened), then processes
/// requests as `(requestId, kind, levelIndex, x, y, width, height)` tuples —
/// `kind` 0 decodes exactly that region of that pyramid level; `kind` 1
/// ignores x/y/width/height and produces a capped-size overview of that
/// level via [_decodePreviewRgba] (which picks sparse vs. banded sampling
/// on its own). Replies are `(requestId, rgba, width, height)` on success or
/// `(requestId, error)` on failure — always tagged with the request's id so
/// the main isolate can match a reply back to what it was for.
void _tileWorkerEntry((SendPort, String) args) {
  final (mainSendPort, filePath) = args;
  TiffImageAdapter.enableJpegSupport();

  final TiffDocument document;
  final List<_PyramidLevel> levels;
  try {
    document = decodeTiffFile(File(filePath));
    levels = _buildPyramidLevels(document);
  } catch (e) {
    mainSendPort.send('$e');
    return;
  }

  final requestPort = ReceivePort();
  mainSendPort.send(requestPort.sendPort);

  requestPort.listen((message) {
    final (requestId, kind, levelIndex, x, y, width, height) = message as (int, int, int, int, int, int, int);
    try {
      final level = levels[levelIndex];
      if (kind == 1) {
        final (rgba, w, h) = _decodePreviewRgba(level.image);
        mainSendPort.send((requestId, rgba, w, h));
      } else {
        final rgba = level.image.decodeRegionRgba8(TiffRegion(x: x, y: y, width: width, height: height));
        mainSendPort.send((requestId, rgba, width, height));
      }
    } catch (e) {
      mainSendPort.send((requestId, '$e'));
    }
  });
}

/// Drives viewport-based deep-zoom tile loading for a tiled page pyramid:
/// an overview appears almost immediately (see [_decodePreviewRgba]/
/// [_decodeSparsePreview]), then only the tiles that intersect whatever
/// [requestVisible] was last called with — at whichever pyramid level best
/// matches the current zoom — are decoded, one at a time, by a persistent
/// worker isolate. Tiles are cached (bounded, LRU-evicted) so panning back
/// over already-seen ground is instant, and never-visited regions of a
/// multi-gigapixel image are simply never decoded at all.
/// One tile-decoding isolate in [_TileEngine]'s worker pool: its own file
/// handle, its own request/response port, busy only while a request it was
/// given is still being decoded.
class _TileWorker {
  Isolate? isolate;
  ReceivePort? receivePort;
  SendPort? sendPort;
  bool busy = false;
}

class _TileEngine extends ChangeNotifier {
  static const _maxCachedTiles = 320;

  /// How many tiles beyond the visible edge to prefetch, in units of one
  /// tile at the active level — small enough to stay cheap, big enough that
  /// a modest pan doesn't show a bare edge while the next tile decodes.
  static const _prefetchMarginTiles = 0.75;

  final String filePath;
  final List<_PyramidLevel> levels;

  /// One isolate per available core (minus one, left for the UI thread),
  /// capped at 4 — tile decode is pure CPU work (JPEG blocks, mostly), so
  /// running several at once directly cuts wall-clock time to fill a
  /// viewport instead of decoding tiles one after another.
  late final List<_TileWorker> _workers = List.generate(
    math.max(1, math.min(4, Platform.numberOfProcessors - 1)),
    (_) => _TileWorker(),
  );

  Object? _fatalError;

  ui.Image? overview;

  final _cache = <String, ui.Image>{};
  final _pending = <String>{};
  final _requestKeyById = <int, String>{};
  int _nextRequestId = 0;

  Rect? _lastVisibleRect;
  double _lastScale = 1;

  _TileEngine({required this.filePath, required this.levels});

  Object? get fatalError => _fatalError;
  bool get isWorking => _workers.any((w) => w.busy) || _pending.isNotEmpty;
  int get baseWidth => levels.first.width;
  int get baseHeight => levels.first.height;

  Future<void> start() async {
    await Future.wait(_workers.map(_startWorker));
    _requestOverview();
  }

  Future<void> _startWorker(_TileWorker worker) async {
    final receivePort = ReceivePort();
    worker.receivePort = receivePort;
    final handshake = Completer<void>();
    receivePort.listen((message) => _onMessage(worker, message, handshake));
    try {
      worker.isolate = await Isolate.spawn(_tileWorkerEntry, (receivePort.sendPort, filePath));
    } catch (e) {
      _fatalError = e;
      notifyListeners();
      if (!handshake.isCompleted) handshake.complete();
    }
    return handshake.future;
  }

  void requestVisible(Rect baseVisibleRect, double scale) {
    _lastVisibleRect = baseVisibleRect;
    _lastScale = scale;
    _pump();
  }

  void _onMessage(_TileWorker worker, dynamic message, Completer<void> handshake) {
    if (message is SendPort) {
      worker.sendPort = message;
      if (!handshake.isCompleted) handshake.complete();
      return;
    }
    if (message is String) {
      _fatalError = message;
      notifyListeners();
      if (!handshake.isCompleted) handshake.complete();
      return;
    }
    if (message is (int, Uint8List, int, int)) {
      final (requestId, rgba, width, height) = message;
      _handleTileResult(worker, requestId, rgba, width, height);
      return;
    }
    if (message is (int, String)) {
      final (requestId, _) = message;
      _handleTileFailure(worker, requestId);
    }
  }

  int _pickOverviewLevelIndex() {
    for (var i = levels.length - 1; i >= 0; i--) {
      if (levels[i].width >= _maxPreviewDim) return i;
    }
    return 0;
  }

  void _requestOverview() {
    final worker = _workers.firstWhere((w) => w.sendPort != null, orElse: () => _workers.first);
    _sendRequest(worker, _pickOverviewLevelIndex(), 1, 0, 0, 0, 0, key: 'overview');
  }

  int _pickLevelForScale(double scale) {
    final requiredWidth = baseWidth * scale;
    for (var i = levels.length - 1; i >= 0; i--) {
      if (levels[i].width >= requiredWidth) return i;
    }
    return 0;
  }

  List<(int, int, int)> _tilesForLevel(int levelIndex, Rect baseRect) {
    final level = levels[levelIndex];
    final ratio = level.width / baseWidth;
    final tw = level.tileWidth;
    final th = level.tileLength;
    final marginX = tw * _prefetchMarginTiles;
    final marginY = th * _prefetchMarginTiles;
    final levelRect = Rect.fromLTRB(
      baseRect.left * ratio - marginX,
      baseRect.top * ratio - marginY,
      baseRect.right * ratio + marginX,
      baseRect.bottom * ratio + marginY,
    ).intersect(Rect.fromLTWH(0, 0, level.width.toDouble(), level.height.toDouble()));
    if (levelRect.isEmpty) return const [];

    final lastTx = (level.width - 1) ~/ tw;
    final lastTy = (level.height - 1) ~/ th;
    final txStart = math.max(0, (levelRect.left / tw).floor());
    final txEnd = math.min(lastTx, (levelRect.right / tw).ceil());
    final tyStart = math.max(0, (levelRect.top / th).floor());
    final tyEnd = math.min(lastTy, (levelRect.bottom / th).ceil());

    final centerX = levelRect.center.dx;
    final centerY = levelRect.center.dy;
    final tiles = <(int, int, int)>[];
    for (var ty = tyStart; ty <= tyEnd; ty++) {
      for (var tx = txStart; tx <= txEnd; tx++) {
        tiles.add((levelIndex, tx, ty));
      }
    }
    tiles.sort((a, b) {
      final ax = a.$2 * tw + tw / 2 - centerX;
      final ay = a.$3 * th + th / 2 - centerY;
      final bx = b.$2 * tw + tw / 2 - centerX;
      final by = b.$3 * th + th / 2 - centerY;
      return (ax * ax + ay * ay).compareTo(bx * bx + by * by);
    });
    return tiles;
  }

  /// Tiles needed to cover the current viewport, ordered coarsest rung
  /// first: every tile of a coarser pyramid level is queued ahead of any
  /// tile of a finer one. [_pump] hands these out to idle workers in this
  /// order, so a finer tile is never even requested while the viewport
  /// still has an un-loaded coarser tile pending — the viewport fills in
  /// at one uniform resolution at a time (overview -> mid rung -> full
  /// detail) instead of a sharp patch appearing in the center while the
  /// edges are still showing the (much blurrier) overview underneath.
  List<(int, int, int)> _neededTiles() {
    final rect = _lastVisibleRect;
    if (rect == null || rect.isEmpty) return const [];
    final targetLevel = _pickLevelForScale(_lastScale);
    final tiles = <(int, int, int)>[];
    for (var levelIndex = levels.length - 1; levelIndex >= targetLevel; levelIndex--) {
      tiles.addAll(_tilesForLevel(levelIndex, rect));
    }
    return tiles;
  }

  /// The coarsest pyramid rung that still has a tile missing from [_cache]
  /// for the current viewport (falling back to [target] once every rung
  /// down to it is fully cached) — the rung [cachedTileEntries] is allowed
  /// to reveal right now, and the rung [_pump] fills first.
  int _activeLevelIndex(Rect rect, int target) {
    for (var levelIndex = levels.length - 1; levelIndex >= target; levelIndex--) {
      final tiles = _tilesForLevel(levelIndex, rect);
      if (tiles.isEmpty) continue;
      final hasOutstanding = tiles.any((t) => !_cache.containsKey('tile:${t.$1}:${t.$2}:${t.$3}'));
      if (hasOutstanding) return levelIndex;
    }
    return target;
  }

  /// Hands every idle worker a tile from the active rung (the coarsest one
  /// still incomplete) first — all of them pitch in to finish that same
  /// rung as fast as possible. Only once the active rung has no more tiles
  /// *left to hand out* (its remainder is already in flight with other
  /// workers, not just unfinished) does a still-idle worker move on to the
  /// next finer rung ahead of time. That prefetched tile lands in the same
  /// [_cache], but [cachedTileEntries] keeps it hidden until its own rung
  /// actually becomes active — so getting a head start never lets a finer
  /// patch visibly race the coarser rung that's still loading.
  void _pump() {
    final idleWorkers = _workers.where((w) => !w.busy && w.sendPort != null).toList();
    if (idleWorkers.isEmpty) return;
    final rect = _lastVisibleRect;
    if (rect == null) return;
    final target = _pickLevelForScale(_lastScale);
    final active = _activeLevelIndex(rect, target);

    var wi = 0;
    for (final (levelIndex, tx, ty) in _tilesForLevel(active, rect)) {
      if (wi >= idleWorkers.length) break;
      final key = 'tile:$levelIndex:$tx:$ty';
      if (_cache.containsKey(key) || _pending.contains(key)) continue;
      _dispatchTile(idleWorkers[wi], levelIndex, tx, ty, key);
      wi++;
    }

    for (var levelIndex = active - 1; wi < idleWorkers.length && levelIndex >= target; levelIndex--) {
      for (final (li, tx, ty) in _tilesForLevel(levelIndex, rect)) {
        if (wi >= idleWorkers.length) break;
        final key = 'tile:$li:$tx:$ty';
        if (_cache.containsKey(key) || _pending.contains(key)) continue;
        _dispatchTile(idleWorkers[wi], li, tx, ty, key);
        wi++;
      }
    }
  }

  void _dispatchTile(_TileWorker worker, int levelIndex, int tx, int ty, String key) {
    final level = levels[levelIndex];
    final x = tx * level.tileWidth;
    final y = ty * level.tileLength;
    final w = math.min(level.tileWidth, level.width - x);
    final h = math.min(level.tileLength, level.height - y);
    _sendRequest(worker, levelIndex, 0, x, y, w, h, key: key);
  }

  void _sendRequest(_TileWorker worker, int levelIndex, int kind, int x, int y, int w, int h, {required String key}) {
    final port = worker.sendPort;
    if (port == null) return;
    final id = _nextRequestId++;
    _pending.add(key);
    _requestKeyById[id] = key;
    worker.busy = true;
    port.send((id, kind, levelIndex, x, y, w, h));
  }

  Future<void> _handleTileResult(_TileWorker worker, int requestId, Uint8List rgba, int width, int height) async {
    final key = _requestKeyById.remove(requestId);
    worker.busy = false;
    if (key == null) {
      _pump();
      return;
    }
    _pending.remove(key);
    final image = await _decodeUiImage(rgba, width, height);
    if (key == 'overview') {
      overview?.dispose();
      overview = image;
    } else {
      _cacheTile(key, image);
    }
    notifyListeners();
    _pump();
  }

  void _handleTileFailure(_TileWorker worker, int requestId) {
    final key = _requestKeyById.remove(requestId);
    worker.busy = false;
    if (key != null) _pending.remove(key);
    _pump();
  }

  Future<ui.Image> _decodeUiImage(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  void _cacheTile(String key, ui.Image image) {
    if (_cache.length >= _maxCachedTiles) {
      // Prefer evicting a tile the current viewport doesn't need right
      // now, so re-decoding isn't triggered for something still on screen.
      final neededKeys = _lastVisibleRect == null ? const <String>{} : _neededTiles().map((t) => 'tile:${t.$1}:${t.$2}:${t.$3}').toSet();
      final victim = _cache.keys.firstWhere((k) => !neededKeys.contains(k), orElse: () => _cache.keys.first);
      _cache.remove(victim)?.dispose();
    }
    _cache[key] = image;
  }

  /// Cached tiles paired with their level, sorted coarsest-first so the
  /// painter can draw finer levels on top of coarser ones. A tile appears
  /// the moment it's decoded, but only once its own rung is the active one
  /// (see [_activeLevelIndex]) — a tile from a finer rung that an idle
  /// worker prefetched ahead of time (see [_pump]) sits in [_cache]
  /// already decoded, but stays hidden here until the coarser rung above
  /// it actually finishes.
  List<(int, int, int, ui.Image)> cachedTileEntries() {
    final rect = _lastVisibleRect;
    final floor = rect == null ? 0 : _activeLevelIndex(rect, _pickLevelForScale(_lastScale));
    final result = <(int, int, int, ui.Image)>[];
    for (final entry in _cache.entries) {
      final parts = entry.key.split(':');
      if (parts[0] != 'tile') continue;
      final levelIndex = int.parse(parts[1]);
      if (levelIndex < floor) continue;
      result.add((levelIndex, int.parse(parts[2]), int.parse(parts[3]), entry.value));
    }
    result.sort((a, b) => b.$1.compareTo(a.$1));
    return result;
  }

  @override
  void dispose() {
    for (final worker in _workers) {
      worker.isolate?.kill(priority: Isolate.immediate);
      worker.receivePort?.close();
    }
    overview?.dispose();
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
    super.dispose();
  }
}

class _TiffViewerPageState extends State<TiffViewerPage> {
  int? _fileSizeBytes;
  TiffDocument? _document;
  Object? _decodeError;
  ui.Image? _renderedImage;
  Object? _renderError;
  String? _writeTestResult;
  bool _runningWriteTest = false;

  Uint8List? _rgba;
  int _rgbaWidth = 0;
  int _rgbaHeight = 0;
  bool _previewDownscaled = false;
  double _brightness = 0;
  double _contrast = 1;
  double _gamma = 1;

  bool _previewLoading = false;
  double? _previewProgress;
  Isolate? _decodeIsolate;
  ReceivePort? _decodePort;

  _TileEngine? _tileEngine;

  bool get _previewStarted => _previewLoading || _renderedImage != null || _tileEngine != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Releases the open file handle a file-backed TiffDocument holds.
    _document?.close();
    _decodePort?.close();
    _decodeIsolate?.kill(priority: Isolate.immediate);
    _tileEngine?.dispose();
    super.dispose();
  }

  /// Opens the file and reads its metadata only — cheap, header/IFD-only
  /// work — so the metadata table can display right away without waiting
  /// on a full image decode. The pixel preview itself is only decoded once
  /// the user asks for it via [_openPreview].
  Future<void> _load() async {
    final TiffDocument document;
    try {
      final file = File(widget.filePath);
      _fileSizeBytes = await file.length();
      // File-backed: only reads the byte ranges it actually needs (header,
      // IFDs, then whichever strips/tiles a decode call touches) instead of
      // loading the whole file into memory up front.
      document = decodeTiffFile(file);
    } catch (e) {
      if (mounted) setState(() => _decodeError = e);
      return;
    }
    if (!mounted) {
      document.close();
      return;
    }
    setState(() => _document = document);
  }

  /// Starts showing the pixel preview. A tiled page (see
  /// [TiffImageMetadata.isTiled]) gets the viewport-driven [_TileEngine] —
  /// only the region currently on screen is ever decoded, at whichever
  /// pyramid level matches the current zoom, so a multi-gigapixel image
  /// never needs a full decode just to be looked at. A non-tiled page falls
  /// back to the single banded decode this app already had, run in a
  /// throwaway background isolate that reports progress as it goes.
  Future<void> _openPreview() async {
    final document = _document;
    if (document == null || _previewStarted) return;

    if (document.images.first.metadata.isTiled) {
      setState(() => _previewLoading = true);
      final engine = _TileEngine(filePath: widget.filePath, levels: _buildPyramidLevels(document));
      engine.addListener(_onTileEngineChanged);
      await engine.start();
      if (!mounted) {
        engine.dispose();
        return;
      }
      setState(() {
        _tileEngine = engine;
        _previewLoading = false;
      });
      return;
    }

    setState(() {
      _previewLoading = true;
      _previewProgress = null;
      _renderError = null;
    });

    final metadata = document.images.first.metadata;
    final receivePort = ReceivePort();
    _decodePort = receivePort;
    try {
      _decodeIsolate = await Isolate.spawn(_decodePreviewIsolateEntry, (receivePort.sendPort, widget.filePath));
    } catch (e) {
      receivePort.close();
      _decodePort = null;
      if (mounted) {
        setState(() {
          _previewLoading = false;
          _renderError = e;
        });
      }
      return;
    }

    await for (final message in receivePort) {
      if (message is double) {
        if (mounted) setState(() => _previewProgress = message);
      } else if (message is String) {
        if (mounted) {
          setState(() {
            _previewLoading = false;
            _renderError = Exception(message);
          });
        }
        break;
      } else {
        final (rgba, width, height) = message as (Uint8List, int, int);
        _rgba = rgba;
        _rgbaWidth = width;
        _rgbaHeight = height;
        _previewDownscaled = width != metadata.width || height != metadata.height;
        final image = await _decodeImageFromPixels(rgba, width, height);
        if (mounted) {
          setState(() {
            _renderedImage = image;
            _previewLoading = false;
          });
        }
        break;
      }
    }

    receivePort.close();
    _decodeIsolate?.kill(priority: Isolate.immediate);
    _decodeIsolate = null;
    _decodePort = null;
  }

  void _onTileEngineChanged() {
    if (mounted) setState(() {});
  }

  Future<ui.Image> _decodeImageFromPixels(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  Future<void> _reapplyAdjustments() async {
    final rgba = _rgba;
    if (rgba == null) return;
    final adjusted = ImageAdjustments.apply(
      rgba,
      brightness: _brightness,
      contrast: _contrast,
      gamma: _gamma,
    );
    final image = await _decodeImageFromPixels(adjusted, _rgbaWidth, _rgbaHeight);
    if (mounted) setState(() => _renderedImage = image);
  }

  bool get _fullDecodeIsSafe {
    final metadata = _document?.images.first.metadata;
    if (metadata == null) return false;
    return metadata.width * metadata.height <= _maxSafeFullDecodePixels;
  }

  Future<void> _runWriteTest() async {
    final document = _document;
    if (document == null || !_fullDecodeIsSafe) return;
    setState(() {
      _runningWriteTest = true;
      _writeTestResult = null;
    });
    try {
      final page = document.images.first;
      final raster = page.decode();
      final isJpeg = page.metadata.compression == 6 || page.metadata.compression == 7;
      // decode() already turned JPEG-in-TIFF into plain RGB samples, so the
      // written copy should say RGB too, not carry over the original
      // (pre-JPEG-decode) YCbCr tag.
      final photometric = isJpeg ? TiffPhotometric.rgb : (page.metadata.photometric ?? TiffPhotometric.blackIsZero);

      final spec = TiffImageSpec(
        width: page.metadata.width,
        height: page.metadata.height,
        samplesPerPixel: raster.samplesPerPixel,
        bitsPerSample: raster.bitsPerSample,
        photometric: photometric,
        samples: raster.samples,
        colorMap: photometric == TiffPhotometric.palette ? page.metadata.colorMap : null,
        compression: 8, // Deflate/ZIP — safe default regardless of bit depth
      );
      final encoded = TiffEncoder.encode([spec], bigTiff: true);

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/tiff_tester_roundtrip.tif');
      await file.writeAsBytes(encoded);
      final readBack = await file.readAsBytes();

      final redecoded = TiffDecoder.decode(readBack);
      final redecodedRaster = redecoded.images.single.decode();
      final matches = _sameSamples(raster.samples, redecodedRaster.samples);

      if (!mounted) return;
      setState(() {
        _writeTestResult =
            '${matches ? 'OK' : 'MISMATCH'} — wrote ${encoded.length} bytes as forced BigTIFF '
            'to ${file.path}\nread back ${readBack.length} bytes, '
            'isBigTiff=${redecoded.isBigTiff}, samples match: $matches';
      });
    } catch (e) {
      if (mounted) setState(() => _writeTestResult = 'FAILED: $e');
    } finally {
      if (mounted) setState(() => _runningWriteTest = false);
    }
  }

  bool _sameSamples(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.filePath.split(Platform.pathSeparator).last;
    return Scaffold(
      appBar: AppBar(title: Text(fileName)),
      body: _document == null && _decodeError == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(widget.filePath, style: Theme.of(context).textTheme.bodySmall),
                if (_fileSizeBytes != null) Text('${_fileSizeBytes!} bytes on disk'),
                const SizedBox(height: 16),
                if (_decodeError != null) _ErrorCard(title: 'TiffDecoder.decode() failed', error: _decodeError!),
                if (_document != null) ..._buildDocumentInfo(_document!),
                const SizedBox(height: 16),
                if (_document != null && _decodeError == null && !_previewStarted) ...[
                  FilledButton.icon(onPressed: _openPreview, icon: const Icon(Icons.image), label: const Text('Xem ảnh')),
                  const SizedBox(height: 16),
                ],
                if (_previewLoading && _tileEngine == null) ...[
                  LinearProgressIndicator(value: _previewProgress),
                  const SizedBox(height: 8),
                  Text(
                    _previewProgress == null
                        ? 'Đang mở ảnh...'
                        : 'Đang giải mã ảnh xem trước... ${(_previewProgress! * 100).toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                ],
                if (_renderError != null && _tileEngine == null) ...[
                  _ErrorCard(title: 'decodeRgba8() failed', error: _renderError!),
                  const SizedBox(height: 16),
                ],
                if (_tileEngine?.fatalError != null) ...[
                  _ErrorCard(title: 'Tile decode failed', error: _tileEngine!.fatalError!),
                  const SizedBox(height: 16),
                ],
                if (_previewDownscaled)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Preview downscaled to $_rgbaWidth x $_rgbaHeight to limit memory use '
                      '(full resolution is ${_document!.images.first.metadata.width} x '
                      '${_document!.images.first.metadata.height}).',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.orange.shade800),
                    ),
                  ),
                if (_tileEngine != null)
                  SizedBox(
                    height: 420,
                    child: _TiledZoomableImage(
                      key: ValueKey(widget.filePath),
                      engine: _tileEngine!,
                      scale: _PixelScale.from(_document!.images.first.metadata),
                    ),
                  )
                else if (_renderedImage != null)
                  SizedBox(
                    height: 420,
                    child: _ZoomableTiffImage(
                      // Keyed by file path (not by the ui.Image, which is
                      // recreated on every brightness/contrast/gamma tweak)
                      // so zoom/pan state survives adjustments but resets
                      // when a different file is opened.
                      key: ValueKey(widget.filePath),
                      image: _renderedImage!,
                      scale: _PixelScale.from(_document!.images.first.metadata),
                    ),
                  ),
                if (_renderedImage != null && _rgba != null) ...[
                  const SizedBox(height: 8),
                  _AdjustmentSlider(
                    label: 'Brightness',
                    value: _brightness,
                    min: -100,
                    max: 100,
                    display: _brightness.toStringAsFixed(0),
                    onChanged: (v) {
                      setState(() => _brightness = v);
                      _reapplyAdjustments();
                    },
                  ),
                  _AdjustmentSlider(
                    label: 'Contrast',
                    value: _contrast,
                    min: 0,
                    max: 3,
                    display: _contrast.toStringAsFixed(2),
                    onChanged: (v) {
                      setState(() => _contrast = v);
                      _reapplyAdjustments();
                    },
                  ),
                  _AdjustmentSlider(
                    label: 'Gamma',
                    value: _gamma,
                    min: 0.1,
                    max: 3,
                    display: _gamma.toStringAsFixed(2),
                    onChanged: (v) {
                      setState(() => _gamma = v);
                      _reapplyAdjustments();
                    },
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        setState(() {
                          _brightness = 0;
                          _contrast = 1;
                          _gamma = 1;
                        });
                        _reapplyAdjustments();
                      },
                      child: const Text('Reset'),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                if (_document != null) ...[
                  Tooltip(
                    message: _fullDecodeIsSafe
                        ? ''
                        : 'Disabled: this image is too large to decode at full resolution without risking an out-of-memory crash.',
                    child: FilledButton.icon(
                      onPressed: (_runningWriteTest || !_fullDecodeIsSafe) ? null : _runWriteTest,
                      icon: _runningWriteTest
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save),
                      label: const Text('Round-trip write test (force BigTIFF, Deflate)'),
                    ),
                  ),
                  if (_writeTestResult != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SelectableText(_writeTestResult!),
                    ),
                ],
              ],
            ),
    );
  }

  List<Widget> _buildDocumentInfo(TiffDocument document) {
    return [
      Text('Byte order: ${document.byteOrder.name}, BigTIFF: ${document.isBigTiff}'),
      const Divider(),
      for (var i = 0; i < document.images.length; i++) ...[
        if (document.images.length > 1) Text('Page $i', style: Theme.of(context).textTheme.titleSmall),
        _MetadataTable(metadata: document.images[i].metadata),
        const SizedBox(height: 8),
      ],
    ];
  }
}

/// How many real-world units one image pixel represents, derived from
/// whichever the file provides: GeoTIFF's ModelPixelScale (georeferenced
/// rasters) or the baseline XResolution/YResolution/ResolutionUnit tags
/// (282/283/296). Falls back to plain pixels when neither is present or
/// ResolutionUnit says "no absolute unit" (value 1).
class _PixelScale {
  final double unitsPerPixelX;
  final double unitsPerPixelY;
  final String unitLabel;

  const _PixelScale({required this.unitsPerPixelX, required this.unitsPerPixelY, required this.unitLabel});

  static const pixelsOnly = _PixelScale(unitsPerPixelX: 1, unitsPerPixelY: 1, unitLabel: 'px');

  factory _PixelScale.from(TiffImageMetadata metadata) {
    final pixelScale = metadata.geoTiff?.modelPixelScale;
    if (pixelScale != null && pixelScale.length >= 2 && pixelScale[0] > 0 && pixelScale[1] > 0) {
      final unitCode = metadata.geoTiff!.geoKeys[GeoTiffKeyId.projLinearUnits] ?? metadata.geoTiff!.geoKeys[GeoTiffKeyId.geogAngularUnits];
      return _PixelScale(unitsPerPixelX: pixelScale[0], unitsPerPixelY: pixelScale[1], unitLabel: _geoUnitName(unitCode));
    }

    final xRes = metadata.rawTags[TiffTagId.xResolution]?.asDouble();
    final yRes = metadata.rawTags[TiffTagId.yResolution]?.asDouble();
    final resUnit = metadata.rawTags[TiffTagId.resolutionUnit]?.asInt() ?? 2;
    if (xRes != null && xRes > 0 && resUnit != 1) {
      final label = resUnit == 3 ? 'cm' : 'in';
      return _PixelScale(unitsPerPixelX: 1 / xRes, unitsPerPixelY: (yRes != null && yRes > 0) ? 1 / yRes : 1 / xRes, unitLabel: label);
    }

    return pixelsOnly;
  }

  bool get isPhysical => unitLabel != 'px';

  static String _geoUnitName(Object? code) {
    final intCode = (code is num) ? code.toInt() : null;
    return switch (intCode) {
      9001 => 'm',
      9002 => 'ft',
      9003 => 'ft (US)',
      9036 => 'km',
      9102 => '°',
      null => 'map units',
      _ => 'units($intCode)',
    };
  }
}

/// Pans/zooms [image] via [InteractiveViewer], with a minimap overlay
/// (tap/drag to jump to a spot) and a scale bar computed from [scale].
class _ZoomableTiffImage extends StatefulWidget {
  final ui.Image image;
  final _PixelScale scale;
  const _ZoomableTiffImage({super.key, required this.image, required this.scale});

  @override
  State<_ZoomableTiffImage> createState() => _ZoomableTiffImageState();
}

class _ZoomableTiffImageState extends State<_ZoomableTiffImage> {
  final _controller = TransformationController();
  bool _fitted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _fitToViewport(Size viewportSize) {
    final imageSize = Size(widget.image.width.toDouble(), widget.image.height.toDouble());
    final scale = math.min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height);
    final dx = (viewportSize.width - imageSize.width * scale) / 2;
    final dy = (viewportSize.height - imageSize.height * scale) / 2;
    _controller.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    final imageSize = Size(widget.image.width.toDouble(), widget.image.height.toDouble());
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        if (!_fitted) {
          _fitted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fitToViewport(viewportSize);
          });
        }
        return ClipRect(
          child: Stack(
            children: [
              ColoredBox(
                color: Colors.black12,
                child: InteractiveViewer(
                  transformationController: _controller,
                  minScale: 0.01,
                  maxScale: 40,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: SizedBox(
                    width: imageSize.width,
                    height: imageSize.height,
                    child: RawImage(key: const Key('mainImage'), image: widget.image, width: imageSize.width, height: imageSize.height),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: _RoundIconButton(icon: Icons.fit_screen, tooltip: 'Fit to screen', onPressed: () => _fitToViewport(viewportSize)),
              ),
              Positioned(
                left: 8,
                bottom: 8,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => _ScaleBar(transform: _controller.value, scale: widget.scale),
                ),
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => _Minimap(image: widget.image, controller: _controller, viewportSize: viewportSize),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Same pan/zoom/minimap/scale-bar shell as [_ZoomableTiffImage], but the
/// child is a [_TilePainter] reading live from a [_TileEngine] instead of a
/// single fixed [ui.Image] — see [_TileEngine] for how tiles are chosen and
/// loaded as the viewport changes.
class _TiledZoomableImage extends StatefulWidget {
  final _TileEngine engine;
  final _PixelScale scale;
  const _TiledZoomableImage({super.key, required this.engine, required this.scale});

  @override
  State<_TiledZoomableImage> createState() => _TiledZoomableImageState();
}

class _TiledZoomableImageState extends State<_TiledZoomableImage> {
  final _controller = TransformationController();
  bool _fitted = false;
  Timer? _debounce;
  Size? _viewportSize;

  Size get _baseSize => Size(widget.engine.baseWidth.toDouble(), widget.engine.baseHeight.toDouble());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_scheduleTileUpdate);
    widget.engine.addListener(_onEngineChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_scheduleTileUpdate);
    widget.engine.removeListener(_onEngineChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onEngineChanged() {
    if (!mounted) return;
    setState(() {});
  }

  // Debounced so a fast drag/pinch gesture doesn't fire a tile-recompute
  // (and a decode request) on every intermediate frame — only once motion
  // settles for a moment.
  void _scheduleTileUpdate() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 80), _updateTiles);
  }

  void _updateTiles() {
    final viewport = _viewportSize;
    if (viewport == null) return;
    final inverse = Matrix4.copy(_controller.value)..invert();
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(inverse, Offset(viewport.width, viewport.height));
    final rect = Rect.fromPoints(topLeft, bottomRight).intersect(Offset.zero & _baseSize);
    widget.engine.requestVisible(rect, _controller.value.getMaxScaleOnAxis());
  }

  void _fitToViewport(Size viewportSize) {
    final imageSize = _baseSize;
    final scale = math.min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height);
    final dx = (viewportSize.width - imageSize.width * scale) / 2;
    final dy = (viewportSize.height - imageSize.height * scale) / 2;
    _controller.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    final imageSize = _baseSize;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        _viewportSize = viewportSize;
        if (!_fitted) {
          _fitted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _fitToViewport(viewportSize);
              _updateTiles();
            }
          });
        }
        return ClipRect(
          child: Stack(
            children: [
              ColoredBox(
                color: Colors.black12,
                child: InteractiveViewer(
                  transformationController: _controller,
                  minScale: 0.01,
                  maxScale: 40,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: SizedBox(
                    width: imageSize.width,
                    height: imageSize.height,
                    child: CustomPaint(key: const Key('mainImage'), painter: _TilePainter(widget.engine, imageSize)),
                  ),
                ),
              ),
              if (widget.engine.overview == null) const Center(child: CircularProgressIndicator()),
              if (widget.engine.overview != null && widget.engine.isWorking)
                const Positioned(
                  top: 8,
                  left: 8,
                  child: _WorkingIndicator(),
                ),
              Positioned(
                top: 8,
                right: 8,
                child: _RoundIconButton(icon: Icons.fit_screen, tooltip: 'Fit to screen', onPressed: () => _fitToViewport(viewportSize)),
              ),
              Positioned(
                left: 8,
                bottom: 8,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => _ScaleBar(transform: _controller.value, scale: widget.scale),
                ),
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_controller, widget.engine]),
                  builder: (context, _) => _TiledMinimap(engine: widget.engine, controller: _controller, viewportSize: viewportSize),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Paints the always-present (blurry-until-ready) overview first, then any
/// cached tiles on top, coarsest level to finest — see
/// [_TileEngine.cachedTileEntries]. Repaints automatically whenever [engine]
/// reports new data via [ChangeNotifier], independent of pan/zoom.
class _TilePainter extends CustomPainter {
  final _TileEngine engine;
  final Size baseSize;
  _TilePainter(this.engine, this.baseSize) : super(repaint: engine);

  @override
  void paint(Canvas canvas, Size size) {
    final dstFull = Offset.zero & baseSize;
    final overview = engine.overview;
    if (overview != null) {
      final src = Rect.fromLTWH(0, 0, overview.width.toDouble(), overview.height.toDouble());
      canvas.drawImageRect(overview, src, dstFull, Paint());
    } else {
      canvas.drawRect(dstFull, Paint()..color = const Color(0xFF1A1A1A));
    }

    for (final (levelIndex, tx, ty, image) in engine.cachedTileEntries()) {
      final level = engine.levels[levelIndex];
      final ratio = engine.baseWidth / level.width;
      final x = tx * level.tileWidth;
      final y = ty * level.tileLength;
      final w = math.min(level.tileWidth, level.width - x);
      final h = math.min(level.tileLength, level.height - y);
      final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
      final dst = Rect.fromLTWH(x * ratio, y * ratio, w * ratio, h * ratio);
      canvas.drawImageRect(image, src, dst, Paint());
    }
  }

  @override
  bool shouldRepaint(covariant _TilePainter oldDelegate) => oldDelegate.engine != engine || oldDelegate.baseSize != baseSize;
}

class _WorkingIndicator extends StatelessWidget {
  const _WorkingIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)),
          SizedBox(width: 8),
          Text('Đang tải nét...', style: TextStyle(color: Colors.white, fontSize: 11)),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  const _RoundIconButton({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: IconButton(icon: Icon(icon, color: Colors.white, size: 20), tooltip: tooltip, onPressed: onPressed),
    );
  }
}

/// Small overview of the whole image with a rectangle marking the area
/// currently visible in the main viewer; tap or drag on it to jump there.
class _Minimap extends StatelessWidget {
  static const _boxSize = Size(140, 100);

  final ui.Image image;
  final TransformationController controller;
  final Size viewportSize;

  const _Minimap({required this.image, required this.controller, required this.viewportSize});

  Rect _visibleImageRect() {
    final inverse = Matrix4.copy(controller.value)..invert();
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(inverse, Offset(viewportSize.width, viewportSize.height));
    final rect = Rect.fromPoints(topLeft, bottomRight);
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    return Rect.fromLTRB(rect.left.clamp(0.0, w), rect.top.clamp(0.0, h), rect.right.clamp(0.0, w), rect.bottom.clamp(0.0, h));
  }

  void _navigateTo(Offset imagePoint) {
    final scale = controller.value.getMaxScaleOnAxis();
    final dx = viewportSize.width / 2 - imagePoint.dx * scale;
    final dy = viewportSize.height / 2 - imagePoint.dy * scale;
    controller.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    return Container(
      width: _boxSize.width,
      height: _boxSize.height,
      decoration: BoxDecoration(border: Border.all(color: Colors.white70), color: Colors.black45),
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: w,
          height: h,
          child: GestureDetector(
            onTapUp: (d) => _navigateTo(d.localPosition),
            onPanUpdate: (d) => _navigateTo(d.localPosition),
            child: Stack(
              children: [
                RawImage(image: image, width: w, height: h),
                CustomPaint(size: Size(w, h), painter: _ViewportRectPainter(_visibleImageRect())),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Minimap for the tiled viewer: same behavior as [_Minimap], but draws
/// [_TileEngine.overview] (cheap, always sized to the base image's aspect
/// ratio) rather than a single full-resolution [ui.Image].
class _TiledMinimap extends StatelessWidget {
  static const _boxSize = Size(140, 100);

  final _TileEngine engine;
  final TransformationController controller;
  final Size viewportSize;

  const _TiledMinimap({required this.engine, required this.controller, required this.viewportSize});

  Rect _visibleImageRect(Size baseSize) {
    final inverse = Matrix4.copy(controller.value)..invert();
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(inverse, Offset(viewportSize.width, viewportSize.height));
    final rect = Rect.fromPoints(topLeft, bottomRight);
    return Rect.fromLTRB(
      rect.left.clamp(0.0, baseSize.width),
      rect.top.clamp(0.0, baseSize.height),
      rect.right.clamp(0.0, baseSize.width),
      rect.bottom.clamp(0.0, baseSize.height),
    );
  }

  void _navigateTo(Offset imagePoint) {
    final scale = controller.value.getMaxScaleOnAxis();
    final dx = viewportSize.width / 2 - imagePoint.dx * scale;
    final dy = viewportSize.height / 2 - imagePoint.dy * scale;
    controller.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    final baseSize = Size(engine.baseWidth.toDouble(), engine.baseHeight.toDouble());
    final overview = engine.overview;
    return Container(
      width: _boxSize.width,
      height: _boxSize.height,
      decoration: BoxDecoration(border: Border.all(color: Colors.white70), color: Colors.black45),
      child: overview == null
          ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)))
          : FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: baseSize.width,
                height: baseSize.height,
                child: GestureDetector(
                  onTapUp: (d) => _navigateTo(d.localPosition),
                  onPanUpdate: (d) => _navigateTo(d.localPosition),
                  child: Stack(
                    children: [
                      SizedBox(width: baseSize.width, height: baseSize.height, child: RawImage(image: overview, width: baseSize.width, height: baseSize.height)),
                      CustomPaint(size: baseSize, painter: _ViewportRectPainter(_visibleImageRect(baseSize))),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _ViewportRectPainter extends CustomPainter {
  final Rect rect;
  _ViewportRectPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = (size.longestSide / 150).clamp(1.0, 40.0);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _ViewportRectPainter oldDelegate) => oldDelegate.rect != rect;
}

/// A scale bar (like on a map) showing what a "nice" round length on screen
/// represents in the file's real-world unit, plus the current zoom percent.
class _ScaleBar extends StatelessWidget {
  final Matrix4 transform;
  final _PixelScale scale;
  const _ScaleBar({required this.transform, required this.scale});

  static const _maxBarWidth = 110.0;

  (double, double) _pickBarLength(double realUnitPerScreenPixel) {
    if (realUnitPerScreenPixel <= 0 || !realUnitPerScreenPixel.isFinite) return (0, 0);
    final maxReal = _maxBarWidth * realUnitPerScreenPixel;
    if (maxReal <= 0 || !maxReal.isFinite) return (0, 0);
    final exp = (math.log(maxReal) / math.ln10).floor();
    var best = math.pow(10, exp).toDouble();
    for (final m in [1, 2, 5, 10]) {
      final candidate = m * math.pow(10, exp).toDouble();
      if (candidate <= maxReal) best = candidate.toDouble();
    }
    return (best, best / realUnitPerScreenPixel);
  }

  String _formatLength(double length) {
    final text = length >= 100
        ? length.toStringAsFixed(0)
        : length >= 1
        ? (length.truncateToDouble() == length ? length.toStringAsFixed(0) : length.toStringAsFixed(1))
        : length.toStringAsFixed(3);
    return '$text ${scale.unitLabel}';
  }

  @override
  Widget build(BuildContext context) {
    final zoom = transform.getMaxScaleOnAxis();
    final (length, barWidth) = _pickBarLength(scale.unitsPerPixelX / zoom);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${(zoom * 100).toStringAsFixed(0)}%', style: const TextStyle(color: Colors.white, fontSize: 11)),
          if (barWidth > 0) ...[
            const SizedBox(height: 4),
            CustomPaint(size: Size(barWidth, 8), painter: _ScaleBarPainter()),
            const SizedBox(height: 2),
            Text(_formatLength(length), style: const TextStyle(color: Colors.white, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

class _ScaleBarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), paint);
    canvas.drawLine(const Offset(0, 0), Offset(0, size.height), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _ScaleBarPainter oldDelegate) => false;
}

class _MetadataTable extends StatelessWidget {
  final TiffImageMetadata metadata;
  const _MetadataTable({required this.metadata});

  @override
  Widget build(BuildContext context) {
    final scale = _PixelScale.from(metadata);
    final rows = <(String, String)>[
      ('Dimensions', '${metadata.width} x ${metadata.height}'),
      ('Samples/pixel', '${metadata.samplesPerPixel}'),
      ('Bits/sample', '${metadata.bitsPerSample}'),
      ('Compression', '${metadata.compression} (${_compressionName(metadata.compression)})'),
      ('Photometric', metadata.photometric?.name ?? '(missing)'),
      ('Predictor', '${metadata.predictor}'),
      ('Layout', metadata.isTiled ? 'tiled (${metadata.tileWidth}x${metadata.tileLength})' : 'strips (${metadata.rowsPerStrip} rows/strip)'),
      (
        'Physical scale',
        scale.isPhysical ? '${scale.unitsPerPixelX} x ${scale.unitsPerPixelY} ${scale.unitLabel}/px' : '(none — pixels only)',
      ),
      if (metadata.colorMap != null) ('ColorMap', '${metadata.colorMap!.length} entries'),
      if (metadata.geoTiff != null) ('GeoTIFF', 'present (${metadata.geoTiff!.geoKeys.length} GeoKeys)'),
      if (metadata.exifTags != null) ('EXIF', '${metadata.exifTags!.length} tags'),
      if (metadata.gpsTags != null) ('GPS', '${metadata.gpsTags!.length} tags'),
    ];
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      children: [
        for (final (label, value) in rows)
          TableRow(
            children: [
              Padding(padding: const EdgeInsets.only(right: 12, bottom: 4), child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(value)),
            ],
          ),
      ],
    );
  }

  static String _compressionName(int code) => switch (code) {
    1 => 'None',
    2 => 'CCITT Group 3 1D',
    3 => 'CCITT Group 3 2D',
    4 => 'CCITT Group 4',
    5 => 'LZW',
    6 => 'Old JPEG',
    7 => 'JPEG',
    8 => 'Deflate/ZIP',
    32773 => 'PackBits',
    32946 => 'Deflate/ZIP (Adobe)',
    _ => 'unknown',
  };
}

class _AdjustmentSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  const _AdjustmentSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(child: Slider(value: value, min: min, max: max, onChanged: onChanged)),
        SizedBox(width: 48, child: Text(display, textAlign: TextAlign.end)),
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String title;
  final Object error;
  const _ErrorCard({required this.title, required this.error});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('$error'),
          ],
        ),
      ),
    );
  }
}
