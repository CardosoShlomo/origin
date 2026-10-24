import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:regent/regent.dart';
import 'crop_image.dart';
import 'ext.dart';
import 'rect_ext.dart';
import 'gestures.dart';
import 'origin_rect.dart';
import 'physics.dart';
import 'recognizer.dart';
import 'release.dart';
import 'stage_overlay.dart';
import 'stage_rows.dart';

class OriginEntry {
  OriginRect? Function()? measure;
  Widget Function()? capture;
  Future<void> Function()? open;
  Future<void> Function(Rect Function(Rect), {VoidCallback? onEnd})? send;
}

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
  /// inspect `displayConfig` and decide what to render. The builder
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

  static bool isDismissingOf(BuildContext context) {
    return InheritedModel.inheritFrom<StageData>(context, aspect: _dismissingAspect)!.dismissing;
  }

  @override
  State<Stage> createState() => _StageState();
}

class _StageState extends State<Stage> with TickerProviderStateMixin {
  /// The stage's state: facts fold here, and every read below comes from it.
  final _ledger = Ledger.root(stageRows);

  StageScene get _scene => _ledger.at(stageScene).state;
  StageStance get _stance => _ledger.at(stageStance).state;
  IdentifiableMap<Object, StageSend> get _sends => _ledger.at(stageSends).entities;
  IdentifiableMap<Object, SendPhase> get _phases => _ledger.at(sendPhases).entities;
  Map<Object, TagState> get _tagStates => {
        for (final p in _phases.values) p.tag: p.state,
      };

  bool _disposed = false;

  /// States [msg] and rebuilds when it changed anything. Facts stated while
  /// the tree is locked (an Origin disposing mid-gesture) rebuild after the
  /// frame.
  void _fact(StageMsg msg) {
    if (_disposed) return;
    final scene = _scene;
    final stance = _stance;
    final sends = _sends;
    final phases = _phases;
    _ledger.dispatch(msg);
    if (identical(scene, _scene) &&
        identical(stance, _stance) &&
        identical(sends, _sends) &&
        identical(phases, _phases)) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase == .persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    if (mounted) setState(() {});
  }

  int _epoch = 0;

  /// The latest session flight taken. The ledger stops folding when the
  /// stage leaves the tree; a flight still landing then asks this instead.
  Flight? _sessionFlight;

  Flight _takeFlight(FlightKind kind) {
    final flight = Flight(kind, ++_epoch);
    if (!flight.isMode) _sessionFlight = flight;
    _fact(FlightTook(flight));
    _syncTransitionFlags();
    return flight;
  }

  bool _isCurrent(Flight flight) =>
      _disposed ? _sessionFlight == flight : _stance.flight == flight;

  /// Lands [flight]. A superseded flight's landing is dropped by the ledger;
  /// a dismiss or effect that lands ends the session and clears the stage.
  void _land(Flight flight) {
    final before = _stance;
    _fact(FlightLanded(flight));
    if (identical(before, _stance)) return;
    _syncTransitionFlags();
    if (flight.kind case .dismissing || .effect) _clearGeometry();
  }

  final _rect = ValueNotifier(Rect.zero);

  /// The active crop rect, owned by Stage just like [_rect]. Initialized
  /// from [CropConfig.initialRect] when a crop mode activates; mutated by
  /// the recognizer (1-pointer drag inside the rect) and by the [Cropper]
  /// widget's handles. Consumers read it via [StageData.crop] when they
  /// need the result. Reset to [Rect.zero] on dismiss.
  final _crop = ValueNotifier<Rect>(.zero);

  /// True while the active gesture is a crop-rect drag (single pointer that
  /// landed inside the crop rect). Flipped in [_onScaleStart], read in
  /// [_onScaleUpdate], cleared in [_onScaleEnd] or when a second pointer
  /// arrives (so pinch always takes over to image scale).
  bool _cropDrag = false;

  final _originToBaseProgress = ValueNotifier(0.0);
  Offset? _lastRectCenter;
  Rect? _dismissStartContainer;
  final _registry = <Object, OriginEntry>{};
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
    _centerX = AnimationController(vsync: this, duration: _defaultDuration)
      ..addListener(_updateRect)
      ..addListener(_updateTransitionProgress);
    _centerY = AnimationController(vsync: this, duration: _defaultDuration)
      ..addListener(_updateRect)
      ..addListener(_updateTransitionProgress);
    _width = AnimationController(vsync: this, duration: _defaultDuration)
      ..addListener(_updateRect)
      ..addListener(_updateTransitionProgress);
    _effect = AnimationController(vsync: this, duration: _defaultDuration);
    _cropAnim = AnimationController(vsync: this, duration: _defaultDuration)
      ..addListener(_updateCrop)
      ..addListener(_updateTransitionProgress);
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

  /// Runs [controller] to 1. The future completes when the animation ends,
  /// whether it got there or something stopped it (a newer animation, a
  /// touch, the stage leaving), so code awaiting it always goes on.
  Future<void> _drive(AnimationController controller, Duration? duration, Curve curve) {
    if (_disposed) return Future.value();
    _safeReset(controller);
    return controller
        .animateTo(1, duration: duration, curve: curve)
        .orCancel
        .catchError((_) {}, test: (e) => e is TickerCanceled);
  }

  /// Animates [crop] from its current value to [to]. Mirrors the rect-animation
  /// path used for [_rect] but for the crop rect — used for the reset action
  /// (snap-back to [CropConfig.initialRect]) and any other place that wants
  /// to programmatically transition the crop rect smoothly instead of
  /// instantly assigning to `stage.crop.value`.
  Future<void> animateCrop({required Rect to, Duration? duration, Curve curve = Curves.easeOut}) {
    _cropTween.begin = _crop.value;
    _cropTween.end = to;
    return _drive(_cropAnim, duration, curve);
  }

  /// Called when a transition flag flips. Snaps progress to 0 (active)
  /// or 1 (inactive) so consumers see a clean 0→1 ramp on each
  /// transition instead of stale values from the last animation.
  /// Controller ticks (via [_updateTransitionProgress]) take over from
  /// there for the duration of the animation.
  void _syncTransitionFlags() {
    if (_disposed) return;
    final v = (_stance.openingOrDismissing || _stance.changingMode) ? 0.0 : 1.0;
    _transitionProgressMin.value = v;
    _transitionProgressMean.value = v;
    _transitionProgressMax.value = v;
  }

  /// Progress 0..1 derived from the four rect/crop controller values
  /// while a real transition is active (`openingOrDismissing ||
  /// changingMode`). Three aggregations — pick whichever fits:
  /// - [_transitionProgressMin]: slowest controller. Hits 1 only when
  ///   *every* animation has finished.
  /// - [_transitionProgressMean]: average across all four. Smooth
  ///   middle-of-the-pack progress.
  /// - [_transitionProgressMax]: fastest controller. Hits 1 as soon
  ///   as *any* animation finishes.
  /// All stay at 1 outside transitions (release/settle don't move them).
  final _transitionProgressMin = ValueNotifier<double>(1.0);
  final _transitionProgressMean = ValueNotifier<double>(1.0);
  final _transitionProgressMax = ValueNotifier<double>(1.0);
  /// Updates the progress notifiers from the four controllers' current
  /// values. Called on every controller tick (via listener). No-op when
  /// no transition is active — idle resets are owned by
  /// [_syncTransitionFlags].
  void _updateTransitionProgress() {
    if (!_stance.openingOrDismissing && !_stance.changingMode) return;
    final values = [
      _centerX.value,
      _centerY.value,
      _width.value,
      _cropAnim.value,
    ];
    _transitionProgressMin.value = values.reduce(math.min);
    _transitionProgressMax.value = values.reduce(math.max);
    _transitionProgressMean.value = values.reduce((a, b) => a + b) / values.length;
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

  DisplayConfig? get _displayConfig => _scene.displayConfig;

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

  /// Swaps the active [DisplayConfig] to the mode-resolved variant and
  /// re-applies any display/displayContainer overrides the new config
  /// carries. Null key = back to the origin's default (no-mode) config.
  ///
  /// Re-uses the same merge semantics as [Origin.modes]: non-null fields
  /// in the mode override the default; null fields inherit.
  void _setMode(Object? key) {
    final before = _scene;
    _fact(ModeSet(key));
    _modeMoved(before);
  }

  /// The geometry a mode change moves: the crop rect it seeds and the rect's
  /// flight to a new display.
  void _modeMoved(StageScene before) {
    final after = _scene;
    // Seed the crop rect when entering a new crop config (by identity) so
    // switching configs (e.g. free → square) re-anchors to the configured
    // initial rect, but in-flight edits within the same config aren't lost.
    //
    // When the display rect ALSO changes (browse → crop), animate the
    // crop rect in parallel with the image rect: start at the initial
    // rect evaluated against the *old* base, end at the initial rect
    // evaluated against the *new* base. Same callback applied to both —
    // so a "biggest square" initialRect grows from old-base shortestSide
    // to new-base shortestSide in sync with the image rect.
    final crop = after.displayConfig?.crop;
    final newBase = after.display.rect.baseRect(after.aspectRatio);
    final displayChanged = after.display.rect != before.display.rect && _rect.value != .zero;
    if (crop != null && !identical(crop, before.displayConfig?.crop)) {
      final endRect = crop.initialRect?.call(newBase) ?? newBase;
      if (displayChanged) {
        final oldBase = before.display.rect.baseRect(after.aspectRatio);
        final startRect = crop.initialRect?.call(oldBase) ?? oldBase;
        _crop.value = startRect;
        animateCrop(to: endRect, curve: Curves.easeOut);
      } else {
        _crop.value = endRect;
      }
    }
    // When the active mode changes the display rect (e.g. crop mode
    // constrains the display to exclude an appbar), animate the live rect
    // to the new base — otherwise the image would jump or sit at a stale
    // position relative to the new container.
    if (displayChanged) {
      final flight = _takeFlight(.changingMode);
      animateRect(to: newBase, curve: Curves.easeOut)
          .whenComplete(() => _land(flight));
    }
  }

  /// An Origin takes the stage: the fact, then the geometry it implies.
  void _take(StageTaken taken) {
    final before = _scene;
    _fact(taken);
    _modeMoved(before);
    setRect(taken.origin.rect);
  }

  /// Stops the rect's own motion (a release settling, a mode change, a zoom
  /// toggle) so a new touch drives it alone. Their futures complete.
  void _stopRectMotion() {
    _motion++;
    _centerX.stop();
    _centerY.stop();
    _width.stop();
    _cropAnim.stop();
    _releaseDecomposed = false;
  }

  void _onScaleStart(ScaleStartDetails details) {
    // Hybrid: merger owns the rect; skip stage's local resolver.
    if (_stance.hybridDriving) return;
    // The touch takes the rect from whatever was still moving it.
    if (_prevPointerCount == 0) _stopRectMotion();
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
    // touching). Promote interacting here, not on pointer-down, so a
    // plain tap never briefly flips it true.
    if (!_stance.interacting) _fact(const InteractionBegan());
    // Hybrid: merger owns the rect; skip stage's local update logic.
    if (_stance.hybridDriving) return;

    // Crop-drag path: hijacked gesture, no resolver, no totalDelta. Move
    // the crop rect by the focal delta (clamped to the image-intersect-
    // display boundary) and shift the image when the crop is pinned to an
    // edge in the drag direction (catch-up capped by overdragMax).
    final cropConfig = _displayConfig?.crop;
    final display = _scene.display;
    final aspectRatio = _scene.aspectRatio;
    if (_cropDrag) {
      if (details.pointerCount > 1) {
        // 2nd finger arrived mid-gesture — exit crop drag, fall into normal
        // scale flow so the pinch zooms the image.
        _cropDrag = false;
      } else if (cropConfig != null) {
        final boundaries = _rect.value.intersect(display.rect);
        final newCrop = _crop.value
            .shift(details.focalPointDelta)
            .cropBoundaries(
              boundaries,
              minAspectRatio: cropConfig.minAspectRatio,
              maxAspectRatio: cropConfig.maxAspectRatio,
            );
        _crop.value = newCrop;
        _rect.value = details.imageRectOnDragCropRect(
          container: display.rect,
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
          final baseRect = display.rect.baseRect(aspectRatio);
          final replacement = override(_rect.value, baseRect);
          if (replacement != null) {
            _active = (start: committed.start, gesture: replacement);
          }
        }

        _lastActive = _active;
        final builder = _active!.gesture.builder;
        if (builder != null) _fact(GestureBuilderSet(builder));
        _startRect = _rect.value;
        _startFocalPoint = details.focalPoint;
        return;
      }

      case DragGesture drag: {
        // For displayed items, the natural rest is the base rect (centered
        // in display), not the thumbnail. axisState's `originRect` is
        // really "the reference rest" — pass base, not the origin's rect.
        final displayRect = display.rect;
        _rect.value = computeDragRect(
          bounds: drag.bounds,
          currentRect: _rect.value,
          originRect: displayRect.baseRect(aspectRatio),
          displayRect: displayRect,
          aspectRatio: aspectRatio,
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
        final originRect = _scene.origin.rect;
        final displayRect = display.rect;
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
        final baseWidth = displayRect.baseWidth(aspectRatio);
        final intendedWidth = _startRect.width * details.scale;
        final dw = intendedWidth - currentRect.width;
        final scaledDw = frictionFromScaleState(
          state: axisStateScale(dw, currentRect.width, baseWidth, scale.shrink, scale.expand),
          shrink: scale.shrink,
          expand: scale.expand,
          delta: dw,
        );
        final newWidth = currentRect.width + scaledDw;
        // Preserve startRect's aspect ratio (not the stage's, which may
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
    if (_stance.interacting) _fact(const InteractionEnded());
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
    final og = _stance.originGesture;
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
        displayRect: _scene.display.rect,
        aspectRatio: _scene.aspectRatio,
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
      // is un-displayed. The display config is null in this state anyway.
      final handler = data.gesture.onRelease
          ?? og.onRelease
          ?? widget.onRelease;
      if (handler != null) {
        handler(context, data);
        return;
      }
      await backToOrigin(data);
      return;
    }

    // Non-hybrid: prefer _active (current commit), fall back to _lastActive
    // (last commit within this lifetime — covers cases where re-resolution
    // after a pointer change didn't commit a new gesture before all fingers
    // lifted).
    final active = _active ?? _lastActive;
    _prevPointerCount = 0;
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
      displayRect: _scene.display.rect,
      aspectRatio: _scene.aspectRatio,
      velocity: details.velocity,
      scaleVelocity: details.scaleVelocity,
      gesture: active.gesture,
    );

    _active = null;
    _lastActive = null;
    _totalDelta = .zero;

    // Cascade: gesture > displayConfig > stage > package default.
    final handler = data.gesture.onRelease ?? _displayConfig?.onRelease ?? widget.onRelease;
    if (handler != null) {
      handler(context, data);
      return;
    }
    await release(.toDisplay(data));
  }

  void _setOriginGesture(OriginGesture? v) {
    _fact(OriginGestureSet(v));
    if (v == null) _originPointers = const {};
  }
  // Pointer positions forwarded from the active Origin's recognizer. Combined
  // with stage's own recognizer's positions to drive hybrid gesture math.
  Map<int, Offset> _originPointers = const {};
  Duration? _originPointersTime;
  void _setOriginPointers(Map<int, Offset> v, Duration? time) {
    _originPointers = Map.of(v);
    _originPointersTime = time;
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
  // The merger's focal and spread trackers, fed with the pointer events' own
  // timestamps. Replaced on re-baseline so velocity is never measured across
  // a pointer-count change.
  VelocityTracker? _hybridFocalTracker;
  VelocityTracker? _hybridScaleTracker;
  double _hybridBaselineSpread = 0;
  // Last same-count velocity. Persists through re-baselines and the final
  // reset, so release fired after a simultaneous lift (a 1-pointer gap
  // between the two recognizers' onEnds) still sees the 2-pointer-era
  // velocity. Staleness checked at read time (100ms window).
  ({Velocity velocity, double scaleVelocity, Duration time})? _lastMergerVelocity;

  /// The latest pointer event time either recognizer saw.
  Duration? get _pointerTime {
    final stage = _stageRecognizer?.lastEventTime;
    final origin = _originPointersTime;
    if (stage == null) return origin;
    if (origin == null) return stage;
    return stage > origin ? stage : origin;
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

  StageTapEvent _tapEvent(Offset local, Offset global) {
    final display = _scene.display;
    return StageTapEvent(
      localPosition: local,
      globalPosition: global,
      currentRect: _rect.value,
      displayRect: display.rect,
      baseRect: display.rect.baseRect(_scene.aspectRatio),
      aspectRatio: _scene.aspectRatio,
    );
  }

  void _onDoubleTap() {
    final handler = _displayConfig?.onDoubleTap ?? widget.onDoubleTap;
    if (handler == null) return;
    final event = _tapEvent(_doubleTapLocal, _doubleTapGlobal);
    if (identical(handler, Stage.zoomToggleOnDoubleTap)) {
      _runZoomToggle(event);
    } else {
      handler(event);
    }
  }

  void _onTap(TapUpDetails details) {
    final handler = _displayConfig?.onTap ?? widget.onTap;
    if (handler == null) return;
    handler(_tapEvent(details.localPosition, details.globalPosition));
  }

  void _resetHybridMerger() {
    _hybridLastFocal = null;
    _hybridLastSpread = null;
    _hybridLastCount = 0;
    _hybridPromotionBaselineSpread = null;
    if (_stance.hybridDriving) _fact(const HybridDrivingSet(false));
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
    final og = _stance.originGesture;
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
    final time = _pointerTime;

    // First activation OR pointer count change ⇒ re-baseline last samples;
    // no rect update this frame (the focal/spread "shift" from the count
    // change isn't real finger motion). Start fresh trackers so velocity is
    // never measured across the pointer-count jump, but keep
    // `_lastMergerVelocity` so a release fired before the next valid sample
    // (e.g. simultaneous lift) still has the most recent same-count velocity.
    if (_hybridLastFocal == null || all.length != _hybridLastCount) {
      _hybridLastFocal = focal;
      _hybridLastSpread = spread;
      _hybridLastCount = all.length;
      _hybridBaselineSpread = spread;
      _hybridFocalTracker = VelocityTracker.withKind(.touch);
      _hybridScaleTracker = VelocityTracker.withKind(.touch);
      if (time != null) {
        _hybridFocalTracker!.addPosition(time, focal);
        _hybridScaleTracker!.addPosition(time, const Offset(1, 0));
      }
      // Track promotion baseline only while we have 2 pointers AND origin
      // is still in drag AND mode is asScale; reset otherwise.
      if (all.length >= 2
          && hybrid.drag == DragHybrid.asScale
          && og.active.gesture is DragGesture) {
        _hybridPromotionBaselineSpread = spread;
      } else {
        _hybridPromotionBaselineSpread = null;
      }
      if (!_stance.hybridDriving) _fact(const HybridDrivingSet(true));
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
    final originRect = _scene.origin.rect;
    final displayRect = _scene.display.rect;
    final baseWidth = displayRect.baseWidth(_scene.aspectRatio);

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
    if (time == null) return;
    final focalTracker = _hybridFocalTracker!..addPosition(time, focal);
    final scaleTracker = _hybridScaleTracker!
      ..addPosition(
        time,
        Offset(_hybridBaselineSpread > 0 ? spread / _hybridBaselineSpread : 1, 0),
      );
    _lastMergerVelocity = (
      velocity: focalTracker.getVelocity(),
      scaleVelocity: scaleTracker.getVelocity().pixelsPerSecond.dx,
      time: time,
    );
  }

  /// Returns the merger's last same-count velocity if it was measured within
  /// 100ms of the latest pointer event. Returns null when the merger didn't
  /// run or its last sample is stale — callers should fall back to the
  /// firing recognizer's own `ScaleEndDetails.velocity`.
  ({Velocity velocity, double scaleVelocity})? _hybridReleaseVelocity() {
    final last = _lastMergerVelocity;
    if (last == null) return null;
    final now = _pointerTime;
    if (now == null || now - last.time > const Duration(milliseconds: 100)) return null;
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

  void _updateContainer() {
    if (_rect.value == .zero) {
      _container.value = null;
      _lastRectCenter = null;
      return;
    }
    final scene = _scene;
    final originC = scene.originContainer;
    if (originC == null) {
      _container.value = scene.displayContainer;
      return;
    }
    final displayC = scene.displayContainer ?? OriginRect(rect: Offset.zero & MediaQuery.sizeOf(context));

    final p = _originToBaseProgress.value;
    final rect = _rect.value;
    final prev = _container.value?.rect ?? originC.rect;

    // Per-frame delta: each incremental movement extends the container in that direction.
    final lastCenter = _lastRectCenter ?? scene.origin.rect.center;
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
    final totalDelta = rect.center - scene.origin.rect.center;
    final shifted = originC.rect.expandToInclude(originC.rect.shift(totalDelta));

    // On dismiss, animate from the captured start container back to the origin container using
    // the same controller as the rect dismiss, so container and item converge together.
    final Rect baseline;
    if (_stance.dismissing && _dismissStartContainer != null) {
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

  /// The geometry a finished session leaves behind, wiped so the next Origin
  /// starts from nothing. The facts already cleared the scene and stance.
  void _clearGeometry() {
    // A stage that lost its tree keeps its last rect for the onEnd work.
    if (_disposed) return;
    setRect(.zero);
    _startRect = .zero;
    _totalDelta = .zero;
    _active = null;
    _container.value = null;
    _lastRectCenter = null;
    _dismissStartContainer = null;
    _rotation.value = null;
    _crop.value = .zero;
    _cropDrag = false;
    // Decomposed-release state — must be cleared so the next gesture's
    // tween-begin lookup falls back to [_rect.value.center.dx] instead
    // of reading stale tween values left over from a release that was
    // interrupted before its natural completion.
    _releaseDecomposed = false;
  }

  /// The session's Origin is gone while its own gesture held the stage: the
  /// stage lets it go at once, with no flight home and no landing work.
  void _abandon(Object tag) {
    // Called from the Origin's dispose, while the tree is locked: the
    // stage's listeners may rebuild only once the frame is done.
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == .persistentCallbacks) {
      binding.addPostFrameCallback((_) => _abandon(tag));
      return;
    }
    if (_disposed) return;
    if (_scene.tag != tag || _stance.open || _stance.flight != null) return;
    _setOriginGesture(null);
    _resetHybridMerger();
    _land(_takeFlight(.effect));
  }

  /// Whether a session holds the stage: an Origin shown, opening or flying
  /// home. A new open or send waits its turn by being refused.
  bool get _busy => _scene.tag != null;

  Future<void> runEffect({
    double? rotateX,
    double? rotateY,
    double? rotateZ,
    double? perspective,
    Duration duration = const Duration(milliseconds: 100),
    Curve curve = Curves.easeOut,
  }) async {
    final flight = _takeFlight(.effect);
    _effect.duration = duration;
    final curved = CurvedAnimation(parent: _effect, curve: curve);
    void update() {
      final t = curved.value;
      _rotation.value = Rotation(
        x: (rotateX ?? 0) * t,
        y: (rotateY ?? 0) * t,
        z: (rotateZ ?? 0) * t,
        perspective: perspective ?? _scene.perspective,
      );
    }
    curved.addListener(update);
    try {
      if (!_disposed) {
        await _effect.forward().orCancel.catchError((_) {}, test: (e) => e is TickerCanceled);
      }
      if (!_disposed) {
        await _effect.reverse().orCancel.catchError((_) {}, test: (e) => e is TickerCanceled);
      }
    } finally {
      curved.removeListener(update);
      curved.dispose();
      if (!_disposed) _rotation.value = null;
      _land(flight);
    }
  }

  /// Flights home still running their landing work after the stage left the
  /// tree; the notifiers they read live until the last one lands.
  int _landingsInAir = 0;

  Future<void> dismiss({Object? tag, Object? except, Settle? settle}) async {
    if (tag != null) {
      _fact(SendsRecalled(tag: tag));
      return;
    }
    _fact(SendsRecalled(except: except));
    if (!_stance.dismissing) _dismissStartContainer = _container.value?.rect;
    _remeasureOrigin();
    final flight = _takeFlight(.dismissing);
    await _landing(() async {
      try {
        await _flyHome(settle);
        // A newer flight superseded this one; its own landing does the work.
        if (_isCurrent(flight)) await _scene.onEnd?.call();
      } finally {
        _land(flight);
      }
    });
  }

  /// Runs [work] that may end in a landing after the stage leaves the tree,
  /// keeping the notifiers it reads alive until it is done.
  Future<void> _landing(Future<void> Function() work) async {
    _landingsInAir++;
    try {
      await work();
    } finally {
      _landingsInAir--;
      if (_disposed && _landingsInAir == 0) _disposeNotifiers();
    }
  }

  /// The home flown back to is where the Origin stands now, unless the
  /// consumer pointed it elsewhere.
  void _remeasureOrigin() {
    final scene = _scene;
    final tag = scene.tag;
    if (tag == null || scene.originPointed) return;
    final measured = _measureEntry(tag);
    if (measured != null) _fact(OriginMeasured(measured));
  }

  Future<void> _flyHome(Settle? settle) async {
    final origin = _scene.origin.rect;
    if (_disposed) {
      if (!_notifiersDisposed) _rect.value = origin;
      return;
    }
    _motion++;
    final current = _rect.value;
    // Per-axis simulation lands at origin's coordinate, so dismiss
    // responds to the configured [Settle] (e.g., stiffness).
    final s = settle ?? const AttractSettle();
    final simX = s.simulationAt(
      position: current.center.dx,
      velocity: 0,
      target: origin.center.dx,
    );
    final simY = s.simulationAt(
      position: current.center.dy,
      velocity: 0,
      target: origin.center.dy,
    );
    final simW = s.simulationAt(
      position: current.width,
      velocity: 0,
      target: origin.width,
    );
    // Duration spans the longest natural-stop across axes; earlier-done
    // axes freeze at target (SimulationCurve clamps progress at 1.0).
    final dt = math.max(
      math.max(_naturalStopTime(simX), _naturalStopTime(simY)),
      _naturalStopTime(simW),
    );
    final duration = Duration(milliseconds: (dt * 1000).round().clamp(1, 1500));
    await Future.wait([
      animateCenterX(
        to: origin.center.dx,
        duration: duration,
        curve: SimulationCurve(simX, dt),
      ),
      animateCenterY(
        to: origin.center.dy,
        duration: duration,
        curve: SimulationCurve(simY, dt),
      ),
      animateWidth(
        to: origin.width,
        height: origin.height,
        duration: duration,
        curve: SimulationCurve(simW, dt),
      ),
    ]);
    // The stage left the tree mid-flight: the flight lands where it was going.
    if (_disposed && !_notifiersDisposed) _rect.value = origin;
  }

  double _naturalStopTime(Simulation sim) {
    const dt = 1.0 / 240;
    for (double t = 0.05; t <= 2.0; t += dt) {
      if (sim.isDone(t)) return t;
    }
    return 2.0;
  }

  Future<void> animateToBase() async {
    final flight = _takeFlight(.opening);
    try {
      final scene = _scene;
      await animateRect(to: scene.display.rect.baseRect(scene.aspectRatio), curve: Curves.easeOut);
    } finally {
      _land(flight);
    }
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
    final scene = _scene;
    final originW = scene.origin.rect.width;
    final baseW = scene.display.rect.baseWidth(scene.aspectRatio);
    // The origin can be wider than the base (a tall image from a wide slot),
    // so progress runs either way between the two widths.
    _originToBaseProgress.value = baseW == originW
        ? 1.0
        : ((w - originW) / (baseW - originW)).clamp(0.0, 1.0);
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
    return _drive(_centerX, duration, curve);
  }

  Future<void> animateCenterY({required double to, Duration? duration, Curve curve = Curves.easeIn}) {
    _centerYTween.begin = _releaseDecomposed
        ? _centerYTween.evaluate(_centerY)
        : _rect.value.center.dy;
    _centerYTween.end = to;
    return _drive(_centerY, duration, curve);
  }

  /// Animates the rect's width to [to]. If [height] is provided, animates
  /// height in lockstep on the same controller (so duration / curve are
  /// shared by construction); otherwise the height tween targets
  /// `to / aspectRatio` to preserve the existing aspect-derived height
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
    _heightTween.end = height ?? to / _scene.aspectRatio;
    return _drive(_width, duration, curve);
  }

  Future<void> animateRect({required Rect to, Duration? duration, Curve curve = Curves.easeIn}) {
    _motion++;
    return Future.wait([
      animateCenterX(to: to.center.dx, duration: duration, curve: curve),
      animateCenterY(to: to.center.dy, duration: duration, curve: curve),
      animateWidth(to: to.width, height: to.height, duration: duration, curve: curve),
    ]);
  }

  Future<void> release(Release plan) async {
    final motion = ++_motion;
    final scaleHasMotion =
        plan.scale.decay.isNotEmpty || plan.scale.settle != null;
    if (!scaleHasMotion) {
      // No scale animation → axes are independent.
      setRect(_rect.value);
      await Future.wait([
        _runAxis(motion, plan.x, animateCenterX),
        _runAxis(motion, plan.y, animateCenterY),
        _runAxis(motion, plan.scale, animateWidth),
      ]);
      return;
    }
    // Decomposed-release: scale drives the proportional center; X/Y add a
    // translation offset on top. Each axis keeps its own curve/duration and
    // the displayed center stays consistent mid-frame.
    final initialRect = _rect.value;
    final display = _scene.display.rect;
    final wFinal = plan.scale.settle?.to ?? plan.scale.decay.last.to;
    final scaleRatio = initialRect.width == 0 ? 1.0 : wFinal / initialRect.width;
    final xPropFinal = display.center.dx
        + (initialRect.center.dx - display.center.dx) * scaleRatio;
    final yPropFinal = display.center.dy
        + (initialRect.center.dy - display.center.dy) * scaleRatio;
    final xAbsTarget = plan.x.settle?.to
        ?? (plan.x.decay.isNotEmpty ? plan.x.decay.last.to : initialRect.center.dx);
    final yAbsTarget = plan.y.settle?.to
        ?? (plan.y.decay.isNotEmpty ? plan.y.decay.last.to : initialRect.center.dy);
    final xOffsetTarget = xAbsTarget - xPropFinal;
    final yOffsetTarget = yAbsTarget - yPropFinal;

    // Enter decomposed-release mode: capture the initial rect / display
    // state and reset the X/Y tweens to zero offset, the width tween to
    // current width.
    _releaseInitialX = initialRect.center.dx;
    _releaseInitialY = initialRect.center.dy;
    _releaseInitialWidth = initialRect.width;
    _releaseDisplayCenter = display.center;
    _centerXTween.begin = 0;
    _centerXTween.end = 0;
    _centerYTween.begin = 0;
    _centerYTween.end = 0;
    _widthTween.begin = initialRect.width;
    _widthTween.end = initialRect.width;
    _heightTween.begin = initialRect.height;
    _heightTween.end = initialRect.height;
    _releaseDecomposed = true;
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
        _runAxis(motion, plan.scale, animateWidth),
      ]);
    } finally {
      if (motion == _motion) _releaseDecomposed = false;
    }
  }

  Future<void> run({
    List<AxisFling>? x,
    List<AxisFling>? y,
    List<AxisFling>? scale,
  }) {
    final motion = ++_motion;
    setRect(_rect.value);
    return Future.wait([
      if (x != null) _runFlings(motion, x, animateCenterX),
      if (y != null) _runFlings(motion, y, animateCenterY),
      if (scale != null) _runFlings(motion, scale, animateWidth),
    ]);
  }

  Future<void> backToOrigin(ReleaseContext data, {Object? except}) {
    return _landing(() async {
      await release(Release.toHalt(data));
      // Use the gesture's configured [Settle] for the dismiss-to-origin motion.
      final b = data.gesture.bounds;
      final settle = b.left?.decay?.settle
          ?? b.right?.decay?.settle
          ?? b.top?.decay?.settle
          ?? b.bottom?.decay?.settle;
      await dismiss(except: except, settle: settle);
    });
  }

  /// Bumped by every motion that takes the whole rect (a release, a run, a
  /// flight, a touch), so a motion it supersedes stops between phases.
  int _motion = 0;

  Future<void> _runAxis(
    int motion,
    AxisRelease axis,
    Future<void> Function({
      required double to,
      Duration? duration,
      Curve curve,
    }) animate,
  ) async {
    for (final f in axis.decay) {
      if (motion != _motion) return;
      await animate(to: f.to, duration: f.duration, curve: f.curve);
    }
    final s = axis.settle;
    if (s != null && motion == _motion) {
      await animate(to: s.to, duration: s.duration, curve: s.curve);
    }
  }

  Future<void> _runFlings(
    int motion,
    List<AxisFling> flings,
    Future<void> Function({
      required double to,
      Duration? duration,
      Curve curve,
    }) animate,
  ) async {
    for (final f in flings) {
      if (motion != _motion) return;
      await animate(to: f.to, duration: f.duration, curve: f.curve);
    }
  }

  /// Animates the image rect back to base and the crop rect back to the
  /// mode's initial crop.
  Future<void> resetCrop() {
    final scene = _scene;
    final base = scene.display.rect.baseRect(scene.aspectRatio);
    final crop = scene.displayConfig?.crop;
    return Future.wait([
      animateRect(to: base, curve: Curves.easeOut),
      animateCrop(to: crop?.initialRect?.call(base) ?? base, curve: Curves.easeOut),
    ]);
  }

  /// Shows [widget] where the crop rect stands and flies it home. With
  /// [aspectRatio], home keeps the slot's width at that ratio — the slot
  /// relays out to the cropped photo while it's away — and the crop rect
  /// rides home beside it.
  Future<void> landCrop(Widget widget, {double? aspectRatio}) async {
    // A slot the consumer just changed is measured where it lays out.
    await _settledFrame();
    if (_disposed) return;
    final cropRect = _crop.value;
    final tag = _scene.tag;
    final home = tag == null ? null : _measureEntry(tag);
    final origin = home == null || aspectRatio == null
        ? null
        : home.copyWith(
            rect: Rect.fromLTWH(
              home.rect.left,
              home.rect.top,
              home.rect.width,
              home.rect.width / aspectRatio,
            ),
          );
    if (origin != null) _fact(OriginPointed(origin));
    _fact(WidgetShown(widget));
    setRect(cropRect);
    if (origin != null) animateCrop(to: origin.rect, curve: Curves.easeOut);
    await dismiss();
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

  /// Waits out a frame already on its way: the Origin a consumer just built
  /// or changed is mounted and laid out once it has run.
  Future<void> _settledFrame() async {
    final binding = SchedulerBinding.instance;
    if (binding.hasScheduledFrame) await binding.endOfFrame;
  }

  Future<void> _openEntry(Object tag) async {
    await _settledFrame();
    if (_disposed) return;
    await _registry[tag]?.open?.call();
  }

  Future<void> _sendEntry(Object tag, Rect Function(Rect) send, {VoidCallback? onEnd}) async {
    await _settledFrame();
    if (_disposed) return;
    await _registry[tag]?.send?.call(send, onEnd: onEnd);
  }

  // --- Sends ---

  void _displace(Object tag, {required Object target, bool park = true}) {
    _fact(SendDisplaced(StageSend(tag: tag, target: target, park: park, key: UniqueKey())));
  }

  @override
  void dispose() {
    _disposed = true;
    // The rect's listeners read the tree, which is gone; a flight still
    // landing keeps only the rect itself.
    _rect
      ..removeListener(_updateProgress)
      ..removeListener(_updateContainer);
    // Stopping completes every animation's future: a flight home lands where
    // it was going and still runs its landing work.
    _centerX.dispose();
    _centerY.dispose();
    _width.dispose();
    _effect.dispose();
    _cropAnim.dispose();
    _ledger.close();
    if (_landingsInAir == 0) _disposeNotifiers();
    super.dispose();
  }

  bool _notifiersDisposed = false;

  void _disposeNotifiers() {
    _notifiersDisposed = true;
    _rect.dispose();
    _crop.dispose();
    _container.dispose();
    _originToBaseProgress.dispose();
    _transitionProgressMin.dispose();
    _transitionProgressMean.dispose();
    _transitionProgressMax.dispose();
    _rotation.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scene = _scene;
    final stance = _stance;
    final tagStates = _tagStates;
    return StageData._(
      stage: this,
      scene: scene,
      stance: stance,
      tagStates: tagStates,
      child: Stack(
        fit: .expand,
        children: [
          widget.child,
          const _AbsorbLayer(),
          for (final send in _sends.values)
            _SendLayer(
              key: send.key,
              tag: send.tag,
              target: send.target,
              returning: tagStates[send.tag] == .returning,
              onArrived: send.park
                  ? () => _fact(SendArrived(send.tag))
                  : () => _fact(SendGone(send.tag)),
              onDone: () => _fact(SendGone(send.tag)),
            ),
          const StageOverlay(),
          Builder(builder: (context) {
            // Stage's gesture detector is active either:
            //  - in displayed-state (open, and not flying home), or
            //  - during a hybrid feed-state gesture so new pointers landing
            //    on stage join the Origin's gesture per its hybrid mode.
            final og = stance.originGesture;
            final hybridActive = og != null && _resolveHybrid(og) != null;
            final displayed = Stage.hasWidgetOf(context) && stance.open && !stance.dismissing;
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
                    (r) => r.onTapUp = _onTap,
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
          if ((_displayConfig?.overlay ?? scene.config.overlay ?? widget.overlay)
              case final overlay?)
            Builder(builder: overlay),
        ],
      ),
    );
  }
}

/// The stage as its subtree reads it. Every getter reads the stage's ledger
/// now, so a [StageData] held from an earlier build never goes stale; the
/// snapshot it was built with only decides which dependents rebuild.
class StageData extends InheritedModel<Object> {
  const StageData._({
    required this._stage,
    required StageScene scene,
    required StageStance stance,
    required Map<Object, TagState> tagStates,
    required super.child,
  })  : _builtScene = scene,
        _builtStance = stance,
        _builtTagStates = tagStates;

  final _StageState _stage;
  final StageScene _builtScene;
  final StageStance _builtStance;
  final Map<Object, TagState> _builtTagStates;

  StageScene get _scene => _stage._scene;
  StageStance get _stance => _stage._stance;

  Object? get tag => _scene.tag;
  Widget? get widget => _scene.widget;
  OriginRect get origin => _scene.origin;
  OriginRect? get originContainer => _scene.originContainer;
  OriginRect get display => _scene.display;
  OriginRect? get displayContainer => _scene.displayContainer;
  double get aspectRatio => _scene.aspectRatio;
  double? get perspective => _scene.perspective;
  Color? get backgroundColor => _scene.backgroundColor;
  StageBuilder? get gestureBuilder => _scene.gestureBuilder;

  /// The currently-active [DisplayConfig] (the displayed origin's, merged
  /// with any active mode override). Null when no origin is displayed.
  /// Tools (e.g., [Cropper]) read this to check whether they should be
  /// active in the current state.
  DisplayConfig? get displayConfig => _scene.displayConfig;

  /// The shown Origin finished opening; the Stage's gestures drive it.
  bool get open => _stance.open;
  bool get dismissing => _stance.dismissing;

  /// True during an open ([animateToBase]) or dismiss ([dismiss])
  /// animation. Release rubber-back / settle paths don't touch this. Used
  /// by crop-mode chrome to fade only during real open/dismiss and stay
  /// solid through interaction + settle.
  bool get openingOrDismissing => _stance.openingOrDismissing;

  /// True while [setMode] is animating its rect/crop transition. Use to
  /// gate mode-transition fades without firing on user interaction.
  bool get changingMode => _stance.changingMode;

  /// True while a gesture on the Stage moves the shown Origin. Read via
  /// [Stage.isInteractingOf] for tag-aware access (which folds in a check
  /// that the queried tag is the active stage tag).
  bool get interacting => _stance.interacting;

  Map<Object, TagState> get tagStates => _stage._tagStates;

  ValueNotifier<Rect> get rect => _stage._rect;

  /// Live crop rect, seeded from [CropConfig.initialRect] when a crop mode
  /// activates and mutated by Stage's recognizer (1-pointer drag inside the
  /// rect) or the [Cropper] widget's handles. Consumers read it (e.g. on
  /// apply) via `Stage.of(context).crop.value`. Reset to [Rect.zero] when
  /// no crop mode is active.
  ValueNotifier<Rect> get crop => _stage._crop;
  ValueNotifier<Rotation?> get rotation => _stage._rotation;
  ValueListenable<double> get originToBaseProgress => _stage._originToBaseProgress;
  ValueListenable<OriginRect?> get container => _stage._container;

  /// Progress 0..1 derived from the four rect/crop animation
  /// controllers, gated by `openingOrDismissing || changingMode` so
  /// release/settle don't move it. Three aggregations exposed —
  /// consumer picks based on desired fade timing:
  /// - [transitionProgressMin]: slowest controller.
  /// - [transitionProgressMean]: average across all four.
  /// - [transitionProgressMax]: fastest controller.
  ValueListenable<double> get transitionProgressMin => _stage._transitionProgressMin;
  ValueListenable<double> get transitionProgressMean => _stage._transitionProgressMean;
  ValueListenable<double> get transitionProgressMax => _stage._transitionProgressMax;

  OnRelease? get onRelease => _stage.widget.onRelease;
  Overrides? get overrides => _stage.widget.overrides;

  /// Stage-level cascade fallback for hybrid pointer routing. Resolved last
  /// before [DragHybrid.lock] / [ScaleHybrid.lock].
  DragHybrid? get dragHybridFromStage => _stage.widget.dragHybridFromStage;
  ScaleHybrid? get scaleHybridFromStage => _stage.widget.scaleHybridFromStage;

  /// Stage-level `scaleVelocityCancel` (raw nullable), the bottom of the
  /// cascade before the package default of `0.8`.
  double? get scaleVelocityCancel => _stage.widget.scaleVelocityCancel;

  /// The Origin gesture in flight (drag or scale on an un-displayed item),
  /// with its hybrid mode resolved up to Origin's level. Null when no
  /// Origin is gesturing.
  OriginGesture? get originGesture => _stance.originGesture;

  /// True while Stage's hybrid merger is driving the rect. Origin reads
  /// this to silence its own rect manipulation while Stage is in control.
  bool get isHybridDriving => _stance.hybridDriving;

  /// Count of the Stage recognizer's pointers. Origin reads this to decide
  /// whether to defer release until stage's pointers also leave.
  int get stagePointerCount => _stage._stageRecognizer?.pointerPositions.length ?? 0;

  /// The hybrid merger's release velocity, or null when the merger didn't
  /// run recently — callers fall back to the firing recognizer's own.
  ({Velocity velocity, double scaleVelocity})? get hybridReleaseVelocity =>
      _stage._hybridReleaseVelocity();

  void setWidget(Widget? widget) => _stage._fact(WidgetShown(widget));

  /// Points the flight home at [origin]; a pointed home is not measured again.
  void setOrigin(OriginRect origin) => _stage._fact(OriginPointed(origin));
  void setAspectRatio(double aspectRatio) => _stage._fact(AspectRatioSet(aspectRatio));
  void setBackgroundColor(Color? color) => _stage._fact(BackgroundSet(color));

  /// Switches the active mode for the currently-displayed origin. Looks
  /// the key up in the origin's modes map, merges with the origin's
  /// default config, and swaps [displayConfig]. Passing `null` returns to
  /// the default config.
  ///
  /// Useful for letting consumer-side UI (e.g., an appbar's Back button)
  /// exit a tool mode without dismissing the displayed origin.
  void setMode(Object? mode) => _stage._setMode(mode);
  void setRect(Rect rect) => _stage.setRect(rect);

  Future<void> animateRect({required Rect to, Duration? duration, Curve curve = Curves.easeIn}) =>
      _stage.animateRect(to: to, duration: duration, curve: curve);

  /// Animates [crop] from its current value to the given rect. Used for
  /// reset transitions and other places that want a smooth crop-rect change
  /// instead of an instant `stage.crop.value = newRect` assignment.
  Future<void> animateCrop({required Rect to, Duration? duration, Curve curve = Curves.easeOut}) =>
      _stage.animateCrop(to: to, duration: duration, curve: curve);

  Future<void> animateToBase() => _stage.animateToBase();

  /// Flies the shown Origin home and ends the session. With [tag], only
  /// that send flies home.
  Future<void> dismiss({Object? tag, Object? except, Settle? settle}) =>
      _stage.dismiss(tag: tag, except: except, settle: settle);

  Future<void> release(Release plan) => _stage.release(plan);

  Future<void> run({List<AxisFling>? x, List<AxisFling>? y, List<AxisFling>? scale}) =>
      _stage.run(x: x, y: y, scale: scale);

  Future<void> backToBase() {
    final scene = _scene;
    return _stage.animateRect(to: scene.display.rect.baseRect(scene.aspectRatio), curve: Curves.easeOut);
  }

  Future<void> backToOrigin(ReleaseContext data, {Object? except}) =>
      _stage.backToOrigin(data, except: except);

  /// Animates the image rect back to base and the crop rect back to the
  /// mode's initial crop.
  Future<void> resetCrop() => _stage.resetCrop();

  /// The crop rect in [sourceSize]'s pixels, for the image the stage shows.
  Rect cropSourceRect(Size sourceSize) => displayRectToSourceRect(
        cropRect: _stage._crop.value,
        imageDisplayRect: _stage._rect.value,
        sourceSize: sourceSize,
      );

  /// Shows [widget] where the crop rect stands and flies it home. With
  /// [aspectRatio], home keeps the slot's width at that ratio — the slot
  /// relays out to the cropped photo while it's away — and the crop rect
  /// rides home beside it.
  Future<void> landCrop(Widget widget, {double? aspectRatio}) =>
      _stage.landCrop(widget, aspectRatio: aspectRatio);

  OriginRect? measureEntry(Object tag) => _stage._measureEntry(tag);

  /// Opens the Origin [tag]. Refused while another session holds the stage.
  Future<void> openEntry(Object tag) => _stage._openEntry(tag);

  /// Flies the Origin [tag] to `send(its rect)`. Refused while another
  /// session holds the stage.
  Future<void> sendEntry(Object tag, Rect Function(Rect) send, {VoidCallback? onEnd}) =>
      _stage._sendEntry(tag, send, onEnd: onEnd);

  @override
  bool updateShouldNotify(StageData oldWidget) => true;

  @override
  bool updateShouldNotifyDependent(StageData oldWidget, Set<Object> dependencies) {
    final tag = _builtScene.tag;
    final oldTag = oldWidget._builtScene.tag;
    final tagStates = _builtTagStates;
    final oldTagStates = oldWidget._builtTagStates;
    final interacting = _builtStance.interacting;
    final oldInteracting = oldWidget._builtStance.interacting;
    for (final dep in dependencies) {
      switch (dep) {
        case _tagAspect:
          if (tag != oldTag) return true;
        case _widgetAspect:
          if (_builtScene.widget != oldWidget._builtScene.widget) return true;
        case _hasWidgetAspect:
          if ((_builtScene.widget != null) != (oldWidget._builtScene.widget != null)) return true;
        case _dismissingAspect:
          if (_builtStance.dismissing != oldWidget._builtStance.dismissing) return true;
        case _interactingAspect:
          if (interacting != oldInteracting) return true;
        case (#tag, final Object t):
          final was = oldTag == t || oldTagStates.containsKey(t);
          final now = tag == t || tagStates.containsKey(t);
          if (was != now) return true;
        case (#active, final Object t):
          if ((tag == t) != (oldTag == t)) return true;
        case (#state, final Object t):
          if (tagStates[t] != oldTagStates[t]) return true;
        case (#interacting, final Object t):
          final was = oldTag == t && oldInteracting;
          final now = tag == t && interacting;
          if (was != now) return true;
      }
    }
    return false;
  }
}

/// Origin's door into its stage: the calls an [Origin] makes while it takes,
/// drives and leaves the stage. The package barrel hides it from consumers.
extension StageDoor on StageData {
  bool get busy => _stage._busy;

  void register(Object tag, OriginEntry entry) => _stage._register(tag, entry);

  void unregister(Object tag, OriginEntry entry) => _stage._unregister(tag, entry);

  Widget? captureEntry(Object tag) => _stage._captureEntry(tag);

  void take(StageTaken taken) => _stage._take(taken);

  void setGestureBuilder(StageBuilder? builder) => _stage._fact(GestureBuilderSet(builder));

  void setOnEnd(FutureOr<void> Function()? onEnd) => _stage._fact(OnEndSet(onEnd));

  void setOriginGesture(OriginGesture? gesture) => _stage._setOriginGesture(gesture);

  void setOriginPointers(Map<int, Offset> pointers, Duration? time) =>
      _stage._setOriginPointers(pointers, time);

  void abandon(Object tag) => _stage._abandon(tag);

  void displace(Object tag, {required Object target, bool park = true}) =>
      _stage._displace(tag, target: target, park: park);

  void releaseSend(Object tag) => _stage._fact(SendGone(tag));

  Future<void> runEffect({
    double? rotateX,
    double? rotateY,
    double? rotateZ,
    double? perspective,
    Duration duration = const Duration(milliseconds: 100),
    Curve curve = Curves.easeOut,
  }) =>
      _stage.runEffect(
        rotateX: rotateX,
        rotateY: rotateY,
        rotateZ: rotateZ,
        perspective: perspective,
        duration: duration,
        curve: curve,
      );
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
    if (!mounted || widget.returning) return;
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
    return _controller
        .animateTo(1, curve: Curves.easeOut)
        .orCancel
        .catchError((_) {}, test: (e) => e is TickerCanceled);
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
