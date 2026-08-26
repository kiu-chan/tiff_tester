part of '../tiff_viewer_page.dart';

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
