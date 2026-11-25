import 'package:flutter/material.dart';

/// The buttons of a recovery/action card: one full-width primary, secondary
/// actions two to a row when every label fits, otherwise stacked.
class RecoveryActions extends StatelessWidget {
  const RecoveryActions({super.key, required this.primaryLabel, required this.onPrimary, this.secondary = const []});

  static const double gap = 8;

  final String primaryLabel;
  final VoidCallback? onPrimary;
  final List<({String label, VoidCallback? onPressed})> secondary;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 15);
    const padding = 2 * 22.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final half = (constraints.maxWidth - gap) / 2;
        bool fits(String label, {double? availableWidth, double insets = padding}) {
          final painter = TextPainter(
            text: TextSpan(text: label, style: labelStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width + insets <= (availableWidth ?? half);
        }

        Widget labelText(String label, {double insets = padding}) {
          final singleLine = fits(label, availableWidth: constraints.maxWidth, insets: insets);
          return Text(label, maxLines: singleLine ? 1 : null, textAlign: singleLine ? null : TextAlign.center);
        }

        Widget outlined(({String label, VoidCallback? onPressed}) action) =>
            OutlinedButton(onPressed: action.onPressed, child: labelText(action.label));
        final paired = secondary.length > 1 && secondary.every((a) => fits(a.label));
        final rows = <Widget>[
          if (paired)
            for (var i = 0; i < secondary.length; i += 2)
              i + 1 < secondary.length
                  ? Row(
                      children: [
                        Expanded(child: outlined(secondary[i])),
                        const SizedBox(width: gap),
                        Expanded(child: outlined(secondary[i + 1])),
                      ],
                    )
                  : outlined(secondary[i])
          else
            for (final action in secondary) outlined(action),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(onPressed: onPrimary, child: labelText(primaryLabel, insets: 48)),
            for (final row in rows) ...[const SizedBox(height: gap), row],
          ],
        );
      },
    );
  }
}
