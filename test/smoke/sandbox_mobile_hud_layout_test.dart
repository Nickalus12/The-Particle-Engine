import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/ui/screens/sandbox_screen.dart';

Future<void> _waitForHud(WidgetTester tester) async {
  for (int i = 0; i < 220; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byIcon(Icons.brush_rounded).evaluate().isNotEmpty) {
      return;
    }
  }
  throw StateError('Sandbox HUD did not appear in time.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile creation HUD keeps toolbar above bottom paint bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: SandboxScreen(isBlankCanvas: true),
      ),
    );

    await _waitForHud(tester);
    await tester.tap(find.byIcon(Icons.brush_rounded));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('tool_bar_container')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('element_bottom_bar_container')),
      findsOneWidget,
    );

    final toolbarRect =
        tester.getRect(find.byKey(const ValueKey('tool_bar_container')));
    final bottomBarRect =
        tester.getRect(find.byKey(const ValueKey('element_bottom_bar_container')));

    expect(
      toolbarRect.bottom,
      lessThanOrEqualTo(bottomBarRect.top),
      reason: 'Toolbar must remain fully above the bottom paint bar.',
    );
  });
}
