import 'package:flutter/gestures.dart';
import 'gestures.dart';

class StageScaleRecognizer extends ScaleGestureRecognizer {
  StageScaleRecognizer({super.supportedDevices, super.dragStartBehavior = .down});

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
    final count = pointerPositions.length;
    // Focal point and scale recompute against the new pointer set when one
    // is added/removed, so velocity across that step is meaningless.
    if (count != _lastCount) {
      _prevScale = details.scale;
      _prevFocal = details.focalPoint;
      _prevTime = details.sourceTimeStamp;
    } else {
      _prevScale = _lastScale;
      _prevFocal = _lastFocal;
      _prevTime = _lastTime;
    }
    _lastScale = details.scale;
    _lastFocal = details.focalPoint;
    _lastTime = details.sourceTimeStamp;
    _lastCount = count;
    _onUpdate?.call(details);
  }

  /// Current positions per tracked pointer (live state). Updated on pointer
  /// down/move/up. Exposed for hybrid mergers that combine pointer sets
  /// across recognizers.
  final pointerPositions = <int, Offset>{};
  /// Fires whenever [pointerPositions] changes (pointer added, moved, or
  /// removed). Receivers can read [pointerPositions] from this recognizer
  /// to get the latest state.
  void Function()? onPointersChanged;
  Offset _totalDelta = .zero;

  // Sample pairs for end-velocity computation (linear focal-point + scale rate).
  double _prevScale = 1.0;
  double _lastScale = 1.0;
  Offset _prevFocal = .zero;
  Offset _lastFocal = .zero;
  Duration? _prevTime;
  Duration? _lastTime;
  int _lastCount = 0;

  bool get _hasSingle => drag?.isNotEmpty ?? false;
  bool get _hasMulti => scale?.isNotEmpty ?? false;
  bool get _hasAny => _hasSingle || _hasMulti;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (pointerPositions.isEmpty) {
      _totalDelta = .zero;
      _resolved = false;
      _accepted = false;
      _prevScale = _lastScale = 1.0;
      _prevFocal = _lastFocal = .zero;
      _prevTime = _lastTime = null;
      _lastCount = 0;
    }
    pointerPositions[event.pointer] = event.position;
    onPointersChanged?.call();
    super.addAllowedPointer(event);
    if (_hasAny && pointerPositions.length > 1 && !_hasMulti) {
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
    var pointersDirty = false;
    if (event is PointerMoveEvent) {
      _totalDelta += event.delta;
      pointerPositions[event.pointer] = event.position;
      pointersDirty = true;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      pointerPositions.remove(event.pointer);
      pointersDirty = true;
    }
    if (pointersDirty) onPointersChanged?.call();
    super.handleEvent(event);
    if (!_resolved && (!_hasAny || pointerPositions.length > 1 || _totalDelta.distance > 4)) {
      _resolved = true;
      resolve(.accepted);
    }
    if (pointerPositions.isEmpty && _accepted) {
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
      if (pointerPositions.length <= 1) {
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
    pointerPositions.remove(pointer);
    super.rejectGesture(pointer);
  }
}
