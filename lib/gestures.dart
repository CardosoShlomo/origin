import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import 'origin_rect.dart';
import 'release.dart';

typedef StageBuilder = Widget Function(BuildContext context, Widget child);

typedef StageTap = void Function(TapEvent event);

class TapEvent {
  TapEvent({
    required this.localPosition,
    required this.globalPosition,
    required this.animateToBase,
    required this.runEffect,
  });

  final Offset localPosition;
  final Offset globalPosition;
  /// Opens the Origin onto the Stage. Optional [mode] is a key into the
  /// Origin's [Origin.modes] map — when set, that mode's DisplayConfig is
  /// merged onto the default before animating. Use this to open with
  /// tool-specific configuration (e.g. `event.animateToBase('crop_square')`).
  final Future<void> Function([Object? mode]) animateToBase;
  final Future<void> Function({
    double? rotateX,
    double? rotateY,
    double? rotateZ,
    double? perspective,
    Duration duration,
    Curve curve,
  }) runEffect;
}

/// Signature for displayed-state tap/double-tap handlers — both carry the
/// same [StageTapEvent] payload.
///
/// Distinct from Origin's [Origin.onTap] (which is a [StageTap], used to open
/// the un-displayed item onto the Stage). This one runs while the item is
/// already on stage and resolves through the cascade [DisplayConfig.onTap] /
/// [DisplayConfig.onDoubleTap] → [Stage.onTap] / [Stage.onDoubleTap] →
/// package default (no-op for [onTap]; toggle baseRect ↔ fit-cover-at-focal
/// for [onDoubleTap]).
///
/// The handler does not receive a [BuildContext] — consumers typically
/// define these callbacks in a `build` body where they already have one in
/// scope and can call `Stage.of(context).dismiss()` etc. directly.
typedef OnStageTap = void Function(StageTapEvent event);

/// Inputs passed to [OnStageTap] when the displayed view receives a single-
/// or double-tap. Carries the tap position plus the current/base/display
/// rects at the moment of the tap.
class StageTapEvent {
  const StageTapEvent({
    required this.localPosition,
    required this.globalPosition,
    required this.currentRect,
    required this.displayRect,
    required this.baseRect,
    required this.aspectRatio,
  });

  final Offset localPosition;
  final Offset globalPosition;
  final Rect currentRect;
  final Rect displayRect;
  final Rect baseRect;
  final double aspectRatio;

  /// True if the tap landed inside the currently-displayed rect.
  bool get insideRect => currentRect.contains(globalPosition);
}

/// Sealed parent for gesture-start enums. Pattern-match exhaustiveness on
/// [DragStart] vs [ScaleStart] is guaranteed.
sealed class GestureStart {}

/// A committed gesture: the matched key (start) and value (gesture).
typedef ActiveGesture = ({GestureStart start, Gesture gesture});

/// An Origin-level gesture currently in flight, surfaced to [StageData] so
/// Stage can decide what to do with new pointers (see [DragHybrid] /
/// [ScaleHybrid]). The hybrid fields are *partially-resolved* — Origin
/// folds in gesture-level + Origin-level, Stage finishes with its own
/// fallback and the package default.
///
/// [scale] carries Origin's scale map so the hybrid merger can re-resolve
/// drag → scale via the scale arena when [DragHybrid.asScale] is active.
/// [onRelease] is Origin's own onRelease fallback, used in the cascade
/// when Stage fires the hybrid release (gesture → Origin → Stage → default).
typedef OriginGesture = ({
  ActiveGesture active,
  DragHybrid? dragHybrid,
  ScaleHybrid? scaleHybrid,
  Map<ScaleStart, ScaleGesture>? scale,
  OnRelease? onRelease,
  double? scaleVelocityCancel,
});

enum DragStart implements GestureStart {
  left, right, up, down,
  upLeft, upRight, downLeft, downRight,
  leftDominant, rightDominant, upDominant, downDominant,
  horizontal, vertical, any,
}

enum DragBound { left, right, top, bottom }

enum ScaleStart implements GestureStart {
  shrink, expand, any,
}

/// Resistance to motion during an active gesture, as a function of progress
/// through a bound state. Range [0, 1]: 0 = no resistance, 1 = block.
class Friction {
  const Friction(double value, {double? end, this.curve = Curves.linear})
      : start = value,
        end = end ?? value;

  final double start;
  final double end;
  final Curve curve;

  double evaluate(double progress) =>
      start + (end - start) * curve.transform(progress.clamp(0.0, 1.0));
}

/// Release-time decay model. Produces a Flutter [Simulation] for the rect's
/// post-gesture motion given a starting position and velocity. Origin reads
/// `x(t)`, `dx(t)`, `isDone(t)` on the returned simulation — anything that
/// conforms to [Simulation] plugs in (friction, spring, custom).
abstract class Decay {
  const Decay({this.endVelocity = 60});

  /// Velocity (logical px/s) at which the decay phase ends. Higher = snappier
  /// handoff to settle; lower = more "complete" tail. Default 60 ≈ 1 px/frame
  /// at 60 Hz, the inter-frame visibility threshold.
  final double endVelocity;

  Simulation simulationAt({required double position, required double velocity});

  // Const factory redirects to ExponentialDecay's named const constructors,
  // so dot-shorthand on a `Decay?` field works and the result stays const.
  const factory Decay.exponential(double drag, {double endVelocity}) = ExponentialDecay;
  const factory Decay.iosScroll({double endVelocity}) = ExponentialDecay.iosScroll;
  const factory Decay.iosFast({double endVelocity}) = ExponentialDecay.iosFast;
  const factory Decay.imageViewer({double endVelocity}) = ExponentialDecay.imageViewer;
  const factory Decay.none({double endVelocity}) = ExponentialDecay.none;

  // Non-const factory redirects for parameterized presets.
  factory Decay.halfLife(Duration t, {double endVelocity}) = ExponentialDecay.halfLife;
  factory Decay.perFrame(double multiplier, {double fps, double endVelocity}) =
      ExponentialDecay.perFrame;
}

/// Rubber-back settle model. Produces a Flutter [Simulation] that starts at
/// the decay's end position and velocity, and lands at the target. Origin
/// renders the motion via the returned simulation, giving velocity
/// continuity with the decay phase.
abstract class Settle {
  const Settle();

  Simulation simulationAt({
    required double position,
    required double velocity,
    required double target,
  });

  const factory Settle.attract({double stiffness}) = AttractSettle;
}

/// Settle via critically-damped [SpringSimulation] — attractor pulls rect to
/// target (force ∝ displacement). Starts slow, accelerates, lands smoothly
/// with no overshoot. [stiffness] controls snap speed; damping is auto-tuned
/// to critical.
class AttractSettle extends Settle {
  const AttractSettle({this.stiffness = 200});

  final double stiffness;

  @override
  Simulation simulationAt({
    required double position,
    required double velocity,
    required double target,
  }) {
    final desc = SpringDescription(
      mass: 1,
      stiffness: stiffness,
      damping: 2 * math.sqrt(stiffness), // critical damping
    );
    return SpringSimulation(
      desc,
      position,
      target,
      velocity,
      // Loose tolerance trims the slow asymptotic tail — sub-perceptible.
      tolerance: const Tolerance(distance: 3, velocity: 150),
    );
  }
}

/// Exponential velocity decay via [FrictionSimulation].
///
/// [decayPerSecond] ∈ [0, 1] is the fraction of velocity lost per second.
/// 0 → never decays, 1 → instant stop.
class ExponentialDecay extends Decay {
  const ExponentialDecay(this.decayPerSecond, {super.endVelocity});

  /// iOS scrollview feel — long fling (per-frame 0.998 @ 60fps).
  const ExponentialDecay.iosScroll({super.endVelocity}) : decayPerSecond = 0.114;
  /// iOS `.fast` / paging feel — snappier (per-frame 0.99 @ 60fps).
  const ExponentialDecay.iosFast({super.endVelocity}) : decayPerSecond = 0.453;
  /// Image-viewer feel — brief, image-sized fling with a visible tail.
  const ExponentialDecay.imageViewer({super.endVelocity}) : decayPerSecond = 0.95;
  /// Velocity is killed at release — no fling at all.
  const ExponentialDecay.none({super.endVelocity}) : decayPerSecond = 1.0;

  /// Velocity half-life — the time for velocity to halve.
  factory ExponentialDecay.halfLife(Duration t, {double endVelocity = 60}) {
    final s = t.inMicroseconds / 1e6;
    if (s <= 0) return ExponentialDecay.none(endVelocity: endVelocity);
    return ExponentialDecay(
      1 - math.pow(0.5, 1 / s).toDouble(),
      endVelocity: endVelocity,
    );
  }

  /// Per-frame velocity multiplier (iOS / JS conventions). 60fps default.
  factory ExponentialDecay.perFrame(double multiplier,
          {double fps = 60, double endVelocity = 60}) =>
      ExponentialDecay(
        1 - math.pow(multiplier, fps).toDouble(),
        endVelocity: endVelocity,
      );

  /// Fraction of velocity lost per second.
  final double decayPerSecond;

  @override
  Simulation simulationAt({required double position, required double velocity}) =>
      FrictionSimulation(
        (1 - decayPerSecond).clamp(0.0, 0.999),
        position,
        velocity,
      );
}

/// Per-state friction during an active gesture.
///
/// Progress dimension: depth into the bound state (0 = entering, 1 = at the state's far edge).
/// `extending`/`retracting`: motion deeper into the bound vs back toward origin.
/// `*PastDisplay`: while the rect is outside the display area.
class FrictionConfig {
  const FrictionConfig({
    this.extending,
    this.extendingPastDisplay,
    this.retracting,
    this.retractingPastDisplay,
  });

  /// Same [Friction] for all four states.
  const FrictionConfig.uniform(Friction friction)
      : extending = friction,
        extendingPastDisplay = friction,
        retracting = friction,
        retractingPastDisplay = friction;

  /// Direction-grouped: in-display and past-display states share the
  /// same ramp per direction.
  const FrictionConfig.byDirection({
    required this.extending,
    required this.retracting,
  })  : extendingPastDisplay = extending,
        retractingPastDisplay = retracting;

  /// Group by *zone*: [inDisplay] applies to both extending and retracting
  /// while the rect's edge is inside the display; [pastDisplay] applies to
  /// both once the edge has crossed.
  const FrictionConfig.byZone({
    required Friction inDisplay,
    required Friction pastDisplay,
  })  : extending = inDisplay,
        retracting = inDisplay,
        extendingPastDisplay = pastDisplay,
        retractingPastDisplay = pastDisplay;

  final Friction? extending;
  final Friction? extendingPastDisplay;
  final Friction? retracting;
  final Friction? retractingPastDisplay;

  FrictionConfig copyWith({
    Friction? extending,
    Friction? extendingPastDisplay,
    Friction? retracting,
    Friction? retractingPastDisplay,
  }) =>
      FrictionConfig(
        extending: extending ?? this.extending,
        extendingPastDisplay: extendingPastDisplay ?? this.extendingPastDisplay,
        retracting: retracting ?? this.retracting,
        retractingPastDisplay: retractingPastDisplay ?? this.retractingPastDisplay,
      );
}

/// Per-state release-time decay model.
///
/// State semantics match [FrictionConfig]: applied based on rect position
/// (in-display vs past-display) and direction (extending vs retracting).
/// The release trajectory consults this 4-state map per phase, picking the
/// [Decay] whose zone the segment occupies.
class DecayConfig {
  const DecayConfig({
    this.extending,
    this.extendingPastDisplay,
    this.retracting,
    this.retractingPastDisplay,
    this.settle,
  });

  /// Same [Decay] for all four states. [settle] is independent.
  const DecayConfig.uniform(Decay decay, {this.settle})
      : extending = decay,
        extendingPastDisplay = decay,
        retracting = decay,
        retractingPastDisplay = decay;

  /// Group by *direction*: [extending] covers both in-display and
  /// past-display extending; [retracting] covers both retracting states.
  const DecayConfig.byDirection({
    required this.extending,
    required this.retracting,
    this.settle,
  })  : extendingPastDisplay = extending,
        retractingPastDisplay = retracting;

  /// Group by *zone*: [inDisplay] covers both extending and retracting
  /// inside the display; [pastDisplay] covers both once the edge has crossed.
  const DecayConfig.byZone({
    required Decay inDisplay,
    required Decay pastDisplay,
    this.settle,
  })  : extending = inDisplay,
        retracting = inDisplay,
        extendingPastDisplay = pastDisplay,
        retractingPastDisplay = pastDisplay;

  final Decay? extending;
  final Decay? extendingPastDisplay;
  final Decay? retracting;
  final Decay? retractingPastDisplay;

  /// Rubber-back motion after decay ends. The simulation is driven by
  /// [Settle.simulationAt] so velocity stays continuous from the decay's
  /// end. Null = use package default ([FrictionSettle]).
  final Settle? settle;

  DecayConfig copyWith({
    Decay? extending,
    Decay? extendingPastDisplay,
    Decay? retracting,
    Decay? retractingPastDisplay,
    Settle? settle,
  }) =>
      DecayConfig(
        extending: extending ?? this.extending,
        extendingPastDisplay: extendingPastDisplay ?? this.extendingPastDisplay,
        retracting: retracting ?? this.retracting,
        retractingPastDisplay: retractingPastDisplay ?? this.retractingPastDisplay,
        settle: settle ?? this.settle,
      );
}

/// Shared base for bound configurations.
///
/// Carries the cross-cutting per-bound fields ([friction], [decay], [builder]).
/// Subclasses add bound-type-specific fields (e.g., [ShrinkBounds.minScale]).
sealed class Bounds {
  const Bounds({
    this.friction,
    this.decay,
    this.builder,
  });

  final FrictionConfig? friction;
  final DecayConfig? decay;
  final StageBuilder? builder;
}

class DragBounds extends Bounds {
  const DragBounds({
    super.friction,
    super.decay,
    super.builder,
    this.scaleResponse,
  });

  /// Per-bound override of [DragGesture.scaleResponse]. Couples rect width to
  /// drag-progress through this bound. Native physics (rect.width changes),
  /// not a visual transform. When configured, the drag uses focal-point-
  /// preserving anchor math instead of plain translation.
  final ScaleResponse? scaleResponse;
}

/// One zone of a [ScaleResponse]. Maps a normalized progress (0..1
/// across that zone's drag travel) to a scale factor that ends at
/// [end] via [curve]. The zone's *start* value is implicit (taken
/// from the prior zone's `end`, or `1.0` at base for the first zone)
/// so consecutive ramps are guaranteed continuous.
///
/// **Reference frame:** [end] is *always relative to baseWidth*, never
/// to the previous zone's end. So `pastDisplay: ScaleRamp(end: 0.2)`
/// means "at full past-display, rect.width = 0.2 × baseWidth"
/// regardless of what [inDisplay.end] was. This keeps the API
/// declarative — each ramp's [end] is the absolute target the rect
/// reaches at the end of that zone's drag.
///
/// Consequences:
/// - `pastDisplay.end < inDisplay.end` → continued shrinking past edge
///   (the usual case).
/// - `pastDisplay.end > inDisplay.end` → rect grows back from edge
///   state during past-display drag (valid; sometimes a useful effect).
/// - `end > 1.0` → grows the rect; `end < 1.0` → shrinks. Both fine.
class ScaleRamp {
  const ScaleRamp({this.end = 0.5, this.curve = Curves.linear});

  /// Scale factor at progress=1 of this zone — absolute multiplier on
  /// baseWidth (not on the previous zone's end). See class doc.
  final double end;

  /// Shape of the ramp from the implicit start value to [end].
  final Curve curve;
}

/// Scale-as-function-of-drag-progress, split into two zones:
/// - [inDisplay]: covers the in-display drag zone (base position →
///   rect's near edge touching display edge). Center lerps from
///   baseCenter → near-edge-on-display center; scale lerps `1.0 →
///   inDisplay.end` over the same curved progress.
/// - [pastDisplay]: covers the past-display drag zone (rect at near
///   edge → rect at far edge). End state = rect's *far* edge touching
///   the display's edge with size `base * pastDisplay.end`. Scale
///   lerps from `inDisplay.end` (or `1.0` if no inDisplay ramp) →
///   `pastDisplay.end`.
///
/// Auto-stitched: each zone's start = previous zone's end, so the
/// response can never be discontinuous at the geometric boundary.
class ScaleResponse {
  const ScaleResponse({this.inDisplay, this.pastDisplay});

  final ScaleRamp? inDisplay;
  final ScaleRamp? pastDisplay;
}

class ShrinkBounds extends Bounds {
  const ShrinkBounds({
    super.friction,
    super.decay,
    super.builder,
    this.minScale,
  });

  /// Scale below which the rect is "past display." Null = no minimum (rect can
  /// shrink without ever entering the past-display state).
  final double? minScale;
}

class ExpandBounds extends Bounds {
  const ExpandBounds({
    super.friction,
    super.decay,
    super.builder,
    this.maxScale,
  });

  /// Scale above which the rect is "past display." Null = no maximum.
  final double? maxScale;
}

/// Per-direction container of [DragBounds] for a gesture's four sides.
/// Replaces the old `Map<DragBound, DragBounds>` so the API stays
/// const-constructible, type-safe, and ships named shortcuts for the
/// common shapes. Use [at] for enum-keyed lookups inside physics code.
///
/// Convenience constructors cover the common shapes; for asymmetric
/// configurations use the default constructor with named args.
class GestureBounds {
  const GestureBounds({this.top, this.bottom, this.left, this.right});

  const GestureBounds.top(this.top) : bottom = null, left = null, right = null;
  const GestureBounds.bottom(this.bottom) : top = null, left = null, right = null;
  const GestureBounds.left(this.left) : top = null, bottom = null, right = null;
  const GestureBounds.right(this.right) : top = null, bottom = null, left = null;

  const GestureBounds.vertical(DragBounds bounds)
      : top = bounds, bottom = bounds, left = null, right = null;
  const GestureBounds.horizontal(DragBounds bounds)
      : left = bounds, right = bounds, top = null, bottom = null;
  const GestureBounds.symmetric({DragBounds? vertical, DragBounds? horizontal})
      : top = vertical, bottom = vertical, left = horizontal, right = horizontal;

  const GestureBounds.all([DragBounds bounds = const DragBounds()])
      : top = bounds, bottom = bounds, left = bounds, right = bounds;

  final DragBounds? top;
  final DragBounds? bottom;
  final DragBounds? left;
  final DragBounds? right;

  DragBounds? operator [](DragBound bound) => switch (bound) {
        .top => top,
        .bottom => bottom,
        .left => left,
        .right => right,
      };

  bool get hasScaleResponse =>
      hasVerticalScaleResponse || hasHorizontalScaleResponse;

  bool get hasVerticalScaleResponse =>
      top?.scaleResponse != null || bottom?.scaleResponse != null;

  bool get hasHorizontalScaleResponse =>
      left?.scaleResponse != null || right?.scaleResponse != null;

  bool get hasVerticalBound => top != null || bottom != null;
  bool get hasHorizontalBound => left != null || right != null;
}

/// Sealed parent for gesture kinds.
sealed class Gesture {
  const Gesture({
    this.bounds = const GestureBounds(),
    this.constraints,
    this.builder,
    this.onRelease,
    this.scaleVelocityCancel,
  });

  /// Directional bounds active during this gesture (drag) or directional
  /// overflow during scale (rect edges past container edges).
  final GestureBounds bounds;

  final GestureConstraints? constraints;
  final StageBuilder? builder;

  /// Called when the gesture ends with a [ReleaseContext] — raw end-state
  /// inputs. Consumer calls `Stage.of(context).release(Release.toDisplay(data))`
  /// for the default plan, or builds a custom plan and calls `.run(...)` /
  /// `.backToOrigin(data)` / etc.
  ///
  /// Cascade fallback when null: [DisplayConfig.onRelease] →
  /// [Origin.onRelease] / [Stage.onRelease] → package default.
  final OnRelease? onRelease;

  /// Per-gesture strength of scale-velocity-based translation cancellation
  /// in `[0, 1]`. Cascade fallback when null: [DisplayConfig.scaleVelocityCancel]
  /// → [Origin.scaleVelocityCancel] → [Stage.scaleVelocityCancel] → 0.5.
  /// Most relevant on [ScaleGesture]; a no-op on [DragGesture] since
  /// scaleVelocity is ~0 there.
  final double? scaleVelocityCancel;
}

/// How a Stage receives pointer additions while an Origin is dragging.
/// Cascade: per-gesture > per-Origin > per-Stage > [lock] default.
enum DragHybrid {
  /// Stage pointers are ignored — Origin's drag stays sole controller.
  lock,
  /// Stage pointers join the drag, contributing to the focal x/y. Origin's
  /// drag config (bounds, friction, override) continues to apply. No scale
  /// math, even with multiple pointers.
  asDrag,
  /// Stage pointers promote drag → scale via Origin's `scale` map. Resolver
  /// re-runs against that map with the new pointer count to pick the
  /// matching [ScaleStart].
  asScale,
}

/// How a Stage receives pointer additions while an Origin is scaling.
/// Cascade: per-gesture > per-Origin > per-Stage > [lock] default.
enum ScaleHybrid {
  /// Stage pointers are ignored.
  lock,
  /// Stage pointers merge into Origin's scale; Origin's scale config applies.
  merge,
}

/// What Stage does in displayed state when a 2nd pointer is added while a
/// [DragGesture] is the active gesture. Cascade: per-gesture > per-displayConfig
/// > per-stage > [scale] default.
enum DragPromote {
  /// Keep the drag; adding a 2nd pointer does not re-resolve to a scale gesture.
  lock,
  /// Default. On 2nd-pointer add, scale arena re-resolves against
  /// [Stage.scale] ∪ [DisplayConfig.scale].
  scale,
}

class DragGesture extends Gesture {
  const DragGesture({
    super.bounds,
    super.constraints,
    super.builder,
    super.onRelease,
    super.scaleVelocityCancel,
    this.override,
    this.hybridFromStage,
    this.promote,
  });

  /// Optional resolver invoked at gesture commit. Receives the rect at gesture
  /// start and the base rect; returns the [DragGesture] to actually use for
  /// the rest of the gesture (or null to keep this one). Lets consumers pick
  /// a different variant based on starting rect state — e.g., shrink-on-drag
  /// only when starting at base; plain translation otherwise.
  final DragGesture? Function(Rect startRect, Rect baseRect)? override;

  /// Per-gesture override for how Stage receives new pointers while this
  /// drag is active. Cascades up to [Origin.dragHybridFromStage] →
  /// [Stage.dragHybridFromStage] → [DragHybrid.lock] when null.
  ///
  /// Context-specific: only read when this [DragGesture] is registered on
  /// [Origin.drag] (an un-displayed item whose drag may be joined by stage
  /// pointers via the hybrid merger). No-op when this gesture is registered
  /// in [Stage.drag] or [DisplayConfig.drag] — see [promote] for the
  /// displayed-state analog.
  final DragHybrid? hybridFromStage;

  /// Per-gesture override for displayed-state drag→scale promotion when a
  /// 2nd pointer is added. Cascades up to [DisplayConfig.dragPromote] →
  /// [Stage.dragPromote] → [DragPromote.scale] when null.
  ///
  /// Context-specific: only read when this [DragGesture] is registered on
  /// [Stage.drag] or [DisplayConfig.drag] (used in displayed state). No-op
  /// when registered on [Origin.drag] — see [hybridFromStage] for the
  /// hybrid-context analog.
  final DragPromote? promote;
}

class ScaleGesture extends Gesture {
  const ScaleGesture({
    super.bounds,
    super.constraints,
    super.builder,
    super.onRelease,
    super.scaleVelocityCancel,
    this.shrink,
    this.expand,
    this.hybridFromStage,
  });

  /// Shrink-axis bound config (with optional minScale threshold).
  final ShrinkBounds? shrink;

  /// Expand-axis bound config (with optional maxScale threshold).
  final ExpandBounds? expand;

  /// Per-gesture override for how Stage receives new pointers while this
  /// scale is active. Cascades up to [Origin.scaleHybridFromStage] →
  /// [Stage.scaleHybridFromStage] → [ScaleHybrid.lock] when null.
  final ScaleHybrid? hybridFromStage;
}

class GestureConstraints {
  const GestureConstraints({
    this.friction,
    this.decay,
    this.perspective,
  });

  final FrictionConfig? friction;
  final DecayConfig? decay;
  final double? perspective;
}

/// Override config applied while an Origin is displayed (active on stage).
///
/// All fields nullable. When unset, the runtime cascade falls back to the
/// Origin's own configuration, then to the enclosing Stage's defaults, then to
/// hardcoded library defaults. Per-key cascade for maps; per-field for [constraints].
class DisplayConfig {
  const DisplayConfig({
    this.drag,
    this.scale,
    this.constraints,
    this.onRelease,
    this.onTap,
    this.onDoubleTap,
    this.doubleTapPullFactor,
    this.dragPromote,
    this.scaleVelocityCancel,
    this.crop,
    this.overlay,
    this.display,
    this.displayContainer,
    this.overrides,
    this.builder,
    this.onTapOutside,
  });

  final Map<DragStart, DragGesture>? drag;
  final Map<ScaleStart, ScaleGesture>? scale;
  final GestureConstraints? constraints;

  /// Cascade fallback for [Gesture.onRelease] while the origin is displayed.
  /// Resolved as: gesture > displayConfig > stage > package default.
  final OnRelease? onRelease;

  /// Cascade fallback for displayed-state single-tap. Resolved as:
  /// displayConfig > stage > package default (no-op). Use this to react to
  /// taps on the displayed view — e.g. toggle a chrome overlay when the tap
  /// is [StageTapEvent.insideRect], dismiss otherwise.
  final OnStageTap? onTap;

  /// Cascade fallback for displayed-state double-tap. Resolved as:
  /// displayConfig > stage > package default (toggle baseRect ↔ fit-cover).
  final OnStageTap? onDoubleTap;

  /// Tunes the panning behavior of the default at-base double-tap (passed to
  /// [RectExt.fitCoverRect] as `pullFactor`). `0` = under-finger, `1` = max
  /// edge attraction. Cascade: displayConfig > stage > package default.
  final double? doubleTapPullFactor;

  /// Cascade fallback for displayed-state drag→scale promotion. Resolved as:
  /// gesture > displayConfig > stage > [DragPromote.scale] default.
  final DragPromote? dragPromote;

  /// Cascade fallback for scale-velocity-based translation cancellation in
  /// `[0, 1]`. Resolved as: gesture > displayConfig > stage > 0.5 default.
  final double? scaleVelocityCancel;

  /// Cropper tool configuration. When non-null and a `Cropper` widget is
  /// present in the displayed view's tree, the cropper renders its UI and
  /// owns 1-finger gestures. Different modes can have different `CropConfig`s
  /// (e.g., `'crop_square'` locks aspect ratio, `'crop_free'` allows any).
  final CropConfig? crop;

  /// Optional overlay builder for this DisplayConfig. Resolved in the
  /// cascade: mode > displayConfig > [Origin.overlay] > [Stage.overlay].
  /// Set on a mode to swap in a tool-specific appbar (e.g., crop toolbar)
  /// only when that mode is active.
  final WidgetBuilder? overlay;

  /// Optional display rect override. Resolved in the cascade
  /// mode > displayConfig > [Origin.display]. Use this on a mode to
  /// constrain the displayed item's rect (e.g., shrink so it doesn't run
  /// under an appbar that's only present in this mode).
  final OriginRect? display;

  /// Optional display container override. Resolved in the cascade
  /// mode > displayConfig > [Origin.displayContainer].
  final OriginRect? displayContainer;

  /// Cascade fallback for [Stage.overrides]/[Origin.overrides] while the
  /// origin is displayed.
  final Overrides? overrides;

  /// Per-mode wrap of the captured widget. Resolved in the cascade
  /// gesture.bounds.builder > gesture.builder > displayConfig > Origin.builder.
  /// Use this to layer mode-specific visual content over the captured widget
  /// (e.g. a picker chrome that crossfades between an icon and a button row
  /// as the rect interpolates from origin to base). Taps inside the builder
  /// are absorbed by Stage's gesture detector — interactive tap targets
  /// belong in [overlay] or in a position-dispatching [onTap].
  final StageBuilder? builder;

  /// Fires when the user taps the scrim (the dim area outside the captured
  /// rect). Lives on the scrim's own [GestureDetector], not Stage's
  /// [TapGestureRecognizer], so it doesn't compete in the gesture arena
  /// with [GestureDetector]s inside the captured widget tree. Pair this
  /// with no [onTap] when the captured widget hosts its own interactive
  /// children that need to win their taps.
  final VoidCallback? onTapOutside;

  /// Returns a new [DisplayConfig] where each non-null field of [override]
  /// replaces the corresponding field of `this`. Null fields in [override]
  /// keep the value from `this`. Used to apply mode-specific configs on top
  /// of the default `DisplayConfig` — see [Origin.modes].
  ///
  /// Note: Map fields (`drag`, `scale`) follow the same "non-null wins" rule,
  /// so passing an empty `{}` in [override] explicitly disables (vs `null`
  /// which inherits).
  DisplayConfig merge(DisplayConfig? override) {
    if (override == null) return this;
    return DisplayConfig(
      drag: override.drag ?? drag,
      scale: override.scale ?? scale,
      constraints: override.constraints ?? constraints,
      onRelease: override.onRelease ?? onRelease,
      onTap: override.onTap ?? onTap,
      onDoubleTap: override.onDoubleTap ?? onDoubleTap,
      doubleTapPullFactor: override.doubleTapPullFactor ?? doubleTapPullFactor,
      dragPromote: override.dragPromote ?? dragPromote,
      scaleVelocityCancel: override.scaleVelocityCancel ?? scaleVelocityCancel,
      crop: override.crop ?? crop,
      overlay: override.overlay ?? overlay,
      display: override.display ?? display,
      displayContainer: override.displayContainer ?? displayContainer,
      overrides: override.overrides ?? overrides,
      builder: override.builder ?? builder,
      onTapOutside: override.onTapOutside ?? onTapOutside,
    );
  }
}

/// Cropper tool configuration. Attached to a [DisplayConfig] via
/// [DisplayConfig.crop]. When non-null in the active mode's DisplayConfig,
/// the [Cropper] widget renders crop UI and applies these constraints when
/// the user manipulates the crop rect.
class CropConfig {
  const CropConfig({
    this.minAspectRatio,
    this.maxAspectRatio,
    this.shortest,
    this.longest,
    this.smallest,
    this.largest,
    this.initialRect,
    this.borderRadius,
    this.overdragMax = 3.0,
  }) : assert(
          minAspectRatio == null ||
              maxAspectRatio == null ||
              maxAspectRatio >= minAspectRatio,
          'maxAspectRatio must be >= minAspectRatio',
        );

  /// Allowed aspect-ratio range (width / height) for the crop rect.
  /// Both null = free aspect. Equal min/max = locked aspect.
  final double? minAspectRatio;
  final double? maxAspectRatio;

  /// Minimum dimensions. Null = no minimum.
  final Size? shortest;

  /// Maximum dimensions. Null = no maximum.
  final Size? longest;

  /// Minimum area (e.g. `width × height` floor). Null = no area floor.
  final double? smallest;

  /// Maximum area (e.g. `width × height` cap). Null = no area limit.
  final double? largest;

  /// Computes the initial crop rect given the base rect. Null = default
  /// to the base rect itself.
  final Rect Function(Rect baseRect)? initialRect;

  /// Computes the visual border radius from the current crop rect.
  /// Lets the radius scale with the rect's dimensions — e.g.,
  /// `(r) => BorderRadius.circular(r.shortestSide / 2)` for a circular
  /// preview, `(r) => BorderRadius.circular(r.shortestSide / 8)` for a
  /// soft-rounded square. Null = rectangular preview.
  final BorderRadius Function(Rect cropRect)? borderRadius;

  /// Caps the per-frame image shift applied when the crop rect is being
  /// dragged into the edge of the image (see
  /// [ScaleExt.imageRectOnDragCropRect]). Higher values let the image catch
  /// up to the finger more aggressively when the crop is pinned against an
  /// edge; lower values keep the image steadier. Default `3.0`, matching
  /// imagineai's original tuning.
  final double overdragMax;
}

/// Inputs supplied to [Overrides.anchor] when computing the rect's center
/// during a drag with [DragGesture.scaleResponse].
class AnchorContext {
  const AnchorContext({
    required this.startFocalPoint,
    required this.currentFocalPoint,
    required this.startRect,
    required this.currentRect,
    required this.scale,
  });

  final Offset startFocalPoint;
  final Offset currentFocalPoint;
  final Rect startRect;
  final Rect currentRect;

  /// `newWidth / startRect.width` — the scale ratio that should drive anchor
  /// adjustment.
  final double scale;
}

/// Stage/Origin-level escape hatches for advanced behavioral overrides.
/// Fields are reserved for power-user customizations; defaults are correct
/// for typical use.
class Overrides {
  const Overrides({this.anchor});

  /// Custom anchor for drag-with-[ScaleResponse]. Receives gesture-time
  /// inputs and returns the rect's new center. Null = package default
  /// (focal-point-preserving:
  /// `currentFocalPoint - (startFocalPoint - startRect.center) * scale`).
  final Offset Function(AnchorContext ctx)? anchor;
}
