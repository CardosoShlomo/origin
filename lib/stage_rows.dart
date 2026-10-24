import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:regent/regent.dart';

import 'gestures.dart';
import 'origin_rect.dart';

/// The facts a Stage folds. Every Stage owns one [Ledger] over [stageRows];
/// its widgets read the folded units and stores, never fields of their own.
sealed class StageMsg extends Msg {
  const StageMsg();
}

/// An Origin took the stage: what it shows, where it flies home to, and the
/// configs its modes resolve against.
final class StageTaken extends StageMsg {
  const StageTaken({
    required this.tag,
    required this.widget,
    required this.origin,
    required this.originContainer,
    required this.aspectRatio,
    required this.config,
    required this.mode,
    required this.perspective,
    required this.backgroundColor,
    required this.onEnd,
  });

  final Object tag;
  final Widget widget;
  final OriginRect origin;
  final OriginRect? originContainer;
  final double aspectRatio;
  final OriginConfig config;
  final Object? mode;
  final double? perspective;
  final Color? backgroundColor;
  final FutureOr<void> Function()? onEnd;
}

/// The shown Origin switched to the mode [mode] (null: its default config).
final class ModeSet extends StageMsg {
  const ModeSet(this.mode);
  final Object? mode;
}

/// The consumer pointed the flight home at [origin]. A pointed home is kept;
/// an unpointed one is measured again when the flight home starts.
final class OriginPointed extends StageMsg {
  const OriginPointed(this.origin);
  final OriginRect origin;
}

/// The home measured where the Origin stands now.
final class OriginMeasured extends StageMsg {
  const OriginMeasured(this.origin);
  final OriginRect origin;
}

final class WidgetShown extends StageMsg {
  const WidgetShown(this.widget);
  final Widget? widget;
}

final class AspectRatioSet extends StageMsg {
  const AspectRatioSet(this.aspectRatio);
  final double aspectRatio;
}

final class BackgroundSet extends StageMsg {
  const BackgroundSet(this.color);
  final Color? color;
}

/// A committed gesture wraps the shown widget with its own builder.
final class GestureBuilderSet extends StageMsg {
  const GestureBuilderSet(this.builder);
  final StageBuilder? builder;
}

/// The work that runs when the flight home lands.
final class OnEndSet extends StageMsg {
  const OnEndSet(this.onEnd);
  final FutureOr<void> Function()? onEnd;
}

/// A flight took off. A newer flight of the same slot supersedes it, so its
/// landing is stale and dropped by [StaleLanding].
final class FlightTook extends StageMsg {
  const FlightTook(this.flight);
  final Flight flight;
}

/// A flight is over: it reached its target, or something stopped it. A
/// dismiss or an effect landing ends the session.
final class FlightLanded extends StageMsg {
  const FlightLanded(this.flight);
  final Flight flight;
}

final class InteractionBegan extends StageMsg {
  const InteractionBegan();
}

final class InteractionEnded extends StageMsg {
  const InteractionEnded();
}

/// An Origin's own gesture is in flight (null: it ended).
final class OriginGestureSet extends StageMsg {
  const OriginGestureSet(this.gesture);
  final OriginGesture? gesture;
}

final class HybridDrivingSet extends StageMsg {
  const HybridDrivingSet(this.driving);
  final bool driving;
}

/// [tag] leaves its slot for [target]'s.
final class SendDisplaced extends StageMsg {
  const SendDisplaced(this.send);
  final StageSend send;
}

final class SendArrived extends StageMsg {
  const SendArrived(this.tag);
  final Object tag;
}

/// The sends fly home: [tag] alone, or every one but [except].
final class SendsRecalled extends StageMsg {
  const SendsRecalled({this.tag, this.except});
  final Object? tag;
  final Object? except;
}

final class SendGone extends StageMsg {
  const SendGone(this.tag);
  final Object tag;
}

enum FlightKind { opening, dismissing, effect, changingMode }

final class Flight {
  const Flight(this.kind, this.epoch);

  final FlightKind kind;
  final int epoch;

  /// The slot a flight holds: a mode change runs beside the session's flight.
  bool get isMode => kind == .changingMode;

  @override
  bool operator ==(Object other) =>
      other is Flight && other.kind == kind && other.epoch == epoch;

  @override
  int get hashCode => Object.hash(kind, epoch);
}

/// Where a shown Origin's display config comes from: its default config, its
/// modes, and the fallbacks a mode doesn't override.
final class OriginConfig {
  const OriginConfig({
    this.defaults,
    this.modes,
    this.overlay,
    this.display,
    this.displayContainer,
    this.screen,
    this.builder,
  });

  final DisplayConfig? defaults;
  final Map<Object, DisplayConfig>? modes;
  final WidgetBuilder? overlay;
  final OriginRect? display;
  final OriginRect? displayContainer;
  final OriginRect? screen;
  final StageBuilder? builder;
}

const _noRect = OriginRect(rect: .zero);
const _keep = Object();

/// What the stage shows: the data. Whether it is opening, shown, landing or
/// touched lives in [StageStance].
final class StageScene {
  const StageScene({
    this.tag,
    this.widget,
    this.origin = _noRect,
    this.originPointed = false,
    this.originContainer,
    this.display = _noRect,
    this.displayContainer,
    this.aspectRatio = 1.0,
    this.displayConfig,
    this.config = const OriginConfig(),
    this.gestureBuilder,
    this.perspective,
    this.backgroundColor,
    this.onEnd,
  });

  final Object? tag;
  final Widget? widget;
  final OriginRect origin;
  final bool originPointed;
  final OriginRect? originContainer;
  final OriginRect display;
  final OriginRect? displayContainer;
  final double aspectRatio;
  final DisplayConfig? displayConfig;
  final OriginConfig config;
  final StageBuilder? gestureBuilder;
  final double? perspective;
  final Color? backgroundColor;
  final FutureOr<void> Function()? onEnd;

  StageScene _with({
    Object? widget = _keep,
    OriginRect? origin,
    bool? originPointed,
    OriginRect? display,
    Object? displayContainer = _keep,
    double? aspectRatio,
    Object? displayConfig = _keep,
    Object? gestureBuilder = _keep,
    Object? backgroundColor = _keep,
    Object? onEnd = _keep,
  }) {
    return StageScene(
      tag: tag,
      widget: identical(widget, _keep) ? this.widget : widget as Widget?,
      origin: origin ?? this.origin,
      originPointed: originPointed ?? this.originPointed,
      originContainer: originContainer,
      display: display ?? this.display,
      displayContainer: identical(displayContainer, _keep)
          ? this.displayContainer
          : displayContainer as OriginRect?,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      displayConfig: identical(displayConfig, _keep)
          ? this.displayConfig
          : displayConfig as DisplayConfig?,
      config: config,
      gestureBuilder: identical(gestureBuilder, _keep)
          ? this.gestureBuilder
          : gestureBuilder as StageBuilder?,
      perspective: perspective,
      backgroundColor: identical(backgroundColor, _keep)
          ? this.backgroundColor
          : backgroundColor as Color?,
      onEnd: identical(onEnd, _keep)
          ? this.onEnd
          : onEnd as FutureOr<void> Function()?,
    );
  }

  /// The scene under [mode]: the mode's config merged onto the default, and
  /// the display, container and builder it resolves to.
  StageScene inMode(Object? mode) {
    final modeConfig = mode == null ? null : config.modes?[mode];
    final effective = config.defaults?.merge(modeConfig) ?? modeConfig;
    return _with(
      displayConfig: effective,
      displayContainer: effective?.displayContainer ?? config.displayContainer,
      display: effective?.display ??
          config.display ??
          (effective?.displayContainer ?? config.displayContainer) ??
          config.screen ??
          _noRect,
      gestureBuilder: effective?.builder ?? config.builder,
    );
  }
}

final class StageSceneUnit extends Unit<StageScene, StageMsg> {
  const StageSceneUnit() : super(const StageScene());

  @override
  StageScene reduce(StageScene state, StageMsg msg) => switch (msg) {
        StageTaken() => StageScene(
            tag: msg.tag,
            widget: msg.widget,
            origin: msg.origin,
            originContainer: msg.originContainer,
            display: state.display,
            displayContainer: state.displayContainer,
            aspectRatio: msg.aspectRatio,
            displayConfig: state.displayConfig,
            config: msg.config,
            gestureBuilder: state.gestureBuilder,
            perspective: msg.perspective,
            backgroundColor: msg.backgroundColor,
            onEnd: msg.onEnd,
          ).inMode(msg.mode),
        ModeSet(:final mode) => state.inMode(mode),
        OriginPointed(:final origin) =>
          state._with(origin: origin, originPointed: true),
        OriginMeasured(:final origin) => state._with(origin: origin),
        WidgetShown(:final widget) => state._with(widget: widget),
        AspectRatioSet(:final aspectRatio) =>
          state._with(aspectRatio: aspectRatio),
        BackgroundSet(:final color) => state._with(backgroundColor: color),
        GestureBuilderSet(:final builder) =>
          state._with(gestureBuilder: builder),
        OnEndSet(:final onEnd) => state._with(onEnd: onEnd),
        FlightLanded(:final flight) => switch (flight.kind) {
            .dismissing || .effect => const StageScene(),
            .opening || .changingMode => state,
          },
        FlightTook() ||
        InteractionBegan() ||
        InteractionEnded() ||
        OriginGestureSet() ||
        HybridDrivingSet() ||
        SendDisplaced() ||
        SendArrived() ||
        SendsRecalled() ||
        SendGone() =>
          state,
      };
}

/// The stage's status beside its [StageScene]: the flights in the air,
/// whether the shown Origin has landed open, and the touch on it.
final class StageStance {
  const StageStance({
    this.open = false,
    this.flight,
    this.modeFlight,
    this.interacting = false,
    this.originGesture,
    this.hybridDriving = false,
  });

  /// The open flight landed: the Stage's own gestures drive the shown Origin.
  final bool open;

  /// The session's flight: opening, dismissing or an effect.
  final Flight? flight;

  /// A mode change animating beside the session's flight.
  final Flight? modeFlight;

  /// A gesture on the Stage is moving the shown Origin.
  final bool interacting;

  /// An Origin's own gesture in flight, before the Origin is shown.
  final OriginGesture? originGesture;

  /// The hybrid merger drives the rect from both recognizers' pointers.
  final bool hybridDriving;

  bool get dismissing => flight?.kind == .dismissing;

  bool get openingOrDismissing =>
      flight?.kind == .opening || flight?.kind == .dismissing;

  bool get changingMode => modeFlight != null;

  StageStance _with({
    bool? open,
    Object? flight = _keep,
    Object? modeFlight = _keep,
    bool? interacting,
    Object? originGesture = _keep,
    bool? hybridDriving,
  }) {
    return StageStance(
      open: open ?? this.open,
      flight: identical(flight, _keep) ? this.flight : flight as Flight?,
      modeFlight: identical(modeFlight, _keep)
          ? this.modeFlight
          : modeFlight as Flight?,
      interacting: interacting ?? this.interacting,
      originGesture: identical(originGesture, _keep)
          ? this.originGesture
          : originGesture as OriginGesture?,
      hybridDriving: hybridDriving ?? this.hybridDriving,
    );
  }
}

final class StageStanceUnit extends Unit<StageStance, StageMsg> {
  const StageStanceUnit() : super(const StageStance());

  @override
  StageStance reduce(StageStance state, StageMsg msg) => switch (msg) {
        FlightTook(:final flight) when flight.isMode =>
          state._with(modeFlight: flight),
        FlightTook(:final flight) => state._with(flight: flight),
        FlightLanded(:final flight) => switch (flight.kind) {
            .changingMode => state._with(modeFlight: null),
            .opening => state._with(flight: null, open: true),
            // The session ends; an Origin's gesture outlives it.
            .dismissing || .effect => StageStance(
                originGesture: state.originGesture,
                hybridDriving: state.hybridDriving,
              ),
          },
        InteractionBegan() => state._with(interacting: true),
        InteractionEnded() => state._with(interacting: false),
        OriginGestureSet(:final gesture) => state._with(originGesture: gesture),
        HybridDrivingSet(:final driving) => state._with(hybridDriving: driving),
        StageTaken() ||
        ModeSet() ||
        OriginPointed() ||
        OriginMeasured() ||
        WidgetShown() ||
        AspectRatioSet() ||
        BackgroundSet() ||
        GestureBuilderSet() ||
        OnEndSet() ||
        SendDisplaced() ||
        SendArrived() ||
        SendsRecalled() ||
        SendGone() =>
          state,
      };
}

/// An Origin displaced from its slot, flying to [target]'s.
final class StageSend with Identifiable<Object> {
  const StageSend({
    required this.tag,
    required this.target,
    required this.park,
    required this.key,
  });

  final Object tag;
  final Object target;

  /// Stays at the target once there, until recalled.
  final bool park;

  /// Keys the send's layer, so a new send of the same tag starts afresh.
  final Key key;

  @override
  Object get id => tag;
}

final class StageSends extends Store<Object, StageSend, StageMsg> {
  const StageSends();

  @override
  IdentifiableMap<Object, StageSend> reduce(
    IdentifiableMap<Object, StageSend> entities,
    StageMsg msg,
  ) => switch (msg) {
        SendDisplaced(:final send) => entities.upsert(send),
        SendGone(:final tag) => entities.removeById(tag),
        FlightLanded(flight: Flight(kind: .dismissing || .effect)) =>
          entities.isEmpty ? entities : const {},
        FlightLanded() ||
        SendArrived() ||
        SendsRecalled() ||
        StageTaken() ||
        ModeSet() ||
        OriginPointed() ||
        OriginMeasured() ||
        WidgetShown() ||
        AspectRatioSet() ||
        BackgroundSet() ||
        GestureBuilderSet() ||
        OnEndSet() ||
        FlightTook() ||
        InteractionBegan() ||
        InteractionEnded() ||
        OriginGestureSet() ||
        HybridDrivingSet() =>
          entities,
      };
}

enum TagState { idle, sending, parked, returning }

/// Where a send is in its flight — the status of a [StageSend].
final class SendPhase with Identifiable<Object> {
  const SendPhase(this.tag, this.state);

  final Object tag;
  final TagState state;

  @override
  Object get id => tag;
}

final class SendPhases extends Store<Object, SendPhase, StageMsg> {
  const SendPhases();

  @override
  IdentifiableMap<Object, SendPhase> reduce(
    IdentifiableMap<Object, SendPhase> entities,
    StageMsg msg,
  ) => switch (msg) {
        // A new send calls every other one in the air home.
        SendDisplaced(:final send) => {
            for (final e in entities.values)
              if (e.tag != send.tag)
                e.tag: e.state == .sending || e.state == .parked
                    ? SendPhase(e.tag, .returning)
                    : e,
            send.tag: SendPhase(send.tag, .sending),
          },
        SendArrived(:final tag) => entities.upsert(SendPhase(tag, .parked)),
        SendsRecalled(:final tag?) => entities.containsKey(tag)
            ? entities.upsert(SendPhase(tag, .returning))
            : entities,
        SendsRecalled(:final except) => {
            for (final e in entities.values)
              e.tag: e.tag == except ? e : SendPhase(e.tag, .returning),
          },
        SendGone(:final tag) => entities.removeById(tag),
        FlightLanded(flight: Flight(kind: .dismissing || .effect)) =>
          entities.isEmpty ? entities : const {},
        FlightLanded() ||
        StageTaken() ||
        ModeSet() ||
        OriginPointed() ||
        OriginMeasured() ||
        WidgetShown() ||
        AspectRatioSet() ||
        BackgroundSet() ||
        GestureBuilderSet() ||
        OnEndSet() ||
        FlightTook() ||
        InteractionBegan() ||
        InteractionEnded() ||
        OriginGestureSet() ||
        HybridDrivingSet() =>
          entities,
      };
}

/// A landing whose flight was superseded is dropped for every row below:
/// it may not end the session that superseded it.
final class StaleLanding extends Veto<FlightLanded> {
  const StaleLanding();

  @override
  bool block(FlightLanded msg, ReadStore read) {
    final stance = read(stageStance);
    final current = msg.flight.isMode ? stance.modeFlight : stance.flight;
    return current != msg.flight;
  }
}

const stageScene = StageSceneUnit();
const stageStance = StageStanceUnit();
const stageSends = StageSends();
const sendPhases = SendPhases();

const stageRows = Regency({
  StaleLanding(),
  stageScene,
  stageStance,
  stageSends,
  sendPhases,
});
