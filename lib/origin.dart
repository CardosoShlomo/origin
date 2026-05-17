import 'dart:async';

export 'corner.dart';
export 'crop_image.dart';
export 'cropper.dart';
export 'physics.dart';
export 'rect_ext.dart';
export 'ext.dart';
export 'gestures.dart';
export 'origin_rect.dart';
export 'ratio.dart';
export 'recognizer.dart';
export 'release.dart';
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
    this.onDoubleTap,
    this.onLongPress,
    this.borderRadius = .zero,
    this.containerTag,
    this.originContainer,
    this.display,
    this.displayContainer,
    this.drag,
    this.scale,
    this.constraints,
    this.displayConfig,
    this.modes,
    this.aspectRatio,
    this.backgroundColor,
    this.onRelease,
    this.overrides,
    this.onEnd,
    this.swapTags,
    this.onSwap,
    this.builder,
    this.dragHybridFromStage,
    this.scaleHybridFromStage,
    this.scaleVelocityCancel,
    this.overlay,
    required this.child,
  });

  final Object tag;
  final StageTap? onTap;

  /// Optional double-tap handler. Mirrors [onTap] — same [TapEvent] shape,
  /// consumer decides what to do (open, run effect, etc.). Registering this
  /// adds a [DoubleTapGestureRecognizer] alongside the tap recognizer, so
  /// single-tap resolution incurs the standard double-tap timeout (~300ms).
  final StageTap? onDoubleTap;

  /// Optional long-press handler. Mirrors [onTap].
  final StageTap? onLongPress;
  final BorderRadius borderRadius;
  final Object? containerTag;
  final OriginRect? originContainer;
  final OriginRect? display;
  final OriginRect? displayContainer;
  final Map<DragStart, DragGesture>? drag;
  final Map<ScaleStart, ScaleGesture>? scale;
  final GestureConstraints? constraints;
  final DisplayConfig? displayConfig;

  /// Mode-specific [DisplayConfig] variants, looked up by key when
  /// `event.animateToBase(modeKey)` is called.
  ///
  /// Each mode's DisplayConfig is merged into [displayConfig] field-by-field:
  /// non-null fields in the mode override the default; null fields inherit.
  /// `Map`-typed fields (`drag`, `scale`) follow the same rule — an empty
  /// `{}` explicitly disables (vs `null` which inherits the default's map).
  ///
  /// Modes are how the same Origin can open with different rules per tap
  /// (e.g., `'crop_square'` vs `'crop_free'`). Tools (cropper, eraser) are
  /// configured *inside* a mode's DisplayConfig via fields like
  /// [DisplayConfig.crop].
  final Map<Object, DisplayConfig>? modes;
  final double? aspectRatio;
  final Color? backgroundColor;
  final OnRelease? onRelease;
  final Overrides? overrides;
  final FutureOr<void> Function(StageData)? onEnd;
  final Set<Object>? swapTags;
  final ValueSetter<Object>? onSwap;
  final StageBuilder? builder;

  /// Origin-level cascade fallback for how new pointers are handled during
  /// an active gesture on this Origin (see [DragGesture.hybridFromStage] /
  /// [ScaleGesture.hybridFromStage] for per-gesture overrides). Resolved
  /// after the per-gesture field, before [Stage.dragHybridFromStage] /
  /// [Stage.scaleHybridFromStage] and the [DragHybrid.lock] / [ScaleHybrid.lock]
  /// package default.
  final DragHybrid? dragHybridFromStage;
  final ScaleHybrid? scaleHybridFromStage;

  /// Origin-level cascade fallback for scale-velocity-based translation
  /// cancellation. Resolved between [Gesture.scaleVelocityCancel] /
  /// [DisplayConfig.scaleVelocityCancel] and [Stage.scaleVelocityCancel].
  final double? scaleVelocityCancel;

  /// Origin-level overlay builder. Resolved in the cascade
  /// mode > displayConfig > this > [Stage.overlay]. Only rendered while
  /// this Origin is the displayed one on Stage.
  final WidgetBuilder? overlay;

  final Widget child;

  bool get _isItem =>
      onTap != null ||
      onDoubleTap != null ||
      onLongPress != null ||
      (drag?.isNotEmpty ?? false) ||
      (scale?.isNotEmpty ?? false);

  static Object? tagOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_OriginData>()?.tag;
  }

  static bool isActiveOf(BuildContext context) {
    final tag = context.dependOnInheritedWidgetOfExactType<_OriginData>()?.tag;
    return tag != null && Stage.isActiveOf(context, tag);
  }

  /// True iff the enclosing Origin's tag is currently active on stage *and*
  /// Stage's recognizer has at least one pointer down. Child widgets that
  /// live in the Origin's subtree can read this without knowing their tag.
  /// Resolves to false when no [_OriginData] is in scope.
  static bool isInteractingOf(BuildContext context) {
    final tag = context.dependOnInheritedWidgetOfExactType<_OriginData>()?.tag;
    return tag != null && Stage.isInteractingOf(context, tag);
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
      _stage.releaseSend(_swapDisplaced!);
      widget.onSwap?.call(_swapDisplaced!);
      _swapDisplaced = null;
    }
    _swapHover = null;
  }

  // --- Item gesture logic ---

  /// Single active-gesture slot. Null = uncommitted.
  ActiveGesture? _active;
  /// Reference to the active recognizer (set by the factory builder).
  /// Used to push pointer positions to Stage at hybrid takeover.
  StageScaleRecognizer? _recognizer;
  Rect _startRect = .zero;
  Offset _startFocalPoint = .zero;
  Offset _totalDelta = .zero;
  /// Tracks whether Stage's merger drove the rect on the previous update.
  /// On a true→false transition (stage's pointers left mid-gesture), Origin
  /// re-baselines [_startRect] / [_startFocalPoint] to current state so its
  /// scale formula (`_startRect.width × details.scale`) doesn't undo the
  /// merger's changes.
  bool _wasHybridDriving = false;

  void _onScaleStart(ScaleStartDetails details) {
    // onStart fires on every pointer-count change. Once committed, refresh
    // start refs but keep _active — Origin uses single-commit semantics
    // (one gesture for the entire pointer-tracking lifetime). Stage handles
    // mid-interaction switching when the displayed item is on stage.
    _startRect = _stage.rect.value;
    _startFocalPoint = details.focalPoint;
    if (_active != null) return;
    _totalDelta = .zero;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    _totalDelta += details.focalPointDelta;

    // Hybrid → non-hybrid transition: rebaseline reference frame so the
    // merger's modifications stick. _startRect.width is set so that
    // `_startRect.width × details.scale` equals the current (merger-driven)
    // rect width — letting Origin's scale formula resume from here without
    // a snap-back.
    final isHybrid = _stage.isHybridDriving();
    if (_wasHybridDriving && !isHybrid) {
      final currentRect = _stage.rect.value;
      final scale = details.scale == 0 ? 1.0 : details.scale;
      _startRect = Rect.fromCenter(
        center: currentRect.center,
        width: currentRect.width / scale,
        height: currentRect.height / scale,
      );
      _startFocalPoint = details.focalPoint;
    }
    _wasHybridDriving = isHybrid;

    // While Stage's hybrid merger owns the rect, Origin stops manipulating
    // it directly — pointer positions are still being forwarded via the
    // recognizer's `onPointersChanged` so Stage has live data.
    if (isHybrid) return;

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

        // Apply DragGesture.override if set.
        if (active.gesture case DragGesture(:final override?)) {
          final baseRect = data.display.rect.baseRect(data.aspectRatio);
          final replacement = override(data.rect.value, baseRect);
          if (replacement != null) {
            active = (start: active.start, gesture: replacement);
            _active = active;
          }
        }

        // Surface the committed gesture to Stage with hybrid resolved up
        // to Origin's level — Stage finishes the cascade for new pointers.
        // Also push current pointer positions so Stage's merger has data
        // available the instant a Stage-area pointer triggers takeover.
        _stage.setOriginGesture(_toOriginGesture(active));
        if (_recognizer != null) {
          _stage.setOriginPointers(_recognizer!.pointerPositions);
        }

        final builder = active.gesture.builder;
        if (builder != null) data.setGestureBuilder(builder);
        _startRect = data.rect.value;
        _startFocalPoint = details.focalPoint;
        _startSwapListening();
        return;
      }

      case DragGesture drag: {
        final hasScaleResponse = drag.bounds.hasScaleResponse;
        final currentRect = _stage.rect.value;
        final originRect = _stage.origin.rect;
        final displayRect = _stage.display.rect;

        if (hasScaleResponse) {
          final baseRect = displayRect.baseRect(_stage.aspectRatio);
          final anchor = _startFocalPoint - _startRect.center;
          final rawCenter = details.focalPoint - anchor;
          final factor = dragScaleFactor(
            rawCenter: rawCenter,
            actualRect: currentRect,
            baseRect: baseRect,
            displayRect: displayRect,
            bounds: drag.bounds,
          );
          final newWidth = baseRect.width * factor;
          final newHeight = newWidth / _stage.aspectRatio;
          final ctx = AnchorContext(
            startFocalPoint: _startFocalPoint,
            currentFocalPoint: details.focalPoint,
            startRect: _startRect,
            currentRect: currentRect,
            scale: _startRect.width == 0 ? 1.0 : newWidth / _startRect.width,
          );
          final anchorFn = widget.overrides?.anchor
              ?? _stage.overrides?.anchor
              ?? defaultDragAnchor;
          final newCenter = anchorFn(ctx);
          _stage.rect.value = Rect.fromCenter(
            center: newCenter,
            width: newWidth,
            height: newHeight,
          );
        } else {
          final delta = details.focalPointDelta;
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
        final scaleRatio = _startRect.width == 0 ? 1.0 : newWidth / _startRect.width;
        final newHeight = _startRect.height * scaleRatio;
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
    required GestureBounds bounds,
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
    required GestureBounds bounds,
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

  /// Builds an [OriginGesture] for [_active] with hybrid mode resolved
  /// through gesture-level → Origin-level. Stage finishes the cascade.
  /// Origin's `scale` map is forwarded so Stage's merger can re-resolve
  /// drag → scale on [DragHybrid.asScale] promotion. Origin's `onRelease`
  /// is forwarded so the hybrid release cascade (gesture → Origin → Stage
  /// → package default) matches Origin's own release cascade.
  OriginGesture _toOriginGesture(ActiveGesture active) {
    return switch (active.gesture) {
      DragGesture g => (
          active: active,
          dragHybrid: g.hybridFromStage ?? widget.dragHybridFromStage,
          scaleHybrid: null,
          scale: widget.scale,
          onRelease: widget.onRelease,
          scaleVelocityCancel: widget.scaleVelocityCancel,
        ),
      ScaleGesture g => (
          active: active,
          dragHybrid: null,
          scaleHybrid: g.hybridFromStage ?? widget.scaleHybridFromStage,
          scale: widget.scale,
          onRelease: widget.onRelease,
          scaleVelocityCancel: widget.scaleVelocityCancel,
        ),
    };
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

    // Zero translation velocity if scale velocity exceeds the configured
    // cutoff. Cascade: per-gesture > Origin > Stage > 0.8. From here the
    // rest of the release uses [details] as if it were the user's gesture.
    details = details.cancelTranslation(
      active.gesture.scaleVelocityCancel
          ?? widget.scaleVelocityCancel
          ?? _stage.scaleVelocityCancel()
          ?? 0.8,
    );

    _active = null;
    _totalDelta = .zero;
    _stopSwapListening();
    // Origin's pointers are gone — push empty so Stage's merger sees it.
    _stage.setOriginPointers(const {});

    // If Stage still has pointers, the gesture continues there. Defer the
    // release — Stage's onScaleEnd will fire it when the last stage pointer
    // leaves. Leave _originGesture set so Stage can use it.
    if (_stage.stagePointerCount() > 0) return;

    // Stage has no pointers either. If a previous release path already fired
    // (clearing _originGesture), skip — this happens on simultaneous lift
    // when Stage's onScaleEnd ran first.
    final stageOg = _stage.originGesture();
    if (stageOg == null) return;

    // Use Stage's view of the active gesture rather than Origin's local
    // [_active] — they diverge after a [DragHybrid.asScale] promotion
    // (Origin still holds the original DragGesture; Stage swapped it to a
    // resolved ScaleGesture). Release should reflect the final gesture so
    // shrink/expand bounds and the onRelease cascade are correct.
    //
    // Prefer the merger's combined velocity if it's still fresh — covers
    // the case where Origin lifts last after a hybrid session, so the
    // release reflects the merger's actual focal/spread motion across
    // both recognizers rather than just Origin's own ScaleEndDetails.
    final merged = _stage.hybridReleaseVelocity();
    final data = ReleaseContext(
      currentRect: _stage.rect.value,
      displayRect: _stage.display.rect,
      aspectRatio: _stage.aspectRatio,
      velocity: merged?.velocity ?? details.velocity,
      scaleVelocity: merged?.scaleVelocity ?? details.scaleVelocity,
      gesture: stageOg.active.gesture,
    );
    _stage.setOriginGesture(null);

    // Cascade: gesture > origin > stage > package default.
    final handler = data.gesture.onRelease ?? widget.onRelease ?? _stage.onRelease;
    if (handler != null) {
      handler(context, data);
      return;
    }
    await _stage.backToOrigin(data, except: _swapDisplaced);
  }

  StageData _setup({Object? mode}) {
    final data = _stage;
    final origin = _measureOrigin();
    final screen = OriginRect(rect: Offset.zero & MediaQuery.sizeOf(context));

    data.setOrigin(origin);
    data.setOriginContainer(widget.originContainer ?? (widget.containerTag != null ? data.measureEntry(widget.containerTag!) : null));
    data.setAspectRatio(widget.aspectRatio ?? context.size!.aspectRatio);
    data.setWidget(_OriginData(tag: widget.tag, child: KeyedSubtree(key: _childKey, child: widget.child)));
    // Register the origin's default config + modes map + display fallbacks
    // so Stage can resolve [setMode] calls later (including re-applying
    // display/displayContainer/builder per the active mode's overrides).
    // [setMode] will seed the gesture builder from
    // `effective.builder ?? widget.builder`, so we don't pre-set it here.
    data.setOriginConfig(
      defaults: widget.displayConfig,
      modes: widget.modes,
      overlay: widget.overlay,
      display: widget.display,
      displayContainer: widget.displayContainer,
      screen: screen,
      builder: widget.builder,
    );
    data.setMode(mode);
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

  Future<void> _open([Object? mode]) {
    return _setup(mode: mode).animateToBase();
  }

  Future<void> _send(Rect Function(Rect) send, {VoidCallback? onEnd}) {
    final data = _setup();
    if (onEnd != null) data.setOnEnd(onEnd);
    final origin = _measureOrigin();
    data.setOrigin(origin.copyWith(rect: send(origin.rect)));
    return data.dismiss();
  }

  TapEvent _buildTapEvent(Offset localPosition, Offset globalPosition) {
    return TapEvent(
      localPosition: localPosition,
      globalPosition: globalPosition,
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
    );
  }

  void _onTapUp(TapUpDetails details) {
    widget.onTap!(_buildTapEvent(details.localPosition, details.globalPosition));
  }

  // Double-tap recognizer fires onDoubleTap without position info; we cache
  // the position from onDoubleTapDown.
  Offset _doubleTapLocal = .zero;
  Offset _doubleTapGlobal = .zero;

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
          if (widget.onDoubleTap != null)
            DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
              DoubleTapGestureRecognizer.new,
              (r) {
                r.onDoubleTapDown = (d) {
                  _doubleTapLocal = d.localPosition;
                  _doubleTapGlobal = d.globalPosition;
                };
                r.onDoubleTap = () => widget.onDoubleTap!(
                  _buildTapEvent(_doubleTapLocal, _doubleTapGlobal),
                );
              },
            ),
          if (widget.onLongPress != null)
            LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              LongPressGestureRecognizer.new,
              (r) => r.onLongPressStart = (d) => widget.onLongPress!(
                _buildTapEvent(d.localPosition, d.globalPosition),
              ),
            ),
          if (hasGestures)
            StageScaleRecognizer: GestureRecognizerFactoryWithHandlers<StageScaleRecognizer>(
              StageScaleRecognizer.new,
              (r) {
                _recognizer = r;
                r.drag = widget.drag;
                r.scale = widget.scale;
                r.onStart = _onScaleStart;
                r.onUpdate = _onScaleUpdate;
                r.onEnd = _onScaleEnd;
                // Forward live positions to Stage only while it's actively
                // driving the rect via the hybrid merger. Initial positions
                // are pushed at commit time (see [_onScaleUpdate]).
                r.onPointersChanged = () {
                  if (_active != null && _stage.isHybridDriving()) {
                    _stage.setOriginPointers(r.pointerPositions);
                  }
                };
              },
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
