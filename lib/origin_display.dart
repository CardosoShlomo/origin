import 'package:flutter/widgets.dart';
import 'origin_data.dart';
import 'origin_overlay.dart';
import 'origin_scope.dart';

/// Wraps a screen to enable origin animations.
/// Provides the overlay Stack where the animated item is rendered.
class OriginDisplay extends StatefulWidget {
  const OriginDisplay({super.key, required this.child});

  final Widget child;

  @override
  State<OriginDisplay> createState() => _OriginDisplayState();
}

class _OriginDisplayState extends State<OriginDisplay> with TickerProviderStateMixin {
  final _rect = ValueNotifier(Rect.zero);

  static const _defaultOriginRect = OriginRect(rect: .zero);

  final _origin = ValueNotifier(_defaultOriginRect);
  final _originContainer = ValueNotifier(_defaultOriginRect);
  final _display = ValueNotifier(_defaultOriginRect);
  final _displayContainer = ValueNotifier(_defaultOriginRect);
  final _aspectRatio = ValueNotifier(1.0);
  final _widget = ValueNotifier<Widget?>(null);

  late final _centerX = AnimationController(vsync: this)..addListener(_updateRect);
  late final _centerY = AnimationController(vsync: this)..addListener(_updateRect);
  late final _width = AnimationController(vsync: this)..addListener(_updateRect);

  final _centerXTween = Tween<double>(begin: 0, end: 0);
  final _centerYTween = Tween<double>(begin: 0, end: 0);
  final _widthTween = Tween<double>(begin: 0, end: 0);

  void setRect(Rect rect) {
    _centerXTween.begin = _centerXTween.end = rect.center.dx;
    _centerYTween.begin = _centerYTween.end = rect.center.dy;
    _widthTween.begin = _widthTween.end = rect.width;
    _rect.value = rect;
  }

  void _updateRect() {
    final cx = _centerXTween.evaluate(_centerX);
    final cy = _centerYTween.evaluate(_centerY);
    final w = _widthTween.evaluate(_width);
    _rect.value = Rect.fromCenter(center: Offset(cx, cy), width: w, height: w / _aspectRatio.value);
  }

  Future<void> animateCenterX({required double to, Duration? duration, Curve curve = Curves.easeIn}) async {
    _centerXTween.begin = _centerXTween.evaluate(_centerX);
    _centerXTween.end = to;
    _centerX.reset();
    await _centerX.animateTo(1, duration: duration, curve: curve);
  }

  Future<void> animateCenterY({required double to, Duration? duration, Curve curve = Curves.easeIn}) async {
    _centerYTween.begin = _centerYTween.evaluate(_centerY);
    _centerYTween.end = to;
    _centerY.reset();
    await _centerY.animateTo(1, duration: duration, curve: curve);
  }

  Future<void> animateWidth({required double to, Duration? duration, Curve curve = Curves.easeIn}) async {
    _widthTween.begin = _widthTween.evaluate(_width);
    _widthTween.end = to;
    _width.reset();
    await _width.animateTo(1, duration: duration, curve: curve);
  }

  Future<void> animateRect({required Rect to, Duration? duration, Curve curve = Curves.easeIn}) {
    return Future.wait([
      animateCenterX(to: to.center.dx, duration: duration, curve: curve),
      animateCenterY(to: to.center.dy, duration: duration, curve: curve),
      animateWidth(to: to.width, duration: duration, curve: curve),
    ]);
  }

  @override
  void dispose() {
    _rect.dispose();
    _origin.dispose();
    _originContainer.dispose();
    _display.dispose();
    _displayContainer.dispose();
    _aspectRatio.dispose();
    _widget.dispose();
    _centerX.dispose();
    _centerY.dispose();
    _width.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OriginScope(
      child: OriginData(
        origin: _origin,
        originContainer: _originContainer,
        display: _display,
        displayContainer: _displayContainer,
        aspectRatio: _aspectRatio,
        rect: _rect,
        widget: _widget,
        setRect: setRect,
        animateRect: animateRect,
        child: Stack(
          children: [
            widget.child,
            const OriginOverlay(),
          ],
        ),
      ),
    );
  }
}
