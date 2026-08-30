part of '../tiff_viewer_page.dart';

/// Decode/geometry budget for the very first thing shown when a page opens
/// — see [TiffInitialView.forViewport]. Deliberately smaller than
/// [_maxPreviewDim]'s cap: that one bounds a capped-and-downsampled
/// *whole-image* overview, while this bounds the centered region a viewer
/// starts already zoomed into, before the user pans or zooms at all.
const _initialViewMaxPixels = 4000000;

/// Centers the [TiffInitialView.region] of [view] in a viewport of
/// [viewportSize], at the scale that displays it at [view]'s zoom —
/// converting from [TiffInitialView]'s device-pixel-per-image-pixel zoom to
/// the logical-pixel-per-image-pixel scale Flutter's transform matrices use
/// by dividing out [devicePixelRatio] (the same one passed to
/// [TiffInitialView.forViewport] to compute [view] in the first place).
Matrix4 _initialViewTransform(TiffInitialView view, Size viewportSize, double devicePixelRatio) {
  final region = view.region;
  final scale = view.zoom / devicePixelRatio;
  final centerX = region.x + region.width / 2;
  final centerY = region.y + region.height / 2;
  final dx = viewportSize.width / 2 - centerX * scale;
  final dy = viewportSize.height / 2 - centerY * scale;
  return Matrix4.identity()
    ..translateByDouble(dx, dy, 0, 1)
    ..scaleByDouble(scale, scale, scale, 1);
}

/// Pans/zooms a non-tiled page via [InteractiveViewer], reading live from a
/// [_RegionEngine] instead of a single fixed [ui.Image] — see
/// [_RegionEngine] for how bands are chosen and loaded as the viewport
/// changes. Same pan/zoom/minimap/scale-bar shell as [_TiledZoomableImage].
class _RegionZoomableImage extends StatefulWidget {
  final _RegionEngine engine;
  final _PixelScale scale;
  const _RegionZoomableImage({super.key, required this.engine, required this.scale});

  @override
  State<_RegionZoomableImage> createState() => _RegionZoomableImageState();
}

class _RegionZoomableImageState extends State<_RegionZoomableImage> {
  final _controller = TransformationController();
  bool _fitted = false;
  Timer? _debounce;
  Size? _viewportSize;

  Size get _baseSize => Size(widget.engine.baseWidth.toDouble(), widget.engine.baseHeight.toDouble());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_scheduleVisibleUpdate);
    widget.engine.addListener(_onEngineChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_scheduleVisibleUpdate);
    widget.engine.removeListener(_onEngineChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onEngineChanged() {
    if (mounted) setState(() {});
  }

  // Debounced so a fast drag/pinch gesture doesn't fire a band-recompute
  // (and a decode request) on every intermediate frame — only once motion
  // settles for a moment.
  void _scheduleVisibleUpdate() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 80), _updateVisible);
  }

  void _updateVisible() {
    final viewport = _viewportSize;
    if (viewport == null) return;
    final inverse = Matrix4.copy(_controller.value)..invert();
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(inverse, Offset(viewport.width, viewport.height));
    final rect = Rect.fromPoints(topLeft, bottomRight).intersect(Offset.zero & _baseSize);
    widget.engine.requestVisible(rect);
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

  /// Starts centered on a region sized for [viewportSize] and this device
  /// (see [TiffInitialView.forViewport]) instead of the whole page — the
  /// "Fit to screen" button (see [_fitToViewport]) is still there for
  /// anyone who wants the old whole-page overview.
  void _applyInitialView(Size viewportSize) {
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    final view = TiffInitialView.forViewport(
      widget.engine.metadata,
      viewportWidth: viewportSize.width,
      viewportHeight: viewportSize.height,
      devicePixelRatio: devicePixelRatio,
      maxDecodedPixels: _initialViewMaxPixels,
    );
    _controller.value = _initialViewTransform(view, viewportSize, devicePixelRatio);
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
              _applyInitialView(viewportSize);
              _updateVisible();
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
                    child: CustomPaint(key: const Key('mainImage'), painter: _RegionPainter(widget.engine, imageSize)),
                  ),
                ),
              ),
              if (widget.engine.overview == null) const Center(child: CircularProgressIndicator()),
              if (widget.engine.overview != null && widget.engine.isWorking)
                const Positioned(top: 8, left: 8, child: _WorkingIndicator()),
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
                child: TiffMinimap(
                  overview: widget.engine.overview,
                  baseWidth: widget.engine.baseWidth,
                  baseHeight: widget.engine.baseHeight,
                  controller: _controller,
                  viewportSize: viewportSize,
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
/// cached bands on top — see [_RegionEngine.cachedBandEntries]. Repaints
/// automatically whenever [engine] reports new data via [ChangeNotifier].
class _RegionPainter extends CustomPainter {
  final _RegionEngine engine;
  final Size baseSize;
  _RegionPainter(this.engine, this.baseSize) : super(repaint: engine);

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

    for (final (bandIndex, image) in engine.cachedBandEntries()) {
      final y = (bandIndex * engine.bandHeight).toDouble();
      final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
      final dst = Rect.fromLTWH(0, y, baseSize.width, image.height.toDouble());
      canvas.drawImageRect(image, src, dst, Paint());
    }
  }

  @override
  bool shouldRepaint(covariant _RegionPainter oldDelegate) => oldDelegate.engine != engine || oldDelegate.baseSize != baseSize;
}

/// Same pan/zoom/minimap/scale-bar shell as [_RegionZoomableImage], but the
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

  /// Starts centered on a region of the native (largest) pyramid rung sized
  /// for [viewportSize] and this device (see [TiffInitialView.forViewport])
  /// instead of the whole page — the "Fit to screen" button (see
  /// [_fitToViewport]) is still there for anyone who wants the old
  /// whole-page overview.
  void _applyInitialView(Size viewportSize) {
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    final view = TiffInitialView.forViewport(
      widget.engine.levels.first.image.metadata,
      viewportWidth: viewportSize.width,
      viewportHeight: viewportSize.height,
      devicePixelRatio: devicePixelRatio,
      maxDecodedPixels: _initialViewMaxPixels,
    );
    _controller.value = _initialViewTransform(view, viewportSize, devicePixelRatio);
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
              _applyInitialView(viewportSize);
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
                child: TiffMinimap(
                  overview: widget.engine.overview,
                  baseWidth: widget.engine.baseWidth,
                  baseHeight: widget.engine.baseHeight,
                  controller: _controller,
                  viewportSize: viewportSize,
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
