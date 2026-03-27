import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/ui/screens/world_create_screen.dart';

Future<void> _pumpWorldCreateScreen(
  WidgetTester tester,
  GlobalKey repaintKey,
) async {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SizedBox.shrink(),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(
        key: repaintKey,
        child: const WorldCreateScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _expectGolden(
  WidgetTester tester,
  GlobalKey repaintKey,
  String relativePath,
) async {
  final boundary = repaintKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ui.Image image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final bytes = byteData!.buffer.asUint8List();
  final goldenUri = Uri.parse(relativePath);
  final absoluteUri = goldenFileComparator.getTestUri(goldenUri, null);
  final file = File.fromUri(absoluteUri);
  if (!file.existsSync()) {
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes, flush: true);
    return;
  }

  final matches = await goldenFileComparator.compare(bytes, goldenUri);
  expect(matches, isTrue, reason: 'Golden mismatch for $relativePath');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorldCreateScreen goldens', () {
    testWidgets('blank preset overview', (tester) async {
      final repaintKey = GlobalKey();
      await _pumpWorldCreateScreen(tester, repaintKey);

      await _expectGolden(tester, repaintKey, '../goldens/ui/world_create_screen_blank.png');
    });

    testWidgets('canyon preset overview', (tester) async {
      final repaintKey = GlobalKey();
      await _pumpWorldCreateScreen(tester, repaintKey);

      final pageView = find.byType(PageView);
      await tester.drag(pageView, const Offset(-1000, 0));
      await tester.pumpAndSettle();
      await tester.drag(pageView, const Offset(-1000, 0));
      await tester.pumpAndSettle();

      await _expectGolden(tester, repaintKey, '../goldens/ui/world_create_screen_canyon.png');
    });
  });
}
