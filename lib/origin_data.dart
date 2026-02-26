import 'package:flutter/widgets.dart';

typedef AnimateRect = Future<void> Function({required Rect to, Duration? duration, Curve curve});

class OriginRect {
  const OriginRect({
    required this.rect,
    this.borderRadius = BorderRadius.zero,
    this.animate = true,
  });

  final Rect rect;
  final BorderRadius borderRadius;
  final bool animate;
}

class OriginData extends InheritedWidget {
  const OriginData({
    super.key,
    required this.origin,
    required this.originContainer,
    required this.display,
    required this.displayContainer,
    required this.aspectRatio,
    required this.rect,
    required this.widget,
    required this.setRect,
    required this.animateRect,
    required super.child,
  });

  final ValueNotifier<OriginRect> origin;
  final ValueNotifier<OriginRect> originContainer;
  final ValueNotifier<OriginRect> display;
  final ValueNotifier<OriginRect> displayContainer;

  final ValueNotifier<double> aspectRatio;
  final ValueNotifier<Rect> rect;
  final ValueNotifier<Widget?> widget;

  final ValueSetter<Rect> setRect;
  final AnimateRect animateRect;

  static OriginData of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<OriginData>()!;
  }

  @override
  bool updateShouldNotify(OriginData oldWidget) => false;
}
