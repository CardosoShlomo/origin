import 'package:flutter/widgets.dart';
import 'origin_data.dart';
import 'origin_ext_on_rect.dart';
import 'origin_overlay.dart';
import 'origin_scope.dart';

/// Wraps a screen to enable origin animations.
/// Provides the overlay Stack where the animated item is rendered.
///
/// Place above [SafeArea] / [Scaffold] so the overlay covers the full screen
/// and coordinates match.
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
  Object? _tag;

  static const _defaultDuration = Duration(milliseconds: 300);

  late final AnimationController _centerX;
  late final AnimationController _centerY;
  late final AnimationController _width;

  @override
  void initState() {
    super.initState();
    _centerX = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _centerY = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _width = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
  }

  final _centerXTween = Tween<double>(begin: 0, end: 0);
  final _centerYTween = Tween<double>(begin: 0, end: 0);
  final _widthTween = Tween<double>(begin: 0, end: 0);

  Offset _dragStart = .zero;
  Rect _dragStartRect = .zero;

  void _onScaleStart(ScaleStartDetails details) {
    _dragStart = details.focalPoint;
    _dragStartRect = _rect.value;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final delta = details.focalPoint - _dragStart;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final scale = (1 - delta.dy.abs() / screenHeight).clamp(0.5, 1.0);
    _rect.value = .fromCenter(
      center: _dragStartRect.center + delta,
      width: _dragStartRect.width * scale,
      height: _dragStartRect.height * scale,
    );
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final delta = _rect.value.center - _dragStartRect.center;
    final screenHeight = MediaQuery.sizeOf(context).height;
    if (delta.dy.abs() > screenHeight * 0.2) {
      dismiss();
    } else {
      animateToBase();
    }
  }

  void _setTag(Object? tag) => setState(() => _tag = tag);

  void reset() {
    setRect(Rect.zero);
    _widget.value = null;
    _setTag(null);
  }

  Future<void> dismiss() async {
    await animateRect(to: _origin.value.rect, curve: Curves.easeOut);
    reset();
  }

  Future<void> animateToBase() {
    return animateRect(to: _display.value.rect.baseRect(_aspectRatio.value), curve: Curves.easeOut);
  }

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

  void _safeReset(AnimationController controller) {
    controller
      ..removeListener(_updateRect)
      ..reset()
      ..addListener(_updateRect);
  }

  Future<void> animateCenterX({required double to, Duration? duration, Curve curve = Curves.easeIn}) {
    _centerXTween.begin = _rect.value.center.dx;
    _centerXTween.end = to;
    _safeReset(_centerX);
    return _centerX.animateTo(1, duration: duration, curve: curve);
  }

  Future<void> animateCenterY({required double to, Duration? duration, Curve curve = Curves.easeIn}) {
    _centerYTween.begin = _rect.value.center.dy;
    _centerYTween.end = to;
    _safeReset(_centerY);
    return _centerY.animateTo(1, duration: duration, curve: curve);
  }

  Future<void> animateWidth({required double to, Duration? duration, Curve curve = Curves.easeIn}) {
    _widthTween.begin = _rect.value.width;
    _widthTween.end = to;
    _safeReset(_width);
    return _width.animateTo(1, duration: duration, curve: curve);
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
        tag: _tag,
        setTag: _setTag,
        setRect: setRect,
        animateRect: animateRect,
        reset: reset,
        animateToBase: animateToBase,
        dismiss: dismiss,
        child: Stack(
          fit: .expand,
          children: [
            widget.child,
            const OriginOverlay(),
            ValueListenableBuilder<Widget?>(
              valueListenable: _widget,
              builder: (context, widget, _) => GestureDetector(
                behavior: widget == null ? .translucent : .opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
