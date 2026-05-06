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

/// Sealed parent for gesture-start enums. Pattern-match exhaustiveness on
/// [DragStart] vs [ScaleStart] is guaranteed.
sealed class GestureStart {}

/// A committed gesture: the matched key (start) and value (gesture).
typedef ActiveGesture = ({GestureStart start, Gesture gesture});

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
  });

  final Friction? extending;
  final Friction? extendingPastDisplay;
  final Friction? retracting;
  final Friction? retractingPastDisplay;
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
  });

  /// Directional bounds active during this gesture (drag) or directional
  /// overflow during scale (rect edges past container edges).
  final Map<DragBound, DragBounds> bounds;

  final GestureConstraints? constraints;
  final StageBuilder? builder;

  /// Called when the gesture ends with the package's computed [Release] —
  /// per-axis trajectory plans. Consumer calls [StageData.backToDisplay] /
  /// [StageData.backToOrigin] / etc. via `Stage.of(context)` to react.
  ///
  /// Cascade fallback when null: [DisplayConfig.onRelease] →
  /// [Origin.onRelease] / [Stage.onRelease] → package default.
  final OnRelease? onRelease;
}

class DragGesture extends Gesture {
  const DragGesture({
    super.bounds,
    super.constraints,
    super.builder,
    super.onRelease,
    this.scaleResponse,
  });

  /// Gesture-level scale-coupling fallback. Applied to any active bound that
  /// doesn't define its own [DragBounds.scaleResponse]. When set (here or on
  /// any active bound), the drag switches to focal-point-preserving anchor
  /// math instead of plain translation.
  final ScaleResponse? scaleResponse;
}

class ScaleGesture extends Gesture {
  const ScaleGesture({
    super.bounds,
    super.constraints,
    super.builder,
    super.onRelease,
    this.shrink,
    this.expand,
  });

  /// Shrink-axis bound config (with optional minScale threshold).
  final ShrinkBounds? shrink;

  /// Expand-axis bound config (with optional maxScale threshold).
  final ExpandBounds? expand;
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
    this.overrides,
  });

  final Map<DragStart, DragGesture>? drag;
  final Map<ScaleStart, ScaleGesture>? scale;
  final GestureConstraints? constraints;

  /// Cascade fallback for [Gesture.onRelease] while the origin is displayed.
  /// Resolved as: gesture > displayConfig > stage > package default.
  final OnRelease? onRelease;

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
