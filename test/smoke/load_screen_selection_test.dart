import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/ui/screens/load_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'particle_engine_load_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method == 'getApplicationDocumentsDirectory') {
            return tempDir.path;
          }
          return null;
        });
  });

  setUp(() async {
    final savesDir = Directory('${tempDir.path}/particle_engine_saves');
    if (await savesDir.exists()) {
      await savesDir.delete(recursive: true);
    }
    await savesDir.create(recursive: true);

    Future<void> writeSlot({
      required int slot,
      required String name,
      required DateTime savedAt,
      required int colonyCount,
    }) async {
      final meta = <String, dynamic>{
        'slot': slot,
        'name': name,
        'savedAt': savedAt.toIso8601String(),
        'gridW': 192,
        'gridH': 108,
        'frameCount': 1200,
        'colonyCount': colonyCount,
      };
      await File(
        '${savesDir.path}/save_$slot.meta',
      ).writeAsString(jsonEncode(meta));
      await File('${savesDir.path}/save_$slot.json').writeAsString('{"ok":1}');
    }

    final now = DateTime.now();
    await writeSlot(
      slot: 0,
      name: 'Auto-save',
      savedAt: now.subtract(const Duration(minutes: 5)),
      colonyCount: 2,
    );
    await writeSlot(
      slot: 1,
      name: 'Alpha Ridge',
      savedAt: now.subtract(const Duration(days: 2)),
      colonyCount: 0,
    );
    await writeSlot(
      slot: 2,
      name: 'Zulu Basin',
      savedAt: now.subtract(const Duration(hours: 1)),
      colonyCount: 4,
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('load screen supports world search and filters', (tester) async {
    tester.view.physicalSize = const Size(1440, 2960);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const MaterialApp(home: LoadScreen()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('load_search_field')), findsOneWidget);
    expect(find.byKey(const ValueKey('load_sort_recent_chip')), findsOneWidget);
    expect(find.byKey(const ValueKey('load_filter_auto_chip')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('load_filter_colonies_chip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('load_selection_summary_strip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('load_quick_latest_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('load_quick_create_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('load_quick_clear_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('load_sort_colonies_chip')),
      findsOneWidget,
    );

    expect(find.text('Auto-save'), findsOneWidget);
    expect(find.text('Alpha Ridge'), findsOneWidget);
    expect(find.text('Zulu Basin'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('load_search_field')),
      'Zulu',
    );
    await tester.pumpAndSettle();

    expect(find.text('Zulu Basin'), findsOneWidget);
    expect(find.text('Auto-save'), findsNothing);
    expect(find.text('Alpha Ridge'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('load_search_field')), '');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('load_sort_colonies_chip')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('load_filter_auto_chip')));
    await tester.pumpAndSettle();
    expect(find.text('Auto-save'), findsOneWidget);
    expect(find.text('Alpha Ridge'), findsNothing);
    expect(find.text('Zulu Basin'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('load_filter_auto_chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('load_filter_colonies_chip')));
    await tester.pumpAndSettle();

    expect(find.text('Auto-save'), findsOneWidget);
    expect(find.text('Zulu Basin'), findsOneWidget);
    expect(find.text('Alpha Ridge'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('load_sort_name_chip')));
    await tester.pumpAndSettle();
    final firstNameFinder = find.descendant(
      of: find.byType(GridView),
      matching: find.text('Auto-save'),
    );
    expect(firstNameFinder, findsOneWidget);

    expect(
      find.byKey(const ValueKey('load_delete_icon_slot_0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('load_rename_icon_slot_0')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('load_search_field')),
      'Alpha',
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha Ridge'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('load_quick_clear_button')));
    await tester.pumpAndSettle();
    expect(find.text('Zulu Basin'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('load_rename_icon_slot_0')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('load_rename_text_field')),
      findsOneWidget,
    );
  });
}
