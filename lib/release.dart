import 'package:flutter/widgets.dart';

import 'gestures.dart';
import 'physics.dart';
import 'rect_ext.dart';

/// Partially cancel translation velocity based on scale velocity. Call at
/// the start of `onScaleEnd` and use the returned details as the gesture's
/// velocity for the rest of the release pipeline.
///
/// Two-stage cancellation: below a small threshold, no cancellation at all
/// (the pinch was too subtle to count). Past the threshold, a baseline 30%
/// cancellation kicks in, plus a quadratic growth term in the excess scale
/// velocity. `k ∈ [0, 1]` scales the whole effect, so `k=0` disables.
///
///   amount = k × (0.3 + (|scaleVelocity| − threshold)²)   if past threshold
///   factor = clamp(1 − amount, 0, 1)
///
/// - `k = 0`   → never cancel.
/// - `k = 0.5, threshold = 0.1`: scaleVel 0.1 → 15%; 0.5 → 23%; 1.0 → 55%.
/// - `k = 0.8, threshold = 0.1`: scaleVel 0.1 → 24%; 0.5 → 37%; 1.0 → 89%.
/// - `k = 1.0, threshold = 0.1`: scaleVel 0.1 → 30%; 0.5 → 46%; 1.0 → full.
extension ScaleEndDetailsCancel on ScaleEndDetails {
  static const _threshold = 0.1;

  ScaleEndDetails cancelTranslation(double k) {
    if (k <= 0) return this;
    final scaleVel = scaleVelocity.abs();
    if (scaleVel < _threshold) return this;
    final excess = scaleVel - _threshold;
    final amount = (k * (0.3 + excess * excess)).clamp(0.0, 1.0);
    final factor = 1.0 - amount;
    if (factor == 1.0) return this;
    return ScaleEndDetails(
      velocity: Velocity(pixelsPerSecond: velocity.pixelsPerSecond * factor),
      scaleVelocity: scaleVelocity,
      pointerCount: pointerCount,
    );
  }
}

/// A computed per-axis fling segment.
///
/// `to`, `duration`, `curve` derive from the same FrictionSimulation —
/// `curve` is the physics-exact mapping of normalized animation time to
/// normalized position, not an approximation.
class AxisFling {
  const AxisFling({
    required this.to,
    required this.duration,
    required this.curve,
  });

  final double to;
  final Duration duration;
  final Curve curve;

  AxisFling copyWith({double? to, Duration? duration, Curve? curve}) =>
      AxisFling(
        to: to ?? this.to,
        duration: duration ?? this.duration,
        curve: curve ?? this.curve,
      );
}

/// Per-axis release plan.
///
/// `decay` is the friction-decay phases (sequential), `settle` is the
/// optional final rubber/snap to the natural rest target. The trajectory
/// shape is described by the `direction` + `startZone` + `endZone` fields
/// on the per-axis subclass — pattern-match those for behavior dispatch.
sealed class AxisRelease {
  const AxisRelease({this.decay = const [], this.settle});
  final List<AxisFling> decay;
  final AxisFling? settle;
}

enum HorizontalDir { idle, ltr, rtl }
enum HorizontalZone { pastLeft, left, right, pastRight }

final class HorizontalRelease extends AxisRelease {
  const HorizontalRelease({
    required this.direction,
    required this.startZone,
    required this.endZone,
    super.decay,
    super.settle,
  });
  final HorizontalDir direction;
  final HorizontalZone startZone;
  final HorizontalZone endZone;

  HorizontalRelease copyWith({
    HorizontalDir? direction,
    HorizontalZone? startZone,
    HorizontalZone? endZone,
    List<AxisFling>? decay,
    AxisFling? settle,
  }) =>
      HorizontalRelease(
        direction: direction ?? this.direction,
        startZone: startZone ?? this.startZone,
        endZone: endZone ?? this.endZone,
        decay: decay ?? this.decay,
        settle: settle ?? this.settle,
      );
}

enum VerticalDir { idle, ttb, btt }
enum VerticalZone { pastTop, top, bottom, pastBottom }

final class VerticalRelease extends AxisRelease {
  const VerticalRelease({
    required this.direction,
    required this.startZone,
    required this.endZone,
    super.decay,
    super.settle,
  });
  final VerticalDir direction;
  final VerticalZone startZone;
  final VerticalZone endZone;

  VerticalRelease copyWith({
    VerticalDir? direction,
    VerticalZone? startZone,
    VerticalZone? endZone,
    List<AxisFling>? decay,
    AxisFling? settle,
  }) =>
      VerticalRelease(
        direction: direction ?? this.direction,
        startZone: startZone ?? this.startZone,
        endZone: endZone ?? this.endZone,
        decay: decay ?? this.decay,
        settle: settle ?? this.settle,
      );
}

enum ScaleDir { idle, outward, inward }
enum ScaleZone { pastShrink, shrink, expand, pastExpand }

final class ScaleRelease extends AxisRelease {
  const ScaleRelease({
    required this.direction,
    required this.startZone,
    required this.endZone,
    super.decay,
    super.settle,
  });
  final ScaleDir direction;
  final ScaleZone startZone;
  final ScaleZone endZone;

  ScaleRelease copyWith({
    ScaleDir? direction,
    ScaleZone? startZone,
    ScaleZone? endZone,
    List<AxisFling>? decay,
    AxisFling? settle,
  }) =>
      ScaleRelease(
        direction: direction ?? this.direction,
        startZone: startZone ?? this.startZone,
        endZone: endZone ?? this.endZone,
        decay: decay ?? this.decay,
        settle: settle ?? this.settle,
      );
}

/// Inputs the package used (and the consumer can use) to build a [Release].
/// Pure data — `gesture` carries the bound configs (decelerate, friction)
/// and the maxScale/minScale used by the default plan.
class ReleaseContext {
  const ReleaseContext({
    required this.currentRect,
    required this.displayRect,
    required this.aspectRatio,
    required this.velocity,
    required this.scaleVelocity,
    required this.gesture,
  });

  final Rect currentRect;
  final Rect displayRect;
  final double aspectRatio;
  final Velocity velocity;
  final double scaleVelocity;
  final Gesture gesture;

  Rect get baseRect => displayRect.baseRect(aspectRatio);
}

/// Bundled per-axis plans. Built from a [ReleaseContext] via factories.
class Release {
  const Release({required this.x, required this.y, required this.scale});

  final HorizontalRelease x;
  final VerticalRelease y;
  final ScaleRelease scale;

  /// The default plan: settle back into the viewport (display). Per axis,
  /// physics-derived flings whose final settle (rubber) lands at a viewport-
  /// correct position — covers display when zoomed (with maxScale clamp +
  /// proportional pan preservation), snaps to base when not zoomed.
  factory Release.toDisplay(ReleaseContext data) {
    final scaleRelease = _scaleReleaseFor(data);
    final scaleTargetWidth = scaleRelease.settle?.to
        ?? (scaleRelease.decay.isEmpty
            ? data.currentRect.width
            : scaleRelease.decay.last.to);
    // Rect at the post-scale-settle dims — used by per-axis helpers to
    // compute viewport-fit at gesture-end *and* decay-end positions.
    final projectedRect = data.currentRect.resizeOnCenter(
      scaleTargetWidth,
      scaleTargetWidth / data.aspectRatio,
    );
    // Damp translation velocity by how scale-y the gesture was at end —
    // a strong pinch means the residual finger drift on the focal point
    // shouldn't translate into a pan fling. `scaleVelocityCancel` (0..1)
    // tunes the overall strength.
    //
    return Release(
      x: releaseFromStateX(
        currentRect: data.currentRect,
        displayRect: data.displayRect,
        bounds: data.gesture.bounds,
        velocity: data.velocity.pixelsPerSecond.dx,
        projectedRect: projectedRect,
      ),
      y: releaseFromStateY(
        currentRect: data.currentRect,
        displayRect: data.displayRect,
        bounds: data.gesture.bounds,
        velocity: data.velocity.pixelsPerSecond.dy,
        projectedRect: projectedRect,
      ),
      scale: scaleRelease,
    );
  }

  /// Decay-only plan: physics-derived friction phases per axis, no settle.
  /// The rect ends wherever the physics naturally halts. Useful as a building
  /// block for flows that compose decay with a custom finalize step (e.g.,
  /// dismiss to origin).
  factory Release.toHalt(ReleaseContext data) {
    final plan = Release.toDisplay(data);
    return Release(
      x: HorizontalRelease(
        direction: plan.x.direction,
        startZone: plan.x.startZone,
        endZone: plan.x.endZone,
        decay: plan.x.decay,
      ),
      y: VerticalRelease(
        direction: plan.y.direction,
        startZone: plan.y.startZone,
        endZone: plan.y.endZone,
        decay: plan.y.decay,
      ),
      scale: ScaleRelease(
        direction: plan.scale.direction,
        startZone: plan.scale.startZone,
        endZone: plan.scale.endZone,
        decay: plan.scale.decay,
      ),
    );
  }

  Release copyWith({
    HorizontalRelease? x,
    VerticalRelease? y,
    ScaleRelease? scale,
  }) =>
      Release(
        x: x ?? this.x,
        y: y ?? this.y,
        scale: scale ?? this.scale,
      );


  static ScaleRelease _scaleReleaseFor(ReleaseContext data) {
    final baseWidth = data.displayRect.baseWidth(data.aspectRatio);
    if (data.gesture case ScaleGesture(:final shrink, :final expand)) {
      return releaseFromStateScale(
        width: data.currentRect.width,
        baseWidth: baseWidth,
        shrink: shrink,
        expand: expand,
        velocity: data.scaleVelocity * baseWidth,
      );
    }
    return releaseFromStateScale(
      width: data.currentRect.width,
      baseWidth: baseWidth,
      shrink: null,
      expand: null,
      velocity: 0,
    );
  }
}

/// Signature for a gesture-end handler. Consumer receives raw inputs via
/// [ReleaseContext]; calls `Release.toDisplay(data)` (or builds a custom plan)
/// and runs it via `Stage.of(context).release(...)` / `.run(...)`.
typedef OnRelease = void Function(BuildContext context, ReleaseContext data);
