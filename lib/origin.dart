import 'dart:async';

export 'origin_rect.dart';
export 'stage.dart';
export 'stage_overlay.dart';
export 'gestures.dart';
export 'recognizer.dart';
export 'ext.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'ext.dart';
import 'gestures.dart';
import 'origin_rect.dart';
import 'recognizer.dart';
import 'stage.dart';

class Origin extends StatefulWidget {
  const Origin({
    super.key,
    required this.tag,
    this.onTap,
    this.borderRadius = BorderRadius.zero,
    this.containerTag,
    this.originContainer,
    this.display,
    this.displayContainer,
    this.gestures = const [],
    this.constraints = const GestureConstraints(),
    this.aspectRatio,
    this.perspective,
    this.backgroundColor,
    this.onEnd,
    this.swapTags,
    this.onSwap,
    this.builder,
    required this.child,
  });

  final Object tag;
  final StageTap? onTap;
  final BorderRadius borderRadius;
  final Object? containerTag;
  final OriginRect? originContainer;
  final OriginRect? display;
  final OriginRect? displayContainer;
  final List<Gesture> gestures;
  final GestureConstraints constraints;
  final double? aspectRatio;
  final double? perspective;
  final Color? backgroundColor;
  final FutureOr<void> Function(StageData)? onEnd;
  final Set<Object>? swapTags;
  final ValueSetter<Object>? onSwap;
  final StageBuilder? builder;
  final Widget child;

  bool get _isItem => onTap != null || gestures.isNotEmpty;

  static Object? tagOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_OriginData>()?.tag;
  }

  static bool isActiveOf(BuildContext context) {
    final tag = context.dependOnInheritedWidgetOfExactType<_OriginData>()?.tag;
    return tag != null && Stage.isActiveOf(context, tag);
  }

  static OriginRect? measureOf(BuildContext context) {
    final tag = context.dependOnInheritedWidgetOfExactType<_OriginData>()?.tag;
    if (tag == null) return null;
    return context.getInheritedWidgetOfExactType<StageData>()!.measureEntry(tag);
  }

  @override
  State<Origin> createState() => _OriginState();
}

class _OriginState extends State<Origin> {
  late final StageData _stage;
  final _childKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _stage = context.getInheritedWidgetOfExactType<StageData>()!;
    _stage.register(widget.tag, _buildEntry());
  }

  @override
  void didUpdateWidget(Origin oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tag != widget.tag) {
      _stage.unregister(oldWidget.tag);
      _stage.register(widget.tag, _buildEntry());
    }
  }

  @override
  void dispose() {
    _stopSwapListening();
    _stage.unregister(widget.tag);
    super.dispose();
  }

  OriginEntry _buildEntry() {
    final entry = OriginEntry()
      ..measure = _measureOrigin
      ..capture = _captureWidget;
    if (widget._isItem) {
      entry.open = _open;
      entry.send = _send;
    }
    return entry;
  }

  OriginRect _measureOrigin() {
    return OriginRect(rect: context.rect, borderRadius: widget.borderRadius);
  }

  Widget _captureWidget() {
    return _OriginData(tag: widget.tag, child: widget.child);
  }

  // --- Swap logic ---

  Object? _swapHover;
  Object? _swapDisplaced;
  bool _swapListening = false;

  void _startSwapListening() {
    if (_swapListening) return;
    if (widget.swapTags?.isEmpty ?? true) return;
    _stage.rect.addListener(_onSwapRect);
    _swapListening = true;
  }

  void _stopSwapListening() {
    if (!_swapListening) return;
    _stage.rect.removeListener(_onSwapRect);
    _swapListening = false;
  }

  void _onSwapRect() {
    final center = _stage.rect.value.center;
    Object? hover;
    for (final tag in widget.swapTags!) {
      if (tag == widget.tag) continue;
      final rect = _stage.measureEntry(tag)?.rect;
      if (rect != null && rect.contains(center)) {
        hover = tag;
        break;
      }
    }

    if (hover != _swapHover) {
      if (_swapDisplaced != null) {
        _stage.dismiss(_swapDisplaced!);
        _swapDisplaced = null;
      }
      if (hover != null) {
        _stage.displace(hover, target: widget.tag);
        _swapDisplaced = hover;
      }
      _swapHover = hover;
    }

    final measured = hover != null
        ? _stage.measureEntry(hover)
        : _measureOrigin();
    if (measured != null) _stage.setOrigin(measured);
  }

  void _finishSwap() {
    if (_swapDisplaced != null) {
      _stage.release(_swapDisplaced!);
      widget.onSwap?.call(_swapDisplaced!);
      _swapDisplaced = null;
    }
    _swapHover = null;
  }

  // --- Item gesture logic ---

  GestureStart? _activeStart;
  Rect _startRect = .zero;
  Offset _totalDelta = .zero;

  void _onScaleStart(ScaleStartDetails details) {
    _startRect = _stage.rect.value;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    _totalDelta += details.focalPointDelta;

    if (_activeStart == null) {
      _activeStart = _resolveStart(details);
      if (_activeStart == null) return;
      final data = _setup();
      final gestureBuilder = _gestureFor(_activeStart!).builder;
      if (gestureBuilder != null) data.setGestureBuilder(gestureBuilder);
      _startRect = data.rect.value;
      _startSwapListening();
    }

    _stage.rect.value = details.rect(startRect: _startRect, currentRect: _stage.rect.value);
  }

  bool _hasStart(GestureStart s) => widget.gestures.any((g) => g.start.contains(s));

  Gesture _gestureFor(GestureStart s) => widget.gestures.firstWhere((g) => g.start.contains(s));

  GestureStart? _resolveStart(ScaleUpdateDetails details) {
    final dx = _totalDelta.dx;
    final dy = _totalDelta.dy;
    final two = details.pointerCount > 1;

    GestureStart? h;
    GestureStart? v;

    if (two) {
      if (details.scale > 1.01 && _hasStart(.pinchOut)) return .pinchOut;
      if (details.scale < 0.99 && _hasStart(.pinchIn)) return .pinchIn;
      if (dx > 10) h = .twoRight;
      if (dx < -10) h = .twoLeft;
      if (dy > 10) v = .twoDown;
      if (dy < -10) v = .twoUp;
    } else {
      if (dx > 10) h = .right;
      if (dx < -10) h = .left;
      if (dy > 10) v = .down;
      if (dy < -10) v = .up;
    }

    if (h != null && !_hasStart(h)) h = null;
    if (v != null && !_hasStart(v)) v = null;

    if (h == null) return v;
    if (v == null) return h;

    final hCoverV = _gestureFor(h).bounds.any((b) => b.bound.contains(v!.bound));
    final vCoverH = _gestureFor(v).bounds.any((b) => b.bound.contains(h!.bound));

    if (hCoverV && !vCoverH) return h;
    if (vCoverH && !hCoverV) return v;

    return dx.abs() >= dy.abs() ? h : v;
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _activeStart = null;
    _totalDelta = .zero;
    _stopSwapListening();
    _stage.dismiss();
  }

  StageData _setup() {
    final data = _stage;
    final origin = _measureOrigin();
    final screen = OriginRect(rect: Offset.zero & MediaQuery.sizeOf(context));

    data.setOrigin(origin);
    data.setDisplayContainer(widget.displayContainer);
    data.setOriginContainer(widget.originContainer ?? (widget.containerTag != null ? data.measureEntry(widget.containerTag!) : null));
    data.setDisplay(widget.display ?? widget.displayContainer ?? screen);
    data.setAspectRatio(widget.aspectRatio ?? context.size!.aspectRatio);
    data.setWidget(_OriginData(tag: widget.tag, child: KeyedSubtree(key: _childKey, child: widget.child)));
    if (widget.builder != null) data.setGestureBuilder(widget.builder);
    data.setPerspective(widget.perspective);
    data.setBackgroundColor(widget.backgroundColor);
    final onEnd = widget.onEnd;
    data.setOnEnd(widget.swapTags != null || onEnd != null ? () async {
      _finishSwap();
      await onEnd?.call(data);
    } : null);
    data.setTag(widget.tag);
    data.setRect(origin.rect);
    return data;
  }

  Future<void> _open() {
    return _setup().animateToBase();
  }

  Future<void> _send(Rect Function(Rect) send, {VoidCallback? onEnd}) {
    final data = _setup();
    if (onEnd != null) data.setOnEnd(onEnd);
    final origin = _measureOrigin();
    data.setOrigin(origin.copyWith(rect: send(origin.rect)));
    return data.dismiss();
  }

  void _onTapUp(TapUpDetails details) {
    widget.onTap!(TapEvent(
      localPosition: details.localPosition,
      globalPosition: details.globalPosition,
      animateToBase: _open,
      runEffect: ({
        double? rotateX,
        double? rotateY,
        double? rotateZ,
        double? perspective,
        Duration duration = const Duration(milliseconds: 100),
        Curve curve = Curves.easeOut,
      }) {
        return _setup().runEffect(
          rotateX: rotateX,
          rotateY: rotateY,
          rotateZ: rotateZ,
          perspective: perspective,
          duration: duration,
          curve: curve,
        );
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget._isItem) {
      return _OriginData(tag: widget.tag, child: widget.child);
    }

    final hasGestures = widget.gestures.isNotEmpty;

    return _OriginData(
      tag: widget.tag,
      child: RawGestureDetector(
        behavior: .translucent,
        gestures: {
          if (widget.onTap != null)
            TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              TapGestureRecognizer.new,
              (r) => r.onTapUp = _onTapUp,
            ),
          if (hasGestures)
            StageScaleRecognizer: GestureRecognizerFactoryWithHandlers<StageScaleRecognizer>(
              StageScaleRecognizer.new,
              (r) => r
                ..gestures = widget.gestures
                ..onStart = _onScaleStart
                ..onUpdate = _onScaleUpdate
                ..onEnd = _onScaleEnd,
            ),
        },
        child: Stage.isTagOf(context, widget.tag)
            ? const SizedBox.expand()
            : ClipRRect(
                borderRadius: widget.borderRadius,
                child: KeyedSubtree(key: _childKey, child: widget.child),
              ),
      ),
    );
  }
}

class _OriginData extends InheritedWidget {
  const _OriginData({required this.tag, required super.child});

  final Object tag;

  @override
  bool updateShouldNotify(_OriginData oldWidget) => tag != oldWidget.tag;
}
