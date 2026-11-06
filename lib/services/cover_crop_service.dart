import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;

/// Crop coordinates are fractions of the oriented image, independent of preview size.
typedef CoverCropRequest = ({Uint8List bytes, double left, double top, double width, double height});

Future<ui.Size> coverPreviewSize(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1536, allowUpscaling: false);
  try {
    final frame = await codec.getNextFrame();
    try {
      return ui.Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

Future<Uint8List> cropCover(CoverCropRequest request) => compute(renderCoverCrop, request);

@visibleForTesting
Uint8List renderCoverCrop(CoverCropRequest request) {
  image.Image? decoded;
  try {
    decoded = image.decodeImage(request.bytes);
  } catch (_) {
    throw const FormatException('Could not read this image');
  }
  if (decoded == null) throw const FormatException('Could not read this image');
  final oriented = image.bakeOrientation(decoded);
  final x = (request.left * oriented.width).round().clamp(0, oriented.width - 1);
  final y = (request.top * oriented.height).round().clamp(0, oriented.height - 1);
  // A square crop is measured in source pixels, never stretched to fit.
  final side = (request.width * oriented.width).round().clamp(1, (oriented.width - x).clamp(1, oriented.height - y));
  var cropped = image.copyCrop(oriented, x: x, y: y, width: side, height: side);
  if (side > 1024) {
    cropped = image.copyResize(cropped, width: 1024, height: 1024, interpolation: image.Interpolation.cubic);
  }
  return Uint8List.fromList(image.encodePng(cropped));
}
