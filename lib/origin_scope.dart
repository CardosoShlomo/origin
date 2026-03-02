import 'package:flutter/widgets.dart';
import 'origin_data.dart';

class OriginScope extends InheritedWidget {
  OriginScope({
    super.key,
    required this.containers,
    required this.items,
    required super.child,
  });

  final Map<Object, OriginRect Function()> containers;
  final Map<Object, Future<void> Function([Rect Function(Rect)?])> items;

  void registerContainer(Object tag, OriginRect Function() measure) {
    assert(
      !containers.containsKey(tag),
      'Duplicate OriginContainer tag "$tag". Each tag must be unique.',
    );
    containers[tag] = measure;
  }

  void unregisterContainer(Object tag) {
    containers.remove(tag);
  }

  OriginRect? measureContainer(Object tag) {
    return containers[tag]?.call();
  }

  void registerItem(Object tag, Future<void> Function([Rect Function(Rect)?]) trigger) {
    assert(
      !items.containsKey(tag),
      'Duplicate OriginItem tag "$tag". Each tag must be unique.',
    );
    items[tag] = trigger;
  }

  void unregisterItem(Object tag) {
    items.remove(tag);
  }

  Future<void> triggerItem(Object tag, [Rect Function(Rect)? send]) {
    return items[tag]?.call(send) ?? Future.value();
  }

  static OriginScope of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<OriginScope>();
    assert(scope != null, 'No OriginDisplay found above this widget.');
    return scope!;
  }

  @override
  bool updateShouldNotify(OriginScope oldWidget) => false;
}
