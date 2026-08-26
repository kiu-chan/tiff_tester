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

part 'tiff_viewer/preview_decoder.dart';
part 'tiff_viewer/tile_engine.dart';
part 'tiff_viewer/region_engine.dart';
part 'tiff_viewer/pixel_scale.dart';
part 'tiff_viewer/zoomable_image.dart';
part 'tiff_viewer/minimap.dart';
part 'tiff_viewer/scale_bar.dart';
part 'tiff_viewer/metadata_table.dart';
part 'tiff_viewer/small_widgets.dart';

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

  _TileEngine? _tileEngine;
  _RegionEngine? _regionEngine;

  bool get _previewStarted => _previewLoading || _tileEngine != null || _regionEngine != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Releases the open file handle a file-backed TiffDocument holds.
    _document?.close();
    _tileEngine?.dispose();
    _regionEngine?.dispose();
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
      final engine = _TileEngine(filePath: widget.filePath, levels: _buildPyramidLevels(document));
      engine.addListener(_onEngineChanged);
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

    final engine = _RegionEngine(filePath: widget.filePath, metadata: document.images.first.metadata);
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
                if (_previewLoading && _tileEngine == null && _regionEngine == null) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text('Đang mở ảnh...', style: Theme.of(context).textTheme.bodySmall),
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
