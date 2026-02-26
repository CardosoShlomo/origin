import 'package:flutter/widgets.dart';
import 'origin_data.dart';

class OriginScope extends InheritedWidget {
  OriginScope({super.key, required super.child});

  final _containers = <Object, OriginRect Function()>{};
  final _items = <Object, VoidCallback>{};

  void registerContainer(Object tag, OriginRect Function() measure) {
    assert(
      !_containers.containsKey(tag),
      'Duplicate OriginContainer tag "$tag". Each tag must be unique.',
    );
    _containers[tag] = measure;
  }

  void unregisterContainer(Object tag) {
    _containers.remove(tag);
  }

  OriginRect? measureContainer(Object tag) {
    return _containers[tag]?.call();
  }

  void registerItem(Object tag, VoidCallback trigger) {
    assert(
      !_items.containsKey(tag),
      'Duplicate OriginItem tag "$tag". Each tag must be unique.',
    );
    _items[tag] = trigger;
  }

  void unregisterItem(Object tag) {
    _items.remove(tag);
  }

  void triggerItem(Object tag) {
    _items[tag]?.call();
  }

  static OriginScope of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<OriginScope>();
    assert(scope != null, 'No OriginDisplay found above this widget.');
    return scope!;
  }

  @override
  bool updateShouldNotify(OriginScope oldWidget) => false;
}
