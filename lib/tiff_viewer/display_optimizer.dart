part of '../tiff_viewer_page.dart';

/// A concrete "N of M" progress update forwarded across an isolate boundary
/// for [_runDisplayCacheBuild] — a plain positional tuple (matching this
/// app's other isolate message types) rather than `_CacheBuildProgress`
/// directly. [_runDisplayOptimization]/[_runPyramidCacheBuild] instead
/// forward `package:tiff`'s own [TiffOptimizeProgress] record as-is (records
/// — and the [TiffOptimizeStage] enum inside this one — cross an
/// `Isolate.spawn`-spawned isolate boundary the same way this tuple always
/// has), since flattening its stage/level/step fields into a positional
/// tuple here would just be lossy busywork undone one call frame later.
typedef _StepProgress = (int completed, int total, double fraction);

/// Entry point for the one-shot isolate behind [_runDisplayOptimization]:
/// re-opens [filePath] (isolates don't share the main isolate's already-open
/// [TiffDocument]), runs `TiffDisplayOptimizer.optimize`, and writes the
/// result to [outputPath] itself — sending the (potentially large) encoded
/// bytes back over a [SendPort] would cost an extra copy for no benefit,
/// since a background isolate can do file I/O directly. Streams
/// [TiffOptimizeProgress] updates back as `optimize` reports them, holding
/// back the very last one (the only one with `fraction == 1.0`) until after
/// the write below actually happens — same reasoning as
/// [_cacheBuildIsolateEntry]. Sends a final `true` on success or a `String`
/// on failure.
void _optimizeIsolateEntry((SendPort, String, String, int, int, int, int?) args) {
  final (sendPort, filePath, outputPath, modeIndex, tileSize, minPyramidDimension, levelCount) = args;
  try {
    TiffImageAdapter.enableJpegSupport();
    final document = decodeTiffFile(File(filePath));
    try {
      TiffOptimizeProgress? lastProgress;
      final bytes = TiffDisplayOptimizer.optimize(
        document.images.first,
        mode: TiffOptimizationMode.values[modeIndex],
        tileSize: tileSize,
        minPyramidDimension: minPyramidDimension,
        levelCount: levelCount,
        onProgress: (p) {
          lastProgress = p;
          if (p.fraction < 1.0) sendPort.send(p);
        },
      );
      File(outputPath).writeAsBytesSync(bytes);
      final last = lastProgress;
      if (last != null) sendPort.send(last);
      sendPort.send(true);
    } finally {
      document.close();
    }
  } catch (e) {
    sendPort.send('$e');
  }
}

/// Runs [_optimizeIsolateEntry] in a throwaway isolate, forwarding its
/// progress updates to [onProgress]. Returns `null` on success, an error
/// message otherwise.
Future<String?> _runDisplayOptimization({
  required String filePath,
  required String outputPath,
  required TiffOptimizationMode mode,
  int tileSize = 512,
  int minPyramidDimension = 512,
  int? levelCount,
  void Function(TiffOptimizeProgress)? onProgress,
}) async {
  final receivePort = ReceivePort();
  try {
    await Isolate.spawn(
      _optimizeIsolateEntry,
      (receivePort.sendPort, filePath, outputPath, mode.index, tileSize, minPyramidDimension, levelCount),
    );
  } catch (e) {
    receivePort.close();
    return '$e';
  }

  String? result;
  await for (final message in receivePort) {
    if (message is TiffOptimizeProgress) {
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

/// Entry point for the one-shot isolate behind [_runDisplayCacheBuild]:
/// re-opens [filePath] and runs [_DisplayCache.build] into the
/// already-resolved [dirPath] (see [_DisplayCache.build]'s doc comment for
/// why the caller must resolve this beforehand rather than the isolate
/// doing it — `getTemporaryDirectory()` needs a platform channel this
/// isolate doesn't have), streaming concrete "band N of M" progress back as
/// a [_StepProgress] as each one finishes — same reasoning as
/// [_decodePreviewRgba]'s callers elsewhere in this app: a single
/// request/response call can't report progress mid-flight. Sends a final
/// `true` on success or a `String` on failure.
Future<void> _cacheBuildIsolateEntry((SendPort, String, String, int, int, int?) args) async {
  final (sendPort, filePath, dirPath, formatIndex, jpegQuality, workerCount) = args;
  try {
    TiffImageAdapter.enableJpegSupport();
    final document = decodeTiffFile(File(filePath));
    try {
      await _DisplayCache.build(
        document.images.first,
        filePath,
        dirPath,
        format: _DisplayCacheFormat.values[formatIndex],
        jpegQuality: jpegQuality,
        workerCount: workerCount,
        onProgress: (p) => sendPort.send((p.completedBands, p.totalBands, p.fraction)),
      );
      sendPort.send(true);
    } finally {
      document.close();
    }
  } catch (e) {
    sendPort.send('$e');
  }
}

/// Runs [_cacheBuildIsolateEntry] in a throwaway isolate, forwarding its
/// progress updates to [onProgress]. Returns `null` on success, an error
/// message otherwise.
Future<String?> _runDisplayCacheBuild(
  String filePath, {
  _DisplayCacheFormat format = _DisplayCacheFormat.rawRgba,
  int jpegQuality = 85,
  int? workerCount,
  void Function(_StepProgress)? onProgress,
}) async {
  final String dirPath;
  try {
    dirPath = await _DisplayCache.resolveDirPath(filePath);
  } catch (e) {
    return '$e';
  }

  final receivePort = ReceivePort();
  try {
    await Isolate.spawn(_cacheBuildIsolateEntry, (receivePort.sendPort, filePath, dirPath, format.index, jpegQuality, workerCount));
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
