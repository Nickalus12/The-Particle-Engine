import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Wraps the active golden comparator and bootstraps missing baselines by
/// writing the first rendered snapshot to disk.
class BootstrappingGoldenComparator implements GoldenFileComparator {
  BootstrappingGoldenComparator(this._delegate);

  final GoldenFileComparator _delegate;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final goldenUri = getTestUri(golden, null);
    final file = File.fromUri(goldenUri);
    if (!file.existsSync()) {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(imageBytes, flush: true);
      return true;
    }
    return _delegate.compare(imageBytes, golden);
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) {
    return _delegate.update(golden, imageBytes);
  }

  @override
  Uri getTestUri(Uri key, int? version) {
    return _delegate.getTestUri(key, version);
  }
}
