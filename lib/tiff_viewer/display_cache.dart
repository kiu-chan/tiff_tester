part of '../tiff_viewer_page.dart';

/// Progress reported by [_DisplayCache.build] as it works — mirrors
/// [TiffOptimizeProgress]'s shape (concrete counts plus a fraction), but in
/// terms of bands rather than pyramid rungs.
typedef _CacheBuildProgress = ({int completedBands, int totalBands, double fraction});

/// How [_DisplayCache.build] stores each band on disk — a size/fidelity
/// trade-off the caller picks, not something this class decides on its own.
/// Every format still hands [_DisplayCache.readBand]/[readOverview]'s caller
/// back plain RGBA8 either way; only what's actually written to disk (and
/// how much space it takes) differs.
enum _DisplayCacheFormat {
  /// Raw, uncompressed RGBA8 — exactly what a decode produces, written
  /// as-is. Largest on disk (4 bytes/pixel, no compression at all) but
  /// cheapest to read back (a plain file read, no decompression step).
  rawRgba,

  /// Alpha dropped (every source page here is fully opaque — see
  /// [_dropAlpha]) and the remaining RGB bytes compressed with `dart:io`'s
  /// built-in Deflate (`ZLibCodec`) — lossless, so pixels read back
  /// bit-for-bit identical to a live decode, typically 2-4x smaller than
  /// [rawRgba] for photographic content. Reading costs a fast inflate pass.
  deflateRgb,

  /// Each band re-encoded as a JPEG (`package:image`, 4:2:0 chroma
  /// subsampling to match how a real whole-slide-image scanner's own JPEG
  /// tiles are usually subsampled) — lossy, and stacked on top of the
  /// source's own JPEG compression if it was JPEG-compressed to begin with,
  /// but by far the smallest on disk (comparable to the source file itself
  /// rather than a multiple of it). Reading costs a full JPEG decode.
  jpeg;

  String get _fileExtension => switch (this) {
    _DisplayCacheFormat.rawRgba => 'rgba',
    _DisplayCacheFormat.deflateRgb => 'rgb.zz',
    _DisplayCacheFormat.jpeg => 'jpg',
  };
}

/// A per-file, on-disk cache of already-decoded pixel bands (plus a small
/// overview), private to this app — see [_RegionEngine]'s cache-backed
/// mode, which reads it directly with plain file reads (plus, for
/// [_DisplayCacheFormat.deflateRgb]/[_DisplayCacheFormat.jpeg], a decode
/// step — see [_decodeStoredBand]) instead of spawning a decode isolate.
///
/// Unlike `TiffDisplayOptimizer` (which produces a portable, standalone
/// tiled/pyramided TIFF that opens in any *other* viewer too), this cache's
/// format is private to this app — but it deliberately lives as a plain,
/// visible `<source file>.tiffcache` directory *next to* the source file
/// (see [_dirFor]) rather than hidden in the OS temp directory, so the user
/// can actually see how much space it's using. It's still invalidated
/// automatically the moment the source file's size or modification time
/// changes (checked against [manifestVersion]'s `sourceSize`/
/// `sourceModifiedMillis`, not encoded into the directory name the way an
/// invisible temp-dir cache could) — no manual cleanup or "does this still
/// match the source" bookkeeping needed.
class _DisplayCache {
  final Directory dir;
  final int width;
  final int height;
  final int bandHeight;
  final int bandCount;
  final _DisplayCacheFormat format;
  final int cacheSizeBytes;

  const _DisplayCache._({
    required this.dir,
    required this.width,
    required this.height,
    required this.bandHeight,
    required this.bandCount,
    required this.format,
    required this.cacheSizeBytes,
  });

  static const _manifestVersion = 2;

  static Future<Directory> _tempRootDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/tiff_tester_display_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// The sibling directory this app always tries first: `<filePath>.tiffcache`,
  /// right next to the source file — easy for the user to find and to see
  /// the size of, unlike a hash-named directory buried in the OS temp dir.
  static Directory _siblingDir(String filePath) => Directory('$filePath.tiffcache');

  /// Falls back here (a directory under the OS temp dir, keyed by a hash of
  /// [filePath] since nothing here encodes it into a name) only when
  /// [_siblingDir] can't be created/written — [filePath] sits on a read-only
  /// volume, or inside a read-only app-bundle asset directory.
  static Future<Directory> _fallbackDir(String filePath) async {
    final root = await _tempRootDir();
    final key = _fnv1a64Hex(filePath);
    return Directory('${root.path}/$key');
  }

  /// Opens the existing, still-valid cache for [filePath], or `null` if
  /// there isn't one — never built, built for a different version of the
  /// file (different size or modification time), or a build that was
  /// interrupted before it finished (see [build]).
  static Future<_DisplayCache?> open(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    final sourceSize = stat.size;
    final sourceModifiedMillis = stat.modified.millisecondsSinceEpoch;

    final fromSibling = await _openDir(_siblingDir(filePath), sourceSize, sourceModifiedMillis);
    if (fromSibling != null) return fromSibling;
    return _openDir(await _fallbackDir(filePath), sourceSize, sourceModifiedMillis);
  }

  static Future<_DisplayCache?> _openDir(Directory dir, int sourceSize, int sourceModifiedMillis) async {
    final manifestFile = File('${dir.path}/manifest.json');
    if (!await manifestFile.exists()) return null;
    try {
      final manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      if (manifest['version'] != _manifestVersion) return null;
      if (manifest['sourceSize'] != sourceSize || manifest['sourceModifiedMillis'] != sourceModifiedMillis) {
        return null;
      }
      return _DisplayCache._(
        dir: dir,
        width: manifest['width'] as int,
        height: manifest['height'] as int,
        bandHeight: manifest['bandHeight'] as int,
        bandCount: manifest['bandCount'] as int,
        format: _DisplayCacheFormat.values.byName(manifest['format'] as String),
        cacheSizeBytes: manifest['cacheSizeBytes'] as int,
      );
    } catch (_) {
      // Corrupt/partial manifest, or an unrecognized format name (e.g. a
      // newer cache read by an older build of this app) — treat exactly
      // like "no cache".
      return null;
    }
  }

  /// Resolves the cache directory to actually build into for [filePath] —
  /// [_siblingDir] if this app can create/write there, [_fallbackDir]
  /// otherwise. Resolved once, on the caller's (platform-channel-capable)
  /// isolate, and the resulting plain path string handed to [build] — see
  /// [build]'s doc comment for why the directory can't be resolved (or
  /// created, for the [_fallbackDir] case, which needs `getTemporaryDirectory()`)
  /// from inside the background isolate that actually calls it.
  static Future<String> resolveDirPath(String filePath) async {
    final sibling = _siblingDir(filePath);
    try {
      await sibling.create(recursive: true);
      return sibling.path;
    } catch (_) {
      final fallback = await _fallbackDir(filePath);
      return fallback.path;
    }
  }

  /// Decodes every band of [page] (plus an overview) and writes them into a
  /// fresh cache directory at [dirPath] (see [resolveDirPath]), reporting
  /// concrete "band N of M" progress via [onProgress] as each one finishes.
  /// Safe to call for a page too large to decode whole at once: the actual
  /// per-band decoding is `package:tiff`'s own `TiffParallelDecoder`
  /// (`package:tiff/tiff_io.dart`), spread across a handful of worker
  /// isolates rather than done here one band at a time on a single core —
  /// how much memory/how many workers that's allowed to use is picked by
  /// `package:tiff`'s own `TiffAutoDecodeBudget.recommend` (reading actual
  /// idle system memory and CPU count), not guessed by this app.
  ///
  /// [format]/[jpegQuality] pick how each band is stored — see
  /// [_DisplayCacheFormat]. Encoding (for [_DisplayCacheFormat.deflateRgb]/
  /// [_DisplayCacheFormat.jpeg]) happens here, on this same build isolate,
  /// as each band arrives — one band at a time, not parallelized the way
  /// the underlying TIFF decode is, so a slower format adds to this
  /// method's total wall time roughly in proportion to how many bands there
  /// are.
  ///
  /// [filePath] is needed alongside [page] because the actual decoding
  /// happens in separate worker isolates, each with its own freshly opened
  /// file handle — a [TiffImage] itself can't cross an isolate boundary.
  /// [dirPath] must already be resolved by the caller via [resolveDirPath]
  /// rather than derived here from [filePath] directly — [build] is meant
  /// to run inside a background isolate (see [_cacheBuildIsolateEntry]),
  /// where a plugin call like `getTemporaryDirectory()` (which
  /// [resolveDirPath] needs for its fallback) has no platform channel to
  /// talk to and would just hang.
  ///
  /// The manifest is written last, so a build interrupted partway (app
  /// killed, disk full, decode error) never leaves behind something [open]
  /// treats as valid — the next attempt just starts over from scratch.
  ///
  /// Delivery granularity for [build] — deliberately *not*
  /// [_RegionEngine._computeBandHeight]/[_RegionEngine._bandTargetBytes],
  /// which target a single low-latency *live* decode request during
  /// interactive panning (capped at a few MiB — a handful of rows for a
  /// wide whole-slide-image page). Reusing that here meant a real WSI page
  /// turned into tens of thousands of separate 1-2-row bands, each its own
  /// file write — and, once [_encodeStoredBand] could mean a full JPEG (or
  /// Deflate) encode per band rather than a raw memcpy, tens of thousands
  /// of encode calls' fixed overhead came to dominate completely, which is
  /// what made building a compressed cache look hung rather than merely
  /// slow. A one-off batch build wants the opposite of the live path's
  /// tuning: as few, as large bands as reasonably fit in memory. This
  /// doesn't risk more peak memory than before — [TiffParallelDecoder
  /// .decodeBanded] still bounds the actual in-flight decode size via its
  /// own chunk sizing ([TiffAutoDecodeBudget]); a bigger [bandHeight] here
  /// only means slicing an already memory-bounded chunk into fewer pieces
  /// before each is written, not decoding more at once.
  static int _computeBuildBandHeight(TiffImageMetadata m) {
    final targetBytes = _MemoryMonitor.budgetFor(
      fraction: 0.05,
      minBytes: 16 * 1024 * 1024,
      maxBytes: 256 * 1024 * 1024,
    );
    return math.max(1, math.min(m.height, targetBytes ~/ (m.width * 4)));
  }

  static Future<void> build(
    TiffImage page,
    String filePath,
    String dirPath, {
    _DisplayCacheFormat format = _DisplayCacheFormat.rawRgba,
    int jpegQuality = 85,
    void Function(_CacheBuildProgress)? onProgress,
  }) async {
    final dir = Directory(dirPath);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    final metadata = page.metadata;
    final bandHeight = _computeBuildBandHeight(metadata);
    final bandCount = (metadata.height + bandHeight - 1) ~/ bandHeight;
    var cacheSizeBytes = 0;

    final (overviewRgba, overviewWidth, overviewHeight) = _decodePreviewRgba(page);
    final encodedOverview = _encodeStoredBand(
      rgba: overviewRgba,
      width: overviewWidth,
      height: overviewHeight,
      format: format,
      jpegQuality: jpegQuality,
    );
    await File('${dir.path}/overview.${format._fileExtension}').writeAsBytes(encodedOverview);
    await File('${dir.path}/overview.meta').writeAsString('$overviewWidth,$overviewHeight');
    cacheSizeBytes += encodedOverview.length;

    // package:tiff picks its own chunk/worker sizing here (via
    // TiffAutoDecodeBudget), reading actual idle system memory and CPU
    // count rather than this app guessing a fixed number — see that
    // class's doc comment for why a fixed number is always either too
    // small (leaves a big multi-core machine mostly idle) or too large
    // (risks the exact kind of system-wide low-memory situation
    // TiffAutoDecodeBudget's reserve/double-buffer margins exist to avoid).
    // Left at the library default rather than pushed higher here: a
    // "one-off build has the machine to itself" assumption doesn't hold on
    // a real dev machine already running a browser/IDE/etc. alongside it.
    final budget = TiffAutoDecodeBudget.recommend(metadata);

    var completedBands = 0;
    await TiffParallelDecoder.decodeBanded(
      filePath: filePath,
      pageIndex: 0,
      bandHeight: bandHeight,
      maxBytesPerChunk: budget.maxBytesPerChunk,
      workerCount: budget.workerCount,
      setUpIsolate: TiffImageAdapter.enableJpegSupport,
      onBand: (band) {
        final encoded = _encodeStoredBand(
          rgba: band.rgba,
          width: metadata.width,
          height: band.height,
          format: format,
          jpegQuality: jpegQuality,
        );
        File('${dir.path}/band_${band.y ~/ bandHeight}.${format._fileExtension}').writeAsBytesSync(encoded);
        cacheSizeBytes += encoded.length;
        completedBands++;
        onProgress?.call((completedBands: completedBands, totalBands: bandCount, fraction: completedBands / bandCount));
      },
    );

    final sourceStat = await File(filePath).stat();
    await File('${dir.path}/manifest.json').writeAsString(
      jsonEncode({
        'version': _manifestVersion,
        'sourceSize': sourceStat.size,
        'sourceModifiedMillis': sourceStat.modified.millisecondsSinceEpoch,
        'width': metadata.width,
        'height': metadata.height,
        'bandHeight': bandHeight,
        'bandCount': bandCount,
        'format': format.name,
        'cacheSizeBytes': cacheSizeBytes,
      }),
    );
  }

  Future<Uint8List> readOverview() async {
    final stored = await File('${dir.path}/overview.${format._fileExtension}').readAsBytes();
    return _decodeStoredBand(stored: stored, format: format);
  }

  Future<(int, int)> readOverviewSize() async {
    final parts = (await File('${dir.path}/overview.meta').readAsString()).split(',');
    return (int.parse(parts[0]), int.parse(parts[1]));
  }

  Future<Uint8List> readBand(int index) async {
    final stored = await File('${dir.path}/band_$index.${format._fileExtension}').readAsBytes();
    return _decodeStoredBand(stored: stored, format: format);
  }
}

/// Encodes one decoded RGBA8 band/overview for on-disk storage per
/// [format] — see [_DisplayCacheFormat] for what each one trades off.
Uint8List _encodeStoredBand({
  required Uint8List rgba,
  required int width,
  required int height,
  required _DisplayCacheFormat format,
  required int jpegQuality,
}) {
  switch (format) {
    case _DisplayCacheFormat.rawRgba:
      return rgba;
    case _DisplayCacheFormat.deflateRgb:
      return Uint8List.fromList(ZLibEncoder().convert(_dropAlpha(rgba)));
    case _DisplayCacheFormat.jpeg:
      final image = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgba.buffer,
        bytesOffset: rgba.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      return img.encodeJpg(image, quality: jpegQuality, chroma: img.JpegChroma.yuv420);
  }
}

/// Reverses [_encodeStoredBand] — always hands back plain RGBA8, regardless
/// of [format], so [_DisplayCache]'s own callers never need to know which
/// format a given cache was built with. No width/height needed here (unlike
/// [_encodeStoredBand]): [_DisplayCacheFormat.jpeg] bytes self-describe
/// their own dimensions, and the other two formats round-trip [stored]'s
/// exact byte count.
Uint8List _decodeStoredBand({required Uint8List stored, required _DisplayCacheFormat format}) {
  switch (format) {
    case _DisplayCacheFormat.rawRgba:
      return stored;
    case _DisplayCacheFormat.deflateRgb:
      final rgb = Uint8List.fromList(ZLibDecoder().convert(stored));
      return _addOpaqueAlpha(rgb);
    case _DisplayCacheFormat.jpeg:
      final image = img.decodeJpg(stored);
      if (image == null) {
        throw const FormatException('Failed to decode a cached JPEG band');
      }
      return image.getBytes(order: img.ChannelOrder.rgba);
  }
}

/// Every page this cache stores is fully opaque (package:tiff's RGBA8
/// decode only ever produces alpha < 255 for a source with a real alpha
/// channel — not the case for any whole-slide-image/photographic TIFF this
/// cache targets), so dropping it before compressing loses nothing and
/// cuts the [_DisplayCacheFormat.deflateRgb] payload by a quarter before
/// Deflate even runs on it.
Uint8List _dropAlpha(Uint8List rgba) {
  final rgb = Uint8List(rgba.length ~/ 4 * 3);
  var o = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    rgb[o++] = rgba[i];
    rgb[o++] = rgba[i + 1];
    rgb[o++] = rgba[i + 2];
  }
  return rgb;
}

/// Reverses [_dropAlpha] — every pixel is fully opaque going back in, same
/// as it was before it was dropped.
Uint8List _addOpaqueAlpha(Uint8List rgb) {
  final rgba = Uint8List(rgb.length ~/ 3 * 4);
  var o = 0;
  for (var i = 0; i < rgb.length; i += 3) {
    rgba[o++] = rgb[i];
    rgba[o++] = rgb[i + 1];
    rgba[o++] = rgb[i + 2];
    rgba[o++] = 255;
  }
  return rgba;
}

/// A small, deterministic (not cryptographic) hash used only to turn a
/// source file path into a safe, fixed-length cache directory name for
/// [_DisplayCache._fallbackDir] — paths themselves can contain characters
/// that aren't valid in a directory name on every platform.
String _fnv1a64Hex(String input) {
  const prime = 0x100000001b3;
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(input)) {
    hash = (hash ^ byte) & 0xFFFFFFFFFFFFFFFF;
    hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
