import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter/physics.dart';

import 'gestures.dart';
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

/// Resolves a drag gesture from the [registered] map for the accumulated
/// motion vector. Returns the matching [ActiveGesture], or null if motion is
/// below the distance threshold or no gesture qualifies.
///
/// The map is walked in insertion order; ties are broken by first-seen.
/// Caller is responsible for cascading/merging multiple sources before
/// passing the registered map.
ActiveGesture? resolveDragArena({
  required Offset totalDelta,
  required Map<DragStart, DragGesture> registered,
  double minDistance = 10,
}) {
  final dx = totalDelta.dx;
  final dy = totalDelta.dy;
  final adx = dx.abs();
  final ady = dy.abs();
  if (adx + ady < minDistance) return null;

  final eligible = <DragStart>{DragStart.any};
  if (dx != 0) eligible.add(DragStart.horizontal);
  if (dy != 0) eligible.add(DragStart.vertical);
  if (dx < 0) eligible.add(DragStart.left);
  if (dx > 0) eligible.add(DragStart.right);
  if (dy < 0) eligible.add(DragStart.up);
  if (dy > 0) eligible.add(DragStart.down);
  if (dx < 0 && dy < 0) eligible.add(DragStart.upLeft);
  if (dx > 0 && dy < 0) eligible.add(DragStart.upRight);
  if (dx < 0 && dy > 0) eligible.add(DragStart.downLeft);
  if (dx > 0 && dy > 0) eligible.add(DragStart.downRight);
  if (dx < 0 && ady <= adx * 0.5) eligible.add(DragStart.leftDominant);
  if (dx > 0 && ady <= adx * 0.5) eligible.add(DragStart.rightDominant);
  if (dy < 0 && adx <= ady * 0.5) eligible.add(DragStart.upDominant);
  if (dy > 0 && adx <= ady * 0.5) eligible.add(DragStart.downDominant);

  final total = adx + ady;
  double bestScore = 0;
  ActiveGesture? best;

  for (final entry in registered.entries) {
    if (!eligible.contains(entry.key)) continue;

    final gesture = entry.value;
    var weighted = 0.0;

    if (dx < 0) {
      final f = gesture.bounds[DragBound.left]?.friction?.extending?.start ?? 1.0;
      weighted += (adx / total) * f;
    } else if (dx > 0) {
      final f = gesture.bounds[DragBound.right]?.friction?.extending?.start ?? 1.0;
      weighted += (adx / total) * f;
    }
    if (dy < 0) {
      final f = gesture.bounds[DragBound.top]?.friction?.extending?.start ?? 1.0;
      weighted += (ady / total) * f;
    } else if (dy > 0) {
      final f = gesture.bounds[DragBound.bottom]?.friction?.extending?.start ?? 1.0;
      weighted += (ady / total) * f;
    }

    final score = 1.0 - weighted;

    if (score >= 1.0) return (start: entry.key, gesture: gesture);
    if (score > bestScore) {
      bestScore = score;
      best = (start: entry.key, gesture: gesture);
    }
  }

  return bestScore > 0 ? best : null;
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
_Step _runPhase({
  required double pos,
  required double vel,
  required double coefficient,
  required double? exitBoundary,
}) {
  final sim = FrictionSimulation(coefficient, pos, vel);
  final naturalTime =
      (math.log(_velocityFloor / vel.abs()) / math.log(coefficient / 100)).abs();

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
    fling: (
      to: endPos,
      duration: Duration(milliseconds: (duration * 1000).round()),
      curve: FrictionCurve(sim, duration),
    ),
    endPos: endPos,
    endVel: sim.dx(duration),
    stopped: stopped,
  );
}

/// Default rubber settle: animate to [targetPos] over 300ms using [friction]'s
/// curve (or [Curves.easeOut] when not configured).
AxisFling _rubberFling({
  required double targetPos,
  required Friction? friction,
}) {
  return (
    to: targetPos,
    duration: const Duration(milliseconds: 300),
    curve: friction?.curve ?? Curves.easeOut,
  );
}

// ─── X axis ──────────────────────────────────────────────────────────────────

enum _XZone { pastLeft, left, right, pastRight }

/// Computes the [HorizontalRelease] plan for the X axis given gesture-end state.
HorizontalRelease releaseFromStateX({
  required Rect currentRect,
  required Rect displayRect,
  required Map<DragBound, DragBounds> bounds,
  required double velocity,
}) {
  final width = currentRect.width;
  final pos = currentRect.center.dx;
  final dispLeft = displayRect.left;
  final dispRight = displayRect.right;
  final dispCenter = displayRect.center.dx;
  final pastLeftBound = dispLeft - width / 2;
  final pastRightBound = dispRight + width / 2;

  final leftDc = bounds[DragBound.left]?.decelerate;
  final rightDc = bounds[DragBound.right]?.decelerate;
  Friction? rubberLeft = leftDc?.retractingPastDisplay;
  Friction? rubberRight = rightDc?.retractingPastDisplay;

  if (velocity.abs() <= _velocityFloor) {
    if (pos < pastLeftBound) {
      return IdlePastLeft(_rubberFling(targetPos: pastLeftBound, friction: rubberLeft));
    }
    if (pos > pastRightBound) {
      return IdlePastRight(_rubberFling(targetPos: pastRightBound, friction: rubberRight));
    }
    return const IdleInDisplay();
  }

  _XZone zoneOf(double p) {
    if (p < pastLeftBound) return .pastLeft;
    if (p > pastRightBound) return .pastRight;
    if (p <= dispCenter) return .left;
    return .right;
  }

  Friction? frictionAt(_XZone zone, bool ltr) {
    final isLeft = zone == .pastLeft || zone == .left;
    final isPast = zone == .pastLeft || zone == .pastRight;
    final dc = isLeft ? leftDc : rightDc;
    if (dc == null) return null;
    final extending = (isLeft && !ltr) || (!isLeft && ltr);
    if (isPast) {
      return extending ? dc.extendingPastDisplay : dc.retractingPastDisplay;
    }
    return extending ? dc.extending : dc.retracting;
  }

  double? exitBoundaryAt(_XZone zone, bool ltr) {
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

  final phases = <({_XZone zone, AxisFling fling})>[];
  var p = pos;
  var v = velocity;
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
    phases.add((zone: zone, fling: step.fling));
    if (step.stopped) break;
    p = step.endPos + v.sign * 0.01;
    v = step.endVel;
  }

  if (phases.isEmpty) return const IdleInDisplay();

  AxisFling? pastLeft, left, right, pastRight;
  for (final ph in phases) {
    switch (ph.zone) {
      case .pastLeft: pastLeft = ph.fling;
      case .left: left = ph.fling;
      case .right: right = ph.fling;
      case .pastRight: pastRight = ph.fling;
    }
  }

  final ltr = velocity > 0;
  final endZone = phases.last.zone;
  if (ltr) {
    switch (endZone) {
      case .pastRight:
        return LeftToRightSpringBack(
          pastLeft: pastLeft, left: left, right: right,
          pastRight: pastRight!,
          rubber: _rubberFling(targetPos: pastRightBound, friction: rubberRight),
        );
      case .pastLeft:
        return LeftToRightContinuation(
          pastLeft: pastLeft!,
          rubber: _rubberFling(targetPos: pastLeftBound, friction: rubberLeft),
        );
      case .left:
      case .right:
        return LeftToRightFlingInDisplay(
          pastLeft: pastLeft, left: left, right: right,
        );
    }
  } else {
    switch (endZone) {
      case .pastLeft:
        return RightToLeftSpringBack(
          pastRight: pastRight, right: right, left: left,
          pastLeft: pastLeft!,
          rubber: _rubberFling(targetPos: pastLeftBound, friction: rubberLeft),
        );
      case .pastRight:
        return RightToLeftContinuation(
          pastRight: pastRight!,
          rubber: _rubberFling(targetPos: pastRightBound, friction: rubberRight),
        );
      case .left:
      case .right:
        return RightToLeftFlingInDisplay(
          pastRight: pastRight, right: right, left: left,
        );
    }
  }
}

// ─── Y axis ──────────────────────────────────────────────────────────────────

enum _YZone { pastTop, top, bottom, pastBottom }

/// Computes the [VerticalRelease] plan for the Y axis given gesture-end state.
VerticalRelease releaseFromStateY({
  required Rect currentRect,
  required Rect displayRect,
  required Map<DragBound, DragBounds> bounds,
  required double velocity,
}) {
  final height = currentRect.height;
  final pos = currentRect.center.dy;
  final dispTop = displayRect.top;
  final dispBottom = displayRect.bottom;
  final dispCenter = displayRect.center.dy;
  final pastTopBound = dispTop - height / 2;
  final pastBottomBound = dispBottom + height / 2;

  final topDc = bounds[DragBound.top]?.decelerate;
  final bottomDc = bounds[DragBound.bottom]?.decelerate;
  Friction? rubberTop = topDc?.retractingPastDisplay;
  Friction? rubberBottom = bottomDc?.retractingPastDisplay;

  if (velocity.abs() <= _velocityFloor) {
    if (pos < pastTopBound) {
      return IdlePastTop(_rubberFling(targetPos: pastTopBound, friction: rubberTop));
    }
    if (pos > pastBottomBound) {
      return IdlePastBottom(_rubberFling(targetPos: pastBottomBound, friction: rubberBottom));
    }
    return const IdleInDisplay();
  }

  _YZone zoneOf(double p) {
    if (p < pastTopBound) return .pastTop;
    if (p > pastBottomBound) return .pastBottom;
    if (p <= dispCenter) return .top;
    return .bottom;
  }

  Friction? frictionAt(_YZone zone, bool ttb) {
    final isTop = zone == .pastTop || zone == .top;
    final isPast = zone == .pastTop || zone == .pastBottom;
    final dc = isTop ? topDc : bottomDc;
    if (dc == null) return null;
    final extending = (isTop && !ttb) || (!isTop && ttb);
    if (isPast) {
      return extending ? dc.extendingPastDisplay : dc.retractingPastDisplay;
    }
    return extending ? dc.extending : dc.retracting;
  }

  double? exitBoundaryAt(_YZone zone, bool ttb) {
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

  final phases = <({_YZone zone, AxisFling fling})>[];
  var p = pos;
  var v = velocity;
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
    phases.add((zone: zone, fling: step.fling));
    if (step.stopped) break;
    p = step.endPos + v.sign * 0.01;
    v = step.endVel;
  }

  if (phases.isEmpty) return const IdleInDisplay();

  AxisFling? pastTop, top, bottom, pastBottom;
  for (final ph in phases) {
    switch (ph.zone) {
      case .pastTop: pastTop = ph.fling;
      case .top: top = ph.fling;
      case .bottom: bottom = ph.fling;
      case .pastBottom: pastBottom = ph.fling;
    }
  }

  final ttb = velocity > 0;
  final endZone = phases.last.zone;
  if (ttb) {
    switch (endZone) {
      case .pastBottom:
        return TopToBottomSpringBack(
          pastTop: pastTop, top: top, bottom: bottom,
          pastBottom: pastBottom!,
          rubber: _rubberFling(targetPos: pastBottomBound, friction: rubberBottom),
        );
      case .pastTop:
        return TopToBottomContinuation(
          pastTop: pastTop!,
          rubber: _rubberFling(targetPos: pastTopBound, friction: rubberTop),
        );
      case .top:
      case .bottom:
        return TopToBottomFlingInDisplay(
          pastTop: pastTop, top: top, bottom: bottom,
        );
    }
  } else {
    switch (endZone) {
      case .pastTop:
        return BottomToTopSpringBack(
          pastBottom: pastBottom, bottom: bottom, top: top,
          pastTop: pastTop!,
          rubber: _rubberFling(targetPos: pastTopBound, friction: rubberTop),
        );
      case .pastBottom:
        return BottomToTopContinuation(
          pastBottom: pastBottom!,
          rubber: _rubberFling(targetPos: pastBottomBound, friction: rubberBottom),
        );
      case .top:
      case .bottom:
        return BottomToTopFlingInDisplay(
          pastBottom: pastBottom, bottom: bottom, top: top,
        );
    }
  }
}

// ─── Scale axis ──────────────────────────────────────────────────────────────

enum _ScaleZone { pastShrink, shrink, expand, pastExpand }

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
  if (baseWidth <= 0) return const IdleInDisplay();

  // Effective scale-axis boundaries. Null thresholds mean "no past zone on
  // that side" — modeled with an out-of-reach width.
  final shrinkLow = shrink?.minScale != null ? shrink!.minScale! * baseWidth : -baseWidth * 100;
  final expandHigh = expand?.maxScale != null ? expand!.maxScale! * baseWidth : baseWidth * 100;
  final dispCenter = baseWidth;

  final shrinkDc = shrink?.decelerate;
  final expandDc = expand?.decelerate;
  Friction? rubberShrink = shrinkDc?.retractingPastDisplay;
  Friction? rubberExpand = expandDc?.retractingPastDisplay;

  if (velocity.abs() <= _velocityFloor) {
    if (width < shrinkLow) {
      return IdlePastShrink(_rubberFling(targetPos: shrinkLow, friction: rubberShrink));
    }
    if (width > expandHigh) {
      return IdlePastExpand(_rubberFling(targetPos: expandHigh, friction: rubberExpand));
    }
    return const IdleInDisplay();
  }

  _ScaleZone zoneOf(double w) {
    if (w < shrinkLow) return .pastShrink;
    if (w > expandHigh) return .pastExpand;
    if (w <= dispCenter) return .shrink;
    return .expand;
  }

  Friction? frictionAt(_ScaleZone zone, bool outward) {
    final isShrink = zone == .pastShrink || zone == .shrink;
    final isPast = zone == .pastShrink || zone == .pastExpand;
    final dc = isShrink ? shrinkDc : expandDc;
    if (dc == null) return null;
    final extending = (isShrink && !outward) || (!isShrink && outward);
    if (isPast) {
      return extending ? dc.extendingPastDisplay : dc.retractingPastDisplay;
    }
    return extending ? dc.extending : dc.retracting;
  }

  double? exitBoundaryAt(_ScaleZone zone, bool outward) {
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

  final phases = <({_ScaleZone zone, AxisFling fling})>[];
  var w = width;
  var v = velocity;
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
    phases.add((zone: zone, fling: step.fling));
    if (step.stopped) break;
    w = step.endPos + v.sign * 0.01;
    v = step.endVel;
  }

  if (phases.isEmpty) return const IdleInDisplay();

  AxisFling? pastShrink, shrinkPhase, expandPhase, pastExpand;
  for (final ph in phases) {
    switch (ph.zone) {
      case .pastShrink: pastShrink = ph.fling;
      case .shrink: shrinkPhase = ph.fling;
      case .expand: expandPhase = ph.fling;
      case .pastExpand: pastExpand = ph.fling;
    }
  }

  final outward = velocity > 0;
  final endZone = phases.last.zone;
  if (outward) {
    switch (endZone) {
      case .pastExpand:
        return ScaleOutwardSpringBack(
          pastShrink: pastShrink, shrink: shrinkPhase, expand: expandPhase,
          pastExpand: pastExpand!,
          rubber: _rubberFling(targetPos: expandHigh, friction: rubberExpand),
        );
      case .pastShrink:
        return ScaleOutwardContinuation(
          pastShrink: pastShrink!,
          rubber: _rubberFling(targetPos: shrinkLow, friction: rubberShrink),
        );
      case .shrink:
      case .expand:
        return ScaleOutwardFlingInDisplay(
          pastShrink: pastShrink, shrink: shrinkPhase, expand: expandPhase,
        );
    }
  } else {
    switch (endZone) {
      case .pastShrink:
        return ScaleInwardSpringBack(
          pastExpand: pastExpand, expand: expandPhase, shrink: shrinkPhase,
          pastShrink: pastShrink!,
          rubber: _rubberFling(targetPos: shrinkLow, friction: rubberShrink),
        );
      case .pastExpand:
        return ScaleInwardContinuation(
          pastExpand: pastExpand!,
          rubber: _rubberFling(targetPos: expandHigh, friction: rubberExpand),
        );
      case .shrink:
      case .expand:
        return ScaleInwardFlingInDisplay(
          pastExpand: pastExpand, expand: expandPhase, shrink: shrinkPhase,
        );
    }
  }
}
