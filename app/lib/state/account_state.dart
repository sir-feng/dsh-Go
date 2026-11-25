/// Account state for the phone.
///
/// The DeepSeek OAuth sign-in flow was local-engine-only (its callback must
/// reach a phone-reachable address) and went with the runtime; sign-in now
/// goes through the API key path. The provider and its state stay so the
/// screens that read a profile keep working.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show Brightness;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import 'account_api.dart';
import 'read_list_epoch.dart';

export 'account_api.dart';

// ── Dependencies (overridable in tests) ─────────────────────────────────────

/// Opens Platform pages (authorization, top-up) outside the app's WebView.
abstract interface class AccountBrowser {
  /// True when something was launched.
  Future<bool> open(Uri url);
}

/// Chrome Custom Tab first (shares the browser's DeepSeek login cookies and
/// keeps the user next to the app), the default browser as a fallback. OAuth
/// stays out of embedded WebViews (RFC 8252).
class SystemAccountBrowser implements AccountBrowser {
  const SystemAccountBrowser();

  @override
  Future<bool> open(Uri url) async {
    // HarmonyOS's url_launcher answers the in-app mode with a developer's toast.
    final modes = Platform.operatingSystem == 'ohos'
        ? const [LaunchMode.externalApplication]
        : const [LaunchMode.inAppBrowserView, LaunchMode.externalApplication];
    for (final mode in modes) {
      try {
        if (await launchUrl(url, mode: mode)) return true;
      } catch (_) {
        // No Custom Tabs provider: try the next mode.
      }
    }
    return false;
  }
}

final accountBrowserProvider = Provider<AccountBrowser>((ref) => const SystemAccountBrowser());


// ── State ────────────────────────────────────────────────────────────────────

enum AccountPhase {
  /// Remote host not connected yet, or its first account snapshot has not arrived.
  unknown,
  signedOut,
  signingIn,
  signedIn,

  /// The engine has no account service (older DSH).
  unsupported,
}

/// Where a running sign-in is, in user terms.
enum SignInStage {
  /// Waiting for the engine or for the Host to prepare the authorization page.
  preparing,

  /// The authorization page is open (or should be) in the browser.
  waitingBrowser,

  /// The browser came back; the Host is exchanging the code and saving the login.
  finishing,
}

enum SignInFailureKind {
  /// No network path to DeepSeek (`no-response`: offline, DNS, timeout).
  offline,

  /// DeepSeek answered with an HTTP error (`network`).
  service,

  /// The authorization did not complete (`protocol`: refused, invalid data, unknown codes).
  rejected,

  /// The attempt deadline passed (`expired`; about 10 minutes).
  timeout,

  /// The engine could not save the login (`storage`).
  storage,

  /// The local engine is not running or did not answer.
  engine,

  /// The engine restarted or disconnected while the attempt was running.
  interrupted,

  /// This engine has no account service.
  unsupported,

  /// No runtime on this phone: the sign-in runs through the local engine.
  noRuntime,
}

class SignInFailure {
  const SignInFailure(this.kind);

  final SignInFailureKind kind;

  String get title => switch (kind) {
    SignInFailureKind.offline => appL10n.stateAccountUnreachable,
    SignInFailureKind.service => appL10n.stateAccountUnavailable,
    SignInFailureKind.rejected => appL10n.stateSignInIncomplete,
    SignInFailureKind.timeout => appL10n.stateSignInTimeout,
    SignInFailureKind.storage => appL10n.stateSignInSaveFailed,
    SignInFailureKind.engine => appL10n.stateEngineNotReady,
    SignInFailureKind.interrupted => appL10n.stateSignInInterrupted,
    SignInFailureKind.unsupported => appL10n.stateAccountUnsupported,
    SignInFailureKind.noRuntime => appL10n.localEnvSignInNeedsRuntime,
  };

  String get message => switch (kind) {
    SignInFailureKind.offline => appL10n.stateCheckPhoneNetwork,
    SignInFailureKind.service => appL10n.stateServiceUnavailableRetry,
    SignInFailureKind.rejected => appL10n.stateAuthorizationFailed,
    SignInFailureKind.timeout => appL10n.stateAuthorizationExpired,
    SignInFailureKind.storage => appL10n.stateRestartEngineRetry,
    SignInFailureKind.engine => appL10n.stateEngineStartingRetry,
    SignInFailureKind.interrupted => appL10n.stateEngineDisconnectedSignIn,
    SignInFailureKind.unsupported => appL10n.stateUpdateRuntimeOrKey,
    SignInFailureKind.noRuntime => appL10n.localEnvSignInInstallFirst,
  };

  static SignInFailure fromCode(SignInErrorCode? code) => SignInFailure(switch (code) {
    SignInErrorCode.noResponse => SignInFailureKind.offline,
    SignInErrorCode.network => SignInFailureKind.service,
    SignInErrorCode.expired => SignInFailureKind.timeout,
    SignInErrorCode.storage => SignInFailureKind.storage,
    _ => SignInFailureKind.rejected,
  });
}

enum SignInResult { success, cancelled, failed }

/// Browser-side hints while waiting; none of them ends the attempt.
enum BrowserHint {
  none,

  /// Nothing could be launched; offer the link to copy.
  notOpened,

  /// The app came back to the foreground but the Host has no result yet
  /// (browser closed early, or the user is still on the page).
  returned,
}

class AccountState {
  const AccountState({
    this.phase = AccountPhase.unknown,
    this.stage,
    this.attemptId,
    this.authorizeUrl,
    this.expiresAt,
    this.browserHint = BrowserHint.none,
    this.profile,
    this.profileFailed = false,
    this.links,
    this.failure,
    this.connected = false,
  });

  final AccountPhase phase;
  final SignInStage? stage;
  final String? attemptId;
  final String? authorizeUrl;
  final DateTime? expiresAt;
  final BrowserHint browserHint;

  /// Display profile; null until the first read after sign-in.
  final AccountProfile? profile;
  final bool profileFailed;

  /// Usage / top-up pages on the Host's configured Platform origin.
  final AccountLinks? links;

  /// Last sign-in failure, shown until the next attempt or [AccountController.dismissFailure].
  final SignInFailure? failure;

  /// The local engine is connected (sign-in can start right away).
  final bool connected;

  bool get signedIn => phase == AccountPhase.signedIn;
  bool get signingIn => phase == AccountPhase.signingIn;

  AccountState copyWith({
    AccountPhase? phase,
    SignInStage? stage,
    String? attemptId,
    String? authorizeUrl,
    DateTime? expiresAt,
    BrowserHint? browserHint,
    AccountProfile? profile,
    bool? profileFailed,
    AccountLinks? links,
    SignInFailure? failure,
    bool? connected,
    bool clearAttempt = false,
    bool clearProfile = false,
    bool clearFailure = false,
  }) => AccountState(
    phase: phase ?? this.phase,
    stage: clearAttempt ? stage : (stage ?? this.stage),
    attemptId: clearAttempt ? attemptId : (attemptId ?? this.attemptId),
    authorizeUrl: clearAttempt ? authorizeUrl : (authorizeUrl ?? this.authorizeUrl),
    expiresAt: clearAttempt ? expiresAt : (expiresAt ?? this.expiresAt),
    browserHint: browserHint ?? (clearAttempt ? BrowserHint.none : this.browserHint),
    profile: clearProfile ? profile : (profile ?? this.profile),
    profileFailed: profileFailed ?? (clearProfile ? false : this.profileFailed),
    links: links ?? this.links,
    failure: clearFailure ? failure : (failure ?? this.failure),
    connected: connected ?? this.connected,
  );
}

// ── Controller ───────────────────────────────────────────────────────────────

/// One `signIn()` call: its result, and the Host attempt it follows.
class _Run {
  final completer = Completer<SignInResult>();

  /// Until `account/startSignIn` answered.
  bool preparing = true;
  bool cancelled = false;
  String? attemptId;
  SignInPhase? phase;
  String? openedUrl;
  Timer? deadline;
}

class AccountController extends Notifier<AccountState> {
  /// Wait for the engine to come up before giving up on a sign-in tap.
  static const engineWait = Duration(seconds: 90);

  /// Grace after returning to the app before suggesting the browser was closed.
  static const returnGrace = Duration(milliseconds: 1500);

  /// Used when the Host does not report an attempt deadline (it defaults to 10 min).
  static const fallbackAttemptTimeout = Duration(minutes: 11);

  AccountApi? _api;
  StreamSubscription<AccountView>? _sub;
  StreamSubscription<DshConnectionState>? _muxSub;
  MuxGeneration? _muxGeneration;
  MuxGeneration? _viewMuxGeneration;
  Timer? _retry;
  _Run? _run;
  Completer<AccountApi>? _apiWaiter;
  Brightness? _theme;
  Timer? _returnTimer;
  int _profileGeneration = 0;
  int _apiGeneration = 0;
  int? _viewGeneration;
  int? _profileIdentityGeneration;

  /// A retained profile is an offline display source, not proof for a new
  /// transport generation, even when the API and client objects are unchanged.
  bool get readListIdentityKnown {
    if (_viewGeneration == null ||
        state.phase == AccountPhase.signedIn &&
            (_profileIdentityGeneration != _viewGeneration || state.profile?.id?.isNotEmpty != true)) {
      return false;
    }
    final api = _api;
    if (api is DshAccountApi && _viewMuxGeneration?.number != api.client.mux.lastReadyGenerationNumber) {
      return false;
    }
    final current = api is DshAccountApi ? api.client.mux.generation : null;
    return current == null || _viewGeneration == _apiGeneration && identical(_viewMuxGeneration, current);
  }

  bool readListIdentityFor(DshClient client) =>
      readListIdentityKnown && _api is DshAccountApi && identical((_api! as DshAccountApi).client, client);

  bool _scopeCurrent(AccountApi api, int generation) =>
      ref.mounted &&
      identical(api, _api) &&
      generation == _apiGeneration &&
      (api is! DshAccountApi || _muxGeneration != null && identical(api.client.mux.generation, _muxGeneration));

  bool get _connected => false;

  @override
  AccountState build() {
    ref.onDispose(_dispose);
    // The DeepSeek OAuth account API was local-engine-only and is gone with
    // the runtime; sign-in now goes through the API key path.
    return AccountState(connected: _connected);
  }

  // ── Public API ──

  /// Starts (or rejoins) a browser sign-in and resolves when it ends. The
  /// authorization page opens with Platform's `theme` matching [brightness].
  Future<SignInResult> signIn({Brightness? brightness}) {
    if (state.signedIn) return Future.value(SignInResult.success);
    if (state.phase == AccountPhase.unsupported) return Future.value(SignInResult.failed);
    if (brightness != null) _theme = brightness;
    if (_run case final run?) {
      unawaited(reopenBrowser());
      return run.completer.future;
    }
    final run = _run = _Run();
    ref.read(readListCredentialEpochProvider.notifier).advance();
    _set(
      state.copyWith(
        phase: AccountPhase.signingIn,
        stage: SignInStage.preparing,
        clearAttempt: true,
        clearFailure: true,
        clearProfile: true,
      ),
    );
    unawaited(_start(run));
    return run.completer.future;
  }

  /// Cancels the running attempt. A login that already reached its final save
  /// completes instead (the Host settles committing attempts first).
  Future<void> cancel() async {
    final run = _run;
    if (run == null) return;
    run.cancelled = true;
    if (_apiWaiter case final waiter? when !waiter.isCompleted) {
      _apiWaiter = null;
      waiter.completeError(const _Cancelled());
    }
    final api = _api;
    final generation = _apiGeneration;
    final id = run.attemptId;
    if (api != null && id != null && _scopeCurrent(api, generation)) {
      try {
        final view = await api.cancelSignIn(id);
        if (identical(_run, run)) _onView(view, api, generation);
      } catch (_) {
        // Engine unreachable: the attempt dies with it; settle locally.
      }
      if (!_scopeCurrent(api, generation)) return;
    }
    // Still starting (no attempt id yet): settle now; _start cancels the attempt when it appears.
    if (identical(_run, run)) _settle(run, SignInResult.cancelled);
  }

  /// Opens the current authorization page again (after the browser was closed).
  Future<void> reopenBrowser() async {
    final url = state.authorizeUrl;
    final run = _run;
    if (url == null || run == null) return;
    await _openBrowser(run, url);
  }

  /// Call when the app returns to the foreground; notices a browser closed early.
  void noteAppResumed() {
    if (!state.signingIn || state.stage != SignInStage.waitingBrowser || _run?.openedUrl == null) return;
    _returnTimer?.cancel();
    _returnTimer = Timer(returnGrace, () {
      if (ref.mounted && state.signingIn && state.stage == SignInStage.waitingBrowser) {
        _set(state.copyWith(browserHint: BrowserHint.returned));
      }
    });
  }

  void dismissFailure() {
    if (state.failure != null) _set(state.copyWith(clearFailure: true));
  }

  /// Removes the local login (API keys stay); Platform revocation runs in the background.
  Future<void> signOut() async {
    final api = _api;
    final generation = _apiGeneration;
    if (api == null || !_scopeCurrent(api, generation)) throw StateError(appL10n.stateEngineDisconnected);
    ref.read(readListCredentialEpochProvider.notifier).advance();
    _onView(await api.signOut(), api, generation);
  }

  /// Whether agents are mid-task on the account route; null when unknown.
  Future<bool?> hasRunningAccountTasks() async {
    try {
      return await _api?.hasRunningAccountTasks();
    } catch (_) {
      return null;
    }
  }

  /// Recharge and bonus wallets; null when signed out. Throws
  /// [AccountQueryFailed] when Platform did not answer (the login is kept).
  Future<AccountBalance?> balance() async {
    final api = _api;
    if (api == null || !state.signedIn) return null;
    return api.getBalance();
  }

  Future<void> refreshProfile() async {
    final api = _api;
    final apiGeneration = _apiGeneration;
    if (api == null || !state.signedIn || _viewGeneration != apiGeneration || !_scopeCurrent(api, apiGeneration)) {
      return;
    }
    final generation = ++_profileGeneration;
    try {
      final profile = await api.getProfile();
      if (generation != _profileGeneration || !_scopeCurrent(api, apiGeneration) || !state.signedIn) {
        return;
      }
      _profileIdentityGeneration = profile == null ? null : apiGeneration;
      _set(state.copyWith(profile: profile, profileFailed: profile == null));
    } catch (_) {
      if (generation != _profileGeneration || !_scopeCurrent(api, apiGeneration) || !state.signedIn) {
        return;
      }
      _set(state.copyWith(profileFailed: true));
    }
  }

  // ── Sign-in ──

  Future<void> _start(_Run run) async {
    // The DeepSeek OAuth account API was local-engine-only (its callback must
    // reach a phone-reachable address) and is gone with the runtime. Sign-in
    // now goes through the API key path; this browser flow reports unsupported.
    _fail(run, const SignInFailure(SignInFailureKind.noRuntime));
  }

  void _onView(AccountView view, AccountApi api, int generation) {
    if (!_scopeCurrent(api, generation)) return;
    final prev = state;
    final run = _run;
    final attempt = view.attempt;
    if (run != null && attempt != null && attempt.phase.isActive && run.attemptId != attempt.id) {
      // startSignIn joins a running attempt instead of starting another: follow it.
      run
        ..attemptId = attempt.id
        ..phase = null;
    }
    final own = run != null && attempt != null && attempt.id == run.attemptId;
    if (own && !view.signedIn && run.phase != null && attempt.phase.index < run.phase!.index) {
      return; // older snapshot of our attempt
    }
    if (own) run.phase = attempt.phase;
    _viewGeneration = generation;
    _viewMuxGeneration = _muxGeneration;
    final next = prev.copyWith(links: view.links, connected: true);

    if (view.signedIn) {
      _profileIdentityGeneration = null;
      _set(next.copyWith(phase: AccountPhase.signedIn, clearAttempt: true, clearFailure: true));
      if (prev.phase != AccountPhase.signedIn) {
        _statusChanged();
      }
      // Each accepted account snapshot can be the first frame after a mux
      // reconnect. A retained signed-in phase must not suppress revalidation.
      unawaited(refreshProfile());
      if (run != null) {
        final api = _api;
        _finish(run, SignInResult.success);
        if (api != null) unawaited(_afterSignIn(api, generation));
      }
      return;
    }

    if (attempt != null && attempt.phase.isActive) {
      final stage = switch (attempt.phase) {
        SignInPhase.initializing => SignInStage.preparing,
        SignInPhase.waitingBrowser => SignInStage.waitingBrowser,
        _ => SignInStage.finishing,
      };
      final waiting = stage == SignInStage.waitingBrowser;
      _set(
        next.copyWith(
          phase: AccountPhase.signingIn,
          stage: stage,
          attemptId: attempt.id,
          authorizeUrl: attempt.authorizeUrl ?? prev.authorizeUrl,
          expiresAt: attempt.expiresAt,
          browserHint: waiting ? null : BrowserHint.none,
          clearProfile: true,
        ),
      );
      if (prev.phase == AccountPhase.signedIn) _statusChanged();
      final url = attempt.authorizeUrl;
      if (own && waiting && url != null && url != run.openedUrl) {
        _armDeadline(run, attempt.expiresAt);
        unawaited(_openBrowser(run, url));
      }
      return;
    }

    // Signed out, nothing running.
    if (run != null) {
      if (!own) return; // a previous attempt's outcome, or ours is not published yet
      final failed = attempt.phase == SignInPhase.failed || attempt.phase == SignInPhase.expired;
      _set(
        next.copyWith(
          phase: AccountPhase.signedOut,
          clearAttempt: true,
          clearProfile: true,
          failure: failed ? SignInFailure.fromCode(attempt.errorCode) : null,
        ),
      );
      _finish(run, failed ? SignInResult.failed : SignInResult.cancelled);
      return;
    }
    _set(next.copyWith(phase: AccountPhase.signedOut, clearAttempt: true, clearProfile: true));
    if (prev.phase == AccountPhase.signedIn) _statusChanged();
  }

  Future<void> _openBrowser(_Run run, String url) async {
    run.openedUrl = url;
    var uri = Uri.tryParse(url);
    if (uri == null) return;
    if (_theme case final theme?) {
      // As DSH's own client does: Platform renders its login page in the app's palette.
      uri = uri.replace(
        queryParameters: {...uri.queryParameters, 'theme': theme == Brightness.dark ? 'dark' : 'light'},
      );
    }
    bool opened;
    try {
      opened = await ref.read(accountBrowserProvider).open(uri);
    } catch (_) {
      opened = false;
    }
    if (!ref.mounted || !identical(_run, run) || !state.signingIn) return;
    _set(state.copyWith(browserHint: opened ? BrowserHint.none : BrowserHint.notOpened));
  }

  Future<void> _afterSignIn(AccountApi api, int generation) async {
    try {
      // As DSH's own client does: the first account model becomes the default
      // when no API key is configured (the Host checks that itself).
      await api.initializeDefaultModel();
    } catch (_) {
      // `session/provider-models-unavailable` and the like: the picker still works.
    }
    if (_scopeCurrent(api, generation)) ref.read(readListCredentialEpochProvider.notifier).advance();
  }

  /// Account presence changes which models are routable: 0.2.1 lists none
  /// until some credential exists, then the `deepseek-account` models.
  void _statusChanged() => ref.read(readListCredentialEpochProvider.notifier).advance();

  void _armDeadline(_Run run, DateTime? expiresAt) {
    run.deadline?.cancel();
    final wait = expiresAt == null
        ? fallbackAttemptTimeout
        : expiresAt.difference(DateTime.now()) + const Duration(seconds: 15);
    run.deadline = Timer(wait.isNegative ? Duration.zero : wait, () => unawaited(_onDeadline(run)));
  }

  /// Safety net if the stream missed the Host's own `expired` outcome.
  Future<void> _onDeadline(_Run run) async {
    final api = _api;
    final generation = _apiGeneration;
    if (!identical(_run, run) || !ref.mounted) return;
    if (api != null && _scopeCurrent(api, generation)) {
      try {
        _onView(await api.getState(), api, generation);
      } catch (_) {}
    }
    if (!identical(_run, run) ||
        !ref.mounted ||
        generation != _apiGeneration ||
        !identical(api, _api) ||
        api != null && !_scopeCurrent(api, generation)) {
      return;
    }
    if (api != null && run.attemptId != null) {
      unawaited(api.cancelSignIn(run.attemptId!).then<void>((_) {}, onError: (_) {}));
    }
    _fail(run, const SignInFailure(SignInFailureKind.timeout));
  }

  void _fail(_Run run, SignInFailure failure) {
    if (!ref.mounted || !identical(_run, run)) return;
    _set(
      state.copyWith(
        phase: AccountPhase.signedOut,
        clearAttempt: true,
        clearProfile: true,
        failure: failure,
        connected: _connected,
      ),
    );
    _finish(run, SignInResult.failed);
  }

  void _settle(_Run run, SignInResult result) {
    if (!ref.mounted || !identical(_run, run)) return;
    if (!state.signedIn) _set(state.copyWith(phase: AccountPhase.signedOut, clearAttempt: true));
    _finish(run, result);
  }

  void _finish(_Run run, SignInResult result) {
    run.deadline?.cancel();
    _returnTimer?.cancel();
    if (identical(_run, run)) _run = null;
    if (!run.completer.isCompleted) run.completer.complete(result);
  }

  void _set(AccountState next) {
    if (ref.mounted) state = next;
  }

  void _dispose() {
    _api = null;
    _apiGeneration++;
    _profileGeneration++;
    _viewGeneration = null;
    _profileIdentityGeneration = null;
    _viewMuxGeneration = null;
    _muxGeneration = null;
    _sub?.cancel();
    _muxSub?.cancel();
    _retry?.cancel();
    _returnTimer?.cancel();
    final run = _run;
    _run = null;
    if (run != null) {
      run.deadline?.cancel();
      if (!run.completer.isCompleted) run.completer.complete(SignInResult.cancelled);
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

final accountProvider = NotifierProvider<AccountController, AccountState>(AccountController.new);

/// Wallets of the signed-in account; null while signed out or while the engine
/// is not connected (unknown, not zero). Refetched on sign-in, on reconnect and
/// when invalidated (refresh, coming back from the top-up page).
final accountBalanceProvider = FutureProvider.autoDispose<AccountBalance?>(
  (ref) async {
    final ready = ref.watch(accountProvider.select((s) => s.signedIn && s.connected));
    if (!ready) return null;
    return ref.read(accountProvider.notifier).balance();
  },
  // A failed Platform query shows "retry" instead of an endless automatic retry.
  retry: (_, _) => null,
);
