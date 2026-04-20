## 1.5.2

* Send overlays now clip against the origin container, matching the main overlay's clipping during reorder.
* Container expansion tracks per-frame drag deltas (monotonic — only grows during drag). Animated shrink back to origin container on dismiss, synced with the rect animation.

## 1.5.1

* Only reject multi-pointer when the recognizer has explicit gestures. Keeps pinch working on Stage's root recognizer.

## 1.5.0

* **Breaking:** `dismiss` signature changed from `dismiss([Object? tag])` to `dismiss({Object? tag, Object? except})`. `except` skips the given tag from the return-all loop (for preserving swap targets).
* **Breaking:** `unregister` now requires the `OriginEntry` instance. Identity-aware unregister only removes the tag from the registry if the stored entry matches, preventing transient duplicates during keyed-children reorders.
* `register` no longer asserts on duplicate tags — transient duplicates are tolerated and later resolved via identity-aware unregister.
* `_displace` now returns other parked/sending items to home on hover change, cleaning up stale displacements proactively.
* `StageScaleRecognizer` rejects the arena when a second pointer joins a single-pointer-only recognizer — releases pointers so nested Origins with multi-pointer gestures can claim them.

## 1.4.0

* `onEnd` accepts `FutureOr<void>` and is awaited before `reset()`.
* `dismiss()` returns all active sends to `.returning` state.

## 1.3.1

* Guard `dismiss(tag)` to prevent stale tag states when tag has no active send.

## 1.3.0

* Swap support: `swapTags` and `onSwap` on `Origin` for drag-to-reorder between Origins.
* `_SendLayer` animates displaced items to target and back.
* `TagState` enum (`idle`, `sending`, `parked`, `returning`) tracks displacement state.
* `Stage.stateOf(context, tag)` and `Stage.isActiveOf(context, tag)` accessors.
* `displace`, `release`, `captureEntry` on `StageData`.
* `isTagOf` now returns `true` for displaced tags (not just the active tag). Use `isActiveOf` for the previous behavior.

## 1.2.1

* Fix `sendEntry` using stale origin rect instead of measured position.

## 1.2.0

* Container computed in `Stage` via `ValueNotifier<OriginRect?>`, expand-only during interaction, shrinks on dismiss.
* `Stage.isDismissingOf(context)` aspect-based accessor.
* `dismissing` field on `StageData`.
* Dismiss drag anchors rect to pointer — content stays pinned under finger while scaling.

## 1.1.0

* **Breaking:** `itemGesturing` / `setItemGesturing` replaced by `locked` / `setLocked`. Stage defaults to locked, unlocks after `animateToBase` completes, relocks on `reset`.
* **Breaking:** `origin`, `originContainer`, `display`, `displayContainer`, `aspectRatio` on `StageData` changed from `ValueNotifier` to plain values with setters.
* **Breaking:** `originContainer` and `displayContainer` are now nullable. `null` means full screen (no container clip).
* Container clipping: overlay clips content to an animated container rect using `ClipPath`. Container expands from `originContainer` toward `displayContainer` as the item moves.
* `Stage.isLockedOf(context)` static accessor.
* `containerTag` no longer falls back to `widget.tag` — only explicit container tags are measured.

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
