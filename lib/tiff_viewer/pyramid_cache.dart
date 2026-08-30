part of '../tiff_viewer_page.dart';

/// A small, disposable sidecar cache of *extra* pyramid rungs for a tiled
/// source page that doesn't already carry its own multi-resolution pyramid
/// (see [_buildPyramidLevels]) — built via `package:tiff`'s
/// `TiffOptimizationMode.pyramidLevelsOnly` so only the smaller rungs are
/// ever written, never a duplicate of the (often huge) base resolution the
/// source file already serves directly by itself. Unlike
/// [TiffDisplayOptimizer]'s `tiledPyramid`/`tiledOnly` modes (a portable
/// standalone TIFF the user saves and manages), this never touches or
/// duplicates the source file's own base resolution — [_openPreview] picks
/// it up automatically next time this same file is opened, exactly like
/// [_DisplayCache].
///
/// Deliberately lives in its *own* sibling directory (`<filePath>.pyramidcache`,
/// see [_siblingDir]) rather than sharing [_DisplayCache]'s `.tiffcache` one:
/// [_DisplayCache.build] unconditionally deletes and recreates its whole
/// directory on every rebuild, so a shared directory would mean building one
/// cache silently wipes out the other whenever it happened to run second.
/// Keeping them fully separate means either cache can be built, rebuilt, or
/// missing with zero coordination between the two.
class _PyramidCache {
  final Directory dir;
  final String levelsFilePath;
  final int tileSize;
  final int minPyramidDimension;
  final int levelCount;

  const _PyramidCache._({
    required this.dir,
    required this.levelsFilePath,
    required this.tileSize,
    required this.minPyramidDimension,
    required this.levelCount,
  });

  static const _manifestVersion = 1;
  static const _manifestFileName = 'manifest.json';
  static const _levelsFileName = 'levels.tif';

  /// The sibling directory this app always tries first: `<filePath>.pyramidcache`,
  /// right next to the source file — same reasoning as
  /// [_DisplayCache._siblingDir], just a distinct suffix so the two caches
  /// never share (and can't clobber) a directory.
  static Directory _siblingDir(String filePath) => Directory('$filePath.pyramidcache');

  static Future<Directory> _tempRootDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/tiff_tester_pyramid_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Falls back here (a directory under the OS temp dir, keyed by a hash of
  /// [filePath]) only when [_siblingDir] can't be created/written — same
  /// reasoning and mechanism as [_DisplayCache._fallbackDir].
  static Future<Directory> _fallbackDir(String filePath) async {
    final root = await _tempRootDir();
    final key = _fnv1a64Hex(filePath);
    return Directory('${root.path}/$key');
  }

  /// Opens the existing, still-valid pyramid cache for [filePath], or `null`
  /// if there isn't one — never built, built for a different version of the
  /// file (different size or modification time), or a build that was
  /// interrupted before it finished (see [build]).
  static Future<_PyramidCache?> open(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    final sourceSize = stat.size;
    final sourceModifiedMillis = stat.modified.millisecondsSinceEpoch;

    final fromSibling = await _openDir(_siblingDir(filePath), sourceSize, sourceModifiedMillis);
    if (fromSibling != null) return fromSibling;
    return _openDir(await _fallbackDir(filePath), sourceSize, sourceModifiedMillis);
  }

  static Future<_PyramidCache?> _openDir(Directory dir, int sourceSize, int sourceModifiedMillis) async {
    final manifestFile = File('${dir.path}/$_manifestFileName');
    if (!await manifestFile.exists()) return null;
    try {
      final manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      if (manifest['version'] != _manifestVersion) return null;
      if (manifest['sourceSize'] != sourceSize || manifest['sourceModifiedMillis'] != sourceModifiedMillis) {
        return null;
      }
      final levelsFilePath = '${dir.path}/$_levelsFileName';
      if (!await File(levelsFilePath).exists()) return null;
      return _PyramidCache._(
        dir: dir,
        levelsFilePath: levelsFilePath,
        tileSize: manifest['tileSize'] as int,
        minPyramidDimension: manifest['minPyramidDimension'] as int,
        levelCount: manifest['levelCount'] as int,
      );
    } catch (_) {
      // Corrupt/partial manifest — treat exactly like "no cache".
      return null;
    }
  }

  /// Resolves the cache directory to actually build into for [filePath] —
  /// [_siblingDir] if this app can create/write there, [_fallbackDir]
  /// otherwise. Same two-step resolve-then-build split as
  /// [_DisplayCache.resolveDirPath]/[_DisplayCache.build], for the same
  /// reason: [build] runs inside a background isolate with no platform
  /// channel, so `getTemporaryDirectory()` (needed for the fallback) has to
  /// happen before that isolate is even spawned.
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

  /// Builds only the pyramid rungs smaller than [page]'s native resolution
  /// (via `TiffDisplayOptimizer.optimize`'s `pyramidLevelsOnly` mode) and
  /// writes them as one small multi-page TIFF into [dirPath] (see
  /// [resolveDirPath]) — the base resolution itself is never re-encoded or
  /// duplicated here. [onProgress] forwards `TiffDisplayOptimizer.optimize`'s
  /// own progress, held back by one step the same way
  /// [_optimizeIsolateEntry] holds back its own final tick: the last call is
  /// deferred until *after* the encoded rungs are actually written to disk
  /// below, not when `optimize` merely finishes encoding them in memory, so
  /// a caller watching for 100% never sees it before the file genuinely
  /// exists.
  ///
  /// The manifest is written last, so a build interrupted partway (app
  /// killed, disk full, decode error) never leaves behind something [open]
  /// treats as valid — the next attempt just starts over from scratch.
  ///
  /// No size limit: below [maxDirectDecodePixels] this is
  /// `TiffDisplayOptimizer.optimize`'s `pyramidLevelsOnly` mode directly
  /// (one whole-page RGBA8 decode, same as any other small page); above it,
  /// `TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels` derives the
  /// first rung via a bounded-memory banded downsample straight from the
  /// source instead, so this never needs the whole page decoded in memory
  /// at once regardless of how large it is.
  static Future<void> build(
    TiffImage page,
    String filePath,
    String dirPath, {
    int tileSize = 512,
    int minPyramidDimension = 512,
    int maxDirectDecodePixels = _maxSafeFullDecodePixels,
    void Function(TiffOptimizeProgress)? onProgress,
  }) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) await dir.create(recursive: true);

    TiffOptimizeProgress? lastProgress;
    void forwardProgress(TiffOptimizeProgress p) {
      lastProgress = p;
      if (p.completedSteps < p.totalSteps) onProgress?.call(p);
    }

    final metadata = page.metadata;
    final bytes = metadata.width * metadata.height <= maxDirectDecodePixels
        ? TiffDisplayOptimizer.optimize(
            page,
            mode: TiffOptimizationMode.pyramidLevelsOnly,
            tileSize: tileSize,
            minPyramidDimension: minPyramidDimension,
            onProgress: forwardProgress,
          )
        : TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
            page,
            tileSize: tileSize,
            minPyramidDimension: minPyramidDimension,
            maxDirectDecodePixels: maxDirectDecodePixels,
            onProgress: forwardProgress,
          );
    // optimize()'s totalSteps is levelCount + 1 (the +1 being its own final
    // encode step, already folded into `bytes` by the time we get here).
    final levelCount = math.max(1, (lastProgress?.totalSteps ?? 2) - 1);

    await File('${dir.path}/$_levelsFileName').writeAsBytes(bytes);

    final sourceStat = await File(filePath).stat();
    await File('${dir.path}/$_manifestFileName').writeAsString(
      jsonEncode({
        'version': _manifestVersion,
        'sourceSize': sourceStat.size,
        'sourceModifiedMillis': sourceStat.modified.millisecondsSinceEpoch,
        'tileSize': tileSize,
        'minPyramidDimension': minPyramidDimension,
        'levelCount': levelCount,
      }),
    );

    final last = lastProgress;
    if (last != null) {
      onProgress?.call((completedSteps: last.completedSteps, totalSteps: last.totalSteps, fraction: 1.0));
    }
  }
}

/// Entry point for the one-shot isolate behind [_runPyramidCacheBuild]:
/// re-opens [filePath] and runs [_PyramidCache.build] into the
/// already-resolved [dirPath] (see [_DisplayCache.build]'s doc comment for
/// why the caller must resolve this beforehand rather than the isolate
/// doing it) — same shape as [_cacheBuildIsolateEntry], just delegating to
/// [_PyramidCache.build] instead, whose own `onProgress` already handles
/// holding back its final tick until the file write is done. Sends a final
/// `true` on success or a `String` on failure.
Future<void> _pyramidCacheIsolateEntry((SendPort, String, String, int, int) args) async {
  final (sendPort, filePath, dirPath, tileSize, minPyramidDimension) = args;
  try {
    TiffImageAdapter.enableJpegSupport();
    final document = decodeTiffFile(File(filePath));
    try {
      await _PyramidCache.build(
        document.images.first,
        filePath,
        dirPath,
        tileSize: tileSize,
        minPyramidDimension: minPyramidDimension,
        onProgress: (p) => sendPort.send((p.completedSteps, p.totalSteps, p.fraction)),
      );
      sendPort.send(true);
    } finally {
      document.close();
    }
  } catch (e) {
    sendPort.send('$e');
  }
}

/// Runs [_pyramidCacheIsolateEntry] in a throwaway isolate, forwarding its
/// progress updates to [onProgress]. Returns `null` on success, an error
/// message otherwise.
Future<String?> _runPyramidCacheBuild(
  String filePath, {
  int tileSize = 512,
  int minPyramidDimension = 512,
  void Function(_StepProgress)? onProgress,
}) async {
  final String dirPath;
  try {
    dirPath = await _PyramidCache.resolveDirPath(filePath);
  } catch (e) {
    return '$e';
  }

  final receivePort = ReceivePort();
  try {
    await Isolate.spawn(
      _pyramidCacheIsolateEntry,
      (receivePort.sendPort, filePath, dirPath, tileSize, minPyramidDimension),
    );
  } catch (e) {
    receivePort.close();
    return '$e';
  }

  String? result;
  await for (final message in receivePort) {
    if (message is _StepProgress) {
      onProgress?.call(message);
    } else if (message is bool) {
      break;
    } else {
      result = message as String;
      break;
    }
  }
  receivePort.close();
  return result;
}
