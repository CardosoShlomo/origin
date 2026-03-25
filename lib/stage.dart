import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'ext.dart';
import 'gestures.dart';
import 'origin_rect.dart';
import 'recognizer.dart';
import 'stage_overlay.dart';

class OriginEntry {
  OriginRect Function()? measure;
  Future<void> Function()? open;
  Future<void> Function(Rect Function(Rect), {VoidCallback? onEnd})? send;
}

class Rotation {
  const Rotation({this.x = 0, this.y = 0, this.z = 0, this.perspective});
  final double x, y, z;
  /// 0-1, maps to 0.001-0.005 perspective depth
  final double? perspective;

  Matrix4 toMatrix4([double? fallbackPerspective]) {
    final p = perspective ?? fallbackPerspective ?? 0;
    return Matrix4.identity()
      ..setEntry(3, 2, 0.001 + p * 0.004)
      ..rotateX(x)
      ..rotateY(y)
      ..rotateZ(z);
  }
}

const _tagAspect = #_stageTag;
const _widgetAspect = #_stageWidget;
const _hasWidgetAspect = #_stageHasWidget;
const _dismissingAspect = #_stageDismissing;

class Stage extends StatefulWidget {
  const Stage({super.key, required this.child});

  final Widget child;

  static StageData of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<StageData>()!;
  }

  static Object? tagOf(BuildContext context) {
    return InheritedModel.inheritFrom<StageData>(context, aspect: _tagAspect)!.tag;
  }

  static bool isTagOf(BuildContext context, Object tag) {
    return InheritedModel.inheritFrom<StageData>(context, aspect: tag)?.tag == tag;
  }

  static Widget? widgetOf(BuildContext context) {
    return InheritedModel.inheritFrom<StageData>(context, aspect: _widgetAspect)!.widget;
  }

  static bool hasWidgetOf(BuildContext context) {
    return InheritedModel.inheritFrom<StageData>(context, aspect: _hasWidgetAspect)!.widget != null;
  }

  static bool isLockedOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<StageData>()!.locked;
  }

  static bool isDismissingOf(BuildContext context) {
    return InheritedModel.inheritFrom<StageData>(context, aspect: _dismissingAspect)!.dismissing;
  }

  @override
  State<Stage> createState() => _StageState();
}

class _StageState extends State<Stage> with TickerProviderStateMixin {
  final _rect = ValueNotifier(Rect.zero);

  static const _defaultOriginRect = OriginRect(rect: .zero);

  OriginRect _origin = _defaultOriginRect;
  OriginRect? _originContainer;
  OriginRect _display = _defaultOriginRect;
  OriginRect? _displayContainer;
  double _aspectRatio = 1.0;
  Widget? _widget;
  final _originToBaseProgress = ValueNotifier(0.0);
  final _registry = <Object, OriginEntry>{};
  double? _perspective;
  Color? _backgroundColor;
  StageBuilder? _gestureBuilder;
  VoidCallback? _onEnd;
  Object? _tag;
  bool _locked = true;
  bool _dismissing = false;
  final _container = ValueNotifier<OriginRect?>(null);

  static const _defaultDuration = Duration(milliseconds: 300);

  late final AnimationController _centerX;
  late final AnimationController _centerY;
  late final AnimationController _width;
  late final AnimationController _effect;
  final _rotation = ValueNotifier<Rotation?>(null);

  @override
  void initState() {
    super.initState();
    _centerX = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _centerY = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _width = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _effect = AnimationController(vsync: this, duration: _defaultDuration);
    _rect.addListener(_updateProgress);
    _rect.addListener(_updateContainer);
  }

  final _centerXTween = Tween<double>(begin: 0, end: 0);
  final _centerYTween = Tween<double>(begin: 0, end: 0);
  final _widthTween = Tween<double>(begin: 0, end: 0);

  Rect _startRect = .zero;
  Offset _startFocalPoint = .zero;

  void _onScaleStart(ScaleStartDetails details) {
    _startRect = _rect.value;
    _startFocalPoint = details.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final baseRect = _display.rect.baseRect(_aspectRatio);
    if (details.pointerCount == 1 && _startRect.width == baseRect.width) {
      final anchor = _startFocalPoint - _startRect.center;
      final rawCenter = details.focalPoint - anchor;
      final dy = (rawCenter.dy - baseRect.center.dy).abs();
      final screenHeight = MediaQuery.sizeOf(context).height;
      final scale = (1 - dy / screenHeight).clamp(0.3, 1.0);
      _rect.value = Rect.fromCenter(
        center: details.focalPoint - anchor * scale,
        width: baseRect.width * scale,
        height: baseRect.height * scale,
      );
    } else {
      _rect.value = details.rect(startRect: _startRect, currentRect: _rect.value);
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final baseRect = _display.rect.baseRect(_aspectRatio);
    if (_rect.value.width < baseRect.width * 0.85) {
      dismiss();
    } else {
      animateToBase();
    }
  }

  void _setOrigin(OriginRect v) => _origin = v;
  void _setOriginContainer(OriginRect? v) => _originContainer = v;
  void _setDisplay(OriginRect v) => _display = v;
  void _setDisplayContainer(OriginRect? v) => _displayContainer = v;
  void _setAspectRatio(double v) => _aspectRatio = v;
  void _setPerspective(double? v) => _perspective = v;
  void _setBackgroundColor(Color? v) => _backgroundColor = v;
  void _setGestureBuilder(StageBuilder? v) => setState(() => _gestureBuilder = v);
  void _setOnEnd(VoidCallback? v) => _onEnd = v;
  void _setTag(Object? tag) => setState(() => _tag = tag);
  void _setWidget(Widget? v) => setState(() => _widget = v);
  void _setLocked(bool v) => setState(() => _locked = v);
  void _setDismissing(bool v) => setState(() => _dismissing = v);

  void _updateContainer() {
    if (_rect.value == .zero) {
      _container.value = null;
      return;
    }
    final originC = _originContainer;
    if (originC == null) {
      _container.value = _displayContainer;
      return;
    }
    final displayC = _displayContainer ?? OriginRect(rect: Offset.zero & MediaQuery.sizeOf(context));

    final p = _originToBaseProgress.value;
    final rect = _rect.value;
    final w = lerpDouble(originC.rect.width, displayC.rect.width, p)!;
    final h = lerpDouble(originC.rect.height, displayC.rect.height, p)!;
    final delta = rect.center - _origin.rect.center;
    final shifted = originC.rect.expandToInclude(originC.rect.shift(delta));
    final computed = Rect.fromLTWH(
      shifted.left.clamp(displayC.rect.left, displayC.rect.right - w),
      shifted.top.clamp(displayC.rect.top, displayC.rect.bottom - h),
      w,
      h,
    );
    final containerBr = BorderRadius.lerp(originC.borderRadius, displayC.borderRadius, p)!;

    final prev = _container.value;
    final expandedRect = (prev != null && !_dismissing)
        ? prev.rect.expandToInclude(computed)
        : computed;

    _container.value = OriginRect(rect: expandedRect, borderRadius: containerBr);
  }

  void reset() {
    setRect(.zero);
    _startRect = .zero;
    _startFocalPoint = .zero;
    _container.value = null;
    _setWidget(null);
    _rotation.value = null;
    _setPerspective(null);
    _setBackgroundColor(null);
    _setGestureBuilder(null);
    _setOnEnd(null);
    _setTag(null);
    _setLocked(true);
    _setDismissing(false);
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
    final curved = CurvedAnimation(parent: _effect, curve: curve);
    void update() {
      final t = curved.value;
      _rotation.value = Rotation(
        x: (rotateX ?? 0) * t,
        y: (rotateY ?? 0) * t,
        z: (rotateZ ?? 0) * t,
        perspective: perspective ?? _perspective,
      );
    }
    curved.addListener(update);
    await _effect.forward();
    await _effect.reverse();
    curved.removeListener(update);
    curved.dispose();
    _rotation.value = null;
    reset();
  }

  Future<void> dismiss() async {
    _setDismissing(true);
    await animateRect(to: _origin.rect, curve: Curves.easeOut);
    _onEnd?.call();
    reset();
  }

  Future<void> animateToBase() async {
    await animateRect(to: _display.rect.baseRect(_aspectRatio), curve: Curves.easeOut);
    _setLocked(false);
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
    _rect.value = Rect.fromCenter(center: Offset(cx, cy), width: w, height: w / _aspectRatio);
  }

  void _updateProgress() {
    final w = _rect.value.width;
    final originW = _origin.rect.width;
    final baseW = _display.rect.baseWidth(_aspectRatio);
    _originToBaseProgress.value = (w.clamp(originW, baseW) - originW) / (baseW - originW);
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

  // --- Registry ---

  void _register(Object tag, OriginEntry entry) {
    assert(
      !_registry.containsKey(tag),
      'Duplicate Origin tag "$tag". Each tag must be unique.',
    );
    _registry[tag] = entry;
  }

  void _unregister(Object tag) {
    _registry.remove(tag);
  }

  OriginRect? _measureEntry(Object tag) {
    return _registry[tag]?.measure?.call();
  }

  Future<void> _openEntry(Object tag) {
    return _registry[tag]?.open?.call() ?? Future.value();
  }

  Future<void> _sendEntry(Object tag, Rect Function(Rect) send, {VoidCallback? onEnd}) {
    return _registry[tag]?.send?.call(send, onEnd: onEnd) ?? Future.value();
  }

  @override
  void dispose() {
    _rect.dispose();
    _container.dispose();
    _originToBaseProgress.dispose();
    _centerX.dispose();
    _centerY.dispose();
    _width.dispose();
    _effect.dispose();
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StageData(
      origin: _origin,
      originContainer: _originContainer,
      display: _display,
      displayContainer: _displayContainer,
      aspectRatio: _aspectRatio,
      rect: _rect,
      rotation: _rotation,
      originToBaseProgress: _originToBaseProgress,
      widget: _widget,
      setWidget: _setWidget,
      perspective: _perspective,
      backgroundColor: _backgroundColor,
      gestureBuilder: _gestureBuilder,
      onEnd: _onEnd,
      tag: _tag,
      locked: _locked,
      dismissing: _dismissing,
      container: _container,
      setOrigin: _setOrigin,
      setOriginContainer: _setOriginContainer,
      setDisplay: _setDisplay,
      setDisplayContainer: _setDisplayContainer,
      setAspectRatio: _setAspectRatio,
      setPerspective: _setPerspective,
      setBackgroundColor: _setBackgroundColor,
      setGestureBuilder: _setGestureBuilder,
      setOnEnd: _setOnEnd,
      setTag: _setTag,
      setLocked: _setLocked,
      setRect: setRect,
      animateRect: animateRect,
      reset: reset,
      animateToBase: animateToBase,
      dismiss: dismiss,
      runEffect: runEffect,
      register: _register,
      unregister: _unregister,
      measureEntry: _measureEntry,
      openEntry: _openEntry,
      sendEntry: _sendEntry,
      child: Stack(
        fit: .expand,
        children: [
          widget.child,
          const _AbsorbLayer(),
          const StageOverlay(),
          Builder(builder: (context) {
            final active = Stage.hasWidgetOf(context) && !_locked;
            return RawGestureDetector(
              behavior: active ? .opaque : .translucent,
              gestures: {
                if (active)
                  StageScaleRecognizer: GestureRecognizerFactoryWithHandlers<StageScaleRecognizer>(
                    StageScaleRecognizer.new,
                    (r) => r
                      ..onStart = _onScaleStart
                      ..onUpdate = _onScaleUpdate
                      ..onEnd = _onScaleEnd,
                  ),
              },
            );
          }),
        ],
      ),
    );
  }
}

class StageData extends InheritedModel<Object> {
  const StageData({
    super.key,
    required this.origin,
    required this.originContainer,
    required this.display,
    required this.displayContainer,
    required this.aspectRatio,
    required this.rect,
    required this.rotation,
    required this.originToBaseProgress,
    required this.widget,
    required this.setWidget,
    required this.perspective,
    required this.backgroundColor,
    required this.gestureBuilder,
    required this.onEnd,
    required this.tag,
    required this.locked,
    required this.dismissing,
    required this.container,
    required this.setOrigin,
    required this.setOriginContainer,
    required this.setDisplay,
    required this.setDisplayContainer,
    required this.setAspectRatio,
    required this.setPerspective,
    required this.setBackgroundColor,
    required this.setGestureBuilder,
    required this.setOnEnd,
    required this.setTag,
    required this.setLocked,
    required this.setRect,
    required this.animateRect,
    required this.reset,
    required this.animateToBase,
    required this.dismiss,
    required this.runEffect,
    required this.register,
    required this.unregister,
    required this.measureEntry,
    required this.openEntry,
    required this.sendEntry,
    required super.child,
  });

  final OriginRect origin;
  final OriginRect? originContainer;
  final OriginRect display;
  final OriginRect? displayContainer;

  final double aspectRatio;
  final ValueNotifier<Rect> rect;
  final ValueNotifier<Rotation?> rotation;
  final ValueNotifier<double> originToBaseProgress;
  final Widget? widget;

  final double? perspective;
  final Color? backgroundColor;
  final StageBuilder? gestureBuilder;
  final VoidCallback? onEnd;
  final Object? tag;
  final bool locked;
  final bool dismissing;
  final ValueNotifier<OriginRect?> container;

  final ValueSetter<Widget?> setWidget;
  final ValueSetter<OriginRect> setOrigin;
  final ValueSetter<OriginRect?> setOriginContainer;
  final ValueSetter<OriginRect> setDisplay;
  final ValueSetter<OriginRect?> setDisplayContainer;
  final ValueSetter<double> setAspectRatio;
  final ValueSetter<double?> setPerspective;
  final ValueSetter<Color?> setBackgroundColor;
  final ValueSetter<StageBuilder?> setGestureBuilder;
  final ValueSetter<VoidCallback?> setOnEnd;
  final ValueSetter<Object?> setTag;
  final ValueSetter<bool> setLocked;
  final ValueSetter<Rect> setRect;
  final AnimateRect animateRect;
  final VoidCallback reset;
  final Future<void> Function() animateToBase;
  final Future<void> Function() dismiss;
  final Future<void> Function({
    double? rotateX,
    double? rotateY,
    double? rotateZ,
    double? perspective,
    Duration duration,
    Curve curve,
  }) runEffect;

  final void Function(Object tag, OriginEntry entry) register;
  final void Function(Object tag) unregister;
  final OriginRect? Function(Object tag) measureEntry;
  final Future<void> Function(Object tag) openEntry;
  final Future<void> Function(Object tag, Rect Function(Rect), {VoidCallback? onEnd}) sendEntry;


  @override
  bool updateShouldNotify(StageData oldWidget) => true;

  @override
  bool updateShouldNotifyDependent(StageData oldWidget, Set<Object> dependencies) {
    for (final dep in dependencies) {
      switch (dep) {
        case _tagAspect:
          if (tag != oldWidget.tag) return true;
        case _widgetAspect:
          if (widget != oldWidget.widget) return true;
        case _hasWidgetAspect:
          if ((widget != null) != (oldWidget.widget != null)) return true;
        case _dismissingAspect:
          if (dismissing != oldWidget.dismissing) return true;
        default:
          if ((tag == dep) != (oldWidget.tag == dep)) return true;
      }
    }
    return false;
  }
}

class _AbsorbLayer extends StatelessWidget {
  const _AbsorbLayer();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !Stage.hasWidgetOf(context),
      child: const AbsorbPointer(),
    );
  }
}
