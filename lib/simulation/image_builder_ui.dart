// Flutter environment implementation using dart:ui.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

Future<ui.Image> buildImageFromPixels(
    Uint8List pixels, int width, int height) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    (image) => completer.complete(image),
  );
  return completer.future;
}
