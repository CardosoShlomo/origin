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
      _focalTracker = VelocityTracker.withKind(_kind);
      _scaleTracker = VelocityTracker.withKind(_kind);
    }
    _lastCount = count;
    final time = details.sourceTimeStamp;
    if (time != null) {
      _focalTracker?.addPosition(time, details.focalPoint);
      _scaleTracker?.addPosition(time, Offset(details.scale, 0));
    }
    _onUpdate?.call(details);
  }

  /// Current positions per tracked pointer (live state). Updated on pointer
  /// down/move/up. Exposed for hybrid mergers that combine pointer sets
  /// across recognizers.
  final pointerPositions = <int, Offset>{};

  /// The timestamp of the latest pointer event this recognizer handled. The
  /// hybrid merger times its velocity samples by it.
  Duration? lastEventTime;

  /// Fires whenever [pointerPositions] changes (pointer added, moved, or
  /// removed). Receivers can read [pointerPositions] from this recognizer
  /// to get the latest state.
  void Function()? onPointersChanged;
  Offset _totalDelta = .zero;

  // Release velocity: least-squares over the recent focal-point and scale
  // samples, the same estimate Flutter's own drag and scale use.
  VelocityTracker? _focalTracker;
  VelocityTracker? _scaleTracker;
  PointerDeviceKind _kind = .touch;
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
      _focalTracker = null;
      _scaleTracker = null;
      _kind = event.kind;
      _lastCount = 0;
    }
    pointerPositions[event.pointer] = event.position;
    lastEventTime = event.timeStamp;
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
    lastEventTime = event.timeStamp;
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
    final focal = _focalTracker;
    if (focal == null) return ScaleEndDetails();
    var velocity = focal.getVelocity();
    final speed = velocity.pixelsPerSecond.distance;
    // Below fling speed the release has no velocity; above the cap it is
    // clamped, as Flutter's scale recognizer does.
    if (speed <= kMinFlingVelocity) {
      velocity = Velocity.zero;
    } else if (speed > kMaxFlingVelocity) {
      velocity = Velocity(pixelsPerSecond: velocity.pixelsPerSecond / speed * kMaxFlingVelocity);
    }
    return ScaleEndDetails(
      velocity: velocity,
      scaleVelocity: _scaleTracker?.getVelocity().pixelsPerSecond.dx ?? 0,
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
