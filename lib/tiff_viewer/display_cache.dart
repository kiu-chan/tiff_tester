part of '../tiff_viewer_page.dart';

/// Progress reported by [_DisplayCache.build] as it works — mirrors
/// [TiffOptimizeProgress]'s shape (concrete counts plus a fraction), but in
/// terms of bands rather than pyramid rungs.
typedef _CacheBuildProgress = ({int completedBands, int totalBands, double fraction});

/// A per-file, on-disk cache of already-decoded RGBA8 bands (plus a small
/// overview), private to this app — see [_RegionEngine]'s cache-backed
/// mode, which reads it directly with plain file reads instead of spawning
/// a decode isolate.
///
/// Unlike `TiffDisplayOptimizer` (which produces a portable, standalone
/// tiled/pyramided TIFF that opens in any viewer and that the user manages
/// as a real file), this cache is invisible: it lives under the OS temp
/// directory, nothing but [_RegionEngine] ever reads it, and it's
/// invalidated automatically the moment the source file's size or
/// modification time changes — no manual cleanup or "does this still match
/// the source" bookkeeping needed.
class _DisplayCache {
  final Directory dir;
  final int width;
  final int height;
  final int bandHeight;
  final int bandCount;

  const _DisplayCache._({
    required this.dir,
    required this.width,
    required this.height,
    required this.bandHeight,
    required this.bandCount,
  });

  static const _manifestVersion = 1;

  static Future<Directory> _rootDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/tiff_tester_display_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _dirFor(String sourcePath, int sourceSize, int sourceModifiedMillis) async {
    final root = await _rootDir();
    final key = _fnv1a64Hex('$sourcePath|$sourceSize|$sourceModifiedMillis');
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
    final dir = await _dirFor(filePath, stat.size, stat.modified.millisecondsSinceEpoch);
    return _openDir(dir);
  }

  static Future<_DisplayCache?> _openDir(Directory dir) async {
    final manifestFile = File('${dir.path}/manifest.json');
    if (!await manifestFile.exists()) return null;
    try {
      final manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      if (manifest['version'] != _manifestVersion) return null;
      return _DisplayCache._(
        dir: dir,
        width: manifest['width'] as int,
        height: manifest['height'] as int,
        bandHeight: manifest['bandHeight'] as int,
        bandCount: manifest['bandCount'] as int,
      );
    } catch (_) {
      // Corrupt/partial manifest — treat exactly like "no cache".
      return null;
    }
  }

  /// Resolves the cache directory path for [filePath] — a plain string, so
  /// it can be handed to a background isolate (see [build]'s doc comment
  /// for why that matters) instead of a [Directory] tied to this isolate's
  /// platform-channel state.
  static Future<String> resolveDirPath(String filePath) async {
    final stat = await File(filePath).stat();
    final dir = await _dirFor(filePath, stat.size, stat.modified.millisecondsSinceEpoch);
    return dir.path;
  }

  /// Decodes every band of [page] (plus an overview) and writes them into a
  /// fresh cache directory at [dirPath] (see [resolveDirPath]), reporting
  /// concrete "band N of M" progress via [onProgress] as each one finishes.
  /// Safe to call for a page too large to decode whole at once: the actual
  /// per-band decoding is `package:tiff`'s own `TiffParallelDecoder`
  /// (`package:tiff/tiff_io.dart`), spread across a handful of worker
  /// isolates rather than done here one band at a time on a single core —
  /// this app only decides *how much* memory/how many workers that's
  /// allowed to use (see [_buildMemoryCapBytes]/[_workerCount] below),
  /// which is exactly the budget/worker-count parameters
  /// `TiffParallelDecoder.decodeBanded` takes as explicit arguments rather
  /// than guessing at itself.
  ///
  /// [filePath] is needed alongside [page] because the actual decoding
  /// happens in separate worker isolates, each with its own freshly opened
  /// file handle — a [TiffImage] itself can't cross an isolate boundary.
  /// [dirPath] must already be resolved by the caller via [resolveDirPath]
  /// rather than derived here from [filePath] directly — [build] is meant
  /// to run inside a background isolate (see [_cacheBuildIsolateEntry]),
  /// where a plugin call like `getTemporaryDirectory()` (which
  /// [resolveDirPath] needs) has no platform channel to talk to and would
  /// just hang.
  ///
  /// The manifest is written last, so a build interrupted partway (app
  /// killed, disk full, decode error) never leaves behind something [open]
  /// treats as valid — the next attempt just starts over from scratch.
  static Future<void> build(
    TiffImage page,
    String filePath,
    String dirPath, {
    void Function(_CacheBuildProgress)? onProgress,
  }) async {
    final dir = Directory(dirPath);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    final metadata = page.metadata;
    final bandHeight = _RegionEngine._computeBandHeight(metadata);
    final bandCount = (metadata.height + bandHeight - 1) ~/ bandHeight;

    final (overviewRgba, overviewWidth, overviewHeight) = _decodePreviewRgba(page);
    await File('${dir.path}/overview.rgba').writeAsBytes(overviewRgba);
    await File('${dir.path}/overview.meta').writeAsString('$overviewWidth,$overviewHeight');

    // This app's own choice of memory budget (see _MemoryMonitor) and
    // worker count — package:tiff's TiffChunkPlan/TiffParallelDecoder take
    // both as plain parameters and do no memory-reading or CPU-detection
    // of their own. maxBytesPerChunk is deliberately the *aggregate*
    // budget, not divided by worker count: TiffChunkPlan picks chunk size
    // first (tile/strip-aligned, to avoid TiffImage.decodeRegionRgba8
    // redecoding the same underlying chunk once per band it overlaps), and
    // recommendedWorkerCount derives how many such chunks can run at once
    // within that same budget afterward — dividing the budget by worker
    // count instead would shrink chunks below one tile/strip and
    // reintroduce that redundant-redecode problem for a page whose tiles
    // are large relative to the budget (a real whole-slide-image file,
    // easily).
    final aggregateBudgetBytes = _buildMemoryCapBytes();
    final chunkPlan = TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: aggregateBudgetBytes);
    final workerCount = TiffChunkPlan.recommendedWorkerCount(
      bytesPerChunk: chunkPlan.bytesPerChunk,
      aggregateBudgetBytes: aggregateBudgetBytes,
      cpuCount: math.max(1, math.min(4, Platform.numberOfProcessors - 1)),
    );

    var completedBands = 0;
    await TiffParallelDecoder.decodeBanded(
      filePath: filePath,
      pageIndex: 0,
      bandHeight: bandHeight,
      maxBytesPerChunk: aggregateBudgetBytes,
      workerCount: workerCount,
      setUpIsolate: TiffImageAdapter.enableJpegSupport,
      onBand: (band) {
        File('${dir.path}/band_${band.y ~/ bandHeight}.rgba').writeAsBytesSync(band.rgba);
        completedBands++;
        onProgress?.call((completedBands: completedBands, totalBands: bandCount, fraction: completedBands / bandCount));
      },
    );

    await File('${dir.path}/manifest.json').writeAsString(
      jsonEncode({
        'version': _manifestVersion,
        'width': metadata.width,
        'height': metadata.height,
        'bandHeight': bandHeight,
        'bandCount': bandCount,
      }),
    );
  }

  /// Aggregate ceiling for [build]'s decode work — see the class doc
  /// comment on [_MemoryMonitor] for what "aggregate" means here (the sum
  /// across every concurrently-running chunk, not a per-chunk number). A
  /// one-off build gets a much bigger slice of the budget than the
  /// interactive viewing paths (75% vs. a few percent) — it isn't sharing
  /// that memory with a live view at the same time, and the whole point is
  /// getting as close to one-decode-per-tile-row as headroom allows.
  static int _buildMemoryCapBytes() => _MemoryMonitor.budgetFor(
    fraction: 0.75,
    minBytes: 64 * 1024 * 1024,
    maxBytes: 768 * 1024 * 1024,
  );

  Future<Uint8List> readOverview() => File('${dir.path}/overview.rgba').readAsBytes();

  Future<(int, int)> readOverviewSize() async {
    final parts = (await File('${dir.path}/overview.meta').readAsString()).split(',');
    return (int.parse(parts[0]), int.parse(parts[1]));
  }

  Future<Uint8List> readBand(int index) => File('${dir.path}/band_$index.rgba').readAsBytes();
}

/// A small, deterministic (not cryptographic) hash used only to turn a
/// source file path into a safe, fixed-length cache directory name — paths
/// themselves can contain characters that aren't valid in a directory name
/// on every platform.
String _fnv1a64Hex(String input) {
  const prime = 0x100000001b3;
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(input)) {
    hash = (hash ^ byte) & 0xFFFFFFFFFFFFFFFF;
    hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
