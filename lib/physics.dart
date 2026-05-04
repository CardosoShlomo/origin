import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter/physics.dart';

import 'gestures.dart';

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

/// Computes the fling plan given a per-axis state, or null if no fling
/// warranted. Uses [FrictionSimulation]'s actual position-vs-time as the
/// animation curve (via [FrictionCurve]).
///
/// TODO: extend release to a 3-phase model per axis (× x / y / scale):
///   1. `toDisplay`     — rect coasting toward the display position
///   2. `pastDisplay`   — rect overshoot past display (rubber-band)
///   3. `backToDisplay` — rect returning from past-display to display
/// Each phase has distinct physics (e.g., past-display decelerates harder than
/// toDisplay; backToDisplay may be faster or curve-different). Today we model
/// the gesture-end as a single fling plan; the 3-phase model would let
/// consumers configure the rebound dynamics independently from the initial
/// coast and the snap-back.
AxisFling? flingFromState({
  required AxisState state,
  required Map<DragBound, DragBounds> bounds,
  required double startPos,
  required double velocity,
}) {
  if (velocity.abs() <= 10) return null;
  final boundConfig = bounds[state.activeBound];
  if (boundConfig == null) return null;
  final dc = boundConfig.decelerate;
  if (dc == null) return null;
  final decelerate = state.pastDisplay
      ? (state.extending ? dc.extendingPastDisplay : dc.retractingPastDisplay)
      : (state.extending ? dc.extending : dc.retracting);
  if (decelerate == null || decelerate.start <= 0) return null;

  final coefficient = decelerate.start;
  final sim = FrictionSimulation(coefficient, startPos, velocity);
  final time = (math.log(10 / velocity.abs()) / math.log(coefficient / 100)).abs();
  final clampedTime = time.clamp(0.1, 1.0); // 100..1000 ms
  return (
    to: sim.x(clampedTime),
    duration: Duration(milliseconds: (clampedTime * 1000).round()),
    curve: FrictionCurve(sim, clampedTime),
  );
}
