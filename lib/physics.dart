import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter/physics.dart';

import 'gestures.dart';
import 'rect_ext.dart';
import 'release.dart';

/// Per-axis classification used by friction / fling lookups.
typedef AxisState = ({
  DragBound activeBound,
  bool extending,
  bool pastDisplay,
  double progress,
});

/// Curve that exactly tracks a [FrictionSimulation]'s position over its
/// duration. Maps normalized animation time `t ∈ [0, 1]` to normalized
/// position progress `∈ [0, 1]`.
class FrictionCurve extends Curve {
  FrictionCurve(this.simulation, this.realDuration);

  final FrictionSimulation simulation;
  final double realDuration; // seconds

  late final double _start = simulation.x(0);
  late final double _end = simulation.x(realDuration);
  late final double _span = _end - _start;

  @override
  double transformInternal(double t) {
    if (_span == 0) return t;
    return ((simulation.x(t * realDuration) - _start) / _span).clamp(0.0, 1.0);
  }
}

/// Computes the X-axis state given the current motion ([signedAmount] is the
/// motion direction sign, e.g., delta or velocity) and the rect geometry.
AxisState axisStateX(
  double signedAmount,
  Rect currentRect,
  Rect originRect,
  Rect displayRect,
) {
  final inRight = currentRect.center.dx >= originRect.center.dx;
  final pastDisplay = inRight
      ? currentRect.right > displayRect.right
      : currentRect.left < displayRect.left;
  final progress = pastDisplay
      ? ((inRight
              ? currentRect.right - displayRect.right
              : displayRect.left - currentRect.left) / displayRect.width).clamp(0.0, 1.0)
      : ((currentRect.center.dx - originRect.center.dx).abs() / (displayRect.width / 2)).clamp(0.0, 1.0);
  return (
    activeBound: inRight ? DragBound.right : DragBound.left,
    extending: (inRight && signedAmount > 0) || (!inRight && signedAmount < 0),
    pastDisplay: pastDisplay,
    progress: progress,
  );
}

/// Computes the Y-axis state.
AxisState axisStateY(
  double signedAmount,
  Rect currentRect,
  Rect originRect,
  Rect displayRect,
) {
  final inBottom = currentRect.center.dy >= originRect.center.dy;
  final pastDisplay = inBottom
      ? currentRect.bottom > displayRect.bottom
      : currentRect.top < displayRect.top;
  final progress = pastDisplay
      ? ((inBottom
              ? currentRect.bottom - displayRect.bottom
              : displayRect.top - currentRect.top) / displayRect.height).clamp(0.0, 1.0)
      : ((currentRect.center.dy - originRect.center.dy).abs() / (displayRect.height / 2)).clamp(0.0, 1.0);
  return (
    activeBound: inBottom ? DragBound.bottom : DragBound.top,
    extending: (inBottom && signedAmount > 0) || (!inBottom && signedAmount < 0),
    pastDisplay: pastDisplay,
    progress: progress,
  );
}

/// Friction-scaled delta given a per-axis state.
/// Absent bound = blocked (returns 0). Absent friction = free (returns delta).
double frictionFromState({
  required AxisState state,
  required Map<DragBound, DragBounds> bounds,
  required double delta,
}) {
  if (delta == 0) return 0;
  final boundConfig = bounds[state.activeBound];
  if (boundConfig == null) return 0;
  final fc = boundConfig.friction;
  if (fc == null) return delta;
  final friction = state.pastDisplay
      ? (state.extending ? fc.extendingPastDisplay : fc.retractingPastDisplay)
      : (state.extending ? fc.extending : fc.retracting);
  if (friction == null) return delta;
  return delta * (1.0 - friction.evaluate(state.progress));
}

/// Side of the scale axis active at the given width.
enum ScaleSide { shrink, expand }

/// Per-axis classification for the scale axis (parallel to [AxisState] for
/// drag axes).
typedef ScaleAxisState = ({
  ScaleSide activeSide,
  bool extending,
  bool pastDisplay,
  double progress,
});

/// Computes the scale-axis state given the current width and motion direction.
///
/// [signedAmount] = direction-bearing scalar (e.g., width-velocity or width
/// delta). [currentWidth] = the rect's width now. [baseWidth] = scale-1.0
/// rest width. [shrink] / [expand] carry the configured min/maxScale.
ScaleAxisState axisStateScale(
  double signedAmount,
  double currentWidth,
  double baseWidth,
  ShrinkBounds? shrink,
  ExpandBounds? expand,
) {
  final inExpand = currentWidth > baseWidth;
  final activeSide = inExpand ? ScaleSide.expand : ScaleSide.shrink;
  final shrinkLow =
      shrink?.minScale != null ? shrink!.minScale! * baseWidth : double.negativeInfinity;
  final expandHigh =
      expand?.maxScale != null ? expand!.maxScale! * baseWidth : double.infinity;
  final pastDisplay = inExpand ? currentWidth > expandHigh : currentWidth < shrinkLow;
  // Progress: in-display = distance from base normalized to half-range; past = depth past edge.
  final progress = pastDisplay
      ? (inExpand
              ? (currentWidth - expandHigh) / (expandHigh - baseWidth).abs()
              : (shrinkLow - currentWidth) / (baseWidth - shrinkLow).abs())
          .clamp(0.0, 1.0)
      : (inExpand
              ? (currentWidth - baseWidth) / (expandHigh - baseWidth).abs()
              : (baseWidth - currentWidth) / (baseWidth - shrinkLow).abs())
          .clamp(0.0, 1.0);
  // extending = motion increases the magnitude (further from base).
  final extending = (inExpand && signedAmount > 0) || (!inExpand && signedAmount < 0);
  return (
    activeSide: activeSide,
    extending: extending,
    pastDisplay: pastDisplay,
    progress: progress.isNaN ? 0.0 : progress,
  );
}

/// Friction-scaled width delta given a scale-axis state.
/// Absent side config = blocked (returns 0). Absent friction = free (returns delta).
double frictionFromScaleState({
  required ScaleAxisState state,
  required ShrinkBounds? shrink,
  required ExpandBounds? expand,
  required double delta,
}) {
  if (delta == 0) return 0;
  final sideConfig = switch (state.activeSide) {
    ScaleSide.shrink => shrink as Bounds?,
    ScaleSide.expand => expand as Bounds?,
  };
  if (sideConfig == null) return 0;
  final fc = sideConfig.friction;
  if (fc == null) return delta;
  final friction = state.pastDisplay
      ? (state.extending ? fc.extendingPastDisplay : fc.retractingPastDisplay)
      : (state.extending ? fc.extending : fc.retracting);
  if (friction == null) return delta;
  return delta * (1.0 - friction.evaluate(state.progress));
}

// ─── Drag scale-response coupling ────────────────────────────────────────────

/// Combined scale factor for drag-with-[ScaleResponse]. Per axis:
/// - Active bound = side of [baseRect.center] where [rawCenter] sits.
/// - ScaleResponse comes from `bounds[activeBound].scaleResponse` (no
///   gesture-level fallback — bounds without scaleResponse contribute 1.0).
/// - Progress evaluated against in-display / past-display ramps. The
///   in-display zone uses the *actual* rect's half-dim (from [actualRect])
///   for the past-edge threshold, so a shrinking rect keeps its in-display
///   zone proportional to its current size — past-display only kicks in
///   when the rect's real edge crosses the display edge.
/// - Per-axis factors multiplied.
double dragScaleFactor({
  required Offset rawCenter,
  required Rect actualRect,
  required Rect baseRect,
  required Rect displayRect,
  required Map<DragBound, DragBounds> bounds,
}) {
  final DragBound boundY = rawCenter.dy < baseRect.center.dy ? .top : .bottom;
  final factorY = _axisScaleFactor(
    rawPos: rawCenter.dy,
    basePos: baseRect.center.dy,
    dispLow: displayRect.top,
    dispHigh: displayRect.bottom,
    halfDim: actualRect.height / 2,
    displayDim: displayRect.height,
    response: bounds[boundY]?.scaleResponse,
  );

  final DragBound boundX = rawCenter.dx < baseRect.center.dx ? .left : .right;
  final factorX = _axisScaleFactor(
    rawPos: rawCenter.dx,
    basePos: baseRect.center.dx,
    dispLow: displayRect.left,
    dispHigh: displayRect.right,
    halfDim: actualRect.width / 2,
    displayDim: displayRect.width,
    response: bounds[boundX]?.scaleResponse,
  );

  return factorX * factorY;
}

double _axisScaleFactor({
  required double rawPos,
  required double basePos,
  required double dispLow,
  required double dispHigh,
  required double halfDim,
  required double displayDim,
  required ScaleResponse? response,
}) {
  if (response == null) return 1.0;
  final isHigh = rawPos >= basePos;
  if (isHigh) {
    final dispEdge = dispHigh - halfDim;
    if (rawPos <= dispEdge) {
      final span = dispEdge - basePos;
      if (span <= 0) return response.inDisplay?.start ?? 1.0;
      final progress = ((rawPos - basePos) / span).clamp(0.0, 1.0);
      return response.inDisplay?.evaluate(progress) ?? 1.0;
    }
    final progress = ((rawPos - dispEdge) / displayDim).clamp(0.0, 1.0);
    return response.pastDisplay?.evaluate(progress)
        ?? response.inDisplay?.end
        ?? 1.0;
  } else {
    final dispEdge = dispLow + halfDim;
    if (rawPos >= dispEdge) {
      final span = basePos - dispEdge;
      if (span <= 0) return response.inDisplay?.start ?? 1.0;
      final progress = ((basePos - rawPos) / span).clamp(0.0, 1.0);
      return response.inDisplay?.evaluate(progress) ?? 1.0;
    }
    final progress = ((dispEdge - rawPos) / displayDim).clamp(0.0, 1.0);
    return response.pastDisplay?.evaluate(progress)
        ?? response.inDisplay?.end
        ?? 1.0;
  }
}

/// Default focal-point-preserving anchor: the rect.center is positioned so
/// the user's finger stays at the same relative point of the rect as it
/// scales. Used when no [Overrides.anchor] is configured.
Offset defaultDragAnchor(AnchorContext ctx) {
  final anchor = ctx.startFocalPoint - ctx.startRect.center;
  return ctx.currentFocalPoint - anchor * ctx.scale;
}

/// Resolves a drag gesture from the [registered] map for the accumulated
/// motion vector. Returns the matching [ActiveGesture], or null if no axis
/// has crossed [minDistance] yet, or no registered key matches.
///
/// Resolution: per-axis threshold (each axis must independently cross
/// [minDistance] to count). Candidates are tried in priority order from
/// most-specific to least-specific:
///
///   1. Diagonal (when both axes crossed)
///   2. Dominant (axis ≥ 2× the other)
///   3. Primary direction (the dominant axis's specific direction)
///   4. Secondary direction (the other axis's specific direction)
///   5. `horizontal` / `vertical` (axis-only)
///   6. `any`
///
/// First registered match wins. No friction-based scoring — direction-key
/// specificity is the contract.
ActiveGesture? resolveDragArena({
  required Offset totalDelta,
  required Map<DragStart, DragGesture> registered,
  double minDistance = 10,
}) {
  final dx = totalDelta.dx;
  final dy = totalDelta.dy;
  final adx = dx.abs();
  final ady = dy.abs();
  if (adx < minDistance && ady < minDistance) return null;

  final hCrossed = adx >= minDistance;
  final vCrossed = ady >= minDistance;
  final DragStart? hDir = hCrossed ? (dx > 0 ? .right : .left) : null;
  final DragStart? vDir = vCrossed ? (dy > 0 ? .down : .up) : null;

  // Diagonal — both axes crossed.
  DragStart? diagonal;
  if (hCrossed && vCrossed) {
    diagonal = switch ((hDir, vDir)) {
      (.left, .up) => .upLeft,
      (.right, .up) => .upRight,
      (.left, .down) => .downLeft,
      (.right, .down) => .downRight,
      _ => null,
    };
  }

  // Dominant — one axis ≥ 2× the other.
  DragStart? dominant;
  if (hCrossed && adx >= 2 * ady) {
    dominant = dx > 0 ? .rightDominant : .leftDominant;
  } else if (vCrossed && ady >= 2 * adx) {
    dominant = dy > 0 ? .downDominant : .upDominant;
  }

  // Primary / secondary by dominant-axis preference.
  final hPrimary = !vCrossed || (hCrossed && adx >= ady);
  final primary = hPrimary ? hDir : vDir;
  final secondary = hPrimary ? vDir : hDir;

  for (final candidate in <DragStart?>[
    diagonal,
    dominant,
    primary,
    secondary,
    if (hCrossed) .horizontal,
    if (vCrossed) .vertical,
    .any,
  ]) {
    if (candidate == null) continue;
    final gesture = registered[candidate];
    if (gesture != null) return (start: candidate, gesture: gesture);
  }
  return null;
}

/// Resolves a scale gesture from the [registered] map for the current scale
/// magnitude. Returns the first eligible entry, or null if scale is below
/// the commit threshold or no gesture qualifies.
ActiveGesture? resolveScaleArena({
  required double scale,
  required Map<ScaleStart, ScaleGesture> registered,
  double minDelta = 0.01,
}) {
  if ((scale - 1.0).abs() < minDelta) return null;

  final eligible = <ScaleStart>{ScaleStart.any};
  if (scale > 1.0) eligible.add(ScaleStart.expand);
  if (scale < 1.0) eligible.add(ScaleStart.shrink);

  for (final entry in registered.entries) {
    if (eligible.contains(entry.key)) return (start: entry.key, gesture: entry.value);
  }
  return null;
}

// ─── Release computation ─────────────────────────────────────────────────────
//
// Each axis owns its own zone enum and trajectory walker. The walker steps the
// rect zone-by-zone, picking the appropriate state-friction (extending/
// retracting × in-display/past-display) for each segment. The collected
// segments are assembled into the direction-specific sealed subtype
// (LeftToRight*, RightToLeft*, TopToBottom*, BottomToTop*, ScaleOutward*,
// ScaleInward*).
//
// The numerical per-phase step (FrictionSimulation + exit-time / natural-stop
// detection) and the rubber-fling builder are shared via [_runPhase] and
// [_rubberFling].

const double _velocityFloor = 10;
const double _maxPhaseTime = 1.0;
const int _maxPhases = 6;

/// Outcome of running one zone segment of the trajectory.
typedef _Step = ({
  AxisFling fling,
  double endPos,
  double endVel,
  bool stopped,
});

/// Runs a single zone phase: a [FrictionSimulation] from [pos] with [vel]
/// using [coefficient], terminating either at the natural decay (when no
/// boundary is reached) or at [exitBoundary] (when the simulation crosses it
/// before decaying). Returns the phase fling and exit state.
///
/// [coefficient] is passed directly as [FrictionSimulation]'s drag — Flutter
/// convention: lower value = more aggressive deceleration / shorter reach.
/// Typical values: ~0.135 (iOS scroll), 0.5 (medium flow), 0.9 (long flow).
/// Clamped to (~0, 1) to avoid `log(0)` and `log(1)` math edge cases —
/// the lower bound is near-zero so very small (or negative) coefficients
/// still produce strong, visible deceleration. A coefficient of exactly 0
/// is treated as "skip this zone" by the caller's bail check.
_Step _runPhase({
  required double pos,
  required double vel,
  required double coefficient,
  required double? exitBoundary,
}) {
  final drag = coefficient.clamp(1e-15, 0.999);
  final sim = FrictionSimulation(drag, pos, vel);
  final naturalTime =
      (math.log(_velocityFloor / vel.abs()) / math.log(drag / 100)).abs();

  double duration;
  double endPos;
  bool stopped;
  if (exitBoundary == null) {
    duration = naturalTime.clamp(0.1, _maxPhaseTime);
    endPos = sim.x(duration);
    stopped = true;
  } else {
    final exitTime = sim.timeAtX(exitBoundary);
    if (exitTime.isNaN || exitTime <= 0 || exitTime > naturalTime) {
      duration = naturalTime.clamp(0.1, _maxPhaseTime);
      endPos = sim.x(duration);
      stopped = true;
    } else {
      duration = exitTime.clamp(0.0001, _maxPhaseTime);
      endPos = exitBoundary;
      stopped = false;
    }
  }

  return (
    fling: AxisFling(
      to: endPos,
      duration: Duration(milliseconds: (duration * 1000).round()),
      curve: FrictionCurve(sim, duration),
    ),
    endPos: endPos,
    endVel: sim.dx(duration),
    stopped: stopped,
  );
}

/// Rubber settle from [startPos] to [targetPos]. Duration scales with
/// distance via a synthesized friction simulation: pick a `v0` such that the
/// natural decay travels exactly the rubber distance, then use its
/// `naturalTime` (clamped to a UX-reasonable range) as the fling duration.
///
/// [settle] supplies both the drag coefficient ([Friction.start], default
/// `0.135` ≈ iOS scroll feel) and the animation curve ([Friction.curve],
/// default [Curves.easeOut]). For [DecelerateConfig.settle], `Friction.end`
/// is unused.
AxisFling _rubberFling({
  required double startPos,
  required double targetPos,
  Friction? settle,
}) {
  final distance = (targetPos - startPos).abs();
  final curve = settle?.curve ?? Curves.easeOut;
  if (distance < 0.5) {
    return AxisFling(to: targetPos, duration: Duration.zero, curve: curve);
  }
  final drag = (settle?.start ?? 0.135).clamp(0.001, 0.999);
  // v0 such that sim's natural-decay distance equals `distance`:
  //   distance = -v0 / log(drag) ⇒ v0 = distance · |log(drag)|.
  final v0 = distance * math.log(drag).abs();
  final naturalTime =
      (math.log(_velocityFloor / v0) / math.log(drag / 100)).abs();
  final duration = naturalTime.clamp(0.1, 1.0);
  return AxisFling(
    to: targetPos,
    duration: Duration(milliseconds: (duration * 1000).round()),
    curve: curve,
  );
}

// ─── X axis ──────────────────────────────────────────────────────────────────

/// Computes the [HorizontalRelease] plan for the X axis given gesture-end state.
///
/// [projectedRect] is the rect at its *post-scale-settle* dimensions — used
/// to compute the viewport-fit center for the rect when it eventually rests.
/// Re-evaluated against the gesture-end position (idle case) and the
/// decay-end position (velocity case) so the rubber target tracks where the
/// rect actually lands. When omitted, defaults to [currentRect]'s dims.
HorizontalRelease releaseFromStateX({
  required Rect currentRect,
  required Rect displayRect,
  required Map<DragBound, DragBounds> bounds,
  required double velocity,
  Rect? projectedRect,
}) {
  final halfWidth = currentRect.width / 2;
  final pos = currentRect.center.dx;
  final dispLeft = displayRect.left;
  final dispRight = displayRect.right;
  final dispCenter = displayRect.center.dx;
  // Past zones start when the rect's *near edge* crosses the display's
  // corresponding edge — i.e., the moment the rect stops covering display
  // on that side. For a rect bigger than display, this is the natural
  // "leaving coverage" point; for a rect equal to display, it's exactly
  // displayCenter; for a rect smaller than display, the inner range is
  // empty so past friction always applies.
  final pastLeftBound = dispRight - halfWidth;
  final pastRightBound = dispLeft + halfWidth;

  final leftDc = bounds[DragBound.left]?.decelerate;
  final rightDc = bounds[DragBound.right]?.decelerate;

  final fitWidth = projectedRect?.width ?? currentRect.width;
  final fitHeight = projectedRect?.height ?? currentRect.height;
  double fitAt(double cx) => Rect.fromCenter(
        center: Offset(cx, currentRect.center.dy),
        width: fitWidth,
        height: fitHeight,
      ).getLimitedCenterXInside(displayRect);
  final fit = fitAt(pos);

  HorizontalZone zoneOf(double p) {
    if (p < pastLeftBound) return .pastLeft;
    if (p > pastRightBound) return .pastRight;
    if (p <= dispCenter) return .left;
    return .right;
  }

  final startZone = zoneOf(pos);

  if (velocity.abs() <= _velocityFloor) {
    if ((pos - fit).abs() < 0.5) {
      return HorizontalRelease(
        direction: .idle,
        startZone: startZone,
        endZone: startZone,
      );
    }
    final settleConfig = (pos > fit ? rightDc : leftDc)?.settle;
    return HorizontalRelease(
      direction: .idle,
      startZone: startZone,
      endZone: startZone,
      settle: _rubberFling(startPos: pos, targetPos: fit, settle: settleConfig),
    );
  }

  Friction? frictionAt(HorizontalZone zone, bool ltr) {
    final (isLeft, isPast) = switch (zone) {
      .pastLeft => (true, true),
      .left => (true, false),
      .right => (false, false),
      .pastRight => (false, true),
    };
    final dc = isLeft ? leftDc : rightDc;
    if (dc == null) return null;
    final extending = (isLeft && !ltr) || (!isLeft && ltr);
    if (isPast) {
      return extending ? dc.extendingPastDisplay : dc.retractingPastDisplay;
    }
    return extending ? dc.extending : dc.retracting;
  }

  double? exitBoundaryAt(HorizontalZone zone, bool ltr) {
    if (ltr) {
      switch (zone) {
        case .pastLeft: return pastLeftBound;
        case .left: return dispCenter;
        case .right: return pastRightBound;
        case .pastRight: return null;
      }
    } else {
      switch (zone) {
        case .pastRight: return pastRightBound;
        case .right: return dispCenter;
        case .left: return pastLeftBound;
        case .pastLeft: return null;
      }
    }
  }

  final decay = <AxisFling>[];
  var p = pos;
  var v = velocity;
  var endPos = pos;
  for (var i = 0; i < _maxPhases; i++) {
    if (v.abs() <= _velocityFloor) break;
    final ltr = v > 0;
    final zone = zoneOf(p);
    final friction = frictionAt(zone, ltr);
    if (friction == null || friction.start <= 0) break;

    final step = _runPhase(
      pos: p,
      vel: v,
      coefficient: friction.start,
      exitBoundary: exitBoundaryAt(zone, ltr),
    );
    decay.add(step.fling);
    endPos = step.endPos;
    if (step.stopped) break;
    p = step.endPos + v.sign * 0.01;
    v = step.endVel;
  }

  final endZone = zoneOf(endPos);
  final HorizontalDir direction = velocity > 0 ? .ltr : .rtl;

  // Recompute fit at the decay-end position — for zoomed rects, the
  // viewport-correct center depends on where the rect actually lands.
  final endFit = fitAt(endPos);
  AxisFling? settle;
  if (endZone case .pastLeft) {
    settle = _rubberFling(startPos: endPos, targetPos: endFit, settle: leftDc?.settle);
  } else if (endZone case .pastRight) {
    settle = _rubberFling(startPos: endPos, targetPos: endFit, settle: rightDc?.settle);
  } else if ((endPos - endFit).abs() >= 0.5) {
    final settleConfig = (endPos > endFit ? rightDc : leftDc)?.settle;
    settle = _rubberFling(startPos: endPos, targetPos: endFit, settle: settleConfig);
  }

  return HorizontalRelease(
    direction: direction,
    startZone: startZone,
    endZone: endZone,
    decay: decay,
    settle: settle,
  );
}

// ─── Y axis ──────────────────────────────────────────────────────────────────

/// Computes the [VerticalRelease] plan for the Y axis given gesture-end state.
///
/// [projectedRect] is the rect at its post-scale-settle dimensions — used
/// to compute the viewport-fit center. Re-evaluated at gesture-end and
/// decay-end so the rubber target tracks where the rect actually lands.
/// See [releaseFromStateX] for full semantics.
VerticalRelease releaseFromStateY({
  required Rect currentRect,
  required Rect displayRect,
  required Map<DragBound, DragBounds> bounds,
  required double velocity,
  Rect? projectedRect,
}) {
  final halfHeight = currentRect.height / 2;
  final pos = currentRect.center.dy;
  final dispTop = displayRect.top;
  final dispBottom = displayRect.bottom;
  final dispCenter = displayRect.center.dy;
  final pastTopBound = dispBottom - halfHeight;
  final pastBottomBound = dispTop + halfHeight;

  final topDc = bounds[DragBound.top]?.decelerate;
  final bottomDc = bounds[DragBound.bottom]?.decelerate;

  final fitWidth = projectedRect?.width ?? currentRect.width;
  final fitHeight = projectedRect?.height ?? currentRect.height;
  double fitAt(double cy) => Rect.fromCenter(
        center: Offset(currentRect.center.dx, cy),
        width: fitWidth,
        height: fitHeight,
      ).getLimitedCenterYInside(displayRect);
  final fit = fitAt(pos);

  VerticalZone zoneOf(double p) {
    if (p < pastTopBound) return .pastTop;
    if (p > pastBottomBound) return .pastBottom;
    if (p <= dispCenter) return .top;
    return .bottom;
  }

  final startZone = zoneOf(pos);

  if (velocity.abs() <= _velocityFloor) {
    if ((pos - fit).abs() < 0.5) {
      return VerticalRelease(
        direction: .idle,
        startZone: startZone,
        endZone: startZone,
      );
    }
    final settleConfig = (pos > fit ? bottomDc : topDc)?.settle;
    return VerticalRelease(
      direction: .idle,
      startZone: startZone,
      endZone: startZone,
      settle: _rubberFling(startPos: pos, targetPos: fit, settle: settleConfig),
    );
  }

  Friction? frictionAt(VerticalZone zone, bool ttb) {
    final (isTop, isPast) = switch (zone) {
      .pastTop => (true, true),
      .top => (true, false),
      .bottom => (false, false),
      .pastBottom => (false, true),
    };
    final dc = isTop ? topDc : bottomDc;
    if (dc == null) return null;
    final extending = (isTop && !ttb) || (!isTop && ttb);
    if (isPast) {
      return extending ? dc.extendingPastDisplay : dc.retractingPastDisplay;
    }
    return extending ? dc.extending : dc.retracting;
  }

  double? exitBoundaryAt(VerticalZone zone, bool ttb) {
    if (ttb) {
      switch (zone) {
        case .pastTop: return pastTopBound;
        case .top: return dispCenter;
        case .bottom: return pastBottomBound;
        case .pastBottom: return null;
      }
    } else {
      switch (zone) {
        case .pastBottom: return pastBottomBound;
        case .bottom: return dispCenter;
        case .top: return pastTopBound;
        case .pastTop: return null;
      }
    }
  }

  final decay = <AxisFling>[];
  var p = pos;
  var v = velocity;
  var endPos = pos;
  for (var i = 0; i < _maxPhases; i++) {
    if (v.abs() <= _velocityFloor) break;
    final ttb = v > 0;
    final zone = zoneOf(p);
    final friction = frictionAt(zone, ttb);
    if (friction == null || friction.start <= 0) break;

    final step = _runPhase(
      pos: p,
      vel: v,
      coefficient: friction.start,
      exitBoundary: exitBoundaryAt(zone, ttb),
    );
    decay.add(step.fling);
    endPos = step.endPos;
    if (step.stopped) break;
    p = step.endPos + v.sign * 0.01;
    v = step.endVel;
  }

  final endZone = zoneOf(endPos);
  final VerticalDir direction = velocity > 0 ? .ttb : .btt;

  final endFit = fitAt(endPos);
  AxisFling? settle;
  if (endZone case .pastTop) {
    settle = _rubberFling(startPos: endPos, targetPos: endFit, settle: topDc?.settle);
  } else if (endZone case .pastBottom) {
    settle = _rubberFling(startPos: endPos, targetPos: endFit, settle: bottomDc?.settle);
  } else if ((endPos - endFit).abs() >= 0.5) {
    final settleConfig = (endPos > endFit ? bottomDc : topDc)?.settle;
    settle = _rubberFling(startPos: endPos, targetPos: endFit, settle: settleConfig);
  }

  return VerticalRelease(
    direction: direction,
    startZone: startZone,
    endZone: endZone,
    decay: decay,
    settle: settle,
  );
}

// ─── Scale axis ──────────────────────────────────────────────────────────────

/// Computes the [ScaleRelease] plan given gesture-end scale-axis state.
///
/// [width] is the current rect width; [baseWidth] is the rest width
/// (scale = 1.0). [shrink]/[expand] hold the configured minScale/maxScale plus
/// their decelerate configs. [velocity] is in width-units per second.
ScaleRelease releaseFromStateScale({
  required double width,
  required double baseWidth,
  required ShrinkBounds? shrink,
  required ExpandBounds? expand,
  required double velocity,
}) {
  if (baseWidth <= 0) {
    return const ScaleRelease(
      direction: .idle,
      startZone: .shrink,
      endZone: .shrink,
    );
  }

  // Effective scale-axis boundaries. Null thresholds mean "no past zone on
  // that side" — modeled with an out-of-reach width.
  final shrinkLow = shrink?.minScale != null ? shrink!.minScale! * baseWidth : -baseWidth * 100;
  final expandHigh = expand?.maxScale != null ? expand!.maxScale! * baseWidth : baseWidth * 100;
  final dispCenter = baseWidth;

  final shrinkDc = shrink?.decelerate;
  final expandDc = expand?.decelerate;

  ScaleZone zoneOf(double w) {
    if (w < shrinkLow) return .pastShrink;
    if (w > expandHigh) return .pastExpand;
    if (w <= dispCenter) return .shrink;
    return .expand;
  }

  final startZone = zoneOf(width);

  if (velocity.abs() <= _velocityFloor) {
    if (width < shrinkLow) {
      return ScaleRelease(
        direction: .idle,
        startZone: startZone,
        endZone: startZone,
        settle: _rubberFling(startPos: width, targetPos: shrinkLow, settle: shrinkDc?.settle),
      );
    }
    if (width > expandHigh) {
      return ScaleRelease(
        direction: .idle,
        startZone: startZone,
        endZone: startZone,
        settle: _rubberFling(startPos: width, targetPos: expandHigh, settle: expandDc?.settle),
      );
    }
    // Expanded within max → stay zoomed (X/Y will shift-to-fit).
    if (width >= dispCenter - 0.5) {
      return ScaleRelease(
        direction: .idle,
        startZone: startZone,
        endZone: startZone,
      );
    }
    // Shrunk in display → snap up to base.
    return ScaleRelease(
      direction: .idle,
      startZone: startZone,
      endZone: startZone,
      settle: _rubberFling(startPos: width, targetPos: dispCenter, settle: shrinkDc?.settle),
    );
  }

  Friction? frictionAt(ScaleZone zone, bool outward) {
    final (isShrink, isPast) = switch (zone) {
      .pastShrink => (true, true),
      .shrink => (true, false),
      .expand => (false, false),
      .pastExpand => (false, true),
    };
    final dc = isShrink ? shrinkDc : expandDc;
    if (dc == null) return null;
    final extending = (isShrink && !outward) || (!isShrink && outward);
    if (isPast) {
      return extending ? dc.extendingPastDisplay : dc.retractingPastDisplay;
    }
    return extending ? dc.extending : dc.retracting;
  }

  double? exitBoundaryAt(ScaleZone zone, bool outward) {
    if (outward) {
      switch (zone) {
        case .pastShrink: return shrinkLow;
        case .shrink: return dispCenter;
        case .expand: return expandHigh;
        case .pastExpand: return null;
      }
    } else {
      switch (zone) {
        case .pastExpand: return expandHigh;
        case .expand: return dispCenter;
        case .shrink: return shrinkLow;
        case .pastShrink: return null;
      }
    }
  }

  final decay = <AxisFling>[];
  var w = width;
  var v = velocity;
  var endPos = width;
  for (var i = 0; i < _maxPhases; i++) {
    if (v.abs() <= _velocityFloor) break;
    final outward = v > 0;
    final zone = zoneOf(w);
    final friction = frictionAt(zone, outward);
    if (friction == null || friction.start <= 0) break;

    final step = _runPhase(
      pos: w,
      vel: v,
      coefficient: friction.start,
      exitBoundary: exitBoundaryAt(zone, outward),
    );
    decay.add(step.fling);
    endPos = step.endPos;
    if (step.stopped) break;
    w = step.endPos + v.sign * 0.01;
    v = step.endVel;
  }

  final endZone = zoneOf(endPos);
  final ScaleDir direction = velocity > 0 ? .outward : .inward;

  // Settle:
  // - past shrink → rubber to shrinkLow (min cap).
  // - past expand → rubber to expandHigh (max cap).
  // - shrunk in display → snap up to base.
  // - expanded in display or at base → stay (X/Y shift-to-fit if needed).
  AxisFling? settle;
  if (endZone case .pastShrink) {
    settle = _rubberFling(startPos: endPos, targetPos: shrinkLow, settle: shrinkDc?.settle);
  } else if (endZone case .pastExpand) {
    settle = _rubberFling(startPos: endPos, targetPos: expandHigh, settle: expandDc?.settle);
  } else if (endPos < dispCenter - 0.5) {
    settle = _rubberFling(startPos: endPos, targetPos: dispCenter, settle: shrinkDc?.settle);
  }

  return ScaleRelease(
    direction: direction,
    startZone: startZone,
    endZone: endZone,
    decay: decay,
    settle: settle,
  );
}
