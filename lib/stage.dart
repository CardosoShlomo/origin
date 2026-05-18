import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'ext.dart';
import 'rect_ext.dart';
import 'gestures.dart';
import 'origin_rect.dart';
import 'physics.dart';
import 'recognizer.dart';
import 'release.dart';
import 'stage_overlay.dart';

class OriginEntry {
  OriginRect Function()? measure;
  Widget Function()? capture;
  Future<void> Function()? open;
  Future<void> Function(Rect Function(Rect), {VoidCallback? onEnd})? send;
}

enum TagState { idle, sending, parked, returning }

/// Internal sentinel for [Stage.zoomToggleOnDoubleTap]. Stage detects this
/// function by identity in `_onDoubleTap` and dispatches to the internal
/// zoom-toggle implementation (which has access to the live Stage state).
/// Invoking this directly is a no-op.
void _zoomToggleSentinel(StageTapEvent _) {}

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
const _interactingAspect = #interacting;

class Stage extends StatefulWidget {
  const Stage({
    super.key,
    required this.child,
    this.drag,
    this.scale,
    this.constraints,
    this.onRelease,
    this.onTap,
    this.onDoubleTap,
    this.doubleTapPullFactor,
    this.dragPromote,
    this.scaleVelocityCancel,
    this.overrides,
    this.overlay,
    this.dragHybridFromStage,
    this.scaleHybridFromStage,
  });

  final Widget child;

  /// Stage-level fallback drag gestures. Origins under this Stage cascade
  /// through their own [Origin.drag] first, then this map for any unhandled keys.
  final Map<DragStart, DragGesture>? drag;

  /// Stage-level fallback scale gestures.
  final Map<ScaleStart, ScaleGesture>? scale;

  /// Stage-level fallback constraints (per-field cascade).
  final GestureConstraints? constraints;

  /// Top-level onRelease fallback. Resolved last in both Stage and Origin
  /// gesture-end cascades.
  final OnRelease? onRelease;

  /// Stage-level fallback for displayed-state single-tap. Resolved as:
  /// [DisplayConfig.onTap] → this → package default (no-op). Use this for
  /// global tap behavior (e.g. dismiss-on-outside) that all displayed
  /// configs inherit unless they override.
  final OnStageTap? onTap;

  /// Stage-level fallback for displayed-state double-tap. Resolved as:
  /// [DisplayConfig.onDoubleTap] → this. Both null means no
  /// [DoubleTapGestureRecognizer] is registered — so single-tap fires on
  /// the up event without waiting for the double-tap timeout. Pass
  /// [Stage.zoomToggleOnDoubleTap] explicitly to opt in to the
  /// baseRect ↔ fit-cover-at-focal toggle.
  final OnStageTap? onDoubleTap;

  /// Pan tuning for the bundled [zoomToggleOnDoubleTap] handler when it
  /// transitions from base to fit-cover-at-focal. Cascade:
  /// [DisplayConfig.doubleTapPullFactor] → this → package default (0.4).
  /// Has no effect unless [zoomToggleOnDoubleTap] is wired in to
  /// [onDoubleTap] on this stage or the active [DisplayConfig].
  final double? doubleTapPullFactor;

  /// Sentinel handler — pass to [onDoubleTap] (here or on a
  /// [DisplayConfig]) to opt in to the package's default zoom toggle
  /// (baseRect ↔ fit-cover-at-focal at the tap position). Detected by
  /// identity inside Stage so the implementation can use the live Stage
  /// instance to animate the rect; invoking this function directly is a
  /// no-op.
  static const OnStageTap zoomToggleOnDoubleTap = _zoomToggleSentinel;

  /// Stage-level fallback for displayed-state drag→scale promotion when a
  /// 2nd pointer is added. Cascade: per-gesture > displayConfig > this >
  /// [DragPromote.scale] default.
  final DragPromote? dragPromote;

  /// Stage-level strength of scale-velocity-based translation cancellation
  /// in `[0, 1]`. Threaded into [ReleaseContext.scaleVelocityCancel] by
  /// the package's built-in release paths. Default `0.8`.
  final double? scaleVelocityCancel;

  /// Top-level escape hatches for advanced behavioral customization.
  /// Resolved last in the per-field overrides cascade (gesture-context-
  /// specific levels first, Stage as final fallback).
  final Overrides? overrides;

  /// Builder for an optional consumer-provided overlay rendered *above*
  /// the displayed origin and Stage's own overlay/scrim. Use it to add
  /// mode-aware UI (e.g., a crop tool's appbar). Read [Stage.of] to
  /// inspect `displayConfig()` and decide what to render. The builder
  /// is invoked on every Stage rebuild — consumer owns any animations
  /// (e.g. `AnimatedSwitcher` / `AnimatedOpacity`) around its output.
  final WidgetBuilder? overlay;

  /// Stage-level cascade fallback for how new pointers are handled during
  /// an active gesture (see [DragGesture.hybridFromStage] /
  /// [ScaleGesture.hybridFromStage]). Final fallback before
  /// [DragHybrid.lock] / [ScaleHybrid.lock].
  final DragHybrid? dragHybridFromStage;
  final ScaleHybrid? scaleHybridFromStage;

  static StageData of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<StageData>()!;
  }

  static Object? tagOf(BuildContext context) {
    return InheritedModel.inheritFrom<StageData>(context, aspect: _tagAspect)!.tag;
  }

  static TagState stateOf(BuildContext context, Object tag) {
    return InheritedModel.inheritFrom<StageData>(context, aspect: (#state, tag))!.tagStates[tag] ?? .idle;
  }

  static bool isTagOf(BuildContext context, Object tag) {
    final data = InheritedModel.inheritFrom<StageData>(context, aspect: (#tag, tag))!;
    return data.tag == tag || data.tagStates.containsKey(tag);
  }

  static bool isActiveOf(BuildContext context, Object tag) {
    final data = InheritedModel.inheritFrom<StageData>(context, aspect: (#active, tag))!;
    return data.tag == tag;
  }

  /// Coarse "is the user touching the stage right now?" signal.
  ///
  /// When [tag] is omitted, returns true if Stage's recognizer has any
  /// pointer down — untagged, fires for any interaction. Suitable for
  /// callers guaranteed to be mounted only while their tag is active (e.g.
  /// overlay-slot builders) or for any caller that doesn't care which origin
  /// is being touched.
  ///
  /// When [tag] is provided, returns true iff [tag] is the active stage tag
  /// *and* there's at least one pointer down. The aspect is tag-scoped, so
  /// consumers in unrelated origin subtrees don't rebuild on peer-origin
  /// interactions.
  static bool isInteractingOf(BuildContext context, [Object? tag]) {
    if (tag == null) {
      return InheritedModel.inheritFrom<StageData>(context, aspect: _interactingAspect)!.interacting;
    }
    final data = InheritedModel.inheritFrom<StageData>(context, aspect: (#interacting, tag))!;
    return data.tag == tag && data.interacting;
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
  // True while Stage's recognizer holds &gt; 0 pointers — a coarse "is the user
  // touching the displayed area right now?" signal. Consumers read it via
  // [Stage.isInteractingOf] (tag-aware: returns true iff the queried tag is
  // currently the active stage tag *and* there's at least one pointer down).
  // Independent of which gesture (drag/scale) has committed in arena.
  bool _interacting = false;

  /// The active crop rect, owned by Stage just like [_rect]. Initialized
  /// from [CropConfig.initialRect] when a crop mode activates; mutated by
  /// the recognizer (1-pointer drag inside the rect) and by the [Cropper]
  /// widget's handles. Consumers read it via [StageData.crop] when they
  /// need the result. Reset to [Rect.zero] on dismiss.
  final _crop = ValueNotifier<Rect>(.zero);

  /// Reference equality marker for the last [CropConfig] applied — used by
  /// [_setMode] to decide whether to re-seed [_crop] from
  /// [CropConfig.initialRect]. Switching from one crop config to another
  /// (e.g. free → square) re-seeds; leaving the same config alone preserves
  /// in-flight edits.
  CropConfig? _lastCrop;

  /// True while the active gesture is a crop-rect drag (single pointer that
  /// landed inside the crop rect). Flipped in [_onScaleStart], read in
  /// [_onScaleUpdate], cleared in [_onScaleEnd] or when a second pointer
  /// arrives (so pinch always takes over to image scale).
  bool _cropDrag = false;

  static const _defaultOriginRect = OriginRect(rect: .zero);

  OriginRect _origin = _defaultOriginRect;
  OriginRect? _originContainer;
  OriginRect _display = _defaultOriginRect;
  OriginRect? _displayContainer;
  double _aspectRatio = 1.0;
  Widget? _widget;
  final _originToBaseProgress = ValueNotifier(0.0);
  Offset? _lastRectCenter;
  Rect? _dismissStartContainer;
  final _registry = <Object, OriginEntry>{};
  final _tagStates = <Object, TagState>{};
  double? _perspective;
  Color? _backgroundColor;
  StageBuilder? _gestureBuilder;
  FutureOr<void> Function()? _onEnd;
  Object? _tag;
  bool _locked = true;
  bool _dismissing = false;
  final _container = ValueNotifier<OriginRect?>(null);

  static const _defaultDuration = Duration(milliseconds: 300);

  late final AnimationController _centerX;
  late final AnimationController _centerY;
  late final AnimationController _width;
  late final AnimationController _effect;
  late final AnimationController _cropAnim;
  final _rotation = ValueNotifier<Rotation?>(null);

  @override
  void initState() {
    super.initState();
    _centerX = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _centerY = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _width = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateRect);
    _effect = AnimationController(vsync: this, duration: _defaultDuration);
    _cropAnim = AnimationController(vsync: this, duration: _defaultDuration)..addListener(_updateCrop);
    _rect.addListener(_updateProgress);
    _rect.addListener(_updateContainer);
  }

  /// Hard package floor for both the image rect and the crop rect while in
  /// crop mode (in logical pixels). Mirrors `_CropperState._minCropSide`.
  static const _kCropMinSide = 80.0;

  /// Final clamp applied at the end of [_onScaleUpdate] in crop mode. Three
  /// invariants — package-level, independent of any consumer-set drag bounds
  /// or release physics:
  ///
  /// 1. Crop rect width/height >= [_kCropMinSide].
  /// 2. Image rect width/height >= max(crop's width/height, [_kCropMinSide])
  ///    — the image must be at least as big as the crop on each axis,
  ///    otherwise it can't cover it.
  /// 3. Image rect contains the crop rect — pan it back if a gesture moved
  ///    the image off such that part of the crop fell outside the image.
  ///
  /// Consumer-set bounds / friction still own everything else (rubber to
  /// display, decay, etc.) — these only enforce the image/crop relationship
  /// so the cropper never ends up with no image under it.
  void _clampCropMins() {
    // 1. Crop min size first — the image size invariant depends on the
    // post-clamp crop size.
    final c0 = _crop.value;
    var c = c0;
    if (c.width > 0 && c.height > 0
        && (c.width < _kCropMinSide || c.height < _kCropMinSide)) {
      final scale = math.max(_kCropMinSide / c.width, _kCropMinSide / c.height);
      c = Rect.fromCenter(
        center: c.center,
        width: c.width * scale,
        height: c.height * scale,
      );
      _crop.value = c;
    }

    // 2. Image rect must be at least as big as the crop.
    final r0 = _rect.value;
    var r = r0;
    final minW = math.max(_kCropMinSide, c.width);
    final minH = math.max(_kCropMinSide, c.height);
    if (r.width > 0 && r.height > 0
        && (r.width < minW || r.height < minH)) {
      final scale = math.max(minW / r.width, minH / r.height);
      r = Rect.fromCenter(
        center: r.center,
        width: r.width * scale,
        height: r.height * scale,
      );
    }

    // 3. Image must contain crop — push image back if a gesture put part of
    // the crop outside.
    var left = r.left;
    var top = r.top;
    if (r.left > c.left) left = c.left;
    if (r.right < c.right) left = c.right - r.width;
    if (r.top > c.top) top = c.top;
    if (r.bottom < c.bottom) top = c.bottom - r.height;
    if (left != r.left || top != r.top) {
      r = Rect.fromLTWH(left, top, r.width, r.height);
    }
    if (r != r0) _rect.value = r;
  }

  final _centerXTween = Tween<double>(begin: 0, end: 0);
  final _centerYTween = Tween<double>(begin: 0, end: 0);
  final _widthTween = Tween<double>(begin: 0, end: 0);
  final _heightTween = Tween<double>(begin: 0, end: 0);
  final _cropTween = RectTween(begin: Rect.zero, end: Rect.zero);

  void _updateCrop() {
    _crop.value = _cropTween.evaluate(_cropAnim)!;
  }

  /// Animates [crop] from its current value to [to]. Mirrors the rect-animation
  /// path used for [_rect] but for the crop rect — used for the reset action
  /// (snap-back to [CropConfig.initialRect]) and any other place that wants
  /// to programmatically transition the crop rect smoothly instead of
  /// instantly assigning to `stage.crop.value`.
  Future<void> animateCrop({required Rect to, Duration? duration, Curve curve = Curves.easeOut}) {
    _cropTween.begin = _crop.value;
    _cropTween.end = to;
    _safeReset(_cropAnim);
    return _cropAnim.animateTo(1, duration: duration, curve: curve);
  }

  /// True during an open animation ([animateToBase]) or a dismiss animation
  /// ([dismiss]). Cleared in the finally blocks of both. Release rubber-back
  /// / settle paths don't touch this. Consumers (e.g. crop-mode scrim) use
  /// it to fade only during real open/dismiss and stay solid through
  /// interaction + settle.
  bool _openingOrDismissing = false;
  void _setOpeningOrDismissing(bool v) {
    if (_openingOrDismissing != v) setState(() => _openingOrDismissing = v);
  }

  // Decomposed-release state. When true, [_updateRect] computes the rect's
  // center as `proportional(W) + offset` instead of treating X/Y tweens as
  // absolute positions. Lets the three axes animate with their own curves
  // and durations while still preserving the display-center invariant
  // mid-frame: as scale changes, X/Y are pulled proportionally; on top of
  // that, the X/Y tweens contribute any intended translation as an offset.
  bool _releaseDecomposed = false;
  double _releaseInitialX = 0;
  double _releaseInitialY = 0;
  double _releaseInitialWidth = 1;
  Offset _releaseDisplayCenter = Offset.zero;

  // --- Gesture state for displayed-rect interaction ---
  Rect _startRect = .zero;
  Offset _startFocalPoint = .zero;
  Offset _totalDelta = .zero;
  ActiveGesture? _active;
  // Last gesture committed during the current pointer-tracking lifetime.
  // Preserved across pointer-count changes so [_onScaleEnd] can still cascade
  // onRelease even when a re-resolution didn't commit anything new before lift.
  ActiveGesture? _lastActive;
  // Pointer count at the previous [_onScaleStart] firing, used to detect
  // adds vs removes (recognizer fires onStart on every pointer-count change).
  int _prevPointerCount = 0;
  DisplayConfig? _displayConfig;

  /// Effective drag map: Stage.drag overlaid by active Origin's displayConfig.drag.
  Map<DragStart, DragGesture> get _effectiveDrag => {
        ...?widget.drag,
        ...?_displayConfig?.drag,
      };

  /// Effective scale map: Stage.scale overlaid by active Origin's displayConfig.scale.
  Map<ScaleStart, ScaleGesture> get _effectiveScale => {
        ...?widget.scale,
        ...?_displayConfig?.scale,
      };

  void _setDisplayConfig(DisplayConfig? v) => setState(() => _displayConfig = v);

  // Backing for [Stage.setMode]: at origin setup we store the origin's
  // default config and modes map so [_setMode] can resolve a key later.
  DisplayConfig? _originDefaultConfig;
  Map<Object, DisplayConfig>? _originModes;

  void _setOriginConfig({
    DisplayConfig? defaults,
    Map<Object, DisplayConfig>? modes,
    WidgetBuilder? overlay,
    OriginRect? display,
    OriginRect? displayContainer,
    OriginRect? screen,
    StageBuilder? builder,
  }) {
    _originDefaultConfig = defaults;
    _originModes = modes;
    _originOverlay = overlay;
    _originDisplay = display;
    _originDisplayContainer = displayContainer;
    _originScreen = screen;
    _originBuilder = builder;
  }

  // The currently-displayed origin's overlay/display/displayContainer/screen
  // /builder, used as fallbacks when the active [DisplayConfig] doesn't
  // override them.
  WidgetBuilder? _originOverlay;
  OriginRect? _originDisplay;
  OriginRect? _originDisplayContainer;
  OriginRect? _originScreen;
  StageBuilder? _originBuilder;

  /// Swaps the active [DisplayConfig] to the mode-resolved variant and
  /// re-applies any display/displayContainer overrides the new config
  /// carries. Null key = back to the origin's default (no-mode) config.
  ///
  /// Re-uses the same merge semantics as [Origin.modes]: non-null fields
  /// in the mode override the default; null fields inherit.
  void _setMode(Object? key) {
    final modeConfig = key == null ? null : _originModes?[key];
    final effective = _originDefaultConfig?.merge(modeConfig) ?? modeConfig;
    final prevDisplay = _display;
    final newDisplay = effective?.display
        ?? _originDisplay
        ?? (effective?.displayContainer ?? _originDisplayContainer)
        ?? _originScreen
        ?? _defaultOriginRect;
    setState(() {
      _displayConfig = effective;
      _displayContainer = effective?.displayContainer ?? _originDisplayContainer;
      _display = newDisplay;
      // Per-mode wrap of the captured widget: displayConfig.builder takes
      // precedence over Origin.builder. A gesture commit can still override
      // this temporarily via [_active.gesture.builder].
      _gestureBuilder = effective?.builder ?? _originBuilder;
    });
    // Seed the crop rect when entering a new crop config (by identity) so
    // switching configs (e.g. free → square) re-anchors to the configured
    // initial rect, but in-flight edits within the same config aren't lost.
    final crop = effective?.crop;
    if (crop != null && !identical(crop, _lastCrop)) {
      _lastCrop = crop;
      final base = newDisplay.rect.baseRect(_aspectRatio);
      _crop.value = crop.initialRect?.call(base) ?? base;
    } else if (crop == null) {
      _lastCrop = null;
    }
    // When the active mode changes the display rect (e.g. crop mode
    // constrains the display to exclude an appbar), animate the live rect
    // to the new base — otherwise the image would jump or sit at a stale
    // position relative to the new container.
    if (newDisplay.rect != prevDisplay.rect && _rect.value != .zero) {
      animateRect(to: newDisplay.rect.baseRect(_aspectRatio), curve: Curves.easeOut);
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    // Hybrid: merger owns the rect; skip stage's local resolver.
    if (_isHybridDriving) return;
    // onStart fires on every pointer-count change, not just first touch.
    _startRect = _rect.value;
    _startFocalPoint = details.focalPoint;

    final added = details.pointerCount > _prevPointerCount;
    _prevPointerCount = details.pointerCount;

    // Crop-drag detection: 1-pointer gesture starting inside the active crop
    // rect → drag the crop rect (image follows at edges). Gated on
    // [_active] being null — once a resolver has committed (drag or scale),
    // the gesture stays as image manipulation. Pinch-then-release-1-finger
    // leaves [_active] set to a ScaleGesture, so this won't re-enter crop
    // drag and swallow the image's release physics.
    if (_active == null
        && details.pointerCount == 1
        && _displayConfig?.crop != null
        && _crop.value.contains(details.focalPoint)) {
      _cropDrag = true;
      // No drag/scale resolver — we hijack the gesture.
      return;
    }
    if (_cropDrag && details.pointerCount > 1) {
      _cropDrag = false;
    }

    // Pointer removed (count went down): keep current gesture. The real end
    // is when all pointers leave — that's the recognizer's onEnd.
    if (!added) return;
    // One-way switch: drag → scale. Once scale wins, it stays for the rest
    // of the interaction; adding more pointers doesn't reassess.
    if (_active?.gesture case ScaleGesture _) return;

    // Drag→scale promotion cascade: per-gesture > displayConfig > stage >
    // [DragPromote.scale] default. When locked, keep the active drag.
    if (_active?.gesture case DragGesture drag) {
      final promote = drag.promote
          ?? _displayConfig?.dragPromote
          ?? widget.dragPromote
          ?? DragPromote.scale;
      if (promote == DragPromote.lock) return;
    }

    // Pointer added while idle or in drag (promote=scale): clear so the
    // resolver re-runs with the new pointer count (will commit scale on
    // the next pinch).
    _active = null;
    _totalDelta = .zero;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // First update of a gesture = user is actually manipulating (vs. just
    // touching). Promote [_interacting] here, not on pointer-down, so a
    // plain tap never briefly flips it true.
    if (!_interacting) setState(() => _interacting = true);
    // Hybrid: merger owns the rect; skip stage's local update logic.
    if (_isHybridDriving) return;

    // Crop-drag path: hijacked gesture, no resolver, no totalDelta. Move
    // the crop rect by the focal delta (clamped to the image-intersect-
    // display boundary) and shift the image when the crop is pinned to an
    // edge in the drag direction (catch-up capped by overdragMax).
    final cropConfig = _displayConfig?.crop;
    if (_cropDrag) {
      if (details.pointerCount > 1) {
        // 2nd finger arrived mid-gesture — exit crop drag, fall into normal
        // scale flow so the pinch zooms the image.
        _cropDrag = false;
      } else if (cropConfig != null) {
        final boundaries = _rect.value.intersect(_display.rect);
        final newCrop = _crop.value
            .shift(details.focalPointDelta)
            .cropBoundaries(
              boundaries,
              minAspectRatio: cropConfig.minAspectRatio,
              maxAspectRatio: cropConfig.maxAspectRatio,
            );
        _crop.value = newCrop;
        _rect.value = details.imageRectOnDragCropRect(
          container: _display.rect,
          imageRect: _rect.value,
          cropRect: newCrop,
          overdragMax: cropConfig.overdragMax,
        );
        _clampCropMins();
        return;
      }
    }

    _totalDelta += details.focalPointDelta;

    switch (_active?.gesture) {
      case null: {
        // Resolver: cascade through displayConfig → Stage.
        if (details.pointerCount > 1) {
          final scaleMap = _effectiveScale;
          if (scaleMap.isNotEmpty) {
            _active = resolveScaleArena(scale: details.scale, registered: scaleMap);
          }
        } else if (details.pointerCount == 1) {
          final dragMap = _effectiveDrag;
          if (dragMap.isNotEmpty) {
            _active = resolveDragArena(totalDelta: _totalDelta, registered: dragMap);
          }
        }
        if (_active == null) return;

        // Apply DragGesture.override if set — lets consumer pick a variant
        // based on starting rect state.
        final committed = _active!;
        if (committed.gesture case DragGesture(:final override?)) {
          final baseRect = _display.rect.baseRect(_aspectRatio);
          final replacement = override(_rect.value, baseRect);
          if (replacement != null) {
            _active = (start: committed.start, gesture: replacement);
          }
        }

        _lastActive = _active;
        final builder = _active!.gesture.builder;
        if (builder != null) _setGestureBuilder(builder);
        _startRect = _rect.value;
        _startFocalPoint = details.focalPoint;
        return;
      }

      case DragGesture drag: {
        // For displayed items, the natural rest is the base rect (centered
        // in display), not the thumbnail. axisState's `originRect` is
        // really "the reference rest" — pass base, not [_origin.rect].
        final displayRect = _display.rect;
        _rect.value = computeDragRect(
          bounds: drag.bounds,
          currentRect: _rect.value,
          originRect: displayRect.baseRect(_aspectRatio),
          displayRect: displayRect,
          aspectRatio: _aspectRatio,
          focalPoint: details.focalPoint,
          focalPointDelta: details.focalPointDelta,
          startRect: _startRect,
          startFocalPoint: _startFocalPoint,
          anchorFn: _displayConfig?.overrides?.anchor
              ?? widget.overrides?.anchor
              ?? defaultDragAnchor,
        );
      }

      case ScaleGesture scale: {
        final delta = details.focalPointDelta;
        final currentRect = _rect.value;
        final originRect = _origin.rect;
        final displayRect = _display.rect;
        if (currentRect.width == 0) return;
        final dx = frictionFromState(
          state: axisStateX(delta.dx, currentRect, originRect, displayRect),
          bounds: scale.bounds,
          delta: delta.dx,
        );
        final dy = frictionFromState(
          state: axisStateY(delta.dy, currentRect, originRect, displayRect),
          bounds: scale.bounds,
          delta: delta.dy,
        );

        // Scale-axis friction: apply to the width delta from intended scale.
        final baseWidth = displayRect.baseWidth(_aspectRatio);
        final intendedWidth = _startRect.width * details.scale;
        final dw = intendedWidth - currentRect.width;
        final scaledDw = frictionFromScaleState(
          state: axisStateScale(dw, currentRect.width, baseWidth, scale.shrink, scale.expand),
          shrink: scale.shrink,
          expand: scale.expand,
          delta: dw,
        );
        final newWidth = currentRect.width + scaledDw;
        // Preserve startRect's aspect ratio (not _aspectRatio, which may
        // differ if startRect was off-aspect).
        final scaleRatio = _startRect.width == 0 ? 1.0 : newWidth / _startRect.width;
        final newHeight = _startRect.height * scaleRatio;
        final center = (currentRect.center - details.focalPoint) * newWidth / currentRect.width
            + details.focalPoint
            + Offset(dx, dy);
        _rect.value = Rect.fromCenter(center: center, width: newWidth, height: newHeight);
      }
    }
    // Final clamp: at the very end of crop-mode gesture updates, ensure
    // neither rect dropped below the floor. One pass, no listeners.
    if (_displayConfig?.crop != null) _clampCropMins();
  }

  Future<void> _onScaleEnd(ScaleEndDetails details, BuildContext context) async {
    // All stage pointers up → end of any manipulation. Clear interacting
    // immediately so overlay chrome can fade back in while the release
    // physics still run.
    if (_interacting) setState(() => _interacting = false);
    // Crop-drag end: no release physics — the crop rect was set live each
    // frame and the image is already positioned to match.
    if (_cropDrag) {
      _cropDrag = false;
      _active = null;
      _lastActive = null;
      _totalDelta = .zero;
      _prevPointerCount = 0;
      return;
    }
    // If origin is still gesturing (its recognizer has pointers), defer —
    // origin's onScaleEnd will fire the release when its last pointer leaves.
    if (_originPointers.isNotEmpty) {
      _active = null;
      _lastActive = null;
      _totalDelta = .zero;
      _prevPointerCount = 0;
      return;
    }

    // Hybrid release path: origin's pointers are also gone (or the gesture
    // was hybrid-driven). Prefer the merger's combined velocity if it's
    // fresh (captures simultaneous-lift case across both recognizers);
    // otherwise fall back to stage's own ScaleEndDetails.
    final og = _originGesture;
    if (og != null) {
      // Zero translation if scale velocity exceeds cutoff. Cascade:
      // gesture > Origin (via OriginGesture) > Stage > 0.8.
      details = details.cancelTranslation(
        og.active.gesture.scaleVelocityCancel
            ?? og.scaleVelocityCancel
            ?? widget.scaleVelocityCancel
            ?? 0.8,
      );
      final merged = _hybridReleaseVelocity();
      final data = ReleaseContext(
        currentRect: _rect.value,
        displayRect: _display.rect,
        aspectRatio: _aspectRatio,
        velocity: merged?.velocity ?? details.velocity,
        scaleVelocity: merged?.scaleVelocity ?? details.scaleVelocity,
        gesture: og.active.gesture,
      );
      _setOriginGesture(null);
      _resetHybridMerger();
      _active = null;
      _lastActive = null;
      _totalDelta = .zero;
      _prevPointerCount = 0;

      // Cascade mirrors Origin's own release cascade (gesture → Origin →
      // Stage → package default) — not the displayed-state cascade
      // (which goes through displayConfig), since hybrid runs while origin
      // is un-displayed. _displayConfig is null in this state anyway.
      final handler = data.gesture.onRelease
          ?? og.onRelease
          ?? widget.onRelease;
      if (handler != null) {
        handler(context, data);
        return;
      }
      await Stage.of(context).backToOrigin(data);
      return;
    }

    // Non-hybrid: prefer _active (current commit), fall back to _lastActive
    // (last commit within this lifetime — covers cases where re-resolution
    // after a pointer change didn't commit a new gesture before all fingers
    // lifted).
    final active = _active ?? _lastActive;
    if (active == null) return;

    // Zero translation if scale velocity exceeds cutoff. Cascade:
    // gesture > DisplayConfig > Stage > 0.8. Displayed-state path.
    details = details.cancelTranslation(
      active.gesture.scaleVelocityCancel
          ?? _displayConfig?.scaleVelocityCancel
          ?? widget.scaleVelocityCancel
          ?? 0.8,
    );

    final data = ReleaseContext(
      currentRect: _rect.value,
      displayRect: _display.rect,
      aspectRatio: _aspectRatio,
      velocity: details.velocity,
      scaleVelocity: details.scaleVelocity,
      gesture: active.gesture,
    );

    _active = null;
    _lastActive = null;
    _totalDelta = .zero;
    _prevPointerCount = 0;

    // Cascade: gesture > displayConfig > stage > package default.
    final handler = data.gesture.onRelease ?? _displayConfig?.onRelease ?? widget.onRelease;
    if (handler != null) {
      handler(context, data);
      return;
    }
    await Stage.of(context).release(.toDisplay(data));
  }

  void _setOrigin(OriginRect v) => _origin = v;
  void _setOriginContainer(OriginRect? v) => _originContainer = v;
  void _setDisplay(OriginRect v) => _display = v;
  void _setDisplayContainer(OriginRect? v) => _displayContainer = v;
  void _setAspectRatio(double v) => _aspectRatio = v;
  void _setPerspective(double? v) => _perspective = v;
  void _setBackgroundColor(Color? v) => _backgroundColor = v;
  void _setGestureBuilder(StageBuilder? v) => setState(() => _gestureBuilder = v);
  void _setOnEnd(FutureOr<void> Function()? v) => _onEnd = v;
  void _setTag(Object? tag) => setState(() => _tag = tag);
  void _setWidget(Widget? v) => setState(() => _widget = v);
  void _setLocked(bool v) => setState(() => _locked = v);
  OriginGesture? _originGesture;
  void _setOriginGesture(OriginGesture? v) {
    setState(() => _originGesture = v);
    if (v == null) _originPointers = const {};
  }
  // Pointer positions forwarded from the active Origin's recognizer. Combined
  // with stage's own recognizer's positions to drive hybrid gesture math.
  Map<int, Offset> _originPointers = const {};
  void _setOriginPointers(Map<int, Offset> v) {
    _originPointers = Map.of(v);
    _onHybridPointersChanged();
  }
  // Reference to stage's own recognizer (set when [active] is true in build),
  // used to read its [pointerPositions] for the hybrid merger.
  StageScaleRecognizer? _stageRecognizer;

  // Hybrid merger state — last focal/spread sample, used to compute per-frame
  // deltas (so friction/bounds compose with the same physics as Origin's and
  // Stage's normal scale-update paths). Refreshed every update, re-baselined
  // on pointer-count change.
  Offset? _hybridLastFocal;
  double? _hybridLastSpread;
  int _hybridLastCount = 0;
  // Spread snapshot at the moment we entered 2-pointer mode while Origin's
  // drag was still active under [DragHybrid.asScale]. Used as the baseline
  // for `resolveScaleArena` to decide if the cumulative pinch crossed the
  // commit threshold. Null while not in a promotion-candidate state, or
  // after promotion has fired.
  double? _hybridPromotionBaselineSpread;
  // Per-update merger samples (focal + spread + timestamp). Used to compute
  // a finite-difference velocity across the last two same-count frames.
  // `_hybridPrevSample` is cleared on re-baseline so velocity is never
  // computed across a pointer-count change.
  ({Offset focal, double spread, int timeMicros})? _hybridSample;
  ({Offset focal, double spread, int timeMicros})? _hybridPrevSample;
  // Last valid same-count velocity. Persists through re-baselines and the
  // final reset, so release fired after a simultaneous lift (a 1-pointer
  // gap between the two recognizers' onEnds) still sees the 2-pointer-era
  // velocity. Staleness checked at read time (100ms window).
  ({Velocity velocity, double scaleVelocity, int timeMicros})? _lastMergerVelocity;
  // True while Stage's hybrid merger is driving the rect — Origin reads this
  // and silences its own rect manipulation when set.
  bool _isHybridDriving = false;

  void _setIsHybridDriving(bool v) {
    if (_isHybridDriving == v) return;
    setState(() => _isHybridDriving = v);
  }

  // Cached down-position for the upcoming double-tap callback (the recognizer
  // delivers position in onDoubleTapDown but not in onDoubleTap).
  Offset _doubleTapLocal = .zero;
  Offset _doubleTapGlobal = .zero;

  /// Implementation of [Stage.zoomToggleOnDoubleTap]. Toggles between
  /// baseRect (when zoomed/translated) and fit-cover-at-focal (when at
  /// base). Pan tuning via the [doubleTapPullFactor] cascade.
  void _runZoomToggle(StageTapEvent e) {
    final atBase = (e.currentRect.center - e.baseRect.center).distance < 1.0
        && (e.currentRect.width - e.baseRect.width).abs() < 1.0;
    final pullFactor = _displayConfig?.doubleTapPullFactor
        ?? widget.doubleTapPullFactor
        ?? 0.4;
    final target = atBase
        ? e.displayRect.fitCoverRect(
            e.baseRect,
            e.globalPosition,
            pullFactor: pullFactor,
          )
        : e.baseRect;
    animateRect(to: target, curve: Curves.easeOut);
  }

  void _onDoubleTap() {
    final handler = _displayConfig?.onDoubleTap ?? widget.onDoubleTap;
    if (handler == null) return;
    final event = StageTapEvent(
      localPosition: _doubleTapLocal,
      globalPosition: _doubleTapGlobal,
      currentRect: _rect.value,
      displayRect: _display.rect,
      baseRect: _display.rect.baseRect(_aspectRatio),
      aspectRatio: _aspectRatio,
    );
    if (identical(handler, Stage.zoomToggleOnDoubleTap)) {
      _runZoomToggle(event);
    } else {
      handler(event);
    }
  }

  // Single-tap recognizer fires onTapUp with position info — capture here so
  // we can build a [StageTapEvent] with the rect snapshot at tap time.
  Offset _tapLocal = .zero;
  Offset _tapGlobal = .zero;

  void _onTap() {
    final handler = _displayConfig?.onTap ?? widget.onTap;
    if (handler == null) return;
    final event = StageTapEvent(
      localPosition: _tapLocal,
      globalPosition: _tapGlobal,
      currentRect: _rect.value,
      displayRect: _display.rect,
      baseRect: _display.rect.baseRect(_aspectRatio),
      aspectRatio: _aspectRatio,
    );
    handler(event);
  }

  void _resetHybridMerger() {
    _hybridLastFocal = null;
    _hybridLastSpread = null;
    _hybridLastCount = 0;
    _hybridPromotionBaselineSpread = null;
    _setIsHybridDriving(false);
  }

  /// Resolves the active-gesture-type hybrid mode through Origin → Stage →
  /// package-default cascade. Returns null if locked / no hybrid intent.
  ({DragHybrid? drag, ScaleHybrid? scale})? _resolveHybrid(OriginGesture og) {
    return switch (og.active.gesture) {
      DragGesture _ => () {
          final h = og.dragHybrid ?? widget.dragHybridFromStage ?? DragHybrid.lock;
          return h == DragHybrid.lock ? null : (drag: h, scale: null);
        }(),
      ScaleGesture _ => () {
          final h = og.scaleHybrid ?? widget.scaleHybridFromStage ?? ScaleHybrid.lock;
          return h == ScaleHybrid.lock ? null : (drag: null, scale: h);
        }(),
    };
  }

  /// Triggered whenever pointer positions change on either recognizer (origin
  /// forwards via [_setOriginPointers]; stage's own via the recognizer's
  /// `onPointersChanged`). Combines both pointer sets into a unified focal /
  /// spread, computes a per-frame delta against the last sample, and applies
  /// the active gesture's friction/bounds the same way Origin's and Stage's
  /// normal `_onScaleUpdate` paths do. Re-baselines on pointer-count change
  /// so drop-to-1 / re-add transitions stay smooth.
  void _onHybridPointersChanged() {
    final og = _originGesture;
    if (og == null) {
      _resetHybridMerger();
      return;
    }
    final hybrid = _resolveHybrid(og);
    if (hybrid == null) {
      _resetHybridMerger();
      return;
    }

    final stagePointers = _stageRecognizer?.pointerPositions ?? const {};
    final all = {..._originPointers, ...stagePointers};
    if (all.isEmpty || stagePointers.isEmpty) {
      // No stage pointers ⇒ exit hybrid; Origin resumes local manipulation
      // (or, if Origin's pointers also gone, the gesture is fully over).
      _resetHybridMerger();
      return;
    }

    final focal = _meanOffset(all.values);
    final spread = _meanDistance(all.values, focal);

    // First activation OR pointer count change ⇒ re-baseline last samples;
    // no rect update this frame (the focal/spread "shift" from the count
    // change isn't real finger motion). Drop the prev sample so the next
    // frame's velocity isn't computed across the pointer-count jump, but
    // keep `_lastMergerVelocity` so a release fired before the next valid
    // sample (e.g. simultaneous lift) still has access to the most recent
    // same-count velocity.
    if (_hybridLastFocal == null || all.length != _hybridLastCount) {
      _hybridLastFocal = focal;
      _hybridLastSpread = spread;
      _hybridLastCount = all.length;
      _hybridPrevSample = null;
      _hybridSample = (
        focal: focal,
        spread: spread,
        timeMicros: DateTime.now().microsecondsSinceEpoch,
      );
      // Track promotion baseline only while we have 2 pointers AND origin
      // is still in drag AND mode is asScale; reset otherwise.
      if (all.length >= 2
          && hybrid.drag == DragHybrid.asScale
          && og.active.gesture is DragGesture) {
        _hybridPromotionBaselineSpread = spread;
      } else {
        _hybridPromotionBaselineSpread = null;
      }
      _setIsHybridDriving(true);
      return;
    }

    final frameDelta = focal - _hybridLastFocal!;
    final scaleRatio = (hybrid.drag == DragHybrid.asDrag
            || all.length < 2
            || _hybridLastSpread! <= 0)
        ? 1.0
        : spread / _hybridLastSpread!;

    // asScale promotion: when the cumulative pinch from the 2-pointer
    // baseline crosses the scale-arena commit threshold, swap the active
    // gesture to the matched ScaleGesture (with ScaleHybrid.merge) so the
    // rest of the gesture — and the eventual release — use scale config
    // (shrink/expand bounds, scale-axis onRelease, etc.).
    Gesture activeGesture = og.active.gesture;
    final promotionBaseline = _hybridPromotionBaselineSpread;
    if (promotionBaseline != null
        && hybrid.drag == DragHybrid.asScale
        && activeGesture is DragGesture
        && og.scale != null
        && og.scale!.isNotEmpty
        && promotionBaseline > 0) {
      final cumulative = spread / promotionBaseline;
      final resolved = resolveScaleArena(
        scale: cumulative,
        registered: og.scale!,
      );
      if (resolved != null) {
        _setOriginGesture((
          active: resolved,
          dragHybrid: null,
          scaleHybrid: ScaleHybrid.merge,
          scale: og.scale,
          onRelease: og.onRelease,
          scaleVelocityCancel: og.scaleVelocityCancel,
        ));
        _hybridPromotionBaselineSpread = null;
        activeGesture = resolved.gesture;
      }
    }

    // Pick bounds from the currently-active gesture so the merger respects
    // the same friction/limits as a non-hybrid update would.
    final GestureBounds bounds;
    final ShrinkBounds? shrink;
    final ExpandBounds? expand;
    switch (activeGesture) {
      case DragGesture g:
        bounds = g.bounds;
        shrink = null;
        expand = null;
      case ScaleGesture g:
        bounds = g.bounds;
        shrink = g.shrink;
        expand = g.expand;
    }

    final currentRect = _rect.value;
    final originRect = _origin.rect;
    final displayRect = _display.rect;
    final baseWidth = displayRect.baseWidth(_aspectRatio);

    // Translation: per-axis friction against bounds (same as Origin/Stage
    // normal scale-update paths).
    final dx = frictionFromState(
      state: axisStateX(frameDelta.dx, currentRect, originRect, displayRect),
      bounds: bounds,
      delta: frameDelta.dx,
    );
    final dy = frictionFromState(
      state: axisStateY(frameDelta.dy, currentRect, originRect, displayRect),
      bounds: bounds,
      delta: frameDelta.dy,
    );

    // Scale: friction against shrink/expand. For DragGesture (no shrink/
    // expand), this passes through; future `asScale` re-resolution will
    // swap to a ScaleGesture so scale-axis bounds also apply.
    final intendedWidth = currentRect.width * scaleRatio;
    final dw = intendedWidth - currentRect.width;
    final scaledDw = frictionFromScaleState(
      state: axisStateScale(dw, currentRect.width, baseWidth, shrink, expand),
      shrink: shrink,
      expand: expand,
      delta: dw,
    );
    final newWidth = currentRect.width + scaledDw;
    final widthRatio = currentRect.width == 0 ? 1.0 : newWidth / currentRect.width;
    final newHeight = currentRect.height * widthRatio;
    final newCenter = (currentRect.center - focal) * widthRatio
        + focal
        + Offset(dx, dy);

    _rect.value = Rect.fromCenter(
      center: newCenter,
      width: newWidth,
      height: newHeight,
    );

    _hybridLastFocal = focal;
    _hybridLastSpread = spread;
    // Capture velocity from prev → current (same pointer count). Update
    // [_lastMergerVelocity] only when prev exists so we never measure
    // across a re-baseline.
    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    final prev = _hybridPrevSample;
    if (prev != null) {
      final dtSec = (nowMicros - prev.timeMicros) / 1e6;
      if (dtSec > 0) {
        final scaleVel = prev.spread > 0
            ? (spread - prev.spread) / (prev.spread * dtSec)
            : 0.0;
        _lastMergerVelocity = (
          velocity: Velocity(pixelsPerSecond: (focal - prev.focal) / dtSec),
          scaleVelocity: scaleVel,
          timeMicros: nowMicros,
        );
      }
    }
    _hybridPrevSample = _hybridSample;
    _hybridSample = (focal: focal, spread: spread, timeMicros: nowMicros);
  }

  /// Returns the merger's last valid same-count velocity if it's recent
  /// (≤ 100ms old). Returns null when the merger didn't run or its last
  /// sample is stale — callers should fall back to the firing recognizer's
  /// own `ScaleEndDetails.velocity`.
  ({Velocity velocity, double scaleVelocity})? _hybridReleaseVelocity() {
    final last = _lastMergerVelocity;
    if (last == null) return null;
    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    if (nowMicros - last.timeMicros > 100000) return null;
    return (velocity: last.velocity, scaleVelocity: last.scaleVelocity);
  }

  static Offset _meanOffset(Iterable<Offset> positions) {
    if (positions.isEmpty) return .zero;
    Offset sum = .zero;
    for (final p in positions) {
      sum += p;
    }
    return sum / positions.length.toDouble();
  }

  static double _meanDistance(Iterable<Offset> positions, Offset focal) {
    if (positions.isEmpty) return 0;
    double sum = 0;
    for (final p in positions) {
      sum += (p - focal).distance;
    }
    return sum / positions.length;
  }
  void _setDismissing(bool v) {
    if (v && !_dismissing) {
      _dismissStartContainer = _container.value?.rect;
    } else if (!v) {
      _dismissStartContainer = null;
    }
    setState(() => _dismissing = v);
  }
  void _setTagState(Object tag, TagState state) => setState(() => _tagStates[tag] = state);
  void _clearTagState(Object tag) => setState(() => _tagStates.remove(tag));

  void _updateContainer() {
    if (_rect.value == .zero) {
      _container.value = null;
      _lastRectCenter = null;
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
    final prev = _container.value?.rect ?? originC.rect;

    // Per-frame delta: each incremental movement extends the container in that direction.
    final lastCenter = _lastRectCenter ?? _origin.rect.center;
    _lastRectCenter = rect.center;
    final d = rect.center - lastCenter;
    final grown = Rect.fromLTRB(
      prev.left + (d.dx < 0 ? d.dx : 0),
      prev.top + (d.dy < 0 ? d.dy : 0),
      prev.right + (d.dx > 0 ? d.dx : 0),
      prev.bottom + (d.dy > 0 ? d.dy : 0),
    );

    // Also include origin shifted by total delta — covers scale cases where the active item
    // extends beyond the grown rect even though frame-to-frame delta is small.
    final totalDelta = rect.center - _origin.rect.center;
    final shifted = originC.rect.expandToInclude(originC.rect.shift(totalDelta));

    // On dismiss, animate from the captured start container back to the origin container using
    // the same controller as the rect dismiss, so container and item converge together.
    final Rect baseline;
    if (_dismissing && _dismissStartContainer != null) {
      baseline = Rect.lerp(_dismissStartContainer!, originC.rect, _width.value)!;
    } else {
      baseline = grown.expandToInclude(shifted);
    }

    // Clamp within display container.
    final clamped = Rect.fromLTRB(
      baseline.left.clamp(displayC.rect.left, displayC.rect.right),
      baseline.top.clamp(displayC.rect.top, displayC.rect.bottom),
      baseline.right.clamp(displayC.rect.left, displayC.rect.right),
      baseline.bottom.clamp(displayC.rect.top, displayC.rect.bottom),
    );

    // Lerp edges toward display as progress grows.
    final computed = Rect.fromLTRB(
      lerpDouble(clamped.left, displayC.rect.left, p)!,
      lerpDouble(clamped.top, displayC.rect.top, p)!,
      lerpDouble(clamped.right, displayC.rect.right, p)!,
      lerpDouble(clamped.bottom, displayC.rect.bottom, p)!,
    );
    final containerBr = BorderRadius.lerp(originC.borderRadius, displayC.borderRadius, p)!;

    _container.value = OriginRect(rect: computed, borderRadius: containerBr);
  }

  void reset() {
    setRect(.zero);
    _startRect = .zero;
    _totalDelta = .zero;
    _active = null;
    _container.value = null;
    _lastRectCenter = null;
    _setWidget(null);
    _rotation.value = null;
    _setPerspective(null);
    _setBackgroundColor(null);
    _setGestureBuilder(null);
    _setDisplayConfig(null);
    _setOriginConfig();
    _setOnEnd(null);
    _setTag(null);
    _setLocked(true);
    _setDismissing(false);
    if (_interacting) setState(() => _interacting = false);
    _crop.value = .zero;
    _lastCrop = null;
    _cropDrag = false;
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
    try {
      await _effect.forward();
      await _effect.reverse();
    } finally {
      curved.removeListener(update);
      curved.dispose();
      _rotation.value = null;
      reset();
    }
  }

  Future<void> dismiss({Object? tag, Object? except}) async {
    if (tag != null) {
      if (_sends.containsKey(tag)) _setTagState(tag, .returning);
      return;
    }
    for (final tag in _sends.keys) {
      if (tag == except) continue;
      _setTagState(tag, .returning);
    }
    _setDismissing(true);
    _setOpeningOrDismissing(true);
    try {
      // Smart duration: time the dismiss to the actual trajectory length
      // (current → origin), not to the off-base offset. An at-base dismiss
      // is the reference (1× [_defaultDuration]); a rect already close to
      // origin uses less time, and a rect panned/scaled far from origin
      // uses more. Clamped to 0.3× / 2× so neither extreme feels jarring.
      final base = _display.rect.baseRect(_aspectRatio);
      final origin = _origin.rect;
      final ref = math.max(
        (base.center - origin.center).distance,
        (base.width - origin.width).abs(),
      );
      final actual = math.max(
        (_rect.value.center - origin.center).distance,
        (_rect.value.width - origin.width).abs(),
      );
      final ratio = ref > 0 ? (actual / ref).clamp(0.3, 2.0) : 1.0;
      final ms = (_defaultDuration.inMilliseconds * ratio).round().clamp(200, 1000);
      await animateRect(
        to: _origin.rect,
        duration: Duration(milliseconds: ms),
        curve: Curves.easeOut,
      );
      await _onEnd?.call();
    } finally {
      _setOpeningOrDismissing(false);
      reset();
    }
  }

  Future<void> animateToBase() async {
    _setOpeningOrDismissing(true);
    try {
      await animateRect(to: _display.rect.baseRect(_aspectRatio), curve: Curves.easeOut);
    } finally {
      _setOpeningOrDismissing(false);
    }
    _setLocked(false);
  }

  void setRect(Rect rect) {
    _centerXTween.begin = _centerXTween.end = rect.center.dx;
    _centerYTween.begin = _centerYTween.end = rect.center.dy;
    _widthTween.begin = _widthTween.end = rect.width;
    _heightTween.begin = _heightTween.end = rect.height;
    _rect.value = rect;
  }

  void _updateRect() {
    final w = _widthTween.evaluate(_width);
    final h = _heightTween.evaluate(_width);
    if (_releaseDecomposed) {
      // Decomposed mode: X/Y tweens store *offsets* relative to the
      // proportional position. Displayed center = proportional(W) + offset.
      // Holds the display-center invariant for the no-offset case at every
      // frame, regardless of curve / duration mismatch between axes.
      final scaleRatio =
          _releaseInitialWidth == 0 ? 1.0 : w / _releaseInitialWidth;
      final xProp = _releaseDisplayCenter.dx
          + (_releaseInitialX - _releaseDisplayCenter.dx) * scaleRatio;
      final yProp = _releaseDisplayCenter.dy
          + (_releaseInitialY - _releaseDisplayCenter.dy) * scaleRatio;
      final xOffset = _centerXTween.evaluate(_centerX);
      final yOffset = _centerYTween.evaluate(_centerY);
      _rect.value = Rect.fromCenter(
        center: Offset(xProp + xOffset, yProp + yOffset),
        width: w,
        height: h,
      );
      return;
    }
    final cx = _centerXTween.evaluate(_centerX);
    final cy = _centerYTween.evaluate(_centerY);
    _rect.value = Rect.fromCenter(
      center: Offset(cx, cy),
      width: w,
      height: h,
    );
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
    // In decomposed-release mode the tween stores an *offset* relative to
    // the proportional position (which scale drives), not an absolute X.
    // Seed from the tween's current evaluated value so multi-phase chains
    // pick up where the previous phase left off.
    _centerXTween.begin = _releaseDecomposed
        ? _centerXTween.evaluate(_centerX)
        : _rect.value.center.dx;
    _centerXTween.end = to;
    _safeReset(_centerX);
    return _centerX.animateTo(1, duration: duration, curve: curve);
  }

  Future<void> animateCenterY({required double to, Duration? duration, Curve curve = Curves.easeIn}) {
    _centerYTween.begin = _releaseDecomposed
        ? _centerYTween.evaluate(_centerY)
        : _rect.value.center.dy;
    _centerYTween.end = to;
    _safeReset(_centerY);
    return _centerY.animateTo(1, duration: duration, curve: curve);
  }

  /// Animates the rect's width to [to]. If [height] is provided, animates
  /// height in lockstep on the same controller (so duration / curve are
  /// shared by construction); otherwise the height tween targets
  /// `to / _aspectRatio` to preserve the existing aspect-derived height
  /// behavior.
  Future<void> animateWidth({
    required double to,
    double? height,
    Duration? duration,
    Curve curve = Curves.easeIn,
  }) {
    _widthTween.begin = _rect.value.width;
    _widthTween.end = to;
    _heightTween.begin = _rect.value.height;
    _heightTween.end = height ?? to / _aspectRatio;
    _safeReset(_width);
    return _width.animateTo(1, duration: duration, curve: curve);
  }

  Future<void> animateRect({required Rect to, Duration? duration, Curve curve = Curves.easeIn}) {
    return Future.wait([
      animateCenterX(to: to.center.dx, duration: duration, curve: curve),
      animateCenterY(to: to.center.dy, duration: duration, curve: curve),
      animateWidth(to: to.width, height: to.height, duration: duration, curve: curve),
    ]);
  }

  /// Enters decomposed-release mode (see [_releaseDecomposed]). Captures the
  /// initial rect / display state and resets the X/Y tweens to zero offset,
  /// the width tween to current width. Callers are responsible for pairing
  /// this with [_clearReleaseDecomposed] after the release completes.
  void _setReleaseDecomposed({
    required double initialX,
    required double initialY,
    required double initialWidth,
    required Offset displayCenter,
  }) {
    _releaseInitialX = initialX;
    _releaseInitialY = initialY;
    _releaseInitialWidth = initialWidth;
    _releaseDisplayCenter = displayCenter;
    _centerXTween.begin = 0;
    _centerXTween.end = 0;
    _centerYTween.begin = 0;
    _centerYTween.end = 0;
    _widthTween.begin = initialWidth;
    _widthTween.end = initialWidth;
    _heightTween.begin = _rect.value.height;
    _heightTween.end = _rect.value.height;
    _releaseDecomposed = true;
  }

  void _clearReleaseDecomposed() {
    _releaseDecomposed = false;
  }

  // --- Registry ---

  void _register(Object tag, OriginEntry entry) {
    _registry[tag] = entry;
  }

  void _unregister(Object tag, OriginEntry entry) {
    if (_registry[tag] == entry) {
      _registry.remove(tag);
    }
  }

  OriginRect? _measureEntry(Object tag) {
    return _registry[tag]?.measure?.call();
  }

  Widget? _captureEntry(Object tag) {
    return _registry[tag]?.capture?.call();
  }

  Future<void> _openEntry(Object tag) {
    return _registry[tag]?.open?.call() ?? Future.value();
  }

  Future<void> _sendEntry(Object tag, Rect Function(Rect) send, {VoidCallback? onEnd}) {
    return _registry[tag]?.send?.call(send, onEnd: onEnd) ?? Future.value();
  }

  // --- Sends ---

  final _sends = <Object, ({Object target, bool park, Key key})>{};

  void _displace(Object tag, {required Object target, bool park = true}) {
    for (final t in _sends.keys) {
      if (t == tag) continue;
      final state = _tagStates[t];
      if (state case .sending || .parked) {
        _setTagState(t, .returning);
      }
    }
    _sends[tag] = (target: target, park: park, key: UniqueKey());
    _setTagState(tag, .sending);
  }

  void _releaseSend(Object tag) {
    _sends.remove(tag);
    _clearTagState(tag);
  }

  void _removeSend(Object tag) {
    _sends.remove(tag);
    _clearTagState(tag);
  }

  @override
  void dispose() {
    _rect.dispose();
    _crop.dispose();
    _cropAnim.dispose();
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
      crop: _crop,
      interacting: _interacting,
      openingOrDismissing: _openingOrDismissing,
      rotation: _rotation,
      originToBaseProgress: _originToBaseProgress,
      widget: _widget,
      setWidget: _setWidget,
      perspective: _perspective,
      backgroundColor: _backgroundColor,
      gestureBuilder: _gestureBuilder,
      onRelease: widget.onRelease,
      overrides: widget.overrides,
      dragHybridFromStage: widget.dragHybridFromStage,
      scaleHybridFromStage: widget.scaleHybridFromStage,
      originGesture: () => _originGesture,
      setOriginGesture: _setOriginGesture,
      setOriginPointers: _setOriginPointers,
      displayConfig: () => _displayConfig,
      isHybridDriving: () => _isHybridDriving,
      stagePointerCount: () => _stageRecognizer?.pointerPositions.length ?? 0,
      hybridReleaseVelocity: _hybridReleaseVelocity,
      scaleVelocityCancel: () => widget.scaleVelocityCancel,
      onEnd: _onEnd,
      tag: _tag,
      locked: _locked,
      dismissing: _dismissing,
      tagStates: {..._tagStates},
      container: _container,
      setOrigin: _setOrigin,
      setOriginContainer: _setOriginContainer,
      setDisplay: _setDisplay,
      setDisplayContainer: _setDisplayContainer,
      setAspectRatio: _setAspectRatio,
      setPerspective: _setPerspective,
      setBackgroundColor: _setBackgroundColor,
      setGestureBuilder: _setGestureBuilder,
      setDisplayConfig: _setDisplayConfig,
      setOriginConfig: _setOriginConfig,
      setMode: _setMode,
      setOnEnd: _setOnEnd,
      setTag: _setTag,
      setLocked: _setLocked,
      setRect: setRect,
      animateRect: animateRect,
      animateCrop: animateCrop,
      animateCenterX: animateCenterX,
      animateCenterY: animateCenterY,
      animateWidth: animateWidth,
      setReleaseDecomposed: _setReleaseDecomposed,
      clearReleaseDecomposed: _clearReleaseDecomposed,
      reset: reset,
      animateToBase: animateToBase,
      dismiss: dismiss,
      displace: _displace,
      releaseSend: _releaseSend,
      runEffect: runEffect,
      register: _register,
      unregister: _unregister,
      measureEntry: _measureEntry,
      captureEntry: _captureEntry,
      openEntry: _openEntry,
      sendEntry: _sendEntry,
      child: Stack(
        fit: .expand,
        children: [
          widget.child,
          const _AbsorbLayer(),
          for (final MapEntry(key: tag, value: info) in _sends.entries)
            _SendLayer(
              key: info.key,
              tag: tag,
              target: info.target,
              returning: _tagStates[tag] == .returning,
              onArrived: info.park ? () => _setTagState(tag, .parked) : () => _removeSend(tag),
              onDone: () => _removeSend(tag),
            ),
          const StageOverlay(),
          Builder(builder: (context) {
            // Stage's gesture detector is active either:
            //  - in displayed-state (existing condition), or
            //  - during a hybrid feed-state gesture so new pointers landing
            //    on stage join the Origin's gesture per its hybrid mode.
            final og = _originGesture;
            final hybridActive = og != null && _resolveHybrid(og) != null;
            final displayed = Stage.hasWidgetOf(context) && !_locked;
            final active = displayed || hybridActive;
            // Always translucent so [GestureDetector]s inside the captured
            // widget can win in the arena for taps on their own area
            // (deepest wins). [_AbsorbLayer] above [widget.child] already
            // blocks the underlying tree from receiving pointers while the
            // stage is displayed — Stage's detector doesn't need to absorb
            // on top of that.
            return RawGestureDetector(
              behavior: .translucent,
              gestures: {
                if (active)
                  StageScaleRecognizer: GestureRecognizerFactoryWithHandlers<StageScaleRecognizer>(
                    StageScaleRecognizer.new,
                    (r) {
                      _stageRecognizer = r;
                      r.drag = _effectiveDrag;
                      r.scale = _effectiveScale;
                      r.onStart = _onScaleStart;
                      r.onUpdate = _onScaleUpdate;
                      r.onEnd = (details) => _onScaleEnd(details, context);
                      r.onPointersChanged = _onHybridPointersChanged;
                    },
                  ),
                // Tap and double-tap only run in pure displayed state —
                // hybrid is about pointer-merging during an Origin-driven
                // gesture, not a separate tap surface. Both are opt-in:
                // without an explicit handler the recognizer isn't
                // registered, so it can't claim victory over a deeper
                // [GestureDetector] inside the captured widget tree
                // (Flutter's arena sweeps to the first-added recognizer).
                if (displayed
                    && (_displayConfig?.onTap ?? widget.onTap) != null)
                  TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                    TapGestureRecognizer.new,
                    (r) => r.onTapUp = (d) {
                      _tapLocal = d.localPosition;
                      _tapGlobal = d.globalPosition;
                      _onTap();
                    },
                  ),
                // DoubleTap is opt-in — only registered when a handler is
                // explicitly wired in. Without it, the [TapGestureRecognizer]
                // resolves on the up event instead of waiting `kDoubleTapTimeout`.
                if (displayed
                    && (_displayConfig?.onDoubleTap ?? widget.onDoubleTap) != null)
                  DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
                    DoubleTapGestureRecognizer.new,
                    (r) {
                      r.onDoubleTapDown = (d) {
                        _doubleTapLocal = d.localPosition;
                        _doubleTapGlobal = d.globalPosition;
                      };
                      r.onDoubleTap = _onDoubleTap;
                    },
                  ),
              },
            );
          }),
          // Overlay slot is last → painted on top, hit-tested first. Cascade:
          // active DisplayConfig.overlay > Origin.overlay > Stage.overlay.
          // Tools that own gestures (e.g. Cropper) live here so their
          // detectors take priority over Stage's recognizer; 2-finger
          // gestures fall through to Stage via translucent hit-test.
          if ((_displayConfig?.overlay ?? _originOverlay ?? widget.overlay)
              case final overlay?)
            Builder(builder: overlay),
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
    required this.crop,
    required this.interacting,
    required this.openingOrDismissing,
    required this.rotation,
    required this.originToBaseProgress,
    required this.widget,
    required this.setWidget,
    required this.perspective,
    required this.backgroundColor,
    required this.gestureBuilder,
    required this.onRelease,
    required this.overrides,
    required this.dragHybridFromStage,
    required this.scaleHybridFromStage,
    required this.originGesture,
    required this.setOriginGesture,
    required this.setOriginPointers,
    required this.displayConfig,
    required this.isHybridDriving,
    required this.stagePointerCount,
    required this.hybridReleaseVelocity,
    required this.scaleVelocityCancel,
    required this.onEnd,
    required this.tag,
    required this.locked,
    required this.dismissing,
    required this.tagStates,
    required this.container,
    required this.setOrigin,
    required this.setOriginContainer,
    required this.setDisplay,
    required this.setDisplayContainer,
    required this.setAspectRatio,
    required this.setPerspective,
    required this.setBackgroundColor,
    required this.setGestureBuilder,
    required this.setDisplayConfig,
    required this.setOriginConfig,
    required this.setMode,
    required this.setOnEnd,
    required this.setTag,
    required this.setLocked,
    required this.setRect,
    required this.animateRect,
    required this.animateCrop,
    required this.animateCenterX,
    required this.animateCenterY,
    required this.animateWidth,
    required this.setReleaseDecomposed,
    required this.clearReleaseDecomposed,
    required this.reset,
    required this.animateToBase,
    required this.dismiss,
    required this.displace,
    required this.releaseSend,
    required this.runEffect,
    required this.register,
    required this.unregister,
    required this.measureEntry,
    required this.captureEntry,
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
  /// Live crop rect, seeded from [CropConfig.initialRect] when a crop mode
  /// activates and mutated by Stage's recognizer (1-pointer drag inside the
  /// rect) or the [Cropper] widget's handles. Consumers read it (e.g. on
  /// apply) via `Stage.of(context).crop.value`. Reset to [Rect.zero] when
  /// no crop mode is active.
  final ValueNotifier<Rect> crop;
  /// True while Stage's recognizer holds &gt; 0 pointers. A coarse `x vs 0
  /// pointers` signal — read via [Stage.isInteractingOf] for tag-aware access
  /// (which folds in a check that the queried tag is the active stage tag).
  /// Independent of which gesture committed in arena.
  final bool interacting;

  /// True during an open ([Stage.animateToBase]) or dismiss ([Stage.dismiss])
  /// animation. Release rubber-back / settle paths don't touch this. Used
  /// by crop-mode chrome to fade only during real open/dismiss and stay
  /// solid through interaction + settle.
  final bool openingOrDismissing;
  final ValueNotifier<Rotation?> rotation;
  final ValueNotifier<double> originToBaseProgress;
  final Widget? widget;

  final double? perspective;
  final Color? backgroundColor;
  final StageBuilder? gestureBuilder;
  final OnRelease? onRelease;
  final Overrides? overrides;

  /// Stage-level cascade fallback for hybrid pointer routing. Resolved last
  /// before [DragHybrid.lock] / [ScaleHybrid.lock].
  final DragHybrid? dragHybridFromStage;
  final ScaleHybrid? scaleHybridFromStage;

  /// Live reader: currently-in-flight Origin gesture (drag or scale on an
  /// un-displayed item), with its hybrid mode partially resolved up to
  /// Origin's level. Stage uses this to decide what to do with new pointers
  /// landing in stage-area regions while the Origin is gesturing. Null when
  /// no Origin is gesturing.
  ///
  /// Exposed as a function (not a value) so callers reading it from a cached
  /// [StageData] reference still see the latest state.
  final OriginGesture? Function() originGesture;
  final ValueSetter<OriginGesture?> setOriginGesture;

  /// Origin forwards its recognizer's [pointerPositions] here whenever they
  /// change. Stage merges with its own recognizer's positions to drive the
  /// hybrid gesture math.
  final ValueSetter<Map<int, Offset>> setOriginPointers;

  /// Live reader: the currently-active [DisplayConfig] (the displayed
  /// origin's, merged with any active mode override). Null when no origin
  /// is displayed. Tools (e.g., [Cropper]) read this to check whether they
  /// should be active in the current state.
  final DisplayConfig? Function() displayConfig;

  /// Live reader: true while Stage's hybrid merger is driving the rect.
  /// Origin reads this to silence its own rect manipulation while Stage is
  /// in control.
  final bool Function() isHybridDriving;

  /// Live reader: count of stage's recognizer pointers. Origin reads this to
  /// decide whether to defer release until stage's pointers also leave.
  final int Function() stagePointerCount;

  /// Live reader: the hybrid merger's combined release velocity computed
  /// from its last two focal/spread samples. Returns null if the merger
  /// didn't run recently — callers should fall back to the firing
  /// recognizer's own `ScaleEndDetails.velocity`.
  final ({Velocity velocity, double scaleVelocity})? Function()
      hybridReleaseVelocity;

  /// Live reader: Stage-level `scaleVelocityCancel` (raw nullable), the
  /// bottom of the cascade before the package default of `0.5`. Callers
  /// resolve `gesture > Origin/DisplayConfig > this > 0.5`.
  final double? Function() scaleVelocityCancel;

  final FutureOr<void> Function()? onEnd;
  final Object? tag;
  final bool locked;
  final bool dismissing;
  final Map<Object, TagState> tagStates;
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
  final ValueSetter<DisplayConfig?> setDisplayConfig;

  /// Registers the active origin's mode lookup so [setMode] can resolve a
  /// key into a merged [DisplayConfig]. Origin calls this in its `_setup`.
  /// Also carries Origin-level cascade fallbacks (e.g. `overlay`, display
  /// rect overrides) that Stage merges with the active DisplayConfig.
  final void Function({
    DisplayConfig? defaults,
    Map<Object, DisplayConfig>? modes,
    WidgetBuilder? overlay,
    OriginRect? display,
    OriginRect? displayContainer,
    OriginRect? screen,
    StageBuilder? builder,
  }) setOriginConfig;

  /// Switches the active mode for the currently-displayed origin. Looks
  /// the key up in the origin's modes map (registered via
  /// [setOriginConfig]), merges with the origin's default config, and
  /// swaps [displayConfig]. Passing `null` returns to the default config.
  ///
  /// Useful for letting consumer-side UI (e.g., an appbar's Back button)
  /// exit a tool mode without dismissing the displayed origin.
  final ValueSetter<Object?> setMode;
  final ValueSetter<FutureOr<void> Function()?> setOnEnd;
  final ValueSetter<Object?> setTag;
  final ValueSetter<bool> setLocked;
  final ValueSetter<Rect> setRect;
  final AnimateRect animateRect;
  /// Animates [crop] from its current value to the given rect. Used for
  /// reset transitions and other places that want a smooth crop-rect change
  /// instead of an instant `stage.crop.value = newRect` assignment.
  final AnimateRect animateCrop;
  final Future<void> Function({required double to, Duration? duration, Curve curve}) animateCenterX;
  final Future<void> Function({required double to, Duration? duration, Curve curve}) animateCenterY;
  final Future<void> Function({
    required double to,
    double? height,
    Duration? duration,
    Curve curve,
  }) animateWidth;
  /// Enters decomposed-release mode: while active, the X/Y tweens are
  /// interpreted as *offsets* from the proportional scale-driven position.
  /// Lets the three axes animate with independent curves/durations while
  /// the displayed center stays consistent mid-frame.
  final void Function({
    required double initialX,
    required double initialY,
    required double initialWidth,
    required Offset displayCenter,
  }) setReleaseDecomposed;
  final VoidCallback clearReleaseDecomposed;
  final VoidCallback reset;
  final Future<void> Function() animateToBase;
  final Future<void> Function({Object? tag, Object? except}) dismiss;
  final void Function(Object tag, {required Object target, bool park}) displace;
  final void Function(Object tag) releaseSend;
  final Future<void> Function({
    double? rotateX,
    double? rotateY,
    double? rotateZ,
    double? perspective,
    Duration duration,
    Curve curve,
  }) runEffect;

  final void Function(Object tag, OriginEntry entry) register;
  final void Function(Object tag, OriginEntry entry) unregister;
  final OriginRect? Function(Object tag) measureEntry;
  final Widget? Function(Object tag) captureEntry;
  final Future<void> Function(Object tag) openEntry;
  final Future<void> Function(Object tag, Rect Function(Rect), {VoidCallback? onEnd}) sendEntry;

  Future<void> release(Release plan) async {
    final scaleHasMotion =
        plan.scale.decay.isNotEmpty || plan.scale.settle != null;
    if (!scaleHasMotion) {
      // No scale animation → axes are independent.
      setRect(rect.value);
      await Future.wait([
        _runAxis(plan.x, animateCenterX),
        _runAxis(plan.y, animateCenterY),
        _runAxis(plan.scale, animateWidth),
      ]);
      return;
    }
    // Decomposed-release: scale drives the proportional center; X/Y add a
    // translation offset on top. Each axis keeps its own curve/duration and
    // the displayed center stays consistent mid-frame.
    final initialRect = rect.value;
    final wFinal = plan.scale.settle?.to ?? plan.scale.decay.last.to;
    final scaleRatio = initialRect.width == 0 ? 1.0 : wFinal / initialRect.width;
    final xPropFinal = display.rect.center.dx
        + (initialRect.center.dx - display.rect.center.dx) * scaleRatio;
    final yPropFinal = display.rect.center.dy
        + (initialRect.center.dy - display.rect.center.dy) * scaleRatio;
    final xAbsTarget = plan.x.settle?.to
        ?? (plan.x.decay.isNotEmpty ? plan.x.decay.last.to : initialRect.center.dx);
    final yAbsTarget = plan.y.settle?.to
        ?? (plan.y.decay.isNotEmpty ? plan.y.decay.last.to : initialRect.center.dy);
    final xOffsetTarget = xAbsTarget - xPropFinal;
    final yOffsetTarget = yAbsTarget - yPropFinal;

    setReleaseDecomposed(
      initialX: initialRect.center.dx,
      initialY: initialRect.center.dy,
      initialWidth: initialRect.width,
      displayCenter: display.rect.center,
    );
    try {
      await Future.wait([
        animateCenterX(
          to: xOffsetTarget,
          duration: plan.x.settle?.duration,
          curve: plan.x.settle?.curve ?? Curves.easeOut,
        ),
        animateCenterY(
          to: yOffsetTarget,
          duration: plan.y.settle?.duration,
          curve: plan.y.settle?.curve ?? Curves.easeOut,
        ),
        _runAxis(plan.scale, animateWidth),
      ]);
    } finally {
      clearReleaseDecomposed();
    }
  }

  Future<void> run({
    List<AxisFling>? x,
    List<AxisFling>? y,
    List<AxisFling>? scale,
  }) {
    setRect(rect.value);
    return Future.wait([
      if (x != null) _runFlings(x, animateCenterX),
      if (y != null) _runFlings(y, animateCenterY),
      if (scale != null) _runFlings(scale, animateWidth),
    ]);
  }

  Future<void> backToBase() =>
      animateRect(to: display.rect.baseRect(aspectRatio), curve: Curves.easeOut);

  Future<void> backToOrigin(ReleaseContext data, {Object? except}) async {
    await release(Release.toHalt(data));
    await dismiss(except: except);
  }

  Future<void> _runAxis(
    AxisRelease axis,
    Future<void> Function({
      required double to,
      Duration? duration,
      Curve curve,
    }) animate,
  ) async {
    for (final f in axis.decay) {
      await animate(to: f.to, duration: f.duration, curve: f.curve);
    }
    final s = axis.settle;
    if (s != null) {
      await animate(to: s.to, duration: s.duration, curve: s.curve);
    }
  }

  Future<void> _runFlings(
    List<AxisFling> flings,
    Future<void> Function({
      required double to,
      Duration? duration,
      Curve curve,
    }) animate,
  ) async {
    for (final f in flings) {
      await animate(to: f.to, duration: f.duration, curve: f.curve);
    }
  }

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
        case _interactingAspect:
          if (interacting != oldWidget.interacting) return true;
        case (#tag, final Object t):
          final was = oldWidget.tag == t || oldWidget.tagStates.containsKey(t);
          final now = tag == t || tagStates.containsKey(t);
          if (was != now) return true;
        case (#active, final Object t):
          if ((tag == t) != (oldWidget.tag == t)) return true;
        case (#state, final Object t):
          if (tagStates[t] != oldWidget.tagStates[t]) return true;
        case (#interacting, final Object t):
          final was = oldWidget.tag == t && oldWidget.interacting;
          final now = tag == t && interacting;
          if (was != now) return true;
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

class _SendLayer extends StatefulWidget {
  const _SendLayer({
    super.key,
    required this.tag,
    required this.target,
    required this.returning,
    required this.onArrived,
    required this.onDone,
  });

  final Object tag;
  final Object target;
  final bool returning;
  final VoidCallback onArrived;
  final VoidCallback onDone;

  @override
  State<_SendLayer> createState() => _SendLayerState();
}

class _SendLayerState extends State<_SendLayer> with SingleTickerProviderStateMixin {
  late final StageData _data;
  late final Widget _child;
  late final Rect _homeRect;
  late final BorderRadius _borderRadius;
  late final AnimationController _controller;
  late final ValueNotifier<Rect> _rect;
  final _cxTween = Tween<double>(begin: 0, end: 0);
  final _cyTween = Tween<double>(begin: 0, end: 0);
  final _wTween = Tween<double>(begin: 0, end: 0);

  double get _aspectRatio => _homeRect.width / _homeRect.height;

  @override
  void initState() {
    super.initState();
    _data = context.getInheritedWidgetOfExactType<StageData>()!;
    _child = _data.captureEntry(widget.tag)!;
    final origin = _data.measureEntry(widget.tag)!;
    _homeRect = origin.rect;
    _borderRadius = origin.borderRadius;
    _rect = ValueNotifier(_homeRect);
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 300))
      ..addListener(_updateRect);
    _sendToTarget();
  }

  @override
  void didUpdateWidget(_SendLayer old) {
    super.didUpdateWidget(old);
    if (widget.returning && !old.returning) _animateHome();
  }

  Future<void> _sendToTarget() async {
    final targetRect = _data.measureEntry(widget.target)!.rect;
    await _animateTo(targetRect);
    if (!mounted) return;
    widget.onArrived();
  }

  Future<void> _animateHome() async {
    final homeRect = _data.measureEntry(widget.tag)?.rect ?? _homeRect;
    await _animateTo(homeRect);
    if (!mounted) return;
    widget.onDone();
  }

  Future<void> _animateTo(Rect to) {
    _cxTween
      ..begin = _rect.value.center.dx
      ..end = to.center.dx;
    _cyTween
      ..begin = _rect.value.center.dy
      ..end = to.center.dy;
    _wTween
      ..begin = _rect.value.width
      ..end = to.width;
    _controller.reset();
    return _controller.animateTo(1, curve: Curves.easeOut);
  }

  void _updateRect() {
    final cx = _cxTween.evaluate(_controller);
    final cy = _cyTween.evaluate(_controller);
    final w = _wTween.evaluate(_controller);
    _rect.value = Rect.fromCenter(center: Offset(cx, cy), width: w, height: w / _aspectRatio);
  }

  @override
  void dispose() {
    _controller.dispose();
    _rect.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = ValueListenableBuilder<Rect>(
      valueListenable: _rect,
      builder: (context, rect, child) {
        return Stack(
          fit: .expand,
          children: [
            Positioned.fromRect(
              rect: rect,
              child: ClipRRect(borderRadius: _borderRadius, child: child),
            ),
          ],
        );
      },
      child: _child,
    );
    final container = _data.originContainer ?? _data.displayContainer;
    if (container != null) {
      child = ClipPath(
        clipper: _ContainerClipper(container.rect, container.borderRadius),
        child: child,
      );
    }
    return child;
  }
}

class _ContainerClipper extends CustomClipper<Path> {
  _ContainerClipper(this.rect, this.borderRadius);

  final Rect rect;
  final BorderRadius borderRadius;

  @override
  Path getClip(Size size) => Path()..addRRect(borderRadius.toRRect(rect));

  @override
  bool shouldReclip(_ContainerClipper old) => old.rect != rect || old.borderRadius != borderRadius;
}
