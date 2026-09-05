part of '../tiff_viewer_page.dart';

/// A titled [Card] used to group one logical section of the viewer page
/// (file info, metadata, optimize controls, ...) so the page reads as a
/// list of distinct panels rather than one long flat column.
class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;
  const _SectionCard({required this.title, required this.icon, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// Like [_SectionCard], but collapsible — used for advanced/secondary panels
/// (optimize knobs, developer tools) that shouldn't compete for attention
/// with the primary actions by default.
class _CollapsibleSectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget child;
  const _CollapsibleSectionCard({required this.title, this.subtitle, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: Icon(icon, size: 20, color: colorScheme.primary),
          title: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          subtitle: subtitle != null ? Text(subtitle!, style: Theme.of(context).textTheme.bodySmall) : null,
          children: [child],
        ),
      ),
    );
  }
}

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
          Text('Loading detail...', style: TextStyle(color: Colors.white, fontSize: 11)),
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
        SizedBox(width: 84, child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3),
            child: Slider(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
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
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, size: 20, color: colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(fontWeight: FontWeight.bold, color: colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText('$error', style: TextStyle(color: colorScheme.onErrorContainer)),
          ],
        ),
      ),
    );
  }
}
