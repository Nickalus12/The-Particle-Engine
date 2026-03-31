import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:the_particle_engine/bootstrap/app_bootstrap.dart';
import 'package:the_particle_engine/ui/screens/sandbox_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('can generate a world from the mobile menu flow', (
    tester,
  ) async {
    await bootstrapParticleEngineApp();

    await tester.pumpAndSettle(const Duration(seconds: 6));

    final createButton = find.byKey(const ValueKey('home_create_button'));
    expect(createButton, findsOneWidget);

    await tester.tap(createButton);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final worldCreateButton = find.byKey(const ValueKey('world_create_button'));
    expect(worldCreateButton, findsOneWidget);

    await tester.tap(worldCreateButton);
    await tester.pumpAndSettle(const Duration(seconds: 6));

    expect(find.byType(SandboxScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('sandbox_screen')), findsOneWidget);
  });
}
