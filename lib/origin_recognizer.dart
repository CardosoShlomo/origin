import 'package:flutter/gestures.dart';
import 'origin_triggers.dart';

class OriginScaleRecognizer extends ScaleGestureRecognizer {
  OriginScaleRecognizer({super.supportedDevices, super.dragStartBehavior = DragStartBehavior.down});

  Map<OriginStart, OriginBounds> gestures = {};

  final trackedPointers = <int>{};
  Offset _totalDelta = .zero;

  bool get _hasSinglePointerGestures => gestures.keys.any((s) => switch (s) {
    .left || .right || .up || .down => true,
    _ => false,
  });

  bool get _hasMultiPointerGestures => gestures.keys.any((s) => switch (s) {
    .twoLeft || .twoRight || .twoUp || .twoDown ||
    .pinchIn || .pinchOut => true,
    _ => false,
  });

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (trackedPointers.isEmpty) {
      _totalDelta = .zero;
      _accepted = false;
    }
    trackedPointers.add(event.pointer);
    super.addAllowedPointer(event);
  }

  bool _accepted = false;

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) _totalDelta += event.delta;
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      trackedPointers.remove(event.pointer);
    }
    super.handleEvent(event);
    if (!_accepted && _totalDelta.distance > 4) {
      _accepted = true;
      resolve(.accepted);
    }
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == .accepted) {
      if (trackedPointers.length <= 1) {
        if (!_hasSinglePointerGestures) return;
        if (!_matchesSinglePointer()) {
          super.resolve(.rejected);
          return;
        }
      } else {
        if (!_hasMultiPointerGestures) {
          super.resolve(.rejected);
          return;
        }
      }
    }
    super.resolve(disposition);
  }

  bool _matchesSinglePointer() {
    final dx = _totalDelta.dx;
    final dy = _totalDelta.dy;
    if (dx > 2 && gestures.containsKey(OriginStart.right)) return true;
    if (dx < -2 && gestures.containsKey(OriginStart.left)) return true;
    if (dy > 2 && gestures.containsKey(OriginStart.down)) return true;
    if (dy < -2 && gestures.containsKey(OriginStart.up)) return true;
    return false;
  }

  @override
  void rejectGesture(int pointer) {
    trackedPointers.remove(pointer);
    super.rejectGesture(pointer);
  }
}
