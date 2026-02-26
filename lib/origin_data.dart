import 'package:flutter/widgets.dart';
import 'origin_ext_on_rect.dart';

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

class OriginData extends InheritedModel<String> {
  const OriginData({
    super.key,
    required this.origin,
    required this.originContainer,
    required this.display,
    required this.displayContainer,
    required this.aspectRatio,
    required this.rect,
    required this.widget,
    required this.tag,
    required this.setTag,
    required this.setRect,
    required this.animateRect,
    required this.reset,
    required this.animateToBase,
    required this.dismiss,
    required super.child,
  });

  final ValueNotifier<OriginRect> origin;
  final ValueNotifier<OriginRect> originContainer;
  final ValueNotifier<OriginRect> display;
  final ValueNotifier<OriginRect> displayContainer;

  final ValueNotifier<double> aspectRatio;
  final ValueNotifier<Rect> rect;
  final ValueNotifier<Widget?> widget;

  final Object? tag;

  final ValueSetter<Object?> setTag;
  final ValueSetter<Rect> setRect;
  final AnimateRect animateRect;
  final VoidCallback reset;
  final Future<void> Function() animateToBase;
  final Future<void> Function() dismiss;

  BorderRadius get borderRadius {
    final originW = origin.value.rect.width;
    final baseW = display.value.rect.baseWidth(aspectRatio.value);
    final t = (rect.value.width.clamp(originW, baseW) - originW) / (baseW - originW);
    return BorderRadius.lerp(origin.value.borderRadius, display.value.borderRadius, t)!;
  }

  static OriginData of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<OriginData>()!;
  }

  @override
  bool updateShouldNotify(OriginData oldWidget) => true;

  @override
  bool updateShouldNotifyDependent(OriginData oldWidget, Set<String> dependencies) {
    return dependencies.contains('tag') && tag != oldWidget.tag;
  }
}

abstract final class Origin {
  static OriginData of(BuildContext context) => OriginData.of(context);

  static Object? tagOf(BuildContext context) {
    return InheritedModel.inheritFrom<OriginData>(context, aspect: 'tag')!.tag;
  }
}
