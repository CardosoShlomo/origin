import 'package:flutter/gestures.dart';
import 'gestures.dart';

class StageScaleRecognizer extends ScaleGestureRecognizer {
  StageScaleRecognizer({super.supportedDevices, super.dragStartBehavior = DragStartBehavior.down});

  Map<DragStart, DragGesture>? drag;
  Map<ScaleStart, ScaleGesture>? scale;

  GestureScaleEndCallback? _onEnd;

  @override
  set onEnd(GestureScaleEndCallback? callback) => _onEnd = callback;

  @override
  GestureScaleEndCallback? get onEnd => _onEnd == null ? null : (_) {};

  final trackedPointers = <int>{};
  Offset _totalDelta = .zero;

  bool get _hasSingle => drag?.isNotEmpty ?? false;
  bool get _hasMulti => scale?.isNotEmpty ?? false;
  bool get _hasAny => _hasSingle || _hasMulti;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (trackedPointers.isEmpty) {
      _totalDelta = .zero;
      _resolved = false;
      _accepted = false;
    }
    trackedPointers.add(event.pointer);
    super.addAllowedPointer(event);
    if (_hasAny && trackedPointers.length > 1 && !_hasMulti) {
      _resolved = true;
      resolve(.rejected);
    }
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
    if (!_resolved && (!_hasAny || trackedPointers.length > 1 || _totalDelta.distance > 4)) {
      _resolved = true;
      resolve(.accepted);
    }
    if (trackedPointers.isEmpty && _accepted) {
      _onEnd?.call(ScaleEndDetails());
    }
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == .accepted && _hasAny) {
      if (trackedPointers.length <= 1) {
        if (!_hasSingle) {
          super.resolve(.rejected);
          return;
        }
      } else {
        if (!_hasMulti) {
          super.resolve(.rejected);
          return;
        }
      }
    }
    super.resolve(disposition);
  }

  @override
  void rejectGesture(int pointer) {
    trackedPointers.remove(pointer);
    super.rejectGesture(pointer);
  }
}
