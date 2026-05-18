import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter/physics.dart';

import 'gestures.dart';
import 'rect_ext.dart';
import 'release.dart';

/// Per-axis classification used by friction / fling lookups.
typedef AxisState = ({
  DragBound activeBound,
  DragDirectionState directionState,
  double progress,
});

/// Discrete direction state for a per-axis drag/release. Four-value
/// taxonomy that mirrors [FrictionConfig]'s slots: combines
/// extending-vs-retracting (motion sign relative to base) with
/// in-display-vs-past-display (rect's actual edge vs display edge).
enum DragDirectionState {
  extending,
  extendingPast,
  retracting,
  retractingPast,
}

/// Which X-axis bound the rect is currently sitting on. If centered at
/// base, [delta]'s sign decides (positive → right).
DragBound boundForX({
  required double delta,
  required Rect currentRect,
  required Rect baseRect,
}) {
  if (currentRect.center.dx > baseRect.center.dx) return .right;
  if (currentRect.center.dx < baseRect.center.dx) return .left;
  return delta >= 0 ? .right : .left;
}

/// Which Y-axis bound the rect is currently sitting on. If centered at
/// base, [delta]'s sign decides (positive → bottom).
DragBound boundForY({
  required double delta,
  required Rect currentRect,
  required Rect baseRect,
}) {
  if (currentRect.center.dy > baseRect.center.dy) return .bottom;
  if (currentRect.center.dy < baseRect.center.dy) return .top;
  return delta >= 0 ? .bottom : .top;
}

/// Four-value X-axis direction state: combines the motion direction
/// (extending vs retracting, decided by [delta]'s sign relative to
/// [boundForX]) with whether the rect's relevant edge is past the
/// display edge.
DragDirectionState directionStateForX({
  required double delta,
  required Rect currentRect,
  required Rect baseRect,
  required Rect displayRect,
}) {
  final isRight = boundForX(delta: delta, currentRect: currentRect, baseRect: baseRect) == .right;
  final pastDisplay = isRight
      ? currentRect.right > displayRect.right
      : currentRect.left < displayRect.left;
  final extending = isRight ? delta > 0 : delta < 0;
  if (extending) return pastDisplay ? .extendingPast : .extending;
  return pastDisplay ? .retractingPast : .retracting;
}

/// Four-value Y-axis direction state — mirror of [directionStateForX].
DragDirectionState directionStateForY({
  required double delta,
  required Rect currentRect,
  required Rect baseRect,
  required Rect displayRect,
}) {
  final isBottom = boundForY(delta: delta, currentRect: currentRect, baseRect: baseRect) == .bottom;
  final pastDisplay = isBottom
      ? currentRect.bottom > displayRect.bottom
      : currentRect.top < displayRect.top;
  final extending = isBottom ? delta > 0 : delta < 0;
  if (extending) return pastDisplay ? .extendingPast : .extending;
  return pastDisplay ? .retractingPast : .retracting;
}

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
  final bound = boundForX(delta: signedAmount, currentRect: currentRect, baseRect: originRect);
  final direction = directionStateForX(
    delta: signedAmount,
    currentRect: currentRect,
    baseRect: originRect,
    displayRect: displayRect,
  );
  final isRight = bound == .right;
  final pastDisplay = direction == .extendingPast || direction == .retractingPast;
  final progress = pastDisplay
      ? ((isRight
              ? currentRect.right - displayRect.right
              : displayRect.left - currentRect.left) / displayRect.width).clamp(0.0, 1.0)
      : ((currentRect.center.dx - originRect.center.dx).abs() / (displayRect.width / 2)).clamp(0.0, 1.0);
  return (activeBound: bound, directionState: direction, progress: progress);
}

/// Computes the Y-axis state.
AxisState axisStateY(
  double signedAmount,
  Rect currentRect,
  Rect originRect,
  Rect displayRect,
) {
  final bound = boundForY(delta: signedAmount, currentRect: currentRect, baseRect: originRect);
  final direction = directionStateForY(
    delta: signedAmount,
    currentRect: currentRect,
    baseRect: originRect,
    displayRect: displayRect,
  );
  final isBottom = bound == .bottom;
  final pastDisplay = direction == .extendingPast || direction == .retractingPast;
  final progress = pastDisplay
      ? ((isBottom
              ? currentRect.bottom - displayRect.bottom
              : displayRect.top - currentRect.top) / displayRect.height).clamp(0.0, 1.0)
      : ((currentRect.center.dy - originRect.center.dy).abs() / (displayRect.height / 2)).clamp(0.0, 1.0);
  return (activeBound: bound, directionState: direction, progress: progress);
}

/// Friction-scaled delta given a per-axis state.
/// Absent bound = blocked (returns 0). Absent friction = free (returns delta).
double frictionFromState({
  required AxisState state,
  required GestureBounds bounds,
  required double delta,
}) {
  if (delta == 0) return 0;
  final boundConfig = bounds[state.activeBound];
  if (boundConfig == null) return 0;
  final fc = boundConfig.friction;
  if (fc == null) return delta;
  final friction = fc.forDirection(state.directionState);
  if (friction == null) return delta;
  return delta * (1.0 - friction.evaluate(state.progress));
}

/// Picks the matching [Friction] ramp from a [FrictionConfig] for the
/// given direction state. One-line mapping that mirrors the enum's
/// shape to the config's four slots.
extension FrictionConfigByDirection on FrictionConfig {
  Friction? forDirection(DragDirectionState direction) => switch (direction) {
        .extending => extending,
        .extendingPast => extendingPastDisplay,
        .retracting => retracting,
        .retractingPast => retractingPastDisplay,
      };
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
/// - The in-display / past-display branch boundary is fixed at the *base*
///   rect's edge — it doesn't move as the live rect shrinks during drag.
///   This is deliberate: [displayRect] defines the static physics zone, and
///   a moving boundary would cause the formula to flip branches as the
///   rect updates, producing rect bistability.
/// - When [displayRect] equals [baseRect] (no in-display slack), the whole
///   drag folds into the `inDisplay` ramp over `displayDim`, so a single
///   ramp like `Friction(1.0, end: 0.2)` covers the full shrink without
///   discontinuity.
/// - Per-axis factors multiplied.
/// Per-axis scaleResponse: given the rect's *actual* center on the
/// axis (whatever the friction-damped translation produced), returns
/// the corresponding scale factor by reading the lerp between
/// geometric endpoints. In-display zone end = "rect's near edge
/// touches display edge, size = base*inDisplay.end"; past-display
/// zone end = "rect's far edge touches display edge, size =
/// base*pastDisplay.end".
double scaleForCenter({
  required double center,
  required double basePos,
  required double baseHalfDim,
  required double displayLow,
  required double displayHigh,
  required ScaleResponse? response,
}) {
  if (response == null) return 1.0;
  final isHigh = center >= basePos;
  final dir = isHigh ? 1.0 : -1.0;
  final dispEdge = isHigh ? displayHigh : displayLow;
  final inEnd = response.inDisplay?.end ?? 1.0;
  final inEndCenter = dispEdge - dir * baseHalfDim * inEnd;
  final travel = (center - basePos) * dir;
  final inTravel = (inEndCenter - basePos) * dir;
  if (travel <= inTravel || response.pastDisplay == null) {
    final p = inTravel > 0 ? (travel / inTravel).clamp(0.0, 1.0) : 0.0;
    final curveP = response.inDisplay?.curve.transform(p) ?? 0.0;
    return 1.0 + (inEnd - 1.0) * curveP;
  }
  final pastEnd = response.pastDisplay!.end;
  final pastEndCenter = dispEdge + dir * baseHalfDim * pastEnd;
  final pastTravel = (pastEndCenter - inEndCenter) * dir;
  final p = pastTravel > 0 ? ((travel - inTravel) / pastTravel).clamp(0.0, 1.0) : 1.0;
  final curveP = response.pastDisplay!.curve.transform(p);
  return inEnd + (pastEnd - inEnd) * curveP;
}

/// Convenience method on [GestureBounds] for the friction primitive.
extension GestureBoundsPhysics on GestureBounds {
  /// See [frictionFromState]. Returns the friction-scaled delta for the
  /// given axis state under these bounds.
  double friction(AxisState state, double delta) =>
      frictionFromState(state: state, bounds: this, delta: delta);
}

/// Compute the new rect for a [DragGesture] update. Handles both branches:
/// scaleResponse-driven (per-axis focal-preserving + width scaling, with
/// non-scaleResponse axes still getting friction-scaled translation) and
/// pure translation (friction-scaled deltas on both axes).
Rect computeDragRect({
  required GestureBounds bounds,
  required Rect currentRect,
  required Rect originRect,
  required Rect displayRect,
  required double aspectRatio,
  required Offset focalPoint,
  required Offset focalPointDelta,
  required Rect startRect,
  required Offset startFocalPoint,
  required Offset Function(AnchorContext) anchorFn,
}) {
  final baseRect = displayRect.baseRect(aspectRatio);
  // Pipeline:
  //   1. Friction damps the per-axis focal motion.
  //   2. effectiveFocal = prevEffectiveFocal + frictionedDelta. Prev
  //      effective focal is back-derived from currentRect via the
  //      anchor invariant `rect.center = focal − anchor*scale`.
  //   3. scaleForCenter input: `effectiveFocal − anchor*prevScale`
  //      (the rect's would-be center if scale hadn't changed yet).
  //      This is "scale factor calculated with the anchor's offset".
  //   4. newCenter = `effectiveFocal − anchor * factor` — anchor
  //      offset implemented at the new scale. (focal − center) ∝
  //      scale, so smaller rects ride closer to the pointer.
  //   Without friction this reduces to the prior anchor-only model:
  //   factor = scaleForCenter(focal − anchor); newCenter = focal −
  //   anchor*factor.
  final anchor = startFocalPoint - startRect.center;
  final prevScale = startRect.width == 0 ? 1.0 : currentRect.width / startRect.width;
  final prevEffectiveFocal = currentRect.center + anchor * prevScale;
  final stateX = axisStateX(focalPointDelta.dx, currentRect, originRect, displayRect);
  final stateY = axisStateY(focalPointDelta.dy, currentRect, originRect, displayRect);
  final effectiveDeltaX = bounds.hasHorizontalBound
      ? bounds.friction(stateX, focalPointDelta.dx)
      : focalPointDelta.dx;
  final effectiveDeltaY = bounds.hasVerticalBound
      ? bounds.friction(stateY, focalPointDelta.dy)
      : focalPointDelta.dy;
  final effectiveFocal = prevEffectiveFocal + Offset(effectiveDeltaX, effectiveDeltaY);
  // Anchor-adjusted input for the scale calc (anchor's offset baked in).
  final scaleInputX = effectiveFocal.dx - anchor.dx * prevScale;
  final scaleInputY = effectiveFocal.dy - anchor.dy * prevScale;
  final factorX = bounds.hasHorizontalScaleResponse
      ? scaleForCenter(
          center: scaleInputX,
          basePos: baseRect.center.dx,
          baseHalfDim: baseRect.width / 2,
          displayLow: displayRect.left,
          displayHigh: displayRect.right,
          response: bounds[stateX.activeBound]?.scaleResponse,
        )
      : 1.0;
  final factorY = bounds.hasVerticalScaleResponse
      ? scaleForCenter(
          center: scaleInputY,
          basePos: baseRect.center.dy,
          baseHalfDim: baseRect.height / 2,
          displayLow: displayRect.top,
          displayHigh: displayRect.bottom,
          response: bounds[stateY.activeBound]?.scaleResponse,
        )
      : 1.0;
  final combinedFactor = factorX * factorY;
  // New center: anchor offset implemented at the new scale.
  final newCenterX = effectiveFocal.dx - anchor.dx * combinedFactor;
  final newCenterY = effectiveFocal.dy - anchor.dy * combinedFactor;
  return applyDragTransform(
    newCenter: Offset(newCenterX, newCenterY),
    baseRect: baseRect,
    aspectRatio: aspectRatio,
    scaleFactor: combinedFactor,
  );
}

/// Pure rect-construction helper. Takes the final per-axis [newCenter]
/// (already decided by the caller's routing — scaleResponse center,
/// anchor center, or friction-translated current center) and the final
/// [scaleFactor] (multiplier on [baseRect]'s width). Builds the new
/// rect centered at [newCenter] with `newWidth = baseRect.width *
/// scaleFactor`, `newHeight = newWidth / aspectRatio`.
Rect applyDragTransform({
  required Offset newCenter,
  required Rect baseRect,
  required double aspectRatio,
  required double scaleFactor,
}) {
  final newWidth = baseRect.width * scaleFactor;
  final newHeight = newWidth / aspectRatio;
  return Rect.fromCenter(
    center: newCenter,
    width: newWidth,
    height: newHeight,
  );
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
  required GestureBounds bounds,
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
  // Scale-aware center adjustment: as the rect shrinks from
  // currentRect.width to fitWidth (during scale settle), the point currently
  // at displayRect.center should stay at displayRect.center. That means the
  // rect's new center is the proportional position between displayRect.center
  // and the current center, with the width-ratio as the proportion. Then
  // the cover-clamp (`getLimitedCenterXInside`) is applied as a safety so
  // the rect never exposes a display edge.
  final widthRatio = currentRect.width == 0 ? 1.0 : fitWidth / currentRect.width;
  // Same scale-aware adjustment used by both decay phases and the settle
  // target — keeps the display-center point stable as the rect shrinks.
  double scaleAwareCenter(double cx) =>
      displayRect.center.dx + (cx - displayRect.center.dx) * widthRatio;
  double fitAt(double cx) {
    return Rect.fromCenter(
      center: Offset(scaleAwareCenter(cx), currentRect.center.dy),
      width: fitWidth,
      height: fitHeight,
    ).getLimitedCenterXInside(displayRect);
  }
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
  required GestureBounds bounds,
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
  // Scale-aware center adjustment — see [releaseFromStateX] for the
  // rationale. Keeps the display-center point under display-center after
  // the scale settles, with cover-clamp applied as a safety.
  final heightRatio = currentRect.height == 0 ? 1.0 : fitHeight / currentRect.height;
  double scaleAwareCenter(double cy) =>
      displayRect.center.dy + (cy - displayRect.center.dy) * heightRatio;
  double fitAt(double cy) {
    return Rect.fromCenter(
      center: Offset(currentRect.center.dx, scaleAwareCenter(cy)),
      width: fitWidth,
      height: fitHeight,
    ).getLimitedCenterYInside(displayRect);
  }
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
