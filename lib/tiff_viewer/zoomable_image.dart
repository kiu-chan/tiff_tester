part of '../tiff_viewer_page.dart';

/// Pans/zooms [image] via [InteractiveViewer], with a minimap overlay
/// (tap/drag to jump to a spot) and a scale bar computed from [scale].
class _ZoomableTiffImage extends StatefulWidget {
  final ui.Image image;
  final _PixelScale scale;
  const _ZoomableTiffImage({super.key, required this.image, required this.scale});

  @override
  State<_ZoomableTiffImage> createState() => _ZoomableTiffImageState();
}

class _ZoomableTiffImageState extends State<_ZoomableTiffImage> {
  final _controller = TransformationController();
  bool _fitted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _fitToViewport(Size viewportSize) {
    final imageSize = Size(widget.image.width.toDouble(), widget.image.height.toDouble());
    final scale = math.min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height);
    final dx = (viewportSize.width - imageSize.width * scale) / 2;
    final dy = (viewportSize.height - imageSize.height * scale) / 2;
    _controller.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    final imageSize = Size(widget.image.width.toDouble(), widget.image.height.toDouble());
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        if (!_fitted) {
          _fitted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fitToViewport(viewportSize);
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
                    child: RawImage(key: const Key('mainImage'), image: widget.image, width: imageSize.width, height: imageSize.height),
                  ),
                ),
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
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => _Minimap(image: widget.image, controller: _controller, viewportSize: viewportSize),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Same pan/zoom/minimap/scale-bar shell as [_ZoomableTiffImage], but the
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
              _fitToViewport(viewportSize);
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
                child: AnimatedBuilder(
                  animation: Listenable.merge([_controller, widget.engine]),
                  builder: (context, _) => _TiledMinimap(engine: widget.engine, controller: _controller, viewportSize: viewportSize),
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
