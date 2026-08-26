part of '../tiff_viewer_page.dart';

/// A scale bar (like on a map) showing what a "nice" round length on screen
/// represents in the file's real-world unit, plus the current zoom percent.
class _ScaleBar extends StatelessWidget {
  final Matrix4 transform;
  final _PixelScale scale;
  const _ScaleBar({required this.transform, required this.scale});

  static const _maxBarWidth = 110.0;

  (double, double) _pickBarLength(double realUnitPerScreenPixel) {
    if (realUnitPerScreenPixel <= 0 || !realUnitPerScreenPixel.isFinite) return (0, 0);
    final maxReal = _maxBarWidth * realUnitPerScreenPixel;
    if (maxReal <= 0 || !maxReal.isFinite) return (0, 0);
    final exp = (math.log(maxReal) / math.ln10).floor();
    var best = math.pow(10, exp).toDouble();
    for (final m in [1, 2, 5, 10]) {
      final candidate = m * math.pow(10, exp).toDouble();
      if (candidate <= maxReal) best = candidate.toDouble();
    }
    return (best, best / realUnitPerScreenPixel);
  }

  String _formatLength(double length) {
    final text = length >= 100
        ? length.toStringAsFixed(0)
        : length >= 1
        ? (length.truncateToDouble() == length ? length.toStringAsFixed(0) : length.toStringAsFixed(1))
        : length.toStringAsFixed(3);
    return '$text ${scale.unitLabel}';
  }

  @override
  Widget build(BuildContext context) {
    final zoom = transform.getMaxScaleOnAxis();
    final (length, barWidth) = _pickBarLength(scale.unitsPerPixelX / zoom);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${(zoom * 100).toStringAsFixed(0)}%', style: const TextStyle(color: Colors.white, fontSize: 11)),
          if (barWidth > 0) ...[
            const SizedBox(height: 4),
            CustomPaint(size: Size(barWidth, 8), painter: _ScaleBarPainter()),
            const SizedBox(height: 2),
            Text(_formatLength(length), style: const TextStyle(color: Colors.white, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

class _ScaleBarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), paint);
    canvas.drawLine(const Offset(0, 0), Offset(0, size.height), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _ScaleBarPainter oldDelegate) => false;
}
