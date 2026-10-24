import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:origin/origin.dart';

const _display = Rect.fromLTWH(0, 0, 400, 800);

/// The rect's center and width where a plan's axes come to rest.
({double x, double y, double width}) _rest(Release plan, Rect from) {
  double end(AxisRelease axis, double start) =>
      axis.settle?.to ?? (axis.decay.isEmpty ? start : axis.decay.last.to);
  return (
    x: end(plan.x, from.center.dx),
    y: end(plan.y, from.center.dy),
    width: end(plan.scale, from.width),
  );
}

ReleaseContext _context(Rect current, {Offset velocity = Offset.zero, Gesture? gesture}) =>
    ReleaseContext(
      currentRect: current,
      displayRect: _display,
      aspectRatio: 1,
      velocity: Velocity(pixelsPerSecond: velocity),
      scaleVelocity: 0,
      gesture: gesture ?? const DragGesture(bounds: .all()),
    );

void main() {
  group('geometry', () {
    test('the base rect is the largest rect of the aspect, centered in display', () {
      expect(_display.baseRect(1), const Rect.fromLTWH(0, 200, 400, 400));
      expect(_display.baseRect(2), const Rect.fromLTWH(0, 300, 400, 200));
      expect(_display.baseRect(0.25), const Rect.fromLTWH(100, 0, 200, 800));
    });

    test('a display crop maps into source pixels', () {
      final source = displayRectToSourceRect(
        cropRect: const Rect.fromLTWH(100, 300, 200, 200),
        imageDisplayRect: const Rect.fromLTWH(0, 200, 400, 400),
        sourceSize: const Size(1200, 1200),
      );
      expect(source, const Rect.fromLTWH(300, 300, 600, 600));
      expect(
        displayRectToSourceRect(
          cropRect: const Rect.fromLTWH(0, 0, 10, 10),
          imageDisplayRect: Rect.zero,
          sourceSize: const Size(10, 10),
        ),
        Rect.zero,
      );
    });
  });

  group('arenas', () {
    const any = DragGesture();
    const right = DragGesture(bounds: .horizontal(DragBounds()));
    const downRight = DragGesture(bounds: .all());

    test('a drag commits only past its distance', () {
      expect(resolveDragArena(totalDelta: const Offset(9, 9), registered: {.any: any}), isNull);
      expect(resolveDragArena(totalDelta: const Offset(10, 0), registered: {.any: any})?.start, DragStart.any);
    });

    test('the most specific direction wins', () {
      final registered = <DragStart, DragGesture>{.any: any, .right: right, .downRight: downRight};
      expect(resolveDragArena(totalDelta: const Offset(20, 0), registered: registered)?.start, DragStart.right);
      expect(resolveDragArena(totalDelta: const Offset(20, 20), registered: registered)?.start, DragStart.downRight);
      expect(resolveDragArena(totalDelta: const Offset(0, -20), registered: registered)?.start, DragStart.any);
    });

    test('a pinch commits past its threshold, to its direction', () {
      const expand = ScaleGesture();
      const shrink = ScaleGesture();
      final registered = {ScaleStart.expand: expand, ScaleStart.shrink: shrink};
      expect(resolveScaleArena(scale: 1.005, registered: registered), isNull);
      expect(resolveScaleArena(scale: 1.2, registered: registered)?.gesture, same(expand));
      expect(resolveScaleArena(scale: 0.8, registered: registered)?.gesture, same(shrink));
    });
  });

  group('friction', () {
    final state = axisStateX(10, const Rect.fromLTWH(0, 200, 400, 400), _display.baseRect(1), _display);

    test('a side with no bound blocks, a bound with no friction is free', () {
      expect(frictionFromState(state: state, bounds: const GestureBounds(), delta: 10), 0);
      expect(frictionFromState(state: state, bounds: const .all(), delta: 10), 10);
    });

    test('friction takes its share of the motion', () {
      const bounds = GestureBounds.all(DragBounds(friction: .uniform(Friction(0.75))));
      expect(frictionFromState(state: state, bounds: bounds, delta: 10), closeTo(2.5, 1e-9));
    });
  });

  group('curves', () {
    test('a simulation curve runs from 0 to 1, never back', () {
      final sim = FrictionSimulation(0.135, 0, 1000);
      final curve = SimulationCurve(sim, 0.5);
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      var last = 0.0;
      for (var t = 0.0; t <= 1.0; t += 0.05) {
        final v = curve.transform(t);
        expect(v, greaterThanOrEqualTo(last));
        last = v;
      }
    });

    test('an attract settle lands on its target', () {
      final sim = const AttractSettle().simulationAt(position: 0, velocity: 0, target: 100);
      expect(sim.x(0), closeTo(0, 1e-9));
      expect(sim.x(5), closeTo(100, 0.5));
    });
  });

  group('release', () {
    test('a strong pinch cancels most of the drift', () {
      final details = ScaleEndDetails(
        velocity: const Velocity(pixelsPerSecond: Offset(1000, 0)),
        scaleVelocity: 1.0,
      ).cancelTranslation(0.8);
      expect(details.velocity.pixelsPerSecond.dx, closeTo(1000 * (1 - 0.8 * (0.3 + 0.81)), 1e-6));
      final faint = ScaleEndDetails(
        velocity: const Velocity(pixelsPerSecond: Offset(1000, 0)),
        scaleVelocity: 0.05,
      ).cancelTranslation(0.8);
      expect(faint.velocity.pixelsPerSecond.dx, 1000);
    });

    test('a still release off base settles back to base', () {
      const off = Rect.fromLTWH(60, 260, 400, 400);
      final rest = _rest(.toDisplay(_context(off)), off);
      final base = _display.baseRect(1);
      expect(rest.x, closeTo(base.center.dx, 0.5));
      expect(rest.y, closeTo(base.center.dy, 0.5));
      expect(rest.width, closeTo(base.width, 0.5));
    });

    test('a halt plan has no settle on any axis', () {
      const off = Rect.fromLTWH(60, 260, 400, 400);
      final plan = Release.toHalt(_context(off, velocity: const Offset(800, 0)));
      expect(plan.x.settle, isNull);
      expect(plan.y.settle, isNull);
      expect(plan.scale.settle, isNull);
    });

    test('a release past max scale rubbers back to it', () {
      const zoomed = Rect.fromLTWH(-200, 0, 800, 800);
      final plan = Release.toDisplay(_context(
        zoomed,
        gesture: const ScaleGesture(bounds: .all(), expand: ExpandBounds(maxScale: 1.5)),
      ));
      expect(_rest(plan, zoomed).width, closeTo(600, 0.5));
    });

    test('the same release always makes the same plan', () {
      const off = Rect.fromLTWH(60, 260, 400, 400);
      final a = _rest(.toDisplay(_context(off, velocity: const Offset(1200, -300))), off);
      final b = _rest(.toDisplay(_context(off, velocity: const Offset(1200, -300))), off);
      expect(a, b);
    });
  });
}
