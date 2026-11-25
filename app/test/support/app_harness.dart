import 'package:dsh_app/state/account_state.dart' show AccountController, AccountState;
import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'test_fonts.dart';

ThemeData testTheme(Brightness brightness) {
  final base = brightness == Brightness.dark ? buildDarkTheme() : buildLightTheme();
  return withTestFonts(base.copyWith(textTheme: base.textTheme.apply(fontFamilyFallback: const [cjkFamily])));
}

void usePhoneView(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
  tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 32);
  addTearDown(tester.view.reset);
}

Widget testApp(Widget home, {Brightness brightness = Brightness.light, List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: [accountWalletBalanceProvider.overrideWithValue(null), ...overrides],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: testTheme(Brightness.light),
      darkTheme: testTheme(Brightness.dark),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MirroredSideInsets(child: child!),
      home: home,
    ),
  );
}

Future<void> awayAndBack(WidgetTester tester) async {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

class FakeSettings extends SettingsController {
  FakeSettings(this.initial);

  final AppSettings initial;

  @override
  AppSettings build() => initial;
}

class FakeChatController extends ChatController {
  FakeChatController(super.sessionId, this.initial);

  final ChatState initial;

  @override
  ChatState build() {
    ref.keepAlive();
    return initial;
  }

  void emit(ChatState next) => state = next;
}

/// Controller frozen in [fixed] (goldens): no Host, no streams.
class FixedAccount extends AccountController {
  FixedAccount(this.fixed);

  final AccountState fixed;

  @override
  AccountState build() => fixed;
}
