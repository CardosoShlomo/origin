import 'package:flutter/widgets.dart';
import 'origin_data.dart';

/// The interactive overlay that renders the animated item.
class OriginOverlay extends StatefulWidget {
  const OriginOverlay({super.key});

  @override
  State<OriginOverlay> createState() => _OriginOverlayState();
}

class _OriginOverlayState extends State<OriginOverlay> {
  Offset _dragStart = .zero;
  Rect _dragStartRect = .zero;

  void _onScaleStart(ScaleStartDetails details) {
    _dragStart = details.focalPoint;
    _dragStartRect = OriginData.of(context).rect.value;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final delta = details.focalPoint - _dragStart;
    final data = OriginData.of(context);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final scale = (1 - delta.dy.abs() / screenHeight).clamp(0.5, 1.0);
    data.rect.value = Rect.fromCenter(
      center: _dragStartRect.center + delta,
      width: _dragStartRect.width * scale,
      height: _dragStartRect.height * scale,
    );
  }

  void _onScaleEnd(ScaleEndDetails details) async {
    final data = OriginData.of(context);
    final delta = data.rect.value.center - _dragStartRect.center;
    final screenHeight = MediaQuery.sizeOf(context).height;
    if (delta.dy.abs() > screenHeight * 0.2) {
      await data.animateRect(to: data.origin.value.rect, curve: Curves.easeOut);
      data.setRect(.zero);
      data.widget.value = null;
    } else {
      data.animateRect(to: _dragStartRect, curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = OriginData.of(context);

    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd: _onScaleEnd,
      child: ValueListenableBuilder<Rect>(
        valueListenable: data.rect,
        builder: (context, rect, child) {
          if (rect case .zero) return const SizedBox.shrink();

          return Positioned.fromRect(
            rect: rect,
            child: child!,
          );
        },
        child: ValueListenableBuilder<Widget?>(
          valueListenable: data.widget,
          builder: (context, widget, _) {
            return widget ?? const SizedBox.shrink();
          },
        ),
      ),
    );
  }
}
