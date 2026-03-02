import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'origin_context.dart';
import 'origin_data.dart';
import 'origin_ext_on_scale.dart';
import 'origin_recognizer.dart';
import 'origin_scope.dart';
import 'origin_triggers.dart';

/// The thumbnail source widget. Reports its rect + borderRadius as the origin.
class OriginItem extends StatefulWidget {
  const OriginItem({
    super.key,
    required this.tag,
    this.onTap,
    this.borderRadius = BorderRadius.zero,
    this.containerTag,
    this.originContainer,
    this.display,
    this.displayContainer,
    this.gestures = const [],
    this.constraints = const OriginConstraints(),
    this.aspectRatio,
    this.perspective,
    this.onEnd,
    this.builder,
    required this.child,
  });

  final Object tag;
  final OriginTap? onTap;
  final BorderRadius borderRadius;
  final Object? containerTag;
  final OriginRect? originContainer;
  final OriginRect? display;
  final OriginRect? displayContainer;
  final List<OriginGesture> gestures;
  final OriginConstraints constraints;
  final double? aspectRatio;
  final double? perspective;
  final ValueSetter<OriginData>? onEnd;
  final WidgetBuilder? builder;
  final Widget child;

  @override
  State<OriginItem> createState() => _OriginItemState();
}

class _OriginItemState extends State<OriginItem> {
  late final OriginScope _scope;
  final _childKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _scope = OriginScope.of(context);
    _scope.registerItem(widget.tag, _triggerFromScope);
  }

  @override
  void didUpdateWidget(OriginItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tag != widget.tag) {
      _scope.unregisterItem(oldWidget.tag);
      _scope.registerItem(widget.tag, _triggerFromScope);
    }
  }

  @override
  void dispose() {
    _scope.unregisterItem(widget.tag);
    super.dispose();
  }

  OriginStart? _activeStart;
  Rect _startRect = .zero;
  Offset _totalDelta = .zero;
  OriginScaleRecognizer? _recognizer;

  void _onScaleStart(ScaleStartDetails details) {
    _startRect = Origin.of(context).rect.value;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    _totalDelta += details.focalPointDelta;

    if (_activeStart == null) {
      _activeStart = _resolveStart(details);
      if (_activeStart == null) return;
      final data = _setup();
      data.setGestureBuilder(_gestureFor(_activeStart!).builder);
      data.setItemGesturing(true);
      _startRect = data.rect.value;
    }

    final data = Origin.of(context);
    data.rect.value = details.rect(startRect: _startRect, currentRect: data.rect.value);
  }

  bool _hasStart(OriginStart s) => widget.gestures.any((g) => g.start.contains(s));

  OriginGesture _gestureFor(OriginStart s) => widget.gestures.firstWhere((g) => g.start.contains(s));

  OriginStart? _resolveStart(ScaleUpdateDetails details) {
    final dx = _totalDelta.dx;
    final dy = _totalDelta.dy;
    final two = details.pointerCount > 1;

    OriginStart? h;
    OriginStart? v;

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

    // filter to mapped only
    if (h != null && !_hasStart(h)) h = null;
    if (v != null && !_hasStart(v)) v = null;

    if (h == null) return v;
    if (v == null) return h;

    // fight: prefer the start whose bounds cover the other's direction
    final hCoverV = _gestureFor(h).bounds.any((b) => b.bound.contains(v!.bound));
    final vCoverH = _gestureFor(v).bounds.any((b) => b.bound.contains(h!.bound));

    if (hCoverV && !vCoverH) return h;
    if (vCoverH && !hCoverV) return v;

    // tie: dominant axis wins
    return dx.abs() >= dy.abs() ? h : v;
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (details.pointerCount > 0) {
      if (details.pointerCount == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_recognizer?.trackedPointers.isEmpty ?? true) _finishGesture();
        });
      }
      return;
    }
    _finishGesture();
  }

  void _finishGesture() {
    _activeStart = null;
    _totalDelta = .zero;
    Origin.of(context).dismiss();
  }


  OriginRect _measureOrigin() {
    return OriginRect(rect: context.rect, borderRadius: widget.borderRadius);
  }

  OriginData _setup() {
    final data = Origin.of(context);
    final origin = _measureOrigin();
    final screen = OriginRect(rect: Offset.zero & MediaQuery.sizeOf(context));

    data.origin.value = origin;
    data.displayContainer.value = widget.displayContainer ?? screen;
    data.originContainer.value = widget.originContainer ?? _scope.measureContainer(widget.containerTag ?? widget.tag) ?? data.displayContainer.value;
    data.display.value = widget.display ?? data.displayContainer.value;
    data.aspectRatio.value = widget.aspectRatio ?? context.size!.aspectRatio;
    data.widget.value = KeyedSubtree(key: _childKey, child: widget.builder?.call(context) ?? widget.child);
    data.setPerspective(widget.perspective);
    data.setOnEnd(widget.onEnd != null ? () => widget.onEnd!(data) : null);
    data.setTag(widget.tag);
    data.setRect(origin.rect);
    return data;
  }

  Future<void> _triggerFromScope([Rect Function(Rect)? send]) {
    final data = _setup();
    if (send != null) {
      data.origin.value = data.origin.value.copyWith(rect: send(data.origin.value.rect));
      return data.dismiss();
    }
    return data.animateToBase();
  }

  void _onTapUp(TapUpDetails details) {
    widget.onTap!(OriginTapEvent(
      localPosition: details.localPosition,
      globalPosition: details.globalPosition,
      animateToBase: _triggerFromScope,
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
    final hasGestures = widget.gestures.isNotEmpty;

    return RawGestureDetector(
      behavior: .translucent,
      gestures: {
        if (widget.onTap != null)
          TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer(),
            (r) => r.onTapUp = _onTapUp,
          ),
        if (hasGestures)
          OriginScaleRecognizer: GestureRecognizerFactoryWithHandlers<OriginScaleRecognizer>(
            () => OriginScaleRecognizer(),
            (r) {
              _recognizer = r;
              r
                ..gestures = widget.gestures
                ..onStart = _onScaleStart
                ..onUpdate = _onScaleUpdate
                ..onEnd = _onScaleEnd;
            },
          ),
      },
      child: Origin.tagOf(context) == widget.tag
          ? SizedBox.shrink()
          : ClipRRect(
              borderRadius: widget.borderRadius,
              child: KeyedSubtree(key: _childKey, child: widget.child),
            ),
    );
  }
}
