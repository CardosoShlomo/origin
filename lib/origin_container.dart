import 'package:flutter/widgets.dart';
import 'origin_context.dart';
import 'origin_data.dart';
import 'origin_scope.dart';

/// Clip boundary for the origin item. Parts outside this rect are clipped
/// during the origin→display animation.
class OriginContainer extends StatefulWidget {
  const OriginContainer({
    super.key,
    required this.tag,
    this.borderRadius = BorderRadius.zero,
    required this.child,
  });

  final Object tag;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  State<OriginContainer> createState() => _OriginContainerState();
}

class _OriginContainerState extends State<OriginContainer> {
  OriginRect _measure() {
    return OriginRect(rect: context.rect, borderRadius: widget.borderRadius);
  }

  @override
  void initState() {
    super.initState();
    OriginScope.of(context).registerContainer(widget.tag, _measure);
  }

  @override
  void didUpdateWidget(OriginContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tag != widget.tag) {
      final scope = OriginScope.of(context);
      scope.unregisterContainer(oldWidget.tag);
      scope.registerContainer(widget.tag, _measure);
    }
  }

  @override
  void dispose() {
    OriginScope.of(context).unregisterContainer(widget.tag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
