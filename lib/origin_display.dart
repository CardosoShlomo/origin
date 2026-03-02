import 'package:flutter/widgets.dart';
import 'origin_data.dart';
import 'origin_ext_on_rect.dart';
import 'origin_ext_on_scale.dart';
import 'origin_overlay.dart';
import 'origin_scope.dart';
import 'origin_triggers.dart';

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
  final _containers = <Object, OriginRect Function()>{};
  final _items = <Object, Future<void> Function([Rect Function(Rect)?])>{};
  double? _perspective;
  OriginBuilder? _gestureBuilder;
  VoidCallback? _onEnd;
  Object? _tag;
  bool _itemGesturing = false;

  static const _defaultDuration = Duration(milliseconds: 300);

  late final AnimationController _centerX;
  late final AnimationController _centerY;
  late final AnimationController _width;
  late final AnimationController _effect;
  final _effectTransform = ValueNotifier<Matrix4?>(null);

  @override
  void initState() {
    super.initState();
    _centerX = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _centerY = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _width = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _effect = AnimationController(vsync: this, duration: _defaultDuration);
  }

  final _centerXTween = Tween<double>(begin: 0, end: 0);
  final _centerYTween = Tween<double>(begin: 0, end: 0);
  final _widthTween = Tween<double>(begin: 0, end: 0);

  Rect _startRect = .zero;
  final _pointers = <int>[];

  void _onPointerDown(PointerDownEvent event) {
    _pointers.add(event.pointer);
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startRect = _rect.value;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final baseRect = _display.value.rect.baseRect(_aspectRatio.value);
    if (details.pointerCount == 1 && _startRect.width == baseRect.width) {
      final center = _rect.value.center + details.focalPointDelta;
      final dy = (center.dy - baseRect.center.dy).abs();
      final screenHeight = MediaQuery.sizeOf(context).height;
      final scale = (1 - dy / screenHeight).clamp(0.5, 1.0);
      _rect.value = Rect.fromCenter(
        center: center,
        width: baseRect.width * scale,
        height: baseRect.height * scale,
      );
    } else {
      _rect.value = details.rect(startRect: _startRect, currentRect: _rect.value);
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (details.pointerCount > 0) {
      if (details.pointerCount == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pointers.isEmpty) _finishGesture();
        });
      }
      return;
    }
    _finishGesture();
  }

  void _finishGesture() {
    final baseRect = _display.value.rect.baseRect(_aspectRatio.value);
    if (_rect.value.width < baseRect.width * 0.85) {
      dismiss();
    } else {
      animateToBase();
    }
  }

  void _setPerspective(double? v) => _perspective = v;
  void _setGestureBuilder(OriginBuilder? v) => setState(() => _gestureBuilder = v);
  void _setOnEnd(VoidCallback? v) => _onEnd = v;
  void _setTag(Object? tag) => setState(() => _tag = tag);
  void _setItemGesturing(bool v) => setState(() => _itemGesturing = v);

  void reset() {
    setRect(Rect.zero);
    _widget.value = null;
    _setPerspective(null);
    _setGestureBuilder(null);
    _setOnEnd(null);
    _setTag(null);
    _setItemGesturing(false);
  }

  Future<void> runEffect({
    double? rotateX,
    double? rotateY,
    double? rotateZ,
    double? perspective,
    Duration duration = const Duration(milliseconds: 100),
    Curve curve = Curves.easeOut,
  }) async {
    _effect.duration = duration;
    final p = perspective ?? _perspective ?? 0;
    final perspectiveValue = 0.001 + p * 0.004;
    final curved = CurvedAnimation(parent: _effect, curve: curve);
    void update() {
      final t = curved.value;
      final m = Matrix4.identity();
      m.setEntry(3, 2, perspectiveValue);
      if (rotateX != null) m.rotateX(t * rotateX);
      if (rotateY != null) m.rotateY(t * rotateY);
      if (rotateZ != null) m.rotateZ(t * rotateZ);
      _effectTransform.value = m;
    }
    curved.addListener(update);
    await _effect.forward();
    await _effect.reverse();
    curved.removeListener(update);
    curved.dispose();
    _effectTransform.value = null;
    reset();
  }

  Future<void> dismiss() async {
    await animateRect(to: _origin.value.rect, curve: Curves.easeOut);
    _onEnd?.call();
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
    _effect.dispose();
    _effectTransform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OriginScope(
      containers: _containers,
      items: _items,
      child: OriginData(
        origin: _origin,
        originContainer: _originContainer,
        display: _display,
        displayContainer: _displayContainer,
        aspectRatio: _aspectRatio,
        rect: _rect,
        effectTransform: _effectTransform,
        widget: _widget,
        perspective: _perspective,
        gestureBuilder: _gestureBuilder,
        onEnd: _onEnd,
        tag: _tag,
        itemGesturing: _itemGesturing,
        setPerspective: _setPerspective,
        setGestureBuilder: _setGestureBuilder,
        setOnEnd: _setOnEnd,
        setTag: _setTag,
        setItemGesturing: _setItemGesturing,
        setRect: setRect,
        animateRect: animateRect,
        reset: reset,
        animateToBase: animateToBase,
        dismiss: dismiss,
        runEffect: runEffect,
        child: Stack(
          fit: .expand,
          children: [
            widget.child,
            const OriginOverlay(),
            ValueListenableBuilder<Widget?>(
              valueListenable: _widget,
              builder: (context, widget, _) {
                final active = widget != null && !_itemGesturing;
                return Listener(
                  onPointerDown: active ? _onPointerDown : null,
                  onPointerUp: active ? _onPointerUp : null,
                  child: GestureDetector(
                    behavior: active ? .opaque : .translucent,
                    onScaleStart: active ? _onScaleStart : null,
                    onScaleUpdate: active ? _onScaleUpdate : null,
                    onScaleEnd: active ? _onScaleEnd : null,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
