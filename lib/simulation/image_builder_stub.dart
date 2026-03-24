// Stub for headless environments where dart:ui is unavailable.
// Returns a Future that throws UnsupportedError.
import 'dart:typed_data';

Future<Object> buildImageFromPixels(
    Uint8List pixels, int width, int height) async {
  throw UnsupportedError('dart:ui is not available in this environment');
}
