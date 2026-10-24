import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:origin/origin.dart';

const _shelf = Key('shelf');
const _base = Rect.fromLTWH(100, 0, 600, 600);
const _thumb = Rect.fromLTWH(20, 300, 100, 100);

const _pan = {DragStart.any: DragGesture(bounds: .all())};

/// A product thumbnail on the shelf, at [rect].
Widget _product(
  Object tag, {
  Rect rect = _thumb,
  StageTap? onTap,
  Map<DragStart, DragGesture>? drag,
  OnRelease? onRelease,
  Map<Object, DisplayConfig>? modes,
  FutureOr<void> Function(StageData)? onEnd,
}) {
  return Positioned.fromRect(
    rect: rect,
    child: Origin(
      tag: tag,
      onTap: onTap ?? (event) => event.animateToBase(),
      drag: drag,
      onRelease: onRelease,
      modes: modes,
      onEnd: onEnd,
      child: ColoredBox(key: ValueKey('$tag'), color: const Color(0xFF336699)),
    ),
  );
}

Widget _stage(List<Widget> shelf, {Map<DragStart, DragGesture>? drag}) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(800, 600)),
    child: Directionality(
      textDirection: .ltr,
      child: Stage(
        drag: drag,
        child: Stack(key: _shelf, children: shelf),
      ),
    ),
  );
}

StageData _data(WidgetTester tester) =>
    tester.element(find.byKey(_shelf)).getInheritedWidgetOfExactType<StageData>()!;

Rect _rounded(Rect r) => Rect.fromLTRB(
      r.left.roundToDouble(),
      r.top.roundToDouble(),
      r.right.roundToDouble(),
      r.bottom.roundToDouble(),
    );

void main() {
  group('a session', () {
    testWidgets('a tap opens the product to base and a dismiss flies it home', (tester) async {
      await tester.pumpWidget(_stage([_product('product_1')]));
      await tester.tap(find.byKey(const ValueKey('product_1')));
      await tester.pumpAndSettle();

      final stage = _data(tester);
      expect(stage.tag, 'product_1');
      expect(stage.open, isTrue);
      expect(_rounded(stage.rect.value), _base);

      stage.dismiss();
      await tester.pump();
      expect(stage.dismissing, isTrue);
      await tester.pumpAndSettle();
      expect(stage.tag, isNull);
      expect(stage.widget, isNull);
      expect(stage.open, isFalse);
      expect(stage.rect.value, Rect.zero);
    });

    testWidgets('a stage read at mount reads the live session (#9)', (tester) async {
      await tester.pumpWidget(_stage([_product('product_1')]));
      final atMount = _data(tester);
      expect(atMount.tag, isNull);
      expect(atMount.display.rect, Rect.zero);

      await tester.tap(find.byKey(const ValueKey('product_1')));
      await tester.pumpAndSettle();
      expect(atMount.tag, 'product_1');
      expect(atMount.origin.rect, _thumb);
      expect(atMount.display.rect, const Rect.fromLTWH(0, 0, 800, 600));
      expect(atMount.aspectRatio, 1);
      expect(atMount.open, isTrue);
    });

    testWidgets('a second product cannot take a stage another holds', (tester) async {
      await tester.pumpWidget(_stage([
        _product('product_1'),
        _product('product_2', rect: const Rect.fromLTWH(200, 300, 100, 100)),
      ]));
      final stage = _data(tester);
      await tester.tap(find.byKey(const ValueKey('product_1')));
      await tester.pumpAndSettle();

      final open = stage.openEntry('product_2');
      final send = stage.sendEntry('product_2', (r) => r.shift(const Offset(-900, 0)));
      await tester.pumpAndSettle();
      await open;
      await send;
      expect(stage.tag, 'product_1');
      expect(_rounded(stage.rect.value), _base);
    });

    testWidgets('an open waits out the frame that lays the product out', (tester) async {
      var size = const Size(100, 100);
      late StateSetter setShelf;
      await tester.pumpWidget(_stage([
        StatefulBuilder(builder: (context, setState) {
          setShelf = setState;
          return Stack(children: [
            _product('product_1', rect: Offset(20, 300) & size),
          ]);
        }),
      ]));
      final stage = _data(tester);
      setShelf(() => size = const Size(200, 100));
      final opening = stage.openEntry('product_1');
      await tester.pumpAndSettle();
      await opening;
      expect(stage.origin.rect, const Rect.fromLTWH(20, 300, 200, 100));
      expect(stage.aspectRatio, 2);
    });
  });

  group('the flight home', () {
    testWidgets('lands where the product stands now', (tester) async {
      var at = _thumb;
      late StateSetter setShelf;
      Rect? landed;
      await tester.pumpWidget(_stage([
        StatefulBuilder(builder: (context, setState) {
          setShelf = setState;
          return Stack(children: [
            _product('product_1', rect: at, onEnd: (data) => landed = data.rect.value),
          ]);
        }),
      ]));
      await tester.tap(find.byKey(const ValueKey('product_1')));
      await tester.pumpAndSettle();

      // The shelf relays out while the product is open (a keyboard leaving).
      setShelf(() => at = const Rect.fromLTWH(20, 120, 100, 100));
      await tester.pump();
      _data(tester).dismiss();
      await tester.pumpAndSettle();
      expect(_rounded(landed!), const Rect.fromLTWH(20, 120, 100, 100));
    });

    testWidgets('a pointed home is kept', (tester) async {
      Rect? landed;
      await tester.pumpWidget(_stage([
        _product('product_1', onEnd: (data) => landed = data.rect.value),
      ]));
      await tester.tap(find.byKey(const ValueKey('product_1')));
      await tester.pumpAndSettle();
      final stage = _data(tester);
      stage.setOrigin(const OriginRect(rect: Rect.fromLTWH(-200, 300, 100, 100)));
      stage.dismiss();
      await tester.pumpAndSettle();
      expect(_rounded(landed!), const Rect.fromLTWH(-200, 300, 100, 100));
    });

    testWidgets('a send runs its landing work even when the stage leaves mid-flight (#13)', (tester) async {
      await tester.pumpWidget(_stage([_product('product_1')]));
      final stage = _data(tester);
      Rect? landedAt;
      var ended = false;
      stage.sendEntry(
        'product_1',
        (r) => r.shift(const Offset(-900, 0)),
        onEnd: () {
          ended = true;
          landedAt = stage.rect.value;
        },
      );
      await tester.pump(const Duration(milliseconds: 60));
      expect(stage.dismissing, isTrue);

      // The screen holding the stage is popped mid-flight.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(ended, isTrue);
      expect(_rounded(landedAt!), const Rect.fromLTWH(-880, 300, 100, 100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a release flying home lands when the stage leaves before the dismiss starts', (tester) async {
      var ended = false;
      await tester.pumpWidget(_stage([
        _product('product_1', drag: _pan, onEnd: (_) => ended = true),
      ]));
      final gesture = await tester.startGesture(_thumb.center);
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(ended, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('interrupted motion (#5)', () {
    testWidgets('an open cut short by a dismiss completes, and the stage is free again', (tester) async {
      await tester.pumpWidget(_stage([_product('product_1')]));
      final stage = _data(tester);
      var opened = false;
      stage.openEntry('product_1').then((_) => opened = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(stage.openingOrDismissing, isTrue);

      var dismissed = false;
      stage.dismiss().then((_) => dismissed = true);
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      expect(dismissed, isTrue);
      expect(stage.tag, isNull);
      expect(stage.openingOrDismissing, isFalse);
      expect(stage.transitionProgressMin.value, 1);

      await tester.tap(find.byKey(const ValueKey('product_1')));
      await tester.pumpAndSettle();
      expect(stage.open, isTrue);
    });

    testWidgets('a mode change cut short still ends, so its chrome shows', (tester) async {
      const gallery = OriginRect(rect: Rect.fromLTWH(0, 100, 800, 500));
      await tester.pumpWidget(_stage([
        _product('product_1', modes: {'zoom': const DisplayConfig(display: gallery)}),
      ]));
      await tester.tap(find.byKey(const ValueKey('product_1')));
      await tester.pumpAndSettle();
      final stage = _data(tester);

      stage.setMode('zoom');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(stage.changingMode, isTrue);
      expect(stage.transitionProgressMin.value, lessThan(1));

      // Something else takes the rect mid-change.
      stage.animateRect(to: const Rect.fromLTWH(0, 100, 500, 500));
      await tester.pumpAndSettle();
      expect(stage.changingMode, isFalse);
      expect(stage.transitionProgressMin.value, 1);
    });

    testWidgets('a touch takes the rect from a settling release', (tester) async {
      await tester.pumpWidget(_stage([_product('product_1')], drag: _pan));
      await tester.tap(find.byKey(const ValueKey('product_1')));
      await tester.pumpAndSettle();
      final stage = _data(tester);

      // A fast throw: the rect settles back toward base over many frames.
      final fling = await tester.startGesture(_base.center);
      for (var i = 0; i < 6; i++) {
        await fling.moveBy(const Offset(40, 0), timeStamp: Duration(milliseconds: 16 * (i + 1)));
      }
      await fling.up(timeStamp: const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 80));

      // Grab it mid-settle and hold still.
      final hold = await tester.startGesture(stage.rect.value.center);
      await hold.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 16));
      await hold.moveBy(const Offset(0, 1));
      await tester.pump(const Duration(milliseconds: 16));
      final held = stage.rect.value;
      await tester.pump(const Duration(milliseconds: 200));
      expect(stage.rect.value, held);

      await hold.up();
      await tester.pumpAndSettle();
      expect(_rounded(stage.rect.value), _base);
    });
  });

  group('a lost gesture (#4)', () {
    testWidgets('a product removed mid-drag lets the stage go', (tester) async {
      var shown = true;
      var bought = 0;
      late StateSetter setShelf;
      await tester.pumpWidget(_stage([
        StatefulBuilder(builder: (context, setState) {
          setShelf = setState;
          return Stack(children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: .opaque,
                onTap: () => bought++,
              ),
            ),
            if (shown) _product('product_1', drag: _pan),
          ]);
        }),
      ]));
      final stage = _data(tester);
      final gesture = await tester.startGesture(_thumb.center);
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(stage.tag, 'product_1');
      expect(stage.widget, isNotNull);

      // The listing refreshes and the product is gone under the finger.
      setShelf(() => shown = false);
      await tester.pump();
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(stage.tag, isNull);
      expect(stage.widget, isNull);
      expect(stage.rect.value, Rect.zero);

      await tester.tapAt(const Offset(600, 100));
      expect(bought, 1);
    });

    testWidgets('a product that stops taking drags mid-drag ends it as a release', (tester) async {
      Map<DragStart, DragGesture>? drag = _pan;
      late StateSetter setShelf;
      await tester.pumpWidget(_stage([
        StatefulBuilder(builder: (context, setState) {
          setShelf = setState;
          return Stack(children: [_product('product_1', drag: drag)]);
        }),
      ]));
      final stage = _data(tester);
      final gesture = await tester.startGesture(_thumb.center);
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(stage.tag, 'product_1');

      setShelf(() => drag = null);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(stage.tag, isNull);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(stage.tag, isNull);
    });
  });

  group('release velocity (#12)', () {
    testWidgets('one jittery sample does not throw the product', (tester) async {
      ReleaseContext? released;
      await tester.pumpWidget(_stage([
        _product(
          'product_1',
          drag: _pan,
          onRelease: (context, data) {
            released = data;
            Stage.of(context).backToOrigin(data);
          },
        ),
      ]));
      final gesture = await tester.startGesture(_thumb.center, kind: .touch);
      var t = Duration.zero;
      for (var i = 0; i < 10; i++) {
        t += const Duration(milliseconds: 16);
        await gesture.moveBy(const Offset(10, 0), timeStamp: t);
      }
      // Two events a millisecond apart: a two-sample difference reads it as
      // 10000 px/s.
      t += const Duration(milliseconds: 1);
      await gesture.moveBy(const Offset(10, 0), timeStamp: t);
      await gesture.up(timeStamp: t);
      await tester.pumpAndSettle();

      final speed = released!.velocity.pixelsPerSecond.dx;
      expect(speed, greaterThan(400));
      expect(speed, lessThan(1500));
    });

    testWidgets('a slow release has no fling', (tester) async {
      ReleaseContext? released;
      await tester.pumpWidget(_stage([
        _product(
          'product_1',
          drag: _pan,
          onRelease: (context, data) {
            released = data;
            Stage.of(context).backToOrigin(data);
          },
        ),
      ]));
      final gesture = await tester.startGesture(_thumb.center, kind: .touch);
      var t = Duration.zero;
      for (var i = 0; i < 20; i++) {
        t += const Duration(milliseconds: 16);
        await gesture.moveBy(const Offset(0.5, 0.5), timeStamp: t);
      }
      await gesture.moveBy(const Offset(20, 0), timeStamp: t += const Duration(milliseconds: 400));
      await gesture.up(timeStamp: t);
      await tester.pumpAndSettle();
      expect(released, isNotNull);
      expect(released!.velocity.pixelsPerSecond.distance, lessThan(kMinFlingVelocity + 1));
    });
  });

  group('crop', () {
    const cropMode = DisplayConfig(
      display: OriginRect(rect: Rect.fromLTWH(0, 100, 800, 500)),
      crop: CropConfig(minAspectRatio: 1, maxAspectRatio: 1, initialRect: _square),
    );

    testWidgets('a reset brings the photo and the crop back', (tester) async {
      await tester.pumpWidget(_stage([_product('product_1', modes: {'crop': cropMode})]));
      final stage = _data(tester);
      stage.openEntry('product_1');
      await tester.pumpAndSettle();
      stage.setMode('crop');
      await tester.pumpAndSettle();
      final base = const Rect.fromLTWH(0, 100, 800, 500).baseRect(1);
      expect(_rounded(stage.rect.value), _rounded(base));
      expect(_rounded(stage.crop.value), _rounded(_square(base)));

      stage.crop.value = const Rect.fromLTWH(200, 200, 150, 150);
      stage.setRect(const Rect.fromLTWH(100, 120, 600, 600));
      stage.resetCrop();
      await tester.pumpAndSettle();
      expect(_rounded(stage.rect.value), _rounded(base));
      expect(_rounded(stage.crop.value), _rounded(_square(base)));
    });

    testWidgets('a landed crop flies home at its new aspect', (tester) async {
      Rect? landed;
      await tester.pumpWidget(_stage([
        _product('product_1', modes: {'crop': cropMode}, onEnd: (data) => landed = data.rect.value),
      ]));
      final stage = _data(tester);
      stage.openEntry('product_1');
      await tester.pumpAndSettle();
      stage.setMode('crop');
      await tester.pumpAndSettle();

      stage.landCrop(const SizedBox(key: Key('cropped')), aspectRatio: 2);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('cropped')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(_rounded(landed!), const Rect.fromLTWH(20, 300, 100, 50));
      expect(stage.tag, isNull);
    });

    testWidgets('the crop maps into the photo source', (tester) async {
      await tester.pumpWidget(_stage([_product('product_1', modes: {'crop': cropMode})]));
      final stage = _data(tester);
      stage.openEntry('product_1');
      await tester.pumpAndSettle();
      stage.setMode('crop');
      await tester.pumpAndSettle();
      expect(_rounded(stage.cropSourceRect(const Size(1000, 1000))), const Rect.fromLTWH(0, 0, 1000, 1000));
    });
  });
}

Rect _square(Rect base) =>
    Rect.fromCenter(center: base.center, width: base.shortestSide, height: base.shortestSide);
