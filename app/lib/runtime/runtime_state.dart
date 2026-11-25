import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'background_protection.dart';
import 'runtime_bridge.dart';

final runtimeBridgeProvider = Provider<RuntimeBridge>((ref) => RuntimeBridge());

/// [RuntimeBridge.batteryExempt]; invalidate to read it again.
final batteryExemptProvider = FutureProvider<bool?>((ref) => ref.watch(runtimeBridgeProvider).batteryExempt());

/// The phone maker and the app's name in system settings; null without the native side.
final backgroundSettingsProvider = FutureProvider<BackgroundSettingsInfo?>(
  (ref) => ref.watch(runtimeBridgeProvider).backgroundSettings(),
);

/// Re-read after native status changes and when returning from system settings.
/// Native failures must settle the pending update, not wait for automatic retries.
final backgroundProtectionProvider = FutureProvider.autoDispose<BackgroundProtection?>((ref) {
  return ref.watch(runtimeBridgeProvider).backgroundProtection();
}, retry: (_, _) => null);
