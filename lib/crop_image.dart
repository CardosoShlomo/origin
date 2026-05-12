import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Convert a crop rect from display coordinates to source-image pixel
/// coordinates.
///
/// The display rect (`cropRect`) and the image's current display rect
/// (`imageDisplayRect`) share the same coordinate space (whatever Stage
/// uses — typically the screen). The source image lives in its own pixel
/// space ([sourceSize]). This function maps the crop rect into that pixel
/// space via the scale ratio between the displayed image and its source.
Rect displayRectToSourceRect({
  required Rect cropRect,
  required Rect imageDisplayRect,
  required Size sourceSize,
}) {
  if (imageDisplayRect.width == 0 || imageDisplayRect.height == 0) {
    return Rect.zero;
  }
  final scaleX = sourceSize.width / imageDisplayRect.width;
  final scaleY = sourceSize.height / imageDisplayRect.height;
  return Rect.fromLTWH(
    (cropRect.left - imageDisplayRect.left) * scaleX,
    (cropRect.top - imageDisplayRect.top) * scaleY,
    cropRect.width * scaleX,
    cropRect.height * scaleY,
  );
}

/// Crop a region of an image, returning the cropped bytes.
///
/// Uses Flutter's Skia renderer — GPU-accelerated, no extra dependencies.
/// [source] is the original image's encoded bytes (PNG/JPG/etc., anything
/// `instantiateImageCodec` accepts). [srcRect] is the region to extract,
/// in source-image pixel coordinates (use [displayRectToSourceRect] to
/// convert from display-coord crop rects).
///
/// Returns encoded bytes in [format] (PNG by default).
Future<Uint8List> cropImageBytes(
  Uint8List source,
  Rect srcRect, {
  ui.ImageByteFormat format = ui.ImageByteFormat.png,
}) async {
  final codec = await ui.instantiateImageCodec(source);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final width = srcRect.width.round();
    final height = srcRect.height.round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      srcRect,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    try {
      final cropped = await picture.toImage(width, height);
      try {
        final bytes = await cropped.toByteData(format: format);
        if (bytes == null) {
          throw StateError('Cropped image returned no bytes.');
        }
        return bytes.buffer.asUint8List();
      } finally {
        cropped.dispose();
      }
    } finally {
      picture.dispose();
    }
  } finally {
    image.dispose();
  }
}
