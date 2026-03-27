import 'package:integration_test/integration_test.dart';

import 'package:the_particle_engine/bootstrap/app_bootstrap.dart';

void main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  await bootstrapParticleEngineApp();
}
