import 'package:flutter/widgets.dart';
import 'origin_data.dart';

/// The rendering layer of the animated item.
class OriginOverlay extends StatelessWidget {
  const OriginOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final data = Origin.of(context);

    return ValueListenableBuilder<Rect>(
      valueListenable: data.rect,
      builder: (context, rect, child) {
        if (rect case .zero) return const SizedBox.shrink();

        return Positioned.fromRect(
          rect: rect,
          child: ClipRRect(borderRadius: data.borderRadius, child: child!),
        );
      },
      child: ValueListenableBuilder<Widget?>(
        valueListenable: data.widget,
        builder: (context, widget, _) {
          return widget ?? const SizedBox.shrink();
        },
      ),
    );
  }
}
