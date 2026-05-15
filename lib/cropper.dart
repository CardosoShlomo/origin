import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'corner.dart';
import 'ext.dart';
import 'gestures.dart';
import 'rect_ext.dart';
import 'side.dart';
import 'stage.dart';

/// Image-coupled cropper tool. Designed to live in Stage's overlay slot
/// (typically via [DisplayConfig.overlay]) so its handle detectors render
/// *above* Stage's own recognizer in the hit-test order.
///
/// Reads [StageData.crop] for the live crop rect (owned by Stage, seeded
/// from [CropConfig.initialRect] when a crop mode activates) and renders:
/// - Dim overlay outside the crop rect (shaped by [CropConfig.borderRadius]).
/// - Rule-of-thirds grid inside (always rectangular).
/// - Corner / side resize handles.
///
/// Gesture model:
/// - 1-finger drag *on a handle* — resizes the crop rect via
///   [RectExt.moveCorner] / [RectExt.moveSide], honoring [CropConfig]
///   constraints.
/// - 1-finger drag *inside the crop rect* — handled by Stage's recognizer:
///   pans the crop rect, with the image coupling at edges via
///   [ScaleExt.imageRectOnDragCropRect] (cap configurable via
///   [CropConfig.overdragMax]).
/// - Pinch / drag *outside the crop rect* — falls through to Stage's
///   normal scale/drag gestures on the image.
class Cropper extends StatefulWidget {
  const Cropper({
    super.key,
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newStage = Stage.of(context);
    if (newStage.rect != _stage?.rect) {
      _stage?.rect.removeListener(_onImageRectChanged);
      _stage = newStage;
      _stage!.rect.addListener(_onImageRectChanged);
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
    final clamped = stage.crop.value.cropBoundaries(_boundaries(stage), crop.ratio);
    if (clamped != stage.crop.value) {
      stage.crop.value = clamped;
    }
  }

  Rect _boundaries(StageData stage) =>
      stage.rect.value.intersect(stage.display.rect);

  /// Hard package floor for crop rect dimensions (in logical pixels).
  /// Combined with [CropConfig.shortest] via max-component, so consumers
  /// can raise it but not lower it — a too-tiny crop rect is meaningless
  /// and un-grabbable.
  static const _minCropSide = 80.0;

  Size _effectiveMinSize(CropConfig c) {
    final consumer = c.shortest ?? Size.zero;
    return Size(
      math.max(consumer.width, _minCropSide),
      math.max(consumer.height, _minCropSide),
    );
  }

  void _moveCorner(Corner corner, Offset delta, CropConfig c, StageData stage) {
    // Boundaries computed fresh each update — `stage.rect` can be mid-
    // animation (e.g., setMode rect-rebase) and the captured outer-build
    // boundaries would go stale, causing [_onImageRectChanged] to clamp
    // the rect back the next frame.
    stage.crop.value = stage.crop.value.moveCorner(
      delta: delta,
      corner: corner,
      shortest: _effectiveMinSize(c),
      longest: c.longest,
      largest: c.largest,
      boundaries: _boundaries(stage),
      ratio: c.ratio,
    );
  }

  void _moveSide(Side side, double delta, CropConfig c, StageData stage) {
    stage.crop.value = stage.crop.value.moveSide(
      delta: delta,
      side: side,
      shortest: _effectiveMinSize(c),
      longest: c.longest,
      largest: c.largest,
      boundaries: _boundaries(stage),
      ratio: c.ratio,
    );
  }

  @override
  Widget build(BuildContext context) {
    final stage = Stage.of(context);
    final crop = stage.displayConfig()?.crop;
    if (crop == null) return const SizedBox.shrink();

    return ValueListenableBuilder<Rect>(
      valueListenable: stage.crop,
      builder: (context, cropRect, _) {
        final borderRadius = crop.borderRadius?.call(cropRect);
        // Cropper chrome (dim + grid) fades out during a real dismiss only.
        // Interaction + settle keep it solid. We multiply by
        // [originToBaseProgress] (which goes 1 → 0 as the rect heads back
        // to origin during dismiss).
        return ValueListenableBuilder<double>(
          valueListenable: stage.originToBaseProgress,
          builder: (context, p, _) {
            final chromeAlpha = stage.dismissing ? p : 1.0;
            final dimColor = widget.dimColor.withValues(
              alpha: widget.dimColor.a * chromeAlpha,
            );
            return Stack(
              fit: .expand,
              children: [
                // Dim overlay outside crop rect (visual only — no hit test).
                _DimOverlay(
                  cropRect: cropRect,
                  color: dimColor,
                  borderRadius: borderRadius,
                ),
                // Grid visual only (no gesture detector) — Stage's
                // recognizer owns 1-finger drags inside the crop rect.
                // During dismiss, the grid clips to the configured
                // borderRadius (e.g. circular for an avatar preview) so
                // its rectangular frame morphs in lockstep with the
                // image's clip lerp instead of sticking out as a
                // rectangle over the now-circular target.
                Positioned.fromRect(
                  rect: cropRect,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: chromeAlpha,
                      child: ClipRRect(
                        borderRadius: stage.dismissing
                            ? borderRadius ?? .zero
                            : .zero,
                        child: _CropGrid(
                          color: widget.gridColor,
                          lineWidth: widget.gridLineWidth,
                          borderColor: widget.gridBorderColor ?? widget.gridColor,
                          borderWidth: widget.gridBorderWidth,
                          divisions: widget.gridDivisions,
                          handleColor: widget.handleColor,
                          handleThickness: widget.handleThickness,
                        ),
                      ),
                    ),
                  ),
                ),
                // Corner / side handles — extend a bit beyond the crop
                // rect. Fade with chrome during dismiss too.
                Positioned.fromRect(
                  rect: cropRect.resizeOnCenter(
                    math.max(cropRect.width * 1.15, stage.display.rect.shortestSide / 3.5),
                    math.max(cropRect.height * 1.15, stage.display.rect.shortestSide / 3.5),
                  ),
                  child: Opacity(
                    opacity: chromeAlpha,
                    child: _CropHandles(
                      cropRect: cropRect,
                      minDimension: widget.minHandleDimension,
                      onMoveCorner: (corner, delta) =>
                          _moveCorner(corner, delta, crop, stage),
                      onMoveSide: (side, delta) =>
                          _moveSide(side, delta, crop, stage),
                    ),
                  ),
                ),
              ],
            );
          },
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
/// marks. Always rectangular — even when a [CropConfig.borderRadius] is set,
/// only the dim layer adopts the rounded shape (so e.g. for a circular
/// avatar preview the grid stays a square frame and the dim covers the rect
/// corners outside the circle). Visual only — gestures are handled by
/// [_CropHandles] outside.
class _CropGrid extends StatelessWidget {
  const _CropGrid({
    required this.color,
    required this.lineWidth,
    required this.borderColor,
    required this.borderWidth,
    required this.divisions,
    required this.handleColor,
    required this.handleThickness,
  });

  final Color color;
  final double lineWidth;
  final Color borderColor;
  final double borderWidth;
  final int divisions;
  final Color handleColor;
  final double handleThickness;

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

    final border = DecoratedBox(
      decoration: BoxDecoration(
        border: borderWidth > 0
            ? Border.all(color: borderColor, width: borderWidth)
            : null,
      ),
    );

    return IgnorePointer(
      child: Stack(
        fit: .expand,
        children: [
          Stack(fit: .expand, children: wires),
          _HandleMark(color: handleColor, thickness: handleThickness),
          RotatedBox(
            quarterTurns: 1,
            child: _HandleMark(
              color: handleColor,
              thickness: handleThickness,
            ),
          ),
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
