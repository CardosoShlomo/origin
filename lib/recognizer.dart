import 'package:flutter/gestures.dart';
import 'gestures.dart';

class StageScaleRecognizer extends ScaleGestureRecognizer {
  StageScaleRecognizer({super.supportedDevices, super.dragStartBehavior = DragStartBehavior.down});

  List<Gesture> gestures = [];

  GestureScaleEndCallback? _onEnd;

  @override
  set onEnd(GestureScaleEndCallback? callback) => _onEnd = callback;

  @override
  GestureScaleEndCallback? get onEnd => _onEnd == null ? null : (_) {};

  final trackedPointers = <int>{};
  Offset _totalDelta = .zero;

  bool get _hasSinglePointerGestures => gestures.any((g) => g.start.any((s) => s.isOne));

  bool get _hasMultiPointerGestures => gestures.any((g) => g.start.any((s) => s.isTwo || s.isScale));

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (trackedPointers.isEmpty) {
      _totalDelta = .zero;
      _resolved = false;
      _accepted = false;
    }
    trackedPointers.add(event.pointer);
    super.addAllowedPointer(event);
  }

  bool _resolved = false;
  bool _accepted = false;

  @override
  void acceptGesture(int pointer) {
    _accepted = true;
    super.acceptGesture(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) _totalDelta += event.delta;
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      trackedPointers.remove(event.pointer);
    }
    super.handleEvent(event);
    if (!_resolved && (gestures.isEmpty || trackedPointers.length > 1 || _totalDelta.distance > 4)) {
      _resolved = true;
      resolve(.accepted);
    }
    if (trackedPointers.isEmpty && _accepted) {
      _onEnd?.call(ScaleEndDetails());
    }
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == .accepted && gestures.isNotEmpty) {
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

  bool _hasStart(GestureStart s) => gestures.any((g) => g.start.contains(s));

  bool _matchesSinglePointer() {
    final dx = _totalDelta.dx;
    final dy = _totalDelta.dy;
    if (dx > 2 && _hasStart(.right)) return true;
    if (dx < -2 && _hasStart(.left)) return true;
    if (dy > 2 && _hasStart(.down)) return true;
    if (dy < -2 && _hasStart(.up)) return true;
    return false;
  }

  @override
  void rejectGesture(int pointer) {
    trackedPointers.remove(pointer);
    super.rejectGesture(pointer);
  }
}
