import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/ui/screens/world_create_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('world create screen renders preset cards and create action', (tester) async {
    tester.view.physicalSize = const Size(1440, 2960);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: WorldCreateScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('New World'), findsOneWidget);
    expect(find.text('Blank Canvas'), findsOneWidget);
    expect(find.byKey(const ValueKey('world_create_button')), findsOneWidget);
    expect(find.byKey(const ValueKey('world_preset_insight_panel')), findsOneWidget);
    expect(find.text('MANUAL'), findsOneWidget);
  });

  testWidgets('world create screen updates insight panel when swiping presets', (tester) async {
    tester.view.physicalSize = const Size(1440, 2960);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: WorldCreateScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MANUAL'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('TEMPERATE'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('ARID'), findsOneWidget);
    expect(find.text('Steep walls'), findsOneWidget);
  });
}
