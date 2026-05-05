import 'dart:async';

export 'corner.dart';
export 'physics.dart';
export 'rect_ext.dart';
export 'ext.dart';
export 'gestures.dart';
export 'origin_rect.dart';
export 'ratio.dart';
export 'recognizer.dart';
export 'resolution.dart';
export 'side.dart';
export 'stage.dart';
export 'stage_overlay.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'ext.dart';
import 'gestures.dart';
import 'origin_rect.dart';
import 'physics.dart';
import 'recognizer.dart';
import 'rect_ext.dart';
import 'release.dart';
import 'stage.dart';

class Origin extends StatefulWidget {
  const Origin({
    super.key,
    required this.tag,
    this.onTap,
    this.borderRadius = .zero,
    this.containerTag,
    this.originContainer,
    this.display,
    this.displayContainer,
    this.drag,
    this.scale,
    this.constraints,
    this.displayConfig,
    this.aspectRatio,
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
  final Map<DragStart, DragGesture>? drag;
  final Map<ScaleStart, ScaleGesture>? scale;
  final GestureConstraints? constraints;
  final DisplayConfig? displayConfig;
  final double? aspectRatio;
  final Color? backgroundColor;
  final FutureOr<void> Function(StageData)? onEnd;
  final Set<Object>? swapTags;
  final ValueSetter<Object>? onSwap;
  final StageBuilder? builder;
  final Widget child;

  bool get _isItem =>
      onTap != null ||
      (drag?.isNotEmpty ?? false) ||
      (scale?.isNotEmpty ?? false);

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
  late OriginEntry _entry;
  final _childKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _stage = context.getInheritedWidgetOfExactType<StageData>()!;
    _entry = _buildEntry();
    _stage.register(widget.tag, _entry);
  }

  @override
  void didUpdateWidget(Origin oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tag != widget.tag) {
      _stage.unregister(oldWidget.tag, _entry);
      _entry = _buildEntry();
      _stage.register(widget.tag, _entry);
    }
  }

  @override
  void dispose() {
    _stopSwapListening();
    _stage.unregister(widget.tag, _entry);
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
        _stage.dismiss(tag: _swapDisplaced!);
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

  /// Single active-gesture slot. Null = uncommitted.
  ActiveGesture? _active;
  Rect _startRect = .zero;
  Offset _totalDelta = .zero;

  void _onScaleStart(ScaleStartDetails details) {
    _startRect = _stage.rect.value;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    _totalDelta += details.focalPointDelta;

    switch (_active?.gesture) {
      case null: {
        // Resolver: try to commit a gesture based on pointer count.
        ActiveGesture? active;
        if (details.pointerCount > 1 && widget.scale != null) {
          active = _resolveScaleArena(details);
        } else if (details.pointerCount == 1 && widget.drag != null) {
          active = _resolveDragArena();
        }
        if (active == null) return; // not committed yet
        _active = active;

        final data = _setup();
        final builder = active.gesture.builder;
        if (builder != null) data.setGestureBuilder(builder);
        _startRect = data.rect.value;
        _startSwapListening();
        return;
      }

      case DragGesture drag: {
        final delta = details.focalPointDelta;
        final currentRect = _stage.rect.value;
        final originRect = _stage.origin.rect;
        final displayRect = _stage.display.rect;
        final dx = _frictionScaledX(
          delta: delta.dx, bounds: drag.bounds,
          currentRect: currentRect, originRect: originRect, displayRect: displayRect,
        );
        final dy = _frictionScaledY(
          delta: delta.dy, bounds: drag.bounds,
          currentRect: currentRect, originRect: originRect, displayRect: displayRect,
        );
        _stage.rect.value = currentRect.translate(dx, dy);
      }

      case ScaleGesture scale: {
        final delta = details.focalPointDelta;
        final currentRect = _stage.rect.value;
        final originRect = _stage.origin.rect;
        final displayRect = _stage.display.rect;
        if (currentRect.width == 0) return;
        final dx = _frictionScaledX(
          delta: delta.dx, bounds: scale.bounds,
          currentRect: currentRect, originRect: originRect, displayRect: displayRect,
        );
        final dy = _frictionScaledY(
          delta: delta.dy, bounds: scale.bounds,
          currentRect: currentRect, originRect: originRect, displayRect: displayRect,
        );

        // Scale-axis friction: apply to the width delta from intended scale.
        final baseWidth = displayRect.baseWidth(_stage.aspectRatio);
        final intendedWidth = _startRect.width * details.scale;
        final dw = intendedWidth - currentRect.width;
        final scaledDw = frictionFromScaleState(
          state: axisStateScale(dw, currentRect.width, baseWidth, scale.shrink, scale.expand),
          shrink: scale.shrink,
          expand: scale.expand,
          delta: dw,
        );
        final newWidth = currentRect.width + scaledDw;
        final newHeight = newWidth / _stage.aspectRatio;
        final center = (currentRect.center - details.focalPoint) * newWidth / currentRect.width
            + details.focalPoint
            + Offset(dx, dy);
        _stage.rect.value = Rect.fromCenter(center: center, width: newWidth, height: newHeight);
      }
    }
  }

  // Per-axis convenience wrappers used by call sites.
  // Compose the state computer + resolution helper from physics.dart.

  double _frictionScaledX({
    required double delta,
    required Map<DragBound, DragBounds> bounds,
    required Rect currentRect,
    required Rect originRect,
    required Rect displayRect,
  }) =>
      frictionFromState(
        state: axisStateX(delta, currentRect, originRect, displayRect),
        bounds: bounds,
        delta: delta,
      );

  double _frictionScaledY({
    required double delta,
    required Map<DragBound, DragBounds> bounds,
    required Rect currentRect,
    required Rect originRect,
    required Rect displayRect,
  }) =>
      frictionFromState(
        state: axisStateY(delta, currentRect, originRect, displayRect),
        bounds: bounds,
        delta: delta,
      );

  /// Resolves the active scale gesture from [Origin.scale] (no cascade —
  /// Origin handles idle-state gestures only).
  ActiveGesture? _resolveScaleArena(ScaleUpdateDetails details) {
    final map = widget.scale;
    if (map == null) return null;
    return resolveScaleArena(scale: details.scale, registered: map);
  }

  /// Resolves the active drag gesture from [Origin.drag].
  ActiveGesture? _resolveDragArena() {
    final map = widget.drag;
    if (map == null) return null;
    return resolveDragArena(totalDelta: _totalDelta, registered: map);
  }

  Future<void> _onScaleEnd(ScaleEndDetails details) async {
    final active = _active;
    if (active == null) return;

    final g = active.gesture;
    final velocity = details.velocity.pixelsPerSecond;
    final currentRect = _stage.rect.value;
    final displayRect = _stage.display.rect;

    final xRelease = releaseFromStateX(
      currentRect: currentRect,
      displayRect: displayRect,
      bounds: g.bounds,
      velocity: velocity.dx,
    );
    final yRelease = releaseFromStateY(
      currentRect: currentRect,
      displayRect: displayRect,
      bounds: g.bounds,
      velocity: velocity.dy,
    );
    final baseWidth = displayRect.baseWidth(_stage.aspectRatio);
    final scaleRelease = switch (g) {
      DragGesture _ => const IdleInDisplay(),
      ScaleGesture s => releaseFromStateScale(
          width: currentRect.width,
          baseWidth: baseWidth,
          shrink: s.shrink,
          expand: s.expand,
          velocity: details.scaleVelocity * baseWidth,
        ),
    };

    _active = null;
    _totalDelta = .zero;
    _stopSwapListening();

    final release = Release(x: xRelease, y: yRelease, scale: scaleRelease);

    if (g.onRelease != null) {
      g.onRelease!(context, release);
      return;
    }
    if (!mounted) return;
    await _stage.backToOrigin(release, except: _swapDisplaced);
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
    data.setDisplayConfig(widget.displayConfig);
    data.setPerspective(widget.constraints?.perspective);
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

    final hasGestures =
        (widget.drag?.isNotEmpty ?? false) || (widget.scale?.isNotEmpty ?? false);

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
                ..drag = widget.drag
                ..scale = widget.scale
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
