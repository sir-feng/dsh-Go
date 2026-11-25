// The diagnostics bundle, one ZIP a user can attach to a
// bug report. Gathered into a [DiagnosticsSnapshot] first, so the archive
// itself is built by pure functions (and tested as such).
//
//   dsh-go-diagnostics-20261024-153012.zip
//   ├── summary.json       app and DSH versions, device, Android, runtime
//   │                      manifest, engine state, connection kind
//   ├── settings.json      app settings, secrets reduced to "set or not"
//   ├── system-ime.json    input-method evidence, only when the person agreed
//   ├── crash.json         the last crash classification (when there is one)
//   ├── app-evidence.json  bounded failure evidence the native side kept
//   ├── engine.log         recent engine output
//   ├── failure.log        output around the last failure (when there is one)
//   └── app-errors.json    the app's own error log (when there are errors)
//
// Every string goes through `redactDiagnostics` on the way in.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../performance/performance_state.dart';
import '../state/app_info.dart';
import '../state/connection_state.dart';
import '../state/settings_state.dart';
import '../state/voice_settings.dart';
import 'diagnostics_channel.dart';
import 'app_error_log.dart';
import 'redact.dart';
import 'system_ime_diagnostics.dart';
import 'system_ime_evidence.dart';
import 'zip_writer.dart';

/// Most engine log lines a bundle carries (the native in-memory log's size).
const diagnosticsLogLines = 2000;

/// Everything a bundle is made of, read from the app and Android.
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.at,
    required this.settings,
    this.native = const NativeDiagnostics(),
    this.connection = const {},
    this.performance = const {},
    this.voiceMode = VoiceMode.auto,
    this.appErrors = const [],
    this.systemIme,
  });

  final DateTime at;
  final AppSettings settings;
  final NativeDiagnostics native;

  /// Last observed connection state and remote link stage; may be stale.
  /// `not_observed` means no active observation is currently retained.
  final Map<String, Object?> connection;
  final Map<String, Object?> performance;
  final VoiceMode voiceMode;
  final List<AppErrorRecord> appErrors;

  /// Only a deliberate manual publication/export includes retained opt-in evidence.
  final SystemImeEvidence? systemIme;
}

abstract final class DiagnosticsBundle {
  static const mime = 'application/zip';

  /// `dsh-go-diagnostics-20261024-153012.zip` (ASCII: it travels through
  /// share targets and mail clients).
  static String fileName(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'dsh-go-diagnostics-${at.year}${two(at.month)}${two(at.day)}-'
        '${two(at.hour)}${two(at.minute)}${two(at.second)}.zip';
  }

  static Map<String, Object?> summary(DiagnosticsSnapshot s) {
    return {
      'generatedAt': s.at.toUtc().toIso8601String(),
      'timeZoneOffsetMinutes': s.at.timeZoneOffset.inMinutes,
      'app': {'version': AppInfo.version, ...s.native.app},
      'device': s.native.device,
      'manifest': s.native.manifest,
      'connection': s.connection,
      'performance': s.performance,
      'voice': {...voiceDiagnosticsFacts(s.native.voice), 'mode': s.voiceMode.name},
      'evidence': diagnosticEvidenceFacts(s.native.evidence),
    };
  }

  /// The app's settings; the API key only as whether one is set.
  static Map<String, Object?> settingsSummary(AppSettings s) => {
    'hasApiKey': s.hasApiKey,
    'customProviders': s.customProviderIds.length,
    'themeMode': s.themeMode.name,
    'chatTextScale': s.chatTextScale,
    'autoStartLocal': s.autoStartLocal,
    'autoStartLocalExplicit': s.autoStartLocalExplicit,
    'autoApproveCommands': s.autoApproveCommands,
    'phoneStorage': s.phoneStorage,
    'webPhoneLayout': s.webPhoneLayout,
    'foldCompletedTurns': s.foldCompletedTurns,
    'visualReplies': s.visualReplies,
  };

  /// The archive's files, every string redacted.
  static List<ZipEntry> entries(DiagnosticsSnapshot s) {
    const json = JsonEncoder.withIndent('  ');
    ZipEntry text(String name, String body) => ZipEntry(name, utf8.encode(body));
    ZipEntry jsonFile(String name, Object? value) => text(name, '${json.convert(redactJson(value))}\n');

    return [
      jsonFile('summary.json', summary(s)),
      jsonFile('settings.json', settingsSummary(s.settings)),
      if (s.systemIme case final evidence?) jsonFile('system-ime.json', evidence.toJson()),
      if (s.appErrors.isNotEmpty) jsonFile('app-errors.json', s.appErrors.map((error) => error.toJson()).toList()),
    ];
  }

  static Uint8List build(DiagnosticsSnapshot s) => buildZip(entries(s), modified: s.at);
}

/// Reads a [DiagnosticsSnapshot] from the app's state and Android. Every
/// source is optional: a part that can't be read is left out.
/// (The local engine's status/log/failure sources went with the runtime; the
/// bundle now carries the app, the connection and the remote host's state.)
Future<DiagnosticsSnapshot> collectDiagnostics(Ref ref, DateTime at, {bool includeSystemIme = false}) async {
  final settings = ref.read(settingsProvider);
  final channel = ref.read(diagnosticsChannelProvider);
  final systemIme = includeSystemIme ? ref.read(systemImeDiagnosticsProvider) : null;
  const wait = Duration(seconds: 5);

  Future<T> attempt<T>(Future<T> Function() read, T fallback) async {
    try {
      return await read().timeout(wait);
    } catch (_) {
      return fallback;
    }
  }

  final native = await attempt(channel.info, const NativeDiagnostics());

  return DiagnosticsSnapshot(
    at: at,
    settings: settings,
    native: native,
    connection: ref.read(connectionDiagnosticsProvider).snapshot,
    performance: performanceDiagnostics(ref),
    voiceMode: await attempt(() => ref.read(voiceSettingsProvider.notifier).ready(), VoiceMode.auto),
    appErrors: appErrorLog.snapshot(),
    systemIme: systemIme?.evidence,
  );
}
