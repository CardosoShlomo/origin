## 1.0.0

* **Breaking:** `OriginDisplay` + `OriginScope` merged into `Stage`.
* **Breaking:** `OriginItem` replaced by `Origin`.
* **Breaking:** `triggerEntry` split into `openEntry` and `sendEntry`.
* **Breaking:** `effectTransform` replaced by `Rotation` class with `toMatrix4`.
* `InheritedModel` aspects: `widgetOf`, `hasWidgetOf`, `tagOf`, `isTagOf`.
* `originToBaseProgress` notifier for border radius and scrim interpolation.
* Configurable `backgroundColor` scrim on Stage.
* `onEnd` overridable via `setOnEnd` or `sendEntry` optional parameter.
* `perspective` on `Rotation` class and `runEffect`.

## 0.3.0

* **Breaking:** `OriginItem.builder` signature changed from `WidgetBuilder?` to `Widget Function(BuildContext, Widget)?` — receives the child widget as second parameter.
* **Breaking:** `OriginItem.builder` now acts as the gesture builder in the overlay. If no `OriginGesture.builder` is provided, the item's builder is used instead.
* `OriginItem.builder` no longer replaces the overlay widget — `widget.child` is always used. The builder wraps the clipped child in the overlay.
* Overlay blocks gestures on content beneath when active (absorbs pointers between content and overlay layer).

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
