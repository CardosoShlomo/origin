import 'package:flutter/gestures.dart';
import 'gestures.dart';

class StageScaleRecognizer extends ScaleGestureRecognizer {
  StageScaleRecognizer({super.supportedDevices, super.dragStartBehavior = DragStartBehavior.down});

  Map<DragStart, DragGesture>? drag;
  Map<ScaleStart, ScaleGesture>? scale;

  GestureScaleEndCallback? _onEnd;
  GestureScaleUpdateCallback? _onUpdate;

  @override
  set onEnd(GestureScaleEndCallback? callback) => _onEnd = callback;

  // Override to suppress parent's per-pointer-count-change end firing —
  // [StageScaleRecognizer] fires once when all pointers are up.
  @override
  GestureScaleEndCallback? get onEnd => _onEnd == null ? null : (_) {};

  // Override to wrap the user callback with sample tracking.
  @override
  set onUpdate(GestureScaleUpdateCallback? callback) {
    _onUpdate = callback;
    super.onUpdate = callback == null ? null : _trackingUpdate;
  }

  void _trackingUpdate(ScaleUpdateDetails details) {
    _prevScale = _lastScale;
    _prevFocal = _lastFocal;
    _prevTime = _lastTime;
    _lastScale = details.scale;
    _lastFocal = details.focalPoint;
    _lastTime = details.sourceTimeStamp;
    _onUpdate?.call(details);
  }

  final trackedPointers = <int>{};
  Offset _totalDelta = .zero;

  // Sample pairs for end-velocity computation (linear focal-point + scale rate).
  double _prevScale = 1.0;
  double _lastScale = 1.0;
  Offset _prevFocal = .zero;
  Offset _lastFocal = .zero;
  Duration? _prevTime;
  Duration? _lastTime;

  bool get _hasSingle => drag?.isNotEmpty ?? false;
  bool get _hasMulti => scale?.isNotEmpty ?? false;
  bool get _hasAny => _hasSingle || _hasMulti;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (trackedPointers.isEmpty) {
      _totalDelta = .zero;
      _resolved = false;
      _accepted = false;
      _prevScale = _lastScale = 1.0;
      _prevFocal = _lastFocal = .zero;
      _prevTime = _lastTime = null;
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
      _onEnd?.call(_buildEndDetails());
    }
  }

  ScaleEndDetails _buildEndDetails() {
    final pt = _prevTime;
    final lt = _lastTime;
    if (pt == null || lt == null) return ScaleEndDetails();
    final dt = (lt - pt).inMicroseconds / 1e6;
    if (dt <= 0) return ScaleEndDetails();
    return ScaleEndDetails(
      velocity: Velocity(pixelsPerSecond: (_lastFocal - _prevFocal) / dt),
      scaleVelocity: (_lastScale - _prevScale) / dt,
    );
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
