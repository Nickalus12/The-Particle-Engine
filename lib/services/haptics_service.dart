import 'package:flutter/services.dart';

/// Thin wrapper around [HapticFeedback] with a global toggle and throttle.
///
/// Provides semantic methods for different interaction strengths and prevents
/// excessive vibration by enforcing a minimum interval between haptic events.
class HapticsService {
  HapticsService._();

  static final HapticsService instance = HapticsService._();

  bool _enabled = true;

  bool get isEnabled => _enabled;
  set enabled(bool value) => _enabled = value;

  /// Minimum interval between any two haptic events.
  static const Duration _throttle = Duration(milliseconds: 50);
  DateTime _lastHaptic = DateTime(0);

  bool get _canFire {
    if (!_enabled) return false;
    final now = DateTime.now();
    if (now.difference(_lastHaptic) < _throttle) return false;
    _lastHaptic = now;
    return true;
  }

  /// Light tap — element placement, palette selection.
  void lightTap() {
    if (!_canFire) return;
    HapticFeedback.lightImpact();
  }

  /// Medium impact — reactions (steam, acid).
  void mediumTap() {
    if (!_canFire) return;
    HapticFeedback.mediumImpact();
  }

  /// Heavy impact — explosions, TNT.
  void heavyTap() {
    if (!_canFire) return;
    HapticFeedback.heavyImpact();
  }

  /// Selection click — UI button presses, toggle switches.
  void selectionClick() {
    if (!_canFire) return;
    HapticFeedback.selectionClick();
  }
}
