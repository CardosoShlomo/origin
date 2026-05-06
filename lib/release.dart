import 'package:flutter/widgets.dart';

/// A computed per-axis fling segment.
///
/// `to`, `duration`, `curve` derive from the same FrictionSimulation —
/// `curve` is the physics-exact mapping of normalized animation time to
/// normalized position, not an approximation.
typedef AxisFling = ({double to, Duration duration, Curve curve});

// ─────────────────────────────────────────────────────────────────────────────
// Sealed per-axis release hierarchies.
//
// Each axis (horizontal X, vertical Y, scale) has its own sealed parent.
// Direction is encoded in the class name; the trajectory shape is the type.
//
// Trajectory shapes (per axis):
//   - Idle in display              — no motion, rect inside display.
//   - Idle past <side>             — no motion, rect past a bound. Rubber to edge.
//   - <Direction> fling in display — decay ends inside display.
//   - <Direction> continuation     — released past + retracting, didn't reach
//                                    edge. Rubber continues inward to edge.
//   - <Direction> spring-back      — outward trajectory ending past display.
//                                    Rubber springs back from peak.
//
// Phase fields (when present) run sequentially in trajectory order.
// Optional fields appear only for shapes where the phase may be skipped.
// ─────────────────────────────────────────────────────────────────────────────

sealed class HorizontalRelease {
  const HorizontalRelease();
}

sealed class VerticalRelease {
  const VerticalRelease();
}

sealed class ScaleRelease {
  const ScaleRelease();
}

/// No motion, rect inside display. Shared across all three axes.
final class IdleInDisplay
    implements HorizontalRelease, VerticalRelease, ScaleRelease {
  const IdleInDisplay();
}

// ─── Horizontal ──────────────────────────────────────────────────────────────

final class IdlePastLeft implements HorizontalRelease {
  const IdlePastLeft(this.rubber);
  final AxisFling rubber;
}

final class IdlePastRight implements HorizontalRelease {
  const IdlePastRight(this.rubber);
  final AxisFling rubber;
}

final class LeftToRightFlingInDisplay implements HorizontalRelease {
  const LeftToRightFlingInDisplay({this.pastLeft, this.left, this.right});
  final AxisFling? pastLeft;
  final AxisFling? left;
  final AxisFling? right;
}

final class LeftToRightContinuation implements HorizontalRelease {
  const LeftToRightContinuation({required this.pastLeft, required this.rubber});
  final AxisFling pastLeft;
  final AxisFling rubber;
}

final class LeftToRightSpringBack implements HorizontalRelease {
  const LeftToRightSpringBack({
    this.pastLeft,
    this.left,
    this.right,
    required this.pastRight,
    required this.rubber,
  });
  final AxisFling? pastLeft;
  final AxisFling? left;
  final AxisFling? right;
  final AxisFling pastRight;
  final AxisFling rubber;
}

final class RightToLeftFlingInDisplay implements HorizontalRelease {
  const RightToLeftFlingInDisplay({this.pastRight, this.right, this.left});
  final AxisFling? pastRight;
  final AxisFling? right;
  final AxisFling? left;
}

final class RightToLeftContinuation implements HorizontalRelease {
  const RightToLeftContinuation({required this.pastRight, required this.rubber});
  final AxisFling pastRight;
  final AxisFling rubber;
}

final class RightToLeftSpringBack implements HorizontalRelease {
  const RightToLeftSpringBack({
    this.pastRight,
    this.right,
    this.left,
    required this.pastLeft,
    required this.rubber,
  });
  final AxisFling? pastRight;
  final AxisFling? right;
  final AxisFling? left;
  final AxisFling pastLeft;
  final AxisFling rubber;
}

// ─── Vertical ────────────────────────────────────────────────────────────────

final class IdlePastTop implements VerticalRelease {
  const IdlePastTop(this.rubber);
  final AxisFling rubber;
}

final class IdlePastBottom implements VerticalRelease {
  const IdlePastBottom(this.rubber);
  final AxisFling rubber;
}

final class TopToBottomFlingInDisplay implements VerticalRelease {
  const TopToBottomFlingInDisplay({this.pastTop, this.top, this.bottom});
  final AxisFling? pastTop;
  final AxisFling? top;
  final AxisFling? bottom;
}

final class TopToBottomContinuation implements VerticalRelease {
  const TopToBottomContinuation({required this.pastTop, required this.rubber});
  final AxisFling pastTop;
  final AxisFling rubber;
}

final class TopToBottomSpringBack implements VerticalRelease {
  const TopToBottomSpringBack({
    this.pastTop,
    this.top,
    this.bottom,
    required this.pastBottom,
    required this.rubber,
  });
  final AxisFling? pastTop;
  final AxisFling? top;
  final AxisFling? bottom;
  final AxisFling pastBottom;
  final AxisFling rubber;
}

final class BottomToTopFlingInDisplay implements VerticalRelease {
  const BottomToTopFlingInDisplay({this.pastBottom, this.bottom, this.top});
  final AxisFling? pastBottom;
  final AxisFling? bottom;
  final AxisFling? top;
}

final class BottomToTopContinuation implements VerticalRelease {
  const BottomToTopContinuation({required this.pastBottom, required this.rubber});
  final AxisFling pastBottom;
  final AxisFling rubber;
}

final class BottomToTopSpringBack implements VerticalRelease {
  const BottomToTopSpringBack({
    this.pastBottom,
    this.bottom,
    this.top,
    required this.pastTop,
    required this.rubber,
  });
  final AxisFling? pastBottom;
  final AxisFling? bottom;
  final AxisFling? top;
  final AxisFling pastTop;
  final AxisFling rubber;
}

// ─── Scale ───────────────────────────────────────────────────────────────────

final class IdlePastShrink implements ScaleRelease {
  const IdlePastShrink(this.rubber);
  final AxisFling rubber;
}

final class IdlePastExpand implements ScaleRelease {
  const IdlePastExpand(this.rubber);
  final AxisFling rubber;
}

final class ScaleInwardFlingInDisplay implements ScaleRelease {
  const ScaleInwardFlingInDisplay({this.pastExpand, this.expand, this.shrink});
  final AxisFling? pastExpand;
  final AxisFling? expand;
  final AxisFling? shrink;
}

final class ScaleInwardContinuation implements ScaleRelease {
  const ScaleInwardContinuation({required this.pastExpand, required this.rubber});
  final AxisFling pastExpand;
  final AxisFling rubber;
}

final class ScaleInwardSpringBack implements ScaleRelease {
  const ScaleInwardSpringBack({
    this.pastExpand,
    this.expand,
    this.shrink,
    required this.pastShrink,
    required this.rubber,
  });
  final AxisFling? pastExpand;
  final AxisFling? expand;
  final AxisFling? shrink;
  final AxisFling pastShrink;
  final AxisFling rubber;
}

final class ScaleOutwardFlingInDisplay implements ScaleRelease {
  const ScaleOutwardFlingInDisplay({this.pastShrink, this.shrink, this.expand});
  final AxisFling? pastShrink;
  final AxisFling? shrink;
  final AxisFling? expand;
}

final class ScaleOutwardContinuation implements ScaleRelease {
  const ScaleOutwardContinuation({required this.pastShrink, required this.rubber});
  final AxisFling pastShrink;
  final AxisFling rubber;
}

final class ScaleOutwardSpringBack implements ScaleRelease {
  const ScaleOutwardSpringBack({
    this.pastShrink,
    this.shrink,
    this.expand,
    required this.pastExpand,
    required this.rubber,
  });
  final AxisFling? pastShrink;
  final AxisFling? shrink;
  final AxisFling? expand;
  final AxisFling pastExpand;
  final AxisFling rubber;
}

// ─── Per-axis runners ────────────────────────────────────────────────────────

/// Animator signature compatible with Stage's per-axis animateCenterX /
/// animateCenterY / animateWidth.
typedef AxisAnimator = Future<void> Function({
  required double to,
  Duration? duration,
  Curve curve,
});

/// Runs the X-axis [release] phases sequentially. Skips rubber when
/// [includeRubber] is false (used by `backToOrigin` to play the decay portion
/// only, before dismissing).
Future<void> runHorizontalRelease(
  HorizontalRelease release,
  AxisAnimator animate, {
  bool includeRubber = true,
}) async {
  Future<void> ph(AxisFling f) =>
      animate(to: f.to, duration: f.duration, curve: f.curve);
  switch (release) {
    case IdleInDisplay():
      return;
    case IdlePastLeft(:final rubber) || IdlePastRight(:final rubber):
      if (includeRubber) await ph(rubber);
    case LeftToRightFlingInDisplay(:final pastLeft, :final left, :final right):
      if (pastLeft != null) await ph(pastLeft);
      if (left != null) await ph(left);
      if (right != null) await ph(right);
    case LeftToRightContinuation(:final pastLeft, :final rubber):
      await ph(pastLeft);
      if (includeRubber) await ph(rubber);
    case LeftToRightSpringBack(
        :final pastLeft, :final left, :final right, :final pastRight, :final rubber):
      if (pastLeft != null) await ph(pastLeft);
      if (left != null) await ph(left);
      if (right != null) await ph(right);
      await ph(pastRight);
      if (includeRubber) await ph(rubber);
    case RightToLeftFlingInDisplay(:final pastRight, :final right, :final left):
      if (pastRight != null) await ph(pastRight);
      if (right != null) await ph(right);
      if (left != null) await ph(left);
    case RightToLeftContinuation(:final pastRight, :final rubber):
      await ph(pastRight);
      if (includeRubber) await ph(rubber);
    case RightToLeftSpringBack(
        :final pastRight, :final right, :final left, :final pastLeft, :final rubber):
      if (pastRight != null) await ph(pastRight);
      if (right != null) await ph(right);
      if (left != null) await ph(left);
      await ph(pastLeft);
      if (includeRubber) await ph(rubber);
  }
}

/// Runs the Y-axis [release] phases sequentially.
Future<void> runVerticalRelease(
  VerticalRelease release,
  AxisAnimator animate, {
  bool includeRubber = true,
}) async {
  Future<void> ph(AxisFling f) =>
      animate(to: f.to, duration: f.duration, curve: f.curve);
  switch (release) {
    case IdleInDisplay():
      return;
    case IdlePastTop(:final rubber) || IdlePastBottom(:final rubber):
      if (includeRubber) await ph(rubber);
    case TopToBottomFlingInDisplay(:final pastTop, :final top, :final bottom):
      if (pastTop != null) await ph(pastTop);
      if (top != null) await ph(top);
      if (bottom != null) await ph(bottom);
    case TopToBottomContinuation(:final pastTop, :final rubber):
      await ph(pastTop);
      if (includeRubber) await ph(rubber);
    case TopToBottomSpringBack(
        :final pastTop, :final top, :final bottom, :final pastBottom, :final rubber):
      if (pastTop != null) await ph(pastTop);
      if (top != null) await ph(top);
      if (bottom != null) await ph(bottom);
      await ph(pastBottom);
      if (includeRubber) await ph(rubber);
    case BottomToTopFlingInDisplay(:final pastBottom, :final bottom, :final top):
      if (pastBottom != null) await ph(pastBottom);
      if (bottom != null) await ph(bottom);
      if (top != null) await ph(top);
    case BottomToTopContinuation(:final pastBottom, :final rubber):
      await ph(pastBottom);
      if (includeRubber) await ph(rubber);
    case BottomToTopSpringBack(
        :final pastBottom, :final bottom, :final top, :final pastTop, :final rubber):
      if (pastBottom != null) await ph(pastBottom);
      if (bottom != null) await ph(bottom);
      if (top != null) await ph(top);
      await ph(pastTop);
      if (includeRubber) await ph(rubber);
  }
}

/// Runs the scale-axis [release] phases sequentially.
Future<void> runScaleRelease(
  ScaleRelease release,
  AxisAnimator animate, {
  bool includeRubber = true,
}) async {
  Future<void> ph(AxisFling f) =>
      animate(to: f.to, duration: f.duration, curve: f.curve);
  switch (release) {
    case IdleInDisplay():
      return;
    case IdlePastShrink(:final rubber) || IdlePastExpand(:final rubber):
      if (includeRubber) await ph(rubber);
    case ScaleInwardFlingInDisplay(:final pastExpand, :final expand, :final shrink):
      if (pastExpand != null) await ph(pastExpand);
      if (expand != null) await ph(expand);
      if (shrink != null) await ph(shrink);
    case ScaleInwardContinuation(:final pastExpand, :final rubber):
      await ph(pastExpand);
      if (includeRubber) await ph(rubber);
    case ScaleInwardSpringBack(
        :final pastExpand, :final expand, :final shrink, :final pastShrink, :final rubber):
      if (pastExpand != null) await ph(pastExpand);
      if (expand != null) await ph(expand);
      if (shrink != null) await ph(shrink);
      await ph(pastShrink);
      if (includeRubber) await ph(rubber);
    case ScaleOutwardFlingInDisplay(:final pastShrink, :final shrink, :final expand):
      if (pastShrink != null) await ph(pastShrink);
      if (shrink != null) await ph(shrink);
      if (expand != null) await ph(expand);
    case ScaleOutwardContinuation(:final pastShrink, :final rubber):
      await ph(pastShrink);
      if (includeRubber) await ph(rubber);
    case ScaleOutwardSpringBack(
        :final pastShrink, :final shrink, :final expand, :final pastExpand, :final rubber):
      if (pastShrink != null) await ph(pastShrink);
      if (shrink != null) await ph(shrink);
      if (expand != null) await ph(expand);
      await ph(pastExpand);
      if (includeRubber) await ph(rubber);
  }
}

// ─── Release: bundled per-axis plans ─────────────────────────────────────────

/// The package's computed release plan for a gesture's end. Pure data — three
/// per-axis trajectory plans. Execution helpers live on [StageData] (call
/// `Stage.of(context).backToDisplay(release)` etc.).
class Release {
  const Release({required this.x, required this.y, required this.scale});

  final HorizontalRelease x;
  final VerticalRelease y;
  final ScaleRelease scale;
}

/// Signature for a gesture-end handler. Used by [Gesture.onRelease] and the
/// cascade fallbacks on [Origin], [Stage], and [DisplayConfig].
typedef OnRelease = void Function(BuildContext context, Release release);
