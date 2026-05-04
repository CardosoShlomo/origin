import 'dart:math';

import 'package:flutter/widgets.dart';

import 'rect_ext.dart';

extension ScaleExt on ScaleUpdateDetails {
  Rect rect({
    required Rect startRect,
    required Rect currentRect,
  }) {
    final width = startRect.width * scale;
    final height = startRect.height * scale;
    if (currentRect.width == 0) return currentRect;
    final center = (currentRect.center - focalPoint) * width / currentRect.width + focalPoint + focalPointDelta;
    return Rect.fromCenter(
      center: center,
      width: width,
      height: height,
    );
  }

  Rect imageRectOnDragCropRect({
    required Rect container,
    required Rect imageRect,
    required Rect cropRect,
  }) {
    double dx = -focalPointDelta.dx;
    if ((cropRect.width - container.width).abs() > 1) {
      final leftToFocalDistance = max(0.1, focalPoint.dx - cropRect.left);
      final rightToFocalDistance = max(0.1, cropRect.right - focalPoint.dx);
      if (focalPointDelta.dx < 0 && (cropRect.left - container.left).abs() < 1) {
        dx += 3 - min(3, leftToFocalDistance/rightToFocalDistance);
      } else if (focalPointDelta.dx > 0 && (cropRect.right - container.right).abs() < 1) {
        dx -= 3 - min(3, rightToFocalDistance/leftToFocalDistance);
      } else {
        dx = 0;
      }
    }

    double dy = -focalPointDelta.dy;
    if ((cropRect.height - container.height).abs() > 1) {
      final topToFocalDistance = max(0.1, focalPoint.dy - cropRect.top);
      final bottomToFocalDistance = max(0.1, cropRect.bottom - focalPoint.dy);
      if (focalPointDelta.dy < 0 && (cropRect.top - container.top).abs() < 1) {
        dy += 3 - min(3, topToFocalDistance/bottomToFocalDistance);
      } else if (focalPointDelta.dy > 0 && (cropRect.bottom - container.bottom).abs() < 1) {
        dy -= 3 - min(3, bottomToFocalDistance/topToFocalDistance);
      } else {
        dy = 0;
      }
    }

    return imageRect
        .translate(dx, dy)
        .shiftXToFitInside(container)
        .shiftYToFitInside(container);
  }
}

extension ContextExt on BuildContext {
  Rect get rect {
    final box = findRenderObject() as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}
