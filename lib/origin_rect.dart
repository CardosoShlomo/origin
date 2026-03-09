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
