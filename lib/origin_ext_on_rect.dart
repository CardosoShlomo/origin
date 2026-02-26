import 'dart:math';

import 'package:flutter/widgets.dart';

extension OriginRect on Rect {
  Rect baseRect(double aspectRatio) {
    return Rect.fromCenter(
      center: center,
      width: min(width, height * aspectRatio),
      height: min(height, width / aspectRatio),
    );
  }

  Rect shiftToFitInside(Rect container) {
    final dx = width > container.width
        ? center.dx + min(0, container.left - left) + max(0, container.right - right)
        : container.center.dx;
    final dy = height > container.height
        ? center.dy + min(0, container.top - top) + max(0, container.bottom - bottom)
        : container.center.dy;
    return shift(Offset(dx, dy) - center);
  }
}
