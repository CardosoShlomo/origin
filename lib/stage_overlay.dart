import 'package:flutter/widgets.dart';
import 'origin_rect.dart';
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

        Widget overlay = Stack(
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

        overlay = ValueListenableBuilder<OriginRect?>(
          valueListenable: data.container,
          builder: (context, container, child) {
            if (container == null) return child!;
            return ClipPath(
              clipper: _ContainerClipper(container.rect, container.borderRadius),
              child: child,
            );
          },
          child: overlay,
        );

        return overlay;
      },
      child: ValueListenableBuilder<double>(
        valueListenable: data.originToBaseProgress,
        builder: (context, p, child) {
          final br = BorderRadius.lerp(data.origin.borderRadius, data.display.borderRadius, p)!;
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

class _ContainerClipper extends CustomClipper<Path> {
  _ContainerClipper(this.rect, this.borderRadius);

  final Rect rect;
  final BorderRadius borderRadius;

  @override
  Path getClip(Size size) => Path()..addRRect(borderRadius.toRRect(rect));

  @override
  bool shouldReclip(_ContainerClipper old) => old.rect != rect || old.borderRadius != borderRadius;
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
