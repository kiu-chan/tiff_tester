part of '../tiff_viewer_page.dart';

/// A concrete "N of M" progress update forwarded across an isolate
/// boundary — a plain positional tuple (matching this app's other isolate
/// message types) rather than [TiffOptimizeProgress]/`_CacheBuildProgress`
/// directly, so both isolate entries below can share one wire shape and one
/// [_runOptimize] callback signature regardless of which strategy is
/// running.
typedef _StepProgress = (int completed, int total, double fraction);

/// Entry point for the one-shot isolate behind [_runDisplayOptimization]:
/// re-opens [filePath] (isolates don't share the main isolate's already-open
/// [TiffDocument]), runs `TiffDisplayOptimizer.optimize`, and writes the
/// result to [outputPath] itself — sending the (potentially large) encoded
/// bytes back over a [SendPort] would cost an extra copy for no benefit,
/// since a background isolate can do file I/O directly. Streams concrete
/// step progress back as a [_StepProgress] via `optimize`'s own
/// `onProgress` (one call per pyramid rung, plus a final call once the file
/// is actually written — held back a beat from `optimize`'s own "encoded"
/// signal, which fires before the write below) — same reasoning as
/// [_cacheBuildIsolateEntry]. Sends a final `true` on success or a `String`
/// on failure.
void _optimizeIsolateEntry((SendPort, String, String, int, int, int) args) {
  final (sendPort, filePath, outputPath, modeIndex, tileSize, minPyramidDimension) = args;
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
        onProgress: (p) {
          lastProgress = p;
          if (p.completedSteps < p.totalSteps) {
            sendPort.send((p.completedSteps, p.totalSteps, p.fraction));
          }
        },
      );
      File(outputPath).writeAsBytesSync(bytes);
      final last = lastProgress;
      if (last != null) sendPort.send((last.completedSteps, last.totalSteps, 1.0));
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
  void Function(_StepProgress)? onProgress,
}) async {
  final receivePort = ReceivePort();
  try {
    await Isolate.spawn(
      _optimizeIsolateEntry,
      (receivePort.sendPort, filePath, outputPath, mode.index, tileSize, minPyramidDimension),
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
Future<void> _cacheBuildIsolateEntry((SendPort, String, String) args) async {
  final (sendPort, filePath, dirPath) = args;
  try {
    TiffImageAdapter.enableJpegSupport();
    final document = decodeTiffFile(File(filePath));
    try {
      await _DisplayCache.build(
        document.images.first,
        filePath,
        dirPath,
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
Future<String?> _runDisplayCacheBuild(String filePath, {void Function(_StepProgress)? onProgress}) async {
  final String dirPath;
  try {
    dirPath = await _DisplayCache.resolveDirPath(filePath);
  } catch (e) {
    return '$e';
  }

  final receivePort = ReceivePort();
  try {
    await Isolate.spawn(_cacheBuildIsolateEntry, (receivePort.sendPort, filePath, dirPath));
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
