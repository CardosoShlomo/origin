import 'package:flutter/widgets.dart';
import 'origin_context.dart';
import 'origin_data.dart';
import 'origin_ext_on_scale.dart';
import 'origin_ext_on_rect.dart';
import 'origin_scope.dart';
import 'origin_triggers.dart';

/// The thumbnail source widget. Reports its rect + borderRadius as the origin.
class OriginItem extends StatefulWidget {
  const OriginItem({
    super.key,
    required this.tag,
    this.tap,
    this.borderRadius = BorderRadius.zero,
    this.containerTag,
    this.originContainer,
    this.display,
    this.displayContainer,
    this.gestures = const {},
    this.constraints = const OriginConstraints(),
    this.aspectRatio,
    this.builder,
    required this.child,
  });

  final Object tag;
  final OriginTap? tap;
  final BorderRadius borderRadius;
  final Object? containerTag;
  final OriginRect? originContainer;
  final OriginRect? display;
  final OriginRect? displayContainer;
  final Map<OriginStart, OriginBounds> gestures;
  final OriginConstraints constraints;
  final double? aspectRatio;
  final WidgetBuilder? builder;
  final Widget child;

  @override
  State<OriginItem> createState() => _OriginItemState();
}

class _OriginItemState extends State<OriginItem> {
  late final OriginScope _scope;

  @override
  void initState() {
    super.initState();
    _scope = OriginScope.of(context);
    _scope.registerItem(widget.tag, _trigger);
  }

  @override
  void didUpdateWidget(OriginItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tag != widget.tag) {
      _scope.unregisterItem(oldWidget.tag);
      _scope.registerItem(widget.tag, _trigger);
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

  void _onScaleStart(ScaleStartDetails details) {}

  void _onScaleUpdate(ScaleUpdateDetails details) {
    _totalDelta += details.focalPointDelta;

    if (_activeStart == null) {
      _activeStart = _resolveStart(details);
      if (_activeStart == null) return;
      _setup();
      _startRect = OriginData.of(context).rect.value;
    }

    final data = OriginData.of(context);
    data.rect.value = details.rect(startRect: _startRect, currentRect: data.rect.value);
  }

  OriginStart? _resolveStart(ScaleUpdateDetails details) {
    final dx = _totalDelta.dx;
    final dy = _totalDelta.dy;
    final two = details.pointerCount > 1;

    if (two) {
      final scaleChange = details.scale - 1;
      if (scaleChange > 0.05 && widget.gestures.containsKey(OriginStart.pinchOut)) return .pinchOut;
      if (scaleChange < -0.05 && widget.gestures.containsKey(OriginStart.pinchIn)) return .pinchIn;
    }

    OriginStart? h;
    OriginStart? v;

    if (dx > 10) h = two ? .twoRight : .right;
    if (dx < -10) h = two ? .twoLeft : .left;
    if (dy > 10) v = two ? .twoDown : .down;
    if (dy < -10) v = two ? .twoUp : .up;

    // filter to mapped only
    if (h != null && !widget.gestures.containsKey(h)) h = null;
    if (v != null && !widget.gestures.containsKey(v)) v = null;

    if (h == null) return v;
    if (v == null) return h;

    // fight: prefer the start whose bounds cover the other's direction
    final hCoverV = widget.gestures[h]!.containsKey(v.bound);
    final vCoverH = widget.gestures[v]!.containsKey(h.bound);

    if (hCoverV && !vCoverH) return h;
    if (vCoverH && !hCoverV) return v;

    // tie: dominant axis wins
    return dx.abs() >= dy.abs() ? h : v;
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (details.pointerCount > 0) return;
    _activeStart = null;
    _totalDelta = .zero;
    final data = OriginData.of(context);
    data.animateRect(to: data.origin.value.rect, curve: Curves.easeOut);
  }

  OriginRect _measureOrigin() {
    return OriginRect(rect: context.rect, borderRadius: widget.borderRadius);
  }

  OriginData _setup() {
    final data = OriginData.of(context);
    final origin = _measureOrigin();
    final screen = OriginRect(rect: Offset.zero & MediaQuery.sizeOf(context));

    data.origin.value = origin;
    data.displayContainer.value = widget.displayContainer ?? screen;
    data.originContainer.value = widget.originContainer ?? _scope.measureContainer(widget.containerTag ?? widget.tag) ?? data.displayContainer.value;
    data.display.value = widget.display ?? data.displayContainer.value;
    data.aspectRatio.value = widget.aspectRatio ?? context.size!.aspectRatio;
    data.widget.value = widget.builder?.call(context) ?? widget.child;
    data.setRect(origin.rect);
    return data;
  }

  void _trigger() {
    final data = _setup();
    data.animateRect(to: data.display.value.rect.baseRect(data.aspectRatio.value), curve: Curves.easeIn);
  }

  @override
  Widget build(BuildContext context) {
    final hasGestures = widget.gestures.isNotEmpty;

    return GestureDetector(
      onTap: widget.tap != null ? _trigger : null,
      onScaleStart: hasGestures ? _onScaleStart : null,
      onScaleUpdate: hasGestures ? _onScaleUpdate : null,
      onScaleEnd: hasGestures ? _onScaleEnd : null,
      child: widget.child,
    );
  }
}
