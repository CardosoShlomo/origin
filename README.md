# Origin

Hero transitions you can hold. An `Origin` is a widget in your layout (a
product thumbnail); its `Stage` is the layer above the screen where that
widget flies when it opens, follows the finger while dragged or pinched,
and flies home when it lets go.

```dart
Stage(
  child: ProductGrid(
    itemBuilder: (context, product) => Origin(
      tag: product.id,
      onTap: (event) => event.animateToBase(),
      displayConfig: const DisplayConfig(onDoubleTap: Stage.zoomToggleOnDoubleTap),
      child: ProductPhoto(product),
    ),
  ),
)
```

## What it does

- **Open and fly home.** A tap opens the Origin to its base rect (the
  largest rect of its aspect ratio inside the display). `dismiss` flies it
  back to where the Origin stands now, unless you pointed home elsewhere
  with `setOrigin` (a swiped card flying off screen).
- **Gestures with physics.** `drag` and `scale` maps pick a gesture by start
  direction; `GestureBounds` give each side friction, decay and a settle.
  Release plans (`Release.toDisplay`, `Release.toHalt`) are pure functions
  of the rect, the display and the velocity.
- **Modes.** One Origin, several display configs: `setMode('crop')` merges
  the mode onto the default and animates to its display.
- **Crop.** A `CropConfig` mode with a `Cropper` overlay; `resetCrop`,
  `cropSourceRect` and `landCrop` cover reset, cut and the flight home of
  the cropped photo.
- **Sends and swaps.** `sendEntry` flies an Origin to a computed rect;
  `swapTags` let one dragged Origin displace another.

## State

Every Stage owns a [regent](https://pub.dev/packages/regent) `Ledger` over
`stageRows`. What the stage shows (`StageScene`) is one unit; its status
(open, the flight in the air, the touch, the Origin's gesture) is another
(`StageStance`); sends and their phases are two stores. Flights carry an
epoch, and a landing of a superseded flight is dropped by a veto, so a late
animation can never end the session that replaced it. `StageData` reads the
ledger live, so a `StageData` held from any build is never stale.

Frame-rate geometry (the rect, the crop rect, the rotation, the progress
values) stays on animation controllers and `ValueListenable`s: a position
under a finger is not a fact.

## Tests

`flutter test`: the stage rows replayed as facts, the pure physics, and the
Stage in widget tests (open, dismiss, interrupted motion, lost gestures,
release velocity, a stage leaving mid-flight, crop).
