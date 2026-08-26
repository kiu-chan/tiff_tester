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
