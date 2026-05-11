import 'package:flutter/widgets.dart';

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
  final Future<void> Function() animateToBase;
  final Future<void> Function({
    double? rotateX,
    double? rotateY,
    double? rotateZ,
    double? perspective,
    Duration duration,
    Curve curve,
  }) runEffect;
}

/// Signature for a displayed-state double-tap handler.
///
/// Distinct from Origin's [onDoubleTap] (which is a [StageTap], mirroring
/// [onTap]) — this one runs on the displayed view, carries rect info, and
/// has a package default. Cascade: [DisplayConfig.onDoubleTap] →
/// [Stage.onDoubleTap] → package default (toggle baseRect ↔ fit-cover-at-focal).
typedef OnDoubleTap = void Function(BuildContext context, DoubleTapEvent event);

/// Inputs passed to [OnDoubleTap] when the displayed view receives a
/// double-tap. Carries the tap position plus the current/base/display rects
/// so handlers can compute a target without re-reading [StageData].
class DoubleTapEvent {
  const DoubleTapEvent({
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

/// Resistance to motion as a function of progress through a bound state.
///
/// Conventional range: [0, 1]. 0 = no resistance, 1 = block.
/// Values outside this range are mathematically valid but produce
/// non-standard physics (e.g., negative accelerates motion, > 1 reverses it).
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

  final Friction? extending;
  final Friction? extendingPastDisplay;
  final Friction? retracting;
  final Friction? retractingPastDisplay;
}

/// Per-state velocity decay during a fling animation.
///
/// Progress dimension: fraction of velocity decayed (0 = fling start, 1 = at rest).
/// State semantics match [FrictionConfig] — applied based on rect position/direction
/// during the fling.
///
/// The release trajectory consults this 4-state map per phase, picking the
/// state-friction whose zone the segment occupies.
class DecelerateConfig {
  const DecelerateConfig({
    this.extending,
    this.extendingPastDisplay,
    this.retracting,
    this.retractingPastDisplay,
    this.settle,
  });

  final Friction? extending;
  final Friction? extendingPastDisplay;
  final Friction? retracting;
  final Friction? retractingPastDisplay;

  /// Drives the rubber-back / settle animation that runs after a decay
  /// phase ends. Both fields are used:
  /// - [Friction.start] = drag coefficient for the synthesized friction
  ///   simulation that determines the settle's duration based on the
  ///   rubber-back distance (lower = more drag = shorter settle).
  /// - [Friction.curve] = animation curve for the settle.
  ///
  /// [Friction.end] is unused (settle isn't a start→end interpolation).
  /// Defaults when null: drag 0.135 (iOS-like), curve [Curves.easeOut].
  final Friction? settle;
}

/// Shared base for bound configurations.
///
/// Carries the cross-cutting per-bound fields ([friction], [decelerate], [builder]).
/// Subclasses add bound-type-specific fields (e.g., [ShrinkBounds.minScale]).
sealed class Bounds {
  const Bounds({
    this.friction,
    this.decelerate,
    this.builder,
  });

  final FrictionConfig? friction;
  final DecelerateConfig? decelerate;
  final StageBuilder? builder;
}

class DragBounds extends Bounds {
  const DragBounds({
    super.friction,
    super.decelerate,
    super.builder,
    this.scaleResponse,
  });

  /// Per-bound override of [DragGesture.scaleResponse]. Couples rect width to
  /// drag-progress through this bound. Native physics (rect.width changes),
  /// not a visual transform. When configured, the drag uses focal-point-
  /// preserving anchor math instead of plain translation.
  final ScaleResponse? scaleResponse;
}

/// Scale-as-function-of-drag-progress.
///
/// `inDisplay` ramp covers progress 0..1 from base to display edge.
/// `pastDisplay` ramp covers progress 0..1 from display edge into past zone.
/// Each [Friction] ramp's `start`/`end` are scale multipliers on baseWidth
/// (e.g., `Friction(1.0, end: 0.6)` shrinks from full to 60%).
class ScaleResponse {
  const ScaleResponse({this.inDisplay, this.pastDisplay});

  /// Smooth continuous shrink from 1.0 at base to [end] at full past.
  /// Splits at the display edge so the in-display and past zones meet
  /// at `(1.0 + end) / 2`.
  factory ScaleResponse.smooth({
    double end = 0.5,
    Curve curve = Curves.linear,
  }) {
    final mid = (1.0 + end) / 2;
    return ScaleResponse(
      inDisplay: Friction(1.0, end: mid, curve: curve),
      pastDisplay: Friction(mid, end: end, curve: curve),
    );
  }

  /// Shrink only inside display. Past-display zone holds at `ramp.end`.
  const ScaleResponse.inDisplayOnly(Friction ramp)
      : inDisplay = ramp,
        pastDisplay = null;

  /// Hold flat in display. Shrink only when past edge.
  const ScaleResponse.pastDisplayOnly(Friction ramp)
      : inDisplay = null,
        pastDisplay = ramp;

  final Friction? inDisplay;
  final Friction? pastDisplay;
}

class ShrinkBounds extends Bounds {
  const ShrinkBounds({
    super.friction,
    super.decelerate,
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
    super.decelerate,
    super.builder,
    this.maxScale,
  });

  /// Scale above which the rect is "past display." Null = no maximum.
  final double? maxScale;
}

/// Sealed parent for gesture kinds.
sealed class Gesture {
  const Gesture({
    this.bounds = const {},
    this.constraints,
    this.builder,
    this.onRelease,
    this.scaleVelocityCancel,
  });

  /// Directional bounds active during this gesture (drag) or directional
  /// overflow during scale (rect edges past container edges).
  final Map<DragBound, DragBounds> bounds;

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
    this.decelerate,
    this.perspective,
  });

  final FrictionConfig? friction;
  final DecelerateConfig? decelerate;
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
    this.onDoubleTap,
    this.doubleTapPullFactor,
    this.dragPromote,
    this.scaleVelocityCancel,
    this.overrides,
  });

  final Map<DragStart, DragGesture>? drag;
  final Map<ScaleStart, ScaleGesture>? scale;
  final GestureConstraints? constraints;

  /// Cascade fallback for [Gesture.onRelease] while the origin is displayed.
  /// Resolved as: gesture > displayConfig > stage > package default.
  final OnRelease? onRelease;

  /// Cascade fallback for displayed-state double-tap. Resolved as:
  /// displayConfig > stage > package default (toggle baseRect ↔ fit-cover).
  final OnDoubleTap? onDoubleTap;

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

  /// Cascade fallback for [Stage.overrides]/[Origin.overrides] while the
  /// origin is displayed.
  final Overrides? overrides;
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
