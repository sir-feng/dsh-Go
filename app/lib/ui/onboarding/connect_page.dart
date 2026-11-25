import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/account_state.dart';
import '../../state/onboarding_state.dart';
import '../providers/provider_form_page.dart';
import '../theme/app_icons.dart';
import 'api_key_page.dart';
import 'onboarding_scaffold.dart';

/// First-run "connect" step: the API key first (the DeepSeek OAuth account
/// sign-in was local-engine-only and is gone with the runtime), another
/// provider (own Base URL and key), or skip for now.
class ConnectPage extends ConsumerStatefulWidget {
  const ConnectPage({super.key, required this.onDone});

  /// Called after a saved key, a saved custom provider, or "稍后设置".
  final VoidCallback onDone;

  @override
  ConsumerState<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends ConsumerState<ConnectPage> {
  bool _keyEntry = false;

  /// Depth of the page shown last (choice 0, key entry 1): going deeper slides
  /// forward, coming back slides back.
  int _depth = 0;
  bool _forward = true;

  void _skip() async {
    await ref.read(onboardingPrefsProvider.notifier).setKeySkipped(true);
    widget.onDone();
  }

  /// The add-provider form over this step.
  Future<void> _otherProvider() async {
    ref.read(accountProvider.notifier).dismissFailure();
    final id = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ProviderFormPage()));
    if (id == null || !mounted) return;
    await ref.read(onboardingPrefsProvider.notifier).setKeySkipped(true);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final Widget page;
    if (_keyEntry) {
      page = ApiKeyPage(
        key: const ValueKey('key'),
        onDone: widget.onDone,
        onBack: () => setState(() => _keyEntry = false),
      );
    } else {
      page = _Choose(
        key: const ValueKey('choose'),
        onApiKey: () {
          ref.read(accountProvider.notifier).dismissFailure();
          setState(() => _keyEntry = true);
        },
        onOther: _otherProvider,
        onSkip: _skip,
      );
    }
    final depth = page is _Choose ? 0 : 1;
    if (depth != _depth) {
      _forward = depth > _depth;
      _depth = depth;
    }
    return PopScope<void>(
      canPop: page is _Choose,
      child: OnboardingSwitcher(forward: _forward, child: page),
    );
  }
}

class _Choose extends StatelessWidget {
  const _Choose({super.key, required this.onApiKey, required this.onOther, required this.onSkip});

  final VoidCallback onApiKey;
  final VoidCallback onOther;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return OnboardingScaffold(
      children: [
        const Spacer(),
        OnboardingHeader(
          icon: AppIcons.account,
          title: l10n.shellConnectDeepSeek,
          message: l10n.shellConnectDeepSeekMessage,
        ),
        const Spacer(flex: 2),
        const SizedBox(height: 24),
        FilledButton(onPressed: onApiKey, child: Text(l10n.shellUseApiKey)),
        const SizedBox(height: 6),
        // Two equal halves: the quieter ways on.
        Row(
          children: [
            for (final (label, onTap) in [(l10n.shellOtherProviders, onOther), (l10n.shellSetUpLater, onSkip)])
              Expanded(
                child: TextButton(
                  onPressed: onTap,
                  style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                  child: Text(label),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
