import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:origin/origin.dart';
import 'package:regent/regent.dart';

const _screen = OriginRect(rect: Rect.fromLTWH(0, 0, 400, 800));
const _gallery = OriginRect(rect: Rect.fromLTWH(0, 100, 400, 600));
const _thumb = OriginRect(rect: Rect.fromLTWH(20, 300, 100, 100));

const _zoomMode = DisplayConfig(display: _gallery, doubleTapPullFactor: 0.2);
const _defaults = DisplayConfig(doubleTapPullFactor: 0.6, scaleVelocityCancel: 0.5);

StageTaken _taken({Object tag = 'product_1', Object? mode}) => StageTaken(
      tag: tag,
      widget: const SizedBox(),
      origin: _thumb,
      originContainer: null,
      aspectRatio: 1,
      config: const OriginConfig(
        defaults: _defaults,
        modes: {'zoom': _zoomMode},
        screen: _screen,
      ),
      mode: mode,
      perspective: null,
      backgroundColor: null,
      onEnd: null,
    );

StageScene _scene(List<StageMsg> facts) =>
    replay(stageRows, facts)[stageScene] as StageScene;

StageStance _stance(List<StageMsg> facts) =>
    replay(stageRows, facts)[stageStance] as StageStance;

Map<Object, TagState> _phases(List<StageMsg> facts) => {
      for (final p in (replay(stageRows, facts)[sendPhases] as Map).values.cast<SendPhase>())
        p.tag: p.state,
    };

StageSend _send(Object tag, Object target) =>
    StageSend(tag: tag, target: target, park: true, key: ValueKey(tag));

void main() {
  group('the scene', () {
    test('an Origin taking the stage shows it on its screen by default', () {
      final scene = _scene([_taken()]);
      expect(scene.tag, 'product_1');
      expect(scene.origin, same(_thumb));
      expect(scene.display, same(_screen));
      expect(scene.displayConfig?.doubleTapPullFactor, 0.6);
      expect(scene.originPointed, isFalse);
    });

    test('a mode merges onto the default and brings its display', () {
      final scene = _scene([_taken(mode: 'zoom')]);
      expect(scene.display, same(_gallery));
      expect(scene.displayConfig?.doubleTapPullFactor, 0.2);
      expect(scene.displayConfig?.scaleVelocityCancel, 0.5);
    });

    test('setting the mode back to none returns to the default', () {
      final scene = _scene([_taken(mode: 'zoom'), const ModeSet(null)]);
      expect(scene.display, same(_screen));
      expect(scene.displayConfig?.doubleTapPullFactor, 0.6);
    });

    test('a pointed home is marked, a measured one is not', () {
      const away = OriginRect(rect: Rect.fromLTWH(-500, 300, 100, 100));
      expect(_scene([_taken(), const OriginPointed(away)]).originPointed, isTrue);
      expect(_scene([_taken(), const OriginMeasured(away)]).originPointed, isFalse);
      expect(_scene([_taken(), const OriginMeasured(away)]).origin, same(away));
    });

    test('the scene holds no status: a flight leaves it as it was', () {
      final facts = [_taken()];
      final before = _scene(facts);
      final after = _scene([...facts, const FlightTook(Flight(.opening, 1))]);
      expect(after.tag, before.tag);
      expect(after.display, same(before.display));
    });
  });

  group('the stance', () {
    test('an open landing opens the stage', () {
      const open = Flight(.opening, 1);
      expect(_stance([_taken(), const FlightTook(open)]).openingOrDismissing, isTrue);
      final stance = _stance([_taken(), const FlightTook(open), const FlightLanded(open)]);
      expect(stance.open, isTrue);
      expect(stance.flight, isNull);
      expect(stance.openingOrDismissing, isFalse);
    });

    test('a dismiss landing ends the session', () {
      const open = Flight(.opening, 1);
      const home = Flight(.dismissing, 2);
      final facts = <StageMsg>[
        _taken(),
        const FlightTook(open),
        const FlightLanded(open),
        const FlightTook(home),
      ];
      expect(_stance(facts).dismissing, isTrue);
      final ended = [...facts, const FlightLanded(home)];
      expect(_scene(ended).tag, isNull);
      expect(_stance(ended).open, isFalse);
      expect(_stance(ended).dismissing, isFalse);
    });

    test('a superseded landing is dropped and cannot end the newer session', () {
      const open = Flight(.opening, 1);
      const home = Flight(.dismissing, 2);
      final facts = <StageMsg>[
        _taken(),
        const FlightTook(open),
        const FlightTook(home),
        // The open was cut short by the dismiss; its landing comes late.
        const FlightLanded(open),
      ];
      expect(_stance(facts).open, isFalse);
      expect(_stance(facts).flight, home);
      expect(_scene(facts).tag, 'product_1');
    });

    test('a mode change flies beside the session flight', () {
      const open = Flight(.opening, 1);
      const zoom = Flight(.changingMode, 2);
      final facts = <StageMsg>[
        _taken(),
        const FlightTook(open),
        const FlightTook(zoom),
        const FlightLanded(open),
      ];
      expect(_stance(facts).changingMode, isTrue);
      expect(_stance(facts).open, isTrue);
      expect(_stance([...facts, const FlightLanded(zoom)]).changingMode, isFalse);
    });

    test('touch and the origin gesture are status, beside the data', () {
      final stance = _stance([_taken(), const InteractionBegan(), const HybridDrivingSet(true)]);
      expect(stance.interacting, isTrue);
      expect(stance.hybridDriving, isTrue);
      expect(_stance([_taken(), const InteractionBegan(), const InteractionEnded()]).interacting, isFalse);
    });
  });

  group('sends', () {
    test('a new send calls the one in the air home', () {
      final phases = _phases([
        SendDisplaced(_send('product_1', 'cart')),
        SendDisplaced(_send('product_2', 'cart')),
      ]);
      expect(phases, {'product_1': TagState.returning, 'product_2': TagState.sending});
    });

    test('an arrival parks, a recall spares the one excepted', () {
      final phases = _phases([
        SendDisplaced(_send('product_1', 'cart')),
        const SendArrived('product_1'),
      ]);
      expect(phases, {'product_1': TagState.parked});
      expect(
        _phases([
          SendDisplaced(_send('product_1', 'cart')),
          const SendsRecalled(except: 'product_1'),
        ]),
        {'product_1': TagState.sending},
      );
      expect(
        _phases([
          SendDisplaced(_send('product_1', 'cart')),
          const SendsRecalled(tag: 'product_1'),
        ]),
        {'product_1': TagState.returning},
      );
    });

    test('a gone send leaves both stores, a dismiss landing clears them', () {
      final facts = <StageMsg>[SendDisplaced(_send('product_1', 'cart'))];
      final gone = replay(stageRows, [...facts, const SendGone('product_1')]);
      expect(gone[stageSends], isEmpty);
      expect(gone[sendPhases], isEmpty);
      const home = Flight(.dismissing, 1);
      final landed = replay(stageRows, [
        _taken(),
        ...facts,
        const FlightTook(home),
        const FlightLanded(home),
      ]);
      expect(landed[stageSends], isEmpty);
      expect(landed[sendPhases], isEmpty);
    });
  });
}
