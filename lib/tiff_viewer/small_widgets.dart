part of '../tiff_viewer_page.dart';

class _WorkingIndicator extends StatelessWidget {
  const _WorkingIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)),
          SizedBox(width: 8),
          Text('Đang tải nét...', style: TextStyle(color: Colors.white, fontSize: 11)),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  const _RoundIconButton({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: IconButton(icon: Icon(icon, color: Colors.white, size: 20), tooltip: tooltip, onPressed: onPressed),
    );
  }
}

class _AdjustmentSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  const _AdjustmentSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(child: Slider(value: value, min: min, max: max, onChanged: onChanged)),
        SizedBox(width: 48, child: Text(display, textAlign: TextAlign.end)),
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String title;
  final Object error;
  const _ErrorCard({required this.title, required this.error});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('$error'),
          ],
        ),
      ),
    );
  }
}
