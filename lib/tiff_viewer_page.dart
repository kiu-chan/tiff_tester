import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_image_adapter.dart';
import 'package:tiff/tiff_io.dart';
import 'package:tiff/tiff_minimap.dart';

part 'tiff_viewer/memory_monitor.dart';
part 'tiff_viewer/preview_decoder.dart';
part 'tiff_viewer/tile_engine.dart';
part 'tiff_viewer/region_engine.dart';
part 'tiff_viewer/display_cache.dart';
part 'tiff_viewer/display_optimizer.dart';
part 'tiff_viewer/pyramid_cache.dart';
part 'tiff_viewer/pixel_scale.dart';
part 'tiff_viewer/zoomable_image.dart';
part 'tiff_viewer/scale_bar.dart';
part 'tiff_viewer/metadata_table.dart';
part 'tiff_viewer/small_widgets.dart';

/// Cap on the longest side of the decoded preview. Above this, the image is
/// decoded band-by-band (via [TiffImage.decodeRegionRgba8]) and downsampled
/// on the fly, so a multi-gigapixel file never needs a full-resolution RGBA
/// buffer (width*height*4 bytes) in memory just to be looked at.
const _maxPreviewDim = 4096;

/// Roughly how much memory one preview decode band is allowed to use. This
/// bounds the *raw* decoded band, not just its RGBA conversion — see
/// [_bandBytesPerPixel]. Scales with [_MemoryMonitor.availableBudgetBytes]
/// rather than a fixed number, so a preview decode started while the app is
/// already holding a lot of memory (e.g. mid-optimize) claims less at once.
int _maxBandBytes() => _MemoryMonitor.budgetFor(
  fraction: 0.0625, // 32 MiB out of the 512 MiB default budget
  minBytes: 4 * 1024 * 1024,
  maxBytes: 64 * 1024 * 1024,
);

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

class _TiffViewerPageState extends State<TiffViewerPage> {
  int? _fileSizeBytes;
  TiffDocument? _document;
  Object? _decodeError;
  String? _writeTestResult;
  bool _runningWriteTest = false;

  double _brightness = 0;
  double _contrast = 1;
  double _gamma = 1;

  bool _previewLoading = false;

  bool _optimizing = false;
  String? _optimizingLabel;
  double? _optimizeProgress;
  // A ready-to-show status line built directly in the progress callback
  // (see _describeOptimizeProgress/_runOptimize's onCacheProgress) — e.g.
  // "Compressing tile 340/512 (level 2/6)" — rather than raw step counts
  // kept here and formatted later, since the two progress sources this page
  // drives (TiffDisplayOptimizer's per-stage TiffOptimizeProgress, and
  // _DisplayCache's simpler band-only progress) don't share one shape.
  String? _optimizeStatusLine;
  Stopwatch? _optimizeStopwatch;
  Timer? _optimizeTicker;
  String? _optimizeResult;
  bool _optimizeResultIsError = false;

  _TileEngine? _tileEngine;
  _RegionEngine? _regionEngine;

  /// The sidecar _PyramidCache file's own [TiffDocument], if [_openPreview]
  /// opened one to fold extra rungs into [_tileEngine]'s levels — kept
  /// alive for as long as the engine is (each of its worker isolates opens
  /// the same file independently, but this main-isolate copy is what
  /// [_buildPyramidLevels] used to size [_tileEngine]'s own `levels`) and
  /// closed in [dispose].
  TiffDocument? _pyramidCacheDocument;

  int _memoryRssBytes = 0;
  Timer? _memoryTicker;
  late final TextEditingController _memoryBudgetController;

  // Tiling knobs for TiffDisplayOptimizer.optimize (tileSize, minPyramidDimension)
  // — see their doc comments in the `tiff` package for what each controls.
  // Read fresh from these controllers in `_runOptimize`, not mirrored into
  // separate state fields, since nothing else in this page depends on them.
  late final TextEditingController _tileSizeController;
  late final TextEditingController _minPyramidDimensionController;

  // How many pyramid rungs to build for "Tile + pyramid"/"Cache pyramid
  // levels" — see TiffDisplayOptimizer.optimize's levelCount doc comment.
  // Left blank by default: null (see _positiveIntOrNull) means "let
  // minPyramidDimension decide instead", the library's own auto-computed
  // choice (halve down to a size small enough to display smoothly, no
  // further downsampling needed at read time) — only overridden when the
  // user actually types a value here.
  late final TextEditingController _levelCountController;

  // How many isolates to spread a parallel decode across (see
  // TiffAutoDecodeBudget.recommend) — for "Cache pyramid levels" (a large
  // source's banded first rung) and every "Cache (...)" app-cache variant.
  // Left blank by default: null (see _positiveIntOrNull) means "let
  // TiffAutoDecodeBudget.recommend pick it from actual idle memory and CPU
  // count", the same as before this field existed; only overridden when the
  // user actually types a value here.
  late final TextEditingController _workerCountController;

  bool get _previewStarted => _previewLoading || _tileEngine != null || _regionEngine != null;

  @override
  void initState() {
    super.initState();
    _load();
    _memoryRssBytes = _MemoryMonitor.currentRssBytes();
    // Polls the app's own memory use so the readout below (and every
    // adaptive budget in _MemoryMonitor) reflects what's happening right
    // now, not just a snapshot from when the page opened.
    _memoryTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _memoryRssBytes = _MemoryMonitor.currentRssBytes());
    });
    _memoryBudgetController = TextEditingController(text: '${_MemoryMonitor.totalBudgetBytes ~/ (1024 * 1024)}');
    _tileSizeController = TextEditingController(text: '512');
    _minPyramidDimensionController = TextEditingController(text: '512');
    _levelCountController = TextEditingController();
    _workerCountController = TextEditingController();
  }

  @override
  void dispose() {
    // Releases the open file handle a file-backed TiffDocument holds.
    _document?.close();
    _pyramidCacheDocument?.close();
    _tileEngine?.dispose();
    _regionEngine?.dispose();
    _optimizeTicker?.cancel();
    _memoryTicker?.cancel();
    _memoryBudgetController.dispose();
    _tileSizeController.dispose();
    _minPyramidDimensionController.dispose();
    _levelCountController.dispose();
    _workerCountController.dispose();
    super.dispose();
  }

  /// Parses a positive-integer field (tile size / min pyramid dimension),
  /// falling back to [fallback] on anything blank, non-numeric, or <= 0 —
  /// same "ignore an in-progress edit rather than error" behavior as
  /// [_onMemoryBudgetChanged], just without the value being clamped/mirrored
  /// back into the field, since [TiffDisplayOptimizer.optimize] itself
  /// already rejects <= 0 with a clear ArgumentError if this ever let one
  /// through.
  int _positiveIntOrDefault(String text, int fallback) {
    final value = int.tryParse(text.trim());
    return (value == null || value <= 0) ? fallback : value;
  }

  /// Parses the worker-count field: `null` on anything blank, non-numeric,
  /// or <= 0 — meaning "no override", so the caller falls back to
  /// `TiffAutoDecodeBudget.recommend`'s own pick. Unlike
  /// [_positiveIntOrDefault], there's no fallback value to substitute here;
  /// blank is itself a meaningful choice ("let the library decide"), not an
  /// in-progress edit to be papered over.
  int? _positiveIntOrNull(String text) {
    final value = int.tryParse(text.trim());
    return (value == null || value <= 0) ? null : value;
  }

  /// Applies a new memory budget (typed in MB) to [_MemoryMonitor], the
  /// moment it parses as a positive number — every adaptive budget in the
  /// app (band/chunk sizes, worker count for [_DisplayCache.build], the
  /// live viewing engines' caches) reads [_MemoryMonitor.totalBudgetBytes]
  /// fresh each time, so there's nothing else to wire up for a change here
  /// to take effect. [_MemoryMonitor.setTotalBudgetBytes] clamps to a sane
  /// range — if that changed what the user typed, the field is corrected
  /// to show what's actually in effect rather than silently diverging from it.
  void _onMemoryBudgetChanged(String text) {
    final mb = int.tryParse(text.trim());
    if (mb == null || mb <= 0) return;
    setState(() => _MemoryMonitor.setTotalBudgetBytes(mb * 1024 * 1024));
    final effectiveMb = _MemoryMonitor.totalBudgetBytes ~/ (1024 * 1024);
    if (effectiveMb != mb) {
      _memoryBudgetController.value = TextEditingValue(
        text: '$effectiveMb',
        selection: TextSelection.collapsed(offset: '$effectiveMb'.length),
      );
    }
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
  /// [TiffImageMetadata.isTiled]) gets the viewport-driven [_TileEngine];
  /// a non-tiled page gets the analogous band-driven [_RegionEngine] (see
  /// its doc comment for why bands rather than a 2D tile grid). Either way,
  /// only the region currently on screen is ever decoded — a multi-gigapixel
  /// image never needs a full decode just to be looked at — and the viewer
  /// opens already centered on a device-sized region (see
  /// [TiffInitialView.forViewport], applied in [_TiledZoomableImageState]/
  /// [_RegionZoomableImageState]) rather than the whole page shrunk to fit.
  Future<void> _openPreview() async {
    final document = _document;
    if (document == null || _previewStarted) return;

    setState(() => _previewLoading = true);

    if (document.images.first.metadata.isTiled) {
      var levels = _buildPyramidLevels(document);
      String? pyramidCachePath;
      // No native pyramid of its own — see if a sidecar _PyramidCache (built
      // via the "Cache pyramid levels" action below) has extra rungs to
      // fold in, so zooming out doesn't force downsampling the full page
      // live just because the source itself only has one resolution.
      if (levels.length <= 1) {
        final cache = await _PyramidCache.open(widget.filePath);
        if (cache != null) {
          TiffDocument? extraLevelsDocument;
          try {
            extraLevelsDocument = decodeTiffFile(File(cache.levelsFilePath));
            levels = _buildPyramidLevels(document, extraLevelsDocument: extraLevelsDocument);
            pyramidCachePath = cache.levelsFilePath;
            _pyramidCacheDocument = extraLevelsDocument;
          } catch (_) {
            // Corrupt/stale cache file, or a failure after opening it — fall
            // back to just the native level, and release the handle rather
            // than leaking it since _pyramidCacheDocument never got set.
            extraLevelsDocument?.close();
          }
        }
      }
      final engine = _TileEngine(filePath: widget.filePath, levels: levels, pyramidCachePath: pyramidCachePath);
      engine.addListener(_onEngineChanged);
      await engine.start();
      if (!mounted) {
        engine.dispose();
        _pyramidCacheDocument?.close();
        return;
      }
      setState(() {
        _tileEngine = engine;
        _previewLoading = false;
      });
      return;
    }

    // A previously-built display cache (see _DisplayCache, built via the
    // "Optimize" menu below) skips decoding entirely in favor of plain file
    // reads — check for one before falling back to live decode.
    final cache = await _DisplayCache.open(widget.filePath);
    if (!mounted) return;
    final engine = _RegionEngine(filePath: widget.filePath, metadata: document.images.first.metadata, cache: cache);
    engine.addListener(_onEngineChanged);
    await engine.start();
    if (!mounted) {
      engine.dispose();
      return;
    }
    setState(() {
      _regionEngine = engine;
      _previewLoading = false;
    });
  }

  void _onEngineChanged() {
    if (mounted) setState(() {});
  }

  /// Runs one of the three "prepare this file ahead of time" strategies —
  /// a deliberate, separate step the user opts into before viewing, not
  /// something that happens as part of [_openPreview] itself:
  ///
  /// - `tiledPyramid`/`tiledOnly`: [TiffDisplayOptimizer] rewrites the page
  ///   as a new, portable TIFF file the user can open (here or in any other
  ///   viewer) instead of the original.
  /// - `cache`: [_DisplayCache] instead, invisible and private to this app
  ///   — [_openPreview] picks it up automatically next time this same file
  ///   is opened, with no new file for the user to manage.
  Future<void> _runOptimize(String choice, String label) async {
    if (_optimizing) return;
    final stopwatch = Stopwatch()..start();
    setState(() {
      _optimizing = true;
      _optimizingLabel = label;
      _optimizeProgress = 0;
      _optimizeStatusLine = null;
      _optimizeStopwatch = stopwatch;
      _optimizeResult = null;
    });
    // Ticks the elapsed-time display while work is in flight — progress
    // updates themselves arrive in bursts (many per second while tiles are
    // being compressed, none at all during a single long decode/downsample
    // step), so without this the "elapsed Xs" text would stall between
    // updates instead of counting up smoothly.
    _optimizeTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });

    // Drives tiledPyramid/tiledOnly/pyramid_cache — every strategy built on
    // TiffDisplayOptimizer, which now reports real "which stage, which
    // rung, which tile/band" progress (see TiffOptimizeProgress) instead of
    // one opaque step per rung.
    void onOptimizeProgress(TiffOptimizeProgress p) {
      if (!mounted) return;
      setState(() {
        _optimizeProgress = p.fraction;
        _optimizeStatusLine = _describeOptimizeProgress(p);
      });
    }

    // Drives cache_raw/cache_deflate/cache_jpeg — _DisplayCache's own,
    // simpler "band N of M" progress, unrelated to TiffDisplayOptimizer.
    void onCacheProgress(_StepProgress p) {
      final (completed, total, fraction) = p;
      if (!mounted) return;
      setState(() {
        _optimizeProgress = fraction;
        _optimizeStatusLine = 'Encoding band $completed/$total';
      });
    }

    String? error;
    String? successMessage;
    switch (choice) {
      case 'tiledPyramid':
      case 'tiledOnly':
        final mode = choice == 'tiledPyramid' ? TiffOptimizationMode.tiledPyramid : TiffOptimizationMode.tiledOnly;
        final outputPath = _suffixedPath(widget.filePath, choice == 'tiledPyramid' ? 'pyramid' : 'tiled');
        error = await _runDisplayOptimization(
          filePath: widget.filePath,
          outputPath: outputPath,
          mode: mode,
          tileSize: _positiveIntOrDefault(_tileSizeController.text, 512),
          minPyramidDimension: _positiveIntOrDefault(_minPyramidDimensionController.text, 512),
          levelCount: _positiveIntOrNull(_levelCountController.text),
          onProgress: onOptimizeProgress,
        );
        if (error == null) successMessage = 'Saved optimized file to:\n$outputPath';
        break;
      case 'pyramid_cache':
        error = await _runPyramidCacheBuild(
          widget.filePath,
          tileSize: _positiveIntOrDefault(_tileSizeController.text, 512),
          minPyramidDimension: _positiveIntOrDefault(_minPyramidDimensionController.text, 512),
          levelCount: _positiveIntOrNull(_levelCountController.text),
          workerCount: _positiveIntOrNull(_workerCountController.text),
          onProgress: onOptimizeProgress,
        );
        if (error == null) {
          successMessage =
              'Cached extra pyramid levels — the original file is unchanged/not duplicated, '
              'reopening this file will zoom more smoothly.';
          final cache = await _PyramidCache.open(widget.filePath);
          if (cache != null) {
            final cacheBytes = await File(cache.levelsFilePath).length();
            final sourceBytes = _fileSizeBytes;
            final ratio = sourceBytes != null && sourceBytes > 0 ? cacheBytes / sourceBytes : null;
            successMessage +=
                '\nLevels added: ${cache.levelCount}'
                '\nCache size: ${_formatMemoryBytes(cacheBytes)}'
                '${ratio != null ? ' (${(ratio * 100).toStringAsFixed(1)}% of original file)' : ''}'
                '\nLocation: ${cache.dir.path}';
          }
        }
        break;
      case 'cache_raw':
      case 'cache_deflate':
      case 'cache_jpeg':
        final format = switch (choice) {
          'cache_deflate' => _DisplayCacheFormat.deflateRgb,
          'cache_jpeg' => _DisplayCacheFormat.jpeg,
          _ => _DisplayCacheFormat.rawRgba,
        };
        error = await _runDisplayCacheBuild(
          widget.filePath,
          format: format,
          workerCount: _positiveIntOrNull(_workerCountController.text),
          onProgress: onCacheProgress,
        );
        if (error == null) {
          successMessage = 'Created an app-private display cache — reopening this file will be smoother.';
          // Best-effort: reads the manifest just written back to report its
          // actual on-disk size next to the source file's, so the success
          // message shows a real number rather than just "done".
          final cache = await _DisplayCache.open(widget.filePath);
          if (cache != null) {
            final sourceBytes = _fileSizeBytes;
            final ratio = sourceBytes != null && sourceBytes > 0 ? cache.cacheSizeBytes / sourceBytes : null;
            successMessage +=
                '\nCache size: ${_formatMemoryBytes(cache.cacheSizeBytes)}'
                '${ratio != null ? ' (${ratio.toStringAsFixed(1)}x original file)' : ''}'
                '\nLocation: ${cache.dir.path}';
          }
        }
        break;
    }

    stopwatch.stop();
    _optimizeTicker?.cancel();
    _optimizeTicker = null;
    final elapsed = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
    if (!mounted) return;
    setState(() {
      _optimizing = false;
      _optimizingLabel = null;
      _optimizeProgress = null;
      _optimizeStatusLine = null;
      _optimizeStopwatch = null;
      _optimizeResult = successMessage != null ? '$successMessage (${elapsed}s)' : error;
      _optimizeResultIsError = error != null;
    });
  }

  /// Turns one [TiffOptimizeProgress] update into a ready-to-show status
  /// line — the level/band/tile figures it carries are only meaningful once
  /// translated like this, so this lives right next to where progress is
  /// consumed rather than in the `tiff` package itself, which stays UI- and
  /// language-agnostic.
  String _describeOptimizeProgress(TiffOptimizeProgress p) {
    final level = 'level ${p.level + 1}/${p.levelCount}';
    return switch (p.stage) {
      TiffOptimizeStage.decoding => p.stepCount > 1
          ? 'Decoding source image — band ${p.stepIndex}/${p.stepCount}'
          : 'Decoding source image',
      TiffOptimizeStage.downsampling => 'Downsampling $level',
      TiffOptimizeStage.encoding => 'Compressing $level — tile ${p.stepIndex}/${p.stepCount}',
    };
  }

  /// Concrete, live-updating status text for whichever optimize strategy is
  /// running — a per-stage status line (see [_describeOptimizeProgress]/
  /// `onCacheProgress` in [_runOptimize]) and a percentage once the first
  /// progress update arrives, elapsed real time throughout (ticked by
  /// [_optimizeTicker] independently of progress updates, so it counts up
  /// smoothly even during a single long-running step with no updates of its
  /// own).
  String _optimizeStatusText() {
    final elapsedSeconds = ((_optimizeStopwatch?.elapsedMilliseconds ?? 0) / 1000).toStringAsFixed(1);
    final line = _optimizeStatusLine;
    final progress = _optimizeProgress;
    if (line == null || progress == null) {
      return 'Preparing... ($_optimizingLabel, elapsed ${elapsedSeconds}s)';
    }
    final percent = (progress * 100).toStringAsFixed(0);
    return '$line ($percent%) — elapsed ${elapsedSeconds}s';
  }

  /// Inserts `_[suffix]` before [path]'s extension (`foo.tiff` ->
  /// `foo_tiled.tiff`), or appends it if there's no extension to insert
  /// before. Uses an underscore rather than another dot so the result keeps
  /// exactly one extension (`foo_tiled.tiff`, not `foo.tiled.tiff`).
  String _suffixedPath(String path, String suffix) {
    final lastSeparator = path.lastIndexOf(Platform.pathSeparator);
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex <= lastSeparator) return '${path}_$suffix';
    return '${path.substring(0, dotIndex)}_$suffix${path.substring(dotIndex)}';
  }

  bool get _fullDecodeIsSafe {
    final metadata = _document?.images.first.metadata;
    if (metadata == null) return false;
    return metadata.width * metadata.height <= _maxSafeFullDecodePixels;
  }

  /// Whether page 0 is itself tiled — [_PyramidCache] only helps a tiled
  /// source (see [_openPreview]'s [_TileEngine] branch, the only one it
  /// plugs into); a strip-organized source gets no benefit from it, since
  /// [_RegionEngine] doesn't consume pyramid rungs the same way.
  bool get _isTiledSource => _document?.images.first.metadata.isTiled ?? false;

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
                Text(
                  _MemoryMonitor.isSupported
                      ? 'App memory: ${_formatMemoryBytes(_memoryRssBytes)} / '
                            '${_formatMemoryBytes(_MemoryMonitor.totalBudgetBytes)} '
                            '(${_formatMemoryBytes(_MemoryMonitor.availableBudgetFor(_memoryRssBytes))} left) — '
                            'decode/cache sizes scale with this'
                      : 'App memory: unreadable on this platform — using a fixed budget',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                if (_decodeError != null) _ErrorCard(title: 'TiffDecoder.decode() failed', error: _decodeError!),
                if (_document != null) ..._buildDocumentInfo(_document!),
                const SizedBox(height: 16),
                if (_document != null && _decodeError == null && !_previewStarted) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(onPressed: _openPreview, icon: const Icon(Icons.image), label: const Text('View image')),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Optimize ahead of time (optional) — makes the next view smoother:',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 160,
                        child: TextField(
                          controller: _memoryBudgetController,
                          enabled: !_optimizing,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Memory budget (MB)',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onChanged: _onMemoryBudgetChanged,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _MemoryMonitor.isSupported
                                ? 'Recommended: ${_MemoryMonitor.defaultTotalBudgetBytes ~/ (1024 * 1024)} MB — '
                                      'current available memory: ${_formatMemoryBytes(_MemoryMonitor.availableBudgetFor(_memoryRssBytes))}'
                                : 'Recommended: ${_MemoryMonitor.defaultTotalBudgetBytes ~/ (1024 * 1024)} MB — '
                                      'current available memory: unreadable on this platform',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 160,
                        child: TextField(
                          key: const Key('tileSizeField'),
                          controller: _tileSizeController,
                          enabled: !_optimizing,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Tile size (px)',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 160,
                        child: TextField(
                          key: const Key('minPyramidDimensionField'),
                          controller: _minPyramidDimensionController,
                          enabled: !_optimizing,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Min pyramid edge (px)',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 160,
                        child: TextField(
                          key: const Key('levelCountField'),
                          controller: _levelCountController,
                          enabled: !_optimizing,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Pyramid level count',
                            hintText: 'Automatic',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Applies to "Tile + pyramid"/"Cache pyramid levels" '
                            '("Tile only" ignores both). Leave "Pyramid level count" blank: '
                            'computed from "Min pyramid edge" (a smaller value means '
                            'more levels, each level halving the size of the one before) — small '
                            'enough to display smoothly without further downsampling at view time. '
                            'Enter "Pyramid level count" to specify the exact level count, ignoring '
                            '"Min pyramid edge".',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 160,
                        child: TextField(
                          key: const Key('workerCountField'),
                          controller: _workerCountController,
                          enabled: !_optimizing,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Worker count',
                            hintText: 'Automatic',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Applies to "Cache pyramid levels" and every "Cache (...)" — number of parallel decode isolates. '
                            'Leave blank: chosen automatically from CPU core count and current available memory.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Tooltip(
                        message: _fullDecodeIsSafe
                            ? 'Saves a new TIFF file — smooth for both panning and zooming'
                            : 'Disabled: image is too large to decode in full',
                        child: OutlinedButton(
                          onPressed: (_optimizing || !_fullDecodeIsSafe)
                              ? null
                              : () => _runOptimize('tiledPyramid', 'Tile + pyramid'),
                          child: const Text('Tile + pyramid'),
                        ),
                      ),
                      Tooltip(
                        message: _fullDecodeIsSafe ? 'Saves a new TIFF file — smooth for panning' : 'Disabled: image is too large to decode in full',
                        child: OutlinedButton(
                          onPressed: (_optimizing || !_fullDecodeIsSafe)
                              ? null
                              : () => _runOptimize('tiledOnly', 'Tile only'),
                          child: const Text('Tile only'),
                        ),
                      ),
                      Tooltip(
                        message: !_isTiledSource
                            ? 'Disabled: only supports files already in tiled form'
                            : 'Caches smaller pyramid levels separately — the original file is unchanged/not '
                                  'duplicated, much lighter than "Tile + pyramid", and has no image size limit (decodes band by band)',
                        child: OutlinedButton(
                          onPressed: (_optimizing || !_isTiledSource) ? null : () => _runOptimize('pyramid_cache', 'Cache pyramid levels'),
                          child: const Text('Cache pyramid levels'),
                        ),
                      ),
                      Tooltip(
                        message: 'Raw RGBA cache — largest (~4x original file or more), fastest to read, no quality loss',
                        child: OutlinedButton(
                          onPressed: _optimizing ? null : () => _runOptimize('cache_raw', 'Cache (raw RGBA)'),
                          child: const Text('Cache (raw RGBA)'),
                        ),
                      ),
                      Tooltip(
                        message: 'Deflate-compressed cache — ~2-4x smaller than raw RGBA, no quality loss, slightly slower to read',
                        child: OutlinedButton(
                          onPressed: _optimizing ? null : () => _runOptimize('cache_deflate', 'Cache (Deflate)'),
                          child: const Text('Cache (Deflate)'),
                        ),
                      ),
                      Tooltip(
                        message: 'JPEG-compressed cache — smallest, close to the original file size, slight quality loss and slower to read (JPEG decode)',
                        child: OutlinedButton(
                          onPressed: _optimizing ? null : () => _runOptimize('cache_jpeg', 'Cache (JPEG)'),
                          child: const Text('Cache (JPEG)'),
                        ),
                      ),
                    ],
                  ),
                  if (_optimizing) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _optimizeProgress == 0 ? null : _optimizeProgress),
                    const SizedBox(height: 4),
                    Text(_optimizeStatusText(), style: Theme.of(context).textTheme.bodySmall),
                  ],
                  if (_optimizeResult != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _optimizeResult!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _optimizeResultIsError ? Theme.of(context).colorScheme.error : Colors.green.shade700,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                if (_previewLoading && _tileEngine == null && _regionEngine == null) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text('Opening image...', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 16),
                ],
                if (_tileEngine?.fatalError != null) ...[
                  _ErrorCard(title: 'Tile decode failed', error: _tileEngine!.fatalError!),
                  const SizedBox(height: 16),
                ],
                if (_regionEngine?.fatalError != null) ...[
                  _ErrorCard(title: 'Region decode failed', error: _regionEngine!.fatalError!),
                  const SizedBox(height: 16),
                ],
                if (_tileEngine != null)
                  SizedBox(
                    height: 420,
                    child: _TiledZoomableImage(
                      key: ValueKey(widget.filePath),
                      engine: _tileEngine!,
                      scale: _PixelScale.from(_document!.images.first.metadata),
                    ),
                  )
                else if (_regionEngine != null)
                  SizedBox(
                    height: 420,
                    // Keyed by file path so zoom/pan state survives
                    // brightness/contrast/gamma tweaks but resets when a
                    // different file is opened.
                    child: _RegionZoomableImage(
                      key: ValueKey(widget.filePath),
                      engine: _regionEngine!,
                      scale: _PixelScale.from(_document!.images.first.metadata),
                    ),
                  ),
                if (_regionEngine != null) ...[
                  const SizedBox(height: 8),
                  _AdjustmentSlider(
                    label: 'Brightness',
                    value: _brightness,
                    min: -100,
                    max: 100,
                    display: _brightness.toStringAsFixed(0),
                    onChanged: (v) {
                      setState(() => _brightness = v);
                      _regionEngine!.setAdjustments(brightness: _brightness, contrast: _contrast, gamma: _gamma);
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
                      _regionEngine!.setAdjustments(brightness: _brightness, contrast: _contrast, gamma: _gamma);
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
                      _regionEngine!.setAdjustments(brightness: _brightness, contrast: _contrast, gamma: _gamma);
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
                        _regionEngine!.setAdjustments(brightness: _brightness, contrast: _contrast, gamma: _gamma);
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
