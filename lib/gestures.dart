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
  });
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
  /// per-axis trajectory plans plus helpers ([Release.backToDisplay],
  /// [Release.backToOrigin], [Release.simpleDismiss], etc.).
  ///
  /// When null, the package runs [Release.backToDisplay] by default.
  final void Function(BuildContext context, Release release)? onRelease;
}

class DragGesture extends Gesture {
  const DragGesture({
    super.bounds,
    super.constraints,
    super.builder,
  });
}

class ScaleGesture extends Gesture {
  const ScaleGesture({
    super.bounds,
    super.constraints,
    super.builder,
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
  });

  final Map<DragStart, DragGesture>? drag;
  final Map<ScaleStart, ScaleGesture>? scale;
  final GestureConstraints? constraints;
}
