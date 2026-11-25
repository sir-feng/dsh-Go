import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../launch/launch_state.dart';
import '../../launch/startup_trace.dart';
import '../../diagnostics/automatic_diagnostics.dart';
import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import '../../state/onboarding_state.dart';
import '../../state/settings_state.dart';
import '../onboarding/onboarding_flow.dart';
import '../remote/remote_screen.dart';
import '../theme/theme.dart';
import '../web/mode_home.dart';
import 'brand_mark.dart';

/// Where a launch should start, given what is configured.
///
/// 本地引擎已随拆分线删除，首启不再有「本机/远程」安装引导；只保留
/// 远程主机需要的 API key 判断。首启直接进入主界面（远程入口在主界面承载）。
OnboardingStep? initialOnboardingStep({
  required bool hasApiKey,
  required OnboardingPrefs prefs,
  bool hasCustomProvider = false,
}) {
  // 远程主机也需要一个可用的模型入口：没有 key、没有自定义提供方、
  // 且用户没选「稍后设置」时，先走 key 录入。
  if (!hasApiKey && !hasCustomProvider && !prefs.keySkipped) return OnboardingStep.apiKey;
  return null;
}

/// App root: waits for settings and the native runtime to report in, then shows
/// onboarding or the home shell, and auto-starts the local engine once per launch
/// (设置 › 引擎 › 打开 App 时自动启动).
class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key, this.home});

  /// Stands in for [ModeHome] (tests).
  @visibleForTesting
  final Widget? home;

  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<RootGate> {
  bool _decided = false;

  bool _launchReady = false;
  OnboardingStep? _step;

  /// The host list is open over the setup step.
  bool _pickingRemote = false;

  void _goTo(OnboardingStep? step) {
    if (!mounted) return;
    setState(() => _step = step);
  }

  /// 「远程主机」: the host list over the setup step. Picking a host there
  /// (it closes itself) finishes first run; coming back without one returns
  /// to the choice.
  Future<void> _useRemote() async {
    if (_pickingRemote) return;
    _pickingRemote = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemoteScreen()));
    } finally {
      _pickingRemote = false;
    }
    if (!mounted || ref.read(activeHostProvider).isLocal) return;
    await ref.read(onboardingPrefsProvider.notifier).setLocalDeclined(true);
    // Android 13 asks about notifications once the channels exist, before the
    // first reply lands.
    unawaited(ref.read(notifyChannelProvider).status().then<void>((_) {}, onError: (_) {}));
    _goTo(null);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(automaticDiagnosticsProvider);
    final settings = ref.watch(settingsProvider);
    final prefs = ref.watch(onboardingPrefsProvider);
    // The last host comes back while the splash shows, so a remote host
    // doesn't open on 本机 for a frame before it.
    ref.read(activeHostProvider);

    final Widget child;
    if (!settings.loaded || !prefs.loaded) {
      StartupTrace.mark('waiting: settings ${settings.loaded}, setup ${prefs.loaded}');
      child = const _Splash();
    } else {
      if (!_decided) {
        _decided = true;
        _step = initialOnboardingStep(
          hasApiKey: settings.hasApiKey,
          hasCustomProvider: settings.customProviderIds.isNotEmpty,
          prefs: prefs,
        );
      }
      if (_step case final step?) {
        child = OnboardingFlow(
          step: step,
          onRemote: _useRemote,
          onKeyDone: () => _goTo(null),
        );
      } else {
        // 本地引擎已随拆分线删除，直接进入主界面（远程入口在主界面承载）。
        child = widget.home ?? const ModeHome();
      }
    }
    if (child is! _Splash && !_launchReady) {
      // 启动画面: the first page is up.
      _launchReady = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        StartupTrace.mark('first page');
        final launch = LaunchController.active.value;
        if (launch == null) return StartupTrace.finished();
        launch.ready();
      });
    }
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.page),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      child: KeyedSubtree(
        key: ValueKey(child is _Splash ? 'splash' : (_step == null ? 'home' : 'onboarding')),
        child: child,
      ),
    );
  }
}

/// Shown for the few hundred ms before settings arrive. Same
/// colour as the Android launch window; the mark fades in only if loading is slow.
class _Splash extends StatefulWidget {
  const _Splash();

  @override
  State<_Splash> createState() => _SplashState();
}

/// HarmonyOS 的本地引擎重置已随拆分线删除，不再有重置收尾界面。

class _SplashState extends State<_Splash> {
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(Theme.of(context).brightness),
      child: AppBackdrop(
        child: Center(
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: AppMotion.of(context, AppMotion.slow),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [BrandMark(size: 64, tile: true)],
            ),
          ),
        ),
      ),
    );
  }
}
