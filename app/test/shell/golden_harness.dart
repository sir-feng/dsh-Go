// Shared setup for the shell golden tests: real fonts, fake providers, a phone-sized
// surface and a helper that renders one screen in light and dark.

import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/sessions_state.dart' show CurrentSessionController, SessionsController;
import 'package:dsh_client/dsh_client.dart' show SessionProjections, SessionSummary;
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';

Future<void> loadGoldenFonts() => loadTestFonts();

void usePhoneSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.padding = const FakeViewPadding(top: 64, bottom: 48);
  tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 48);
  addTearDown(tester.view.reset);
}

class FakeSessions extends SessionsController {
  FakeSessions(this.sessions);

  final List<SessionSummary> sessions;

  @override
  Future<List<SessionSummary>> build() async => sessions;
}

class FakeCurrentSession extends CurrentSessionController {
  FakeCurrentSession(this.initial);

  final String? initial;

  @override
  String? build() => initial;
}

List<SessionSummary> sampleSessions() => [
    SessionSummary(
      sessionId: 's1',
      updatedAt: DateTime(2026, 10, 31),
      running: true,
      blank: false,
      agentAvailable: true,
      projections: SessionProjections(1, {'title': '修复登录按钮重复提交'}),
    ),
    SessionSummary(
      sessionId: 's2',
      updatedAt: DateTime(2026, 10, 31).subtract(const Duration(hours: 3)),
      running: false,
      blank: false,
      agentAvailable: false,
      projections: SessionProjections(1, {'title': '给设置页加深色模式'}),
    ),
  ];

Widget goldenApp({
  required Widget home,
  required Brightness brightness,
  List<Override> overrides = const [],
  bool animations = false,
}) {
  return ProviderScope(
    overrides: [accountWalletBalanceProvider.overrideWithValue(null), ...overrides],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: withTestFonts(buildLightTheme()),
      darkTheme: withTestFonts(buildDarkTheme()),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MirroredSideInsets(child: child!),
      home: home,
    ),
  );
}

Future<void> goldenBoth(
  String name,
  Widget Function() home, {
  List<Override> Function()? overrides,
  Future<void> Function(WidgetTester)? before,
}) async {
  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('$name ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(home: home(), brightness: brightness, overrides: overrides?.call() ?? const []),
      );
      await tester.pump();
      await before?.call(tester);
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
    });
  }
}
