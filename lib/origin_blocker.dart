import 'package:flutter/widgets.dart';

/// A widget stacked above origin items that must be hidden
/// during the origin→display transition to avoid visual obstruction.
/// A single blocker can block multiple origins, and multiple blockers
/// can block the same origin.
class OriginBlocker extends StatelessWidget {
  const OriginBlocker({
    super.key,
    required this.tags,
    required this.child,
  });

  final Set<Object> tags;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // TODO: listen to animation state, hide child when any tag is animating
    return child;
  }
}
