import 'package:flutter/material.dart';

import 'connect_page.dart';

/// First-run pages. [apiKey] is the "connect DeepSeek" step: account sign-in
/// first, API key as the alternative.
///
/// 本地引擎已随拆分线删除，首启不再有本机/远程安装引导，
/// [welcome]/[runtime]/[appearance]/[access]/[finishing] 这些步骤不再使用。
enum OnboardingStep { welcome, runtime, appearance, access, apiKey, finishing }

/// Moves between the first-run pages. The step itself is owned by the root
/// gate, which also decides where a returning user resumes.
///
/// The welcome and finishing pages stand alone; the steps between show a thin
/// step bar at the top ([OnboardingProgress]) and, beside an unpack, its
/// capsule at the bottom.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.step,
    required this.onKeyDone,
    this.onRemote,
  });

  final OnboardingStep step;
  final VoidCallback onKeyDone;

  /// Picked 「远程主机」.
  final VoidCallback? onRemote;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    // 本地引擎步骤已随拆分线删除，只剩 apiKey（连接 DeepSeek）。
    final Widget page = switch (step) {
      OnboardingStep.apiKey => ConnectPage(onDone: widget.onKeyDone),
      _ => const SizedBox.shrink(),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: KeyedSubtree(
        key: ValueKey(step),
        child: page,
      ),
    );
  }
}
