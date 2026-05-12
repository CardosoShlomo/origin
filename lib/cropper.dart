import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'corner.dart';
import 'ext.dart';
import 'gestures.dart';
import 'rect_ext.dart';
import 'side.dart';
import 'stage.dart';

/// Holds the live crop rect for a [Cropper] instance and exposes basic
/// imperative controls. Consumer creates one and passes it into the
/// `Cropper`. After the user has manipulated the rect, the consumer reads
/// `value` to get the final crop rect and applies it however the host app
/// needs (typically cropping the source image and producing a new asset).
class CropController extends ValueNotifier<Rect> {
  CropController({Rect initial = Rect.zero}) : super(initial);

  void setRect(Rect rect) {
    value = rect;
  }

  void reset(Rect rect) {
    value = rect;
  }
}

/// Image-coupled cropper tool. Designed to live in Stage's overlay slot
/// (typically via `DisplayConfig.overlay`) so its gesture detectors render
/// *above* Stage's own recognizer in the hit-test order.
///
/// Reads `Stage.of(context).displayConfig()?.crop` for its constraints
/// ([CropConfig]). The widget renders:
/// - Dim overlay outside the crop rect.
/// - Rule-of-thirds grid inside.
/// - Corner / side resize handles (opaque hit-test, claim 1-finger pans).
/// - An inner pan detector covering the crop rect interior (translucent
///   hit-test so 2-finger pinch falls through to Stage's scale recognizer).
///
/// Gesture model (matches imagineai):
/// - 1-finger drag *on a handle* — resizes via [RectExt.moveCorner] /
///   [RectExt.moveSide], honoring `CropConfig` constraints.
/// - 1-finger drag *inside the crop rect* — pans the crop rect; the image
///   follows when the crop is at an edge (via [imageRectOnDragCropRect]).
/// - 2-finger pinch — falls through to Stage's scale gesture on the image.
class Cropper extends StatefulWidget {
  const Cropper({
    super.key,
    required this.controller,
    this.dimColor = const Color(0x88000000),
    this.handleColor = const Color(0xFFFFFFFF),
    this.gridColor = const Color(0xFFFFFFFF),
    this.gridLineWidth = 0.5,
    this.gridBorderColor,
    this.gridBorderWidth = 1,
    this.gridDivisions = 3,
    this.handleThickness = 4,
    this.minHandleDimension = 24,
  });

  final CropController controller;
  final Color dimColor;
  final Color handleColor;
  /// Color of the interior grid lines (and the border by default).
  final Color gridColor;
  /// Thickness of the interior grid lines.
  final double gridLineWidth;
  /// Color of the outer border. Falls back to [gridColor] when null.
  final Color? gridBorderColor;
  /// Thickness of the outer border (around the crop rect).
  final double gridBorderWidth;
  /// Number of grid divisions per axis. `3` = rule of thirds (2 interior
  /// lines on each axis). Must be ≥ 1. `1` means no interior lines.
  final int gridDivisions;
  /// Thickness of the visible corner/side handle marks.
  final double handleThickness;
  final double minHandleDimension;

  @override
  State<Cropper> createState() => _CropperState();
}

class _CropperState extends State<Cropper> {
  StageData? _stage;
  CropConfig? _lastCrop;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newStage = Stage.of(context);
    if (newStage.rect != _stage?.rect) {
      _stage?.rect.removeListener(_onImageRectChanged);
      _stage = newStage;
      _stage!.rect.addListener(_onImageRectChanged);
    }
    // First activation of a CropConfig → seed the crop rect via
    // [CropConfig.initialRect] if provided. Re-init on each config change
    // (e.g., switching from `'crop_square'` to `'crop_free'`).
    final crop = newStage.displayConfig()?.crop;
    if (crop != null && !identical(crop, _lastCrop)) {
      _lastCrop = crop;
      final init = crop.initialRect;
      if (init != null) {
        final base = newStage.display.rect.baseRect(newStage.aspectRatio);
        widget.controller.value = init(base);
      }
    } else if (crop == null) {
      _lastCrop = null;
    }
  }

  @override
  void dispose() {
    _stage?.rect.removeListener(_onImageRectChanged);
    super.dispose();
  }

  /// When the underlying image's rect changes (e.g., from a release fling,
  /// programmatic animation, or a parallel scale), re-clamp the crop rect
  /// so it stays inside the visible image.
  void _onImageRectChanged() {
    final stage = _stage;
    if (stage == null) return;
    final crop = stage.displayConfig()?.crop;
    if (crop == null) return;
    final clamped = widget.controller.value
        .cropBoundaries(_boundaries(stage), crop.ratio);
    if (clamped != widget.controller.value) {
      widget.controller.value = clamped;
    }
  }

  Rect _boundaries(StageData stage) =>
      stage.rect.value.intersect(stage.display.rect);

  void _moveCorner(Corner corner, Offset delta, Rect boundaries, CropConfig c) {
    widget.controller.value = widget.controller.value.moveCorner(
      delta: delta,
      corner: corner,
      shortest: c.shortest ?? Size.zero,
      longest: c.longest,
      largest: c.largest,
      boundaries: boundaries,
      ratio: c.ratio,
    );
  }

  void _moveSide(Side side, double delta, Rect boundaries, CropConfig c) {
    widget.controller.value = widget.controller.value.moveSide(
      delta: delta,
      side: side,
      shortest: c.shortest ?? Size.zero,
      longest: c.longest,
      largest: c.largest,
      boundaries: boundaries,
      ratio: c.ratio,
    );
  }

  void _onInnerPanUpdate(DragUpdateDetails details, CropConfig c, StageData stage) {
    final newCrop = widget.controller.value
        .shift(details.delta)
        .cropBoundaries(_boundaries(stage), c.ratio);
    widget.controller.value = newCrop;
    // Image follows when crop reaches an edge — mirrors imagineai's coupling.
    stage.rect.value = ScaleUpdateDetails(
      focalPoint: details.globalPosition,
      focalPointDelta: details.delta,
      localFocalPoint: details.localPosition,
    ).imageRectOnDragCropRect(
      container: stage.display.rect,
      imageRect: stage.rect.value,
      cropRect: newCrop,
    );
  }

  @override
  Widget build(BuildContext context) {
    final stage = Stage.of(context);
    final crop = stage.displayConfig()?.crop;
    if (crop == null) return const SizedBox.shrink();

    final boundaries = _boundaries(stage);

    return ValueListenableBuilder<Rect>(
      valueListenable: widget.controller,
      builder: (context, cropRect, _) {
        final borderRadius = crop.borderRadius?.call(cropRect);
        return Stack(
          fit: .expand,
          children: [
            // Dim overlay outside crop rect (visual only — no hit test).
            _DimOverlay(
              cropRect: cropRect,
              color: widget.dimColor,
              borderRadius: borderRadius,
            ),
            // Inner-area drag detector: 1-finger pan moves the crop rect.
            // Translucent so 2-finger pinch falls through to Stage.
            Positioned.fromRect(
              rect: cropRect,
              child: GestureDetector(
                behavior: .translucent,
                onPanUpdate: (d) => _onInnerPanUpdate(d, crop, stage),
                child: _CropGrid(
                  color: widget.gridColor,
                  lineWidth: widget.gridLineWidth,
                  borderColor: widget.gridBorderColor ?? widget.gridColor,
                  borderWidth: widget.gridBorderWidth,
                  divisions: widget.gridDivisions,
                  handleColor: widget.handleColor,
                  handleThickness: widget.handleThickness,
                  borderRadius: borderRadius,
                ),
              ),
            ),
            // Corner / side handles — extend a bit beyond the crop rect.
            Positioned.fromRect(
              rect: cropRect.resizeOnCenter(
                math.max(cropRect.width * 1.15, stage.display.rect.shortestSide / 3.5),
                math.max(cropRect.height * 1.15, stage.display.rect.shortestSide / 3.5),
              ),
              child: _CropHandles(
                cropRect: cropRect,
                minDimension: widget.minHandleDimension,
                onMoveCorner: (corner, delta) =>
                    _moveCorner(corner, delta, boundaries, crop),
                onMoveSide: (side, delta) =>
                    _moveSide(side, delta, boundaries, crop),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DimOverlay extends StatelessWidget {
  const _DimOverlay({
    required this.cropRect,
    required this.color,
    required this.borderRadius,
  });

  final Rect cropRect;
  final Color color;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    // White "punch-out" shape — rounded if borderRadius is set.
    final punchOut = borderRadius == null
        ? const ColoredBox(color: Color(0xFFFFFFFF))
        : DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: borderRadius,
            ),
          );
    return IgnorePointer(
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(color, BlendMode.srcOut),
        child: Stack(
          fit: .expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xFF000000),
                backgroundBlendMode: BlendMode.dstOut,
              ),
            ),
            Positioned.fromRect(rect: cropRect, child: punchOut),
          ],
        ),
      ),
    );
  }
}

/// Renders the interior grid lines, outer border, and corner/side handle
/// marks. Visual only — gestures are handled by [_CropHandles] outside.
///
/// When [borderRadius] is non-null:
/// - Outer border becomes a rounded rect.
/// - Interior wires are clipped to the rounded shape.
/// - Linear corner/side handle marks are suppressed (they wouldn't align
///   with curved corners). Users still grab via the bigger touch areas.
class _CropGrid extends StatelessWidget {
  const _CropGrid({
    required this.color,
    required this.lineWidth,
    required this.borderColor,
    required this.borderWidth,
    required this.divisions,
    required this.handleColor,
    required this.handleThickness,
    required this.borderRadius,
  });

  final Color color;
  final double lineWidth;
  final Color borderColor;
  final double borderWidth;
  final int divisions;
  final Color handleColor;
  final double handleThickness;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    // Interior wires (rule-of-thirds style) drawn via Aligns. For divisions
    // = n, draw n − 1 horizontal + n − 1 vertical lines at evenly spaced
    // alignment values in [−1, 1].
    final wires = <Widget>[];
    for (int i = 1; i < divisions; i++) {
      final t = -1.0 + 2.0 * i / divisions;
      wires.add(Align(
        alignment: Alignment(0, t),
        child: SizedBox(
          height: lineWidth,
          child: ColoredBox(color: color, child: const SizedBox.expand()),
        ),
      ));
      wires.add(Align(
        alignment: Alignment(t, 0),
        child: SizedBox(
          width: lineWidth,
          child: ColoredBox(color: color, child: const SizedBox.expand()),
        ),
      ));
    }

    Widget interior = Stack(fit: .expand, children: wires);
    if (borderRadius case final br?) {
      interior = ClipRRect(borderRadius: br, child: interior);
    }

    final border = DecoratedBox(
      decoration: BoxDecoration(
        border: borderWidth > 0
            ? Border.all(color: borderColor, width: borderWidth)
            : null,
        borderRadius: borderRadius,
      ),
    );

    return IgnorePointer(
      child: Stack(
        fit: .expand,
        children: [
          interior,
          // Linear handle marks (corner L-shapes + side mid-bars). Hidden
          // when a non-null borderRadius is in play because they'd visually
          // misalign with curved corners.
          if (borderRadius == null) ...[
            _HandleMark(color: handleColor, thickness: handleThickness),
            RotatedBox(
              quarterTurns: 1,
              child: _HandleMark(
                color: handleColor,
                thickness: handleThickness,
              ),
            ),
          ],
          border,
        ],
      ),
    );
  }
}

/// Corner/side handle marks: a Column with a handle row at top, a Spacer,
/// then a handle row at bottom. Stacked with a rotated copy in [_CropGrid]
/// to cover all four sides.
class _HandleMark extends StatelessWidget {
  const _HandleMark({required this.color, required this.thickness});

  final Color color;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final bar = ColoredBox(color: color, child: SizedBox(height: thickness));
    final row = Row(
      children: [
        Expanded(flex: 1, child: bar),
        const Spacer(flex: 3),
        Expanded(flex: 2, child: bar),
        const Spacer(flex: 3),
        Expanded(flex: 1, child: bar),
      ],
    );
    return Column(
      children: [
        row,
        const Spacer(),
        row,
      ],
    );
  }
}

class _CropHandles extends StatelessWidget {
  const _CropHandles({
    required this.cropRect,
    required this.minDimension,
    required this.onMoveCorner,
    required this.onMoveSide,
  });

  final Rect cropRect;
  final double minDimension;
  final void Function(Corner corner, Offset delta) onMoveCorner;
  final void Function(Side side, double delta) onMoveSide;

  Widget _detector({
    required GestureDragUpdateCallback onPanUpdate,
    required Widget child,
  }) {
    return GestureDetector(
      behavior: .opaque,
      onPanUpdate: onPanUpdate,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bigW = math.max(cropRect.width / 2.5, minDimension);
    final bigH = math.max(cropRect.height / 2.5, minDimension);
    final smallW = math.max(bigW / 2, minDimension);
    final smallH = math.max(bigH / 2, minDimension);

    final cornerBox = SizedBox(width: smallW, height: smallH);
    final vBox = SizedBox(width: bigW, height: smallH);
    final hBox = SizedBox(width: smallW, height: bigH);

    return Column(
      mainAxisAlignment: .spaceBetween,
      children: [
        Row(
          mainAxisAlignment: .spaceBetween,
          children: [
            _detector(onPanUpdate: (d) => onMoveCorner(.topLeft, d.delta), child: cornerBox),
            _detector(onPanUpdate: (d) => onMoveSide(.top, d.delta.dy), child: vBox),
            _detector(onPanUpdate: (d) => onMoveCorner(.topRight, d.delta), child: cornerBox),
          ],
        ),
        Row(
          mainAxisAlignment: .spaceBetween,
          children: [
            _detector(onPanUpdate: (d) => onMoveSide(.left, d.delta.dx), child: hBox),
            _detector(onPanUpdate: (d) => onMoveSide(.right, d.delta.dx), child: hBox),
          ],
        ),
        Row(
          mainAxisAlignment: .spaceBetween,
          children: [
            _detector(onPanUpdate: (d) => onMoveCorner(.bottomLeft, d.delta), child: cornerBox),
            _detector(onPanUpdate: (d) => onMoveSide(.bottom, d.delta.dy), child: vBox),
            _detector(onPanUpdate: (d) => onMoveCorner(.bottomRight, d.delta), child: cornerBox),
          ],
        ),
      ],
    );
  }
}
