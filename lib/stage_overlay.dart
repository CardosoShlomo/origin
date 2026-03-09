import 'package:flutter/widgets.dart';
import 'stage.dart';

class StageOverlay extends StatelessWidget {
  const StageOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final data = Stage.of(context);

    return ValueListenableBuilder<Rect>(
      valueListenable: data.rect,
      builder: (context, rect, child) {
        if (rect case .zero) return const SizedBox.shrink();

        return Stack(
          fit: .expand,
          children: [
            const _Scrim(),
            Positioned.fromRect(
              rect: rect,
              child: ValueListenableBuilder<Rotation?>(
                valueListenable: data.rotation,
                builder: (context, rotation, child) {
                  if (rotation == null) return child!;
                  return Transform(
                    transform: rotation.toMatrix4(data.perspective),
                    alignment: .center,
                    child: child,
                  );
                },
                child: child,
              ),
            ),
          ],
        );
      },
      child: ValueListenableBuilder<double>(
        valueListenable: data.originToBaseProgress,
        builder: (context, p, child) {
          final br = BorderRadius.lerp(data.origin.value.borderRadius, data.display.value.borderRadius, p)!;
          final clipped = ClipRRect(borderRadius: br, child: child);
          return data.gestureBuilder?.call(context, clipped) ?? clipped;
        },
        child: Builder(builder: (context) {
          return Stage.widgetOf(context) ?? const SizedBox.shrink();
        }),
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) {
    final data = Stage.of(context);
    final color = data.backgroundColor;
    if (color == null) return const SizedBox.shrink();

    return ValueListenableBuilder<double>(
      valueListenable: data.originToBaseProgress,
      builder: (context, p, _) {
        return ColoredBox(
          color: .lerp(color.withValues(alpha: 0), color, p)!,
          child: const SizedBox.expand(),
        );
      },
    );
  }
}
