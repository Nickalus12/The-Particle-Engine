import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/game/runtime/sandbox_runtime_profile.dart';

void main() {
  group('SandboxRuntimeProfile', () {
    test('phone profile biases toward lower render cost', () {
      const profile = SandboxRuntimeProfile.phone;

      expect(
        profile.gridWidth,
        lessThan(SandboxRuntimeProfile.desktop.gridWidth),
      );
      expect(profile.mobileRenderInterval, greaterThanOrEqualTo(2));
      expect(
        profile.mobilePostProcessInterval,
        greaterThan(profile.mobileRenderInterval),
      );
      expect(profile.mobileCreatureDetail, isFalse);
    });

    test('desktop profile keeps full-detail defaults', () {
      const profile = SandboxRuntimeProfile.desktop;

      expect(profile.mobileRenderInterval, 1);
      expect(profile.mobilePostProcessInterval, 1);
      expect(profile.mobileCreatureDetail, isTrue);
    });
  });
}
