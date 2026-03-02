## 0.2.0

* **Breaking:** `OriginScope.registerItem` callback changed from `VoidCallback` to `Future<void> Function([Rect Function(Rect)?])`.
* **Breaking:** `OriginScope.triggerItem` accepts optional `send` callback for programmatic dismiss to a computed rect.
* **Breaking:** Scope maps moved from widget instance to display state, fixing registration loss on rebuild.
* `OriginItem.onTap` replaces `tap`, provides `OriginTapEvent` with `animateToBase` and `runEffect`.
* `OriginItem.onEnd` callback fires after dismiss animation, before reset.
* `OriginItem.perspective` field with fallback chain: runEffect param → item → 0.
* `OriginRect.copyWith` method.
* Gesture `builder` on `OriginGesture` applied in overlay outside ClipRRect.
* `runEffect` with individual params, back-and-forth animation.
* Effect transform uses `Matrix4?` with null check.
* Removed `OriginEffect` class.

## 0.1.0

* Custom gesture recognizer for arena control.
* GlobalKey state preservation across overlay.
* Vertical shrink dismiss, multi-finger zoom.
* Early gesture acceptance, reduced slop.

## 0.0.3

* Add stackBuilder for showing builder on top of child.

## 0.0.2

* Add tag, visibility, dismiss, animateToBase.
* InheritedModel with aspect-based rebuilds.
* ClipRRect and borderRadius animation on items.
* Safe controller resets.

## 0.0.1

* Initial release.
