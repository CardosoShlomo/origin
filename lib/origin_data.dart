import 'package:flutter/widgets.dart';
import 'origin_ext_on_rect.dart';
import 'origin_triggers.dart';

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

  OriginRect copyWith({
    Rect? rect,
    BorderRadius? borderRadius,
    bool? animate,
  }) {
    return OriginRect(
      rect: rect ?? this.rect,
      borderRadius: borderRadius ?? this.borderRadius,
      animate: animate ?? this.animate,
    );
  }
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
    required this.effectTransform,
    required this.widget,
    required this.perspective,
    required this.gestureBuilder,
    required this.onEnd,
    required this.tag,
    required this.itemGesturing,
    required this.setPerspective,
    required this.setGestureBuilder,
    required this.setOnEnd,
    required this.setTag,
    required this.setItemGesturing,
    required this.setRect,
    required this.animateRect,
    required this.reset,
    required this.animateToBase,
    required this.dismiss,
    required this.runEffect,
    required super.child,
  });

  final ValueNotifier<OriginRect> origin;
  final ValueNotifier<OriginRect> originContainer;
  final ValueNotifier<OriginRect> display;
  final ValueNotifier<OriginRect> displayContainer;

  final ValueNotifier<double> aspectRatio;
  final ValueNotifier<Rect> rect;
  final ValueNotifier<Matrix4?> effectTransform;
  final ValueNotifier<Widget?> widget;

  final double? perspective;
  final OriginBuilder? gestureBuilder;
  final VoidCallback? onEnd;
  final Object? tag;
  final bool itemGesturing;

  final ValueSetter<double?> setPerspective;
  final ValueSetter<OriginBuilder?> setGestureBuilder;
  final ValueSetter<VoidCallback?> setOnEnd;
  final ValueSetter<Object?> setTag;
  final ValueSetter<bool> setItemGesturing;
  final ValueSetter<Rect> setRect;
  final AnimateRect animateRect;
  final VoidCallback reset;
  final Future<void> Function() animateToBase;
  final Future<void> Function() dismiss;
  final Future<void> Function({
    double? rotateX,
    double? rotateY,
    double? rotateZ,
    double? perspective,
    Duration duration,
    Curve curve,
  }) runEffect;

  BorderRadius get borderRadius {
    final originW = origin.value.rect.width;
    final baseW = display.value.rect.baseWidth(aspectRatio.value);
    final t = (rect.value.width.clamp(originW, baseW) - originW) / (baseW - originW);
    return BorderRadius.lerp(origin.value.borderRadius, display.value.borderRadius, t)!;
  }

  @override
  bool updateShouldNotify(OriginData oldWidget) => true;

  @override
  bool updateShouldNotifyDependent(OriginData oldWidget, Set<String> dependencies) {
    if (dependencies.contains('tag') && tag != oldWidget.tag) return true;
    if (dependencies.contains('itemGesturing') && itemGesturing != oldWidget.itemGesturing) return true;
    return false;
  }
}

abstract final class Origin {
  static OriginData of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<OriginData>()!;
  }

  static Object? tagOf(BuildContext context) {
    return InheritedModel.inheritFrom<OriginData>(context, aspect: 'tag')!.tag;
  }
}
