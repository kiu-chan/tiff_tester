part of '../tiff_viewer_page.dart';

/// Small overview of the whole image with a rectangle marking the area
/// currently visible in the main viewer; tap or drag on it to jump there.
class _Minimap extends StatelessWidget {
  static const _boxSize = Size(140, 100);

  final ui.Image image;
  final TransformationController controller;
  final Size viewportSize;

  const _Minimap({required this.image, required this.controller, required this.viewportSize});

  Rect _visibleImageRect() {
    final inverse = Matrix4.copy(controller.value)..invert();
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(inverse, Offset(viewportSize.width, viewportSize.height));
    final rect = Rect.fromPoints(topLeft, bottomRight);
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    return Rect.fromLTRB(rect.left.clamp(0.0, w), rect.top.clamp(0.0, h), rect.right.clamp(0.0, w), rect.bottom.clamp(0.0, h));
  }

  void _navigateTo(Offset imagePoint) {
    final scale = controller.value.getMaxScaleOnAxis();
    final dx = viewportSize.width / 2 - imagePoint.dx * scale;
    final dy = viewportSize.height / 2 - imagePoint.dy * scale;
    controller.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    return Container(
      width: _boxSize.width,
      height: _boxSize.height,
      decoration: BoxDecoration(border: Border.all(color: Colors.white70), color: Colors.black45),
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: w,
          height: h,
          child: GestureDetector(
            onTapUp: (d) => _navigateTo(d.localPosition),
            onPanUpdate: (d) => _navigateTo(d.localPosition),
            child: Stack(
              children: [
                RawImage(image: image, width: w, height: h),
                CustomPaint(size: Size(w, h), painter: _ViewportRectPainter(_visibleImageRect())),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Minimap for the tiled viewer: same behavior as [_Minimap], but draws
/// [_TileEngine.overview] (cheap, always sized to the base image's aspect
/// ratio) rather than a single full-resolution [ui.Image].
class _TiledMinimap extends StatelessWidget {
  static const _boxSize = Size(140, 100);

  final _TileEngine engine;
  final TransformationController controller;
  final Size viewportSize;

  const _TiledMinimap({required this.engine, required this.controller, required this.viewportSize});

  Rect _visibleImageRect(Size baseSize) {
    final inverse = Matrix4.copy(controller.value)..invert();
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(inverse, Offset(viewportSize.width, viewportSize.height));
    final rect = Rect.fromPoints(topLeft, bottomRight);
    return Rect.fromLTRB(
      rect.left.clamp(0.0, baseSize.width),
      rect.top.clamp(0.0, baseSize.height),
      rect.right.clamp(0.0, baseSize.width),
      rect.bottom.clamp(0.0, baseSize.height),
    );
  }

  void _navigateTo(Offset imagePoint) {
    final scale = controller.value.getMaxScaleOnAxis();
    final dx = viewportSize.width / 2 - imagePoint.dx * scale;
    final dy = viewportSize.height / 2 - imagePoint.dy * scale;
    controller.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    final baseSize = Size(engine.baseWidth.toDouble(), engine.baseHeight.toDouble());
    final overview = engine.overview;
    return Container(
      width: _boxSize.width,
      height: _boxSize.height,
      decoration: BoxDecoration(border: Border.all(color: Colors.white70), color: Colors.black45),
      child: overview == null
          ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)))
          : FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: baseSize.width,
                height: baseSize.height,
                child: GestureDetector(
                  onTapUp: (d) => _navigateTo(d.localPosition),
                  onPanUpdate: (d) => _navigateTo(d.localPosition),
                  child: Stack(
                    children: [
                      SizedBox(width: baseSize.width, height: baseSize.height, child: RawImage(image: overview, width: baseSize.width, height: baseSize.height)),
                      CustomPaint(size: baseSize, painter: _ViewportRectPainter(_visibleImageRect(baseSize))),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _ViewportRectPainter extends CustomPainter {
  final Rect rect;
  _ViewportRectPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = (size.longestSide / 150).clamp(1.0, 40.0);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _ViewportRectPainter oldDelegate) => oldDelegate.rect != rect;
}
