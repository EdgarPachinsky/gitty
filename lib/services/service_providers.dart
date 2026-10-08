import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/system_launcher.dart';
import 'ai/ai_engine.dart';
import 'ai/ai_text.dart';
import 'ai/claude_client.dart';
import 'ai/commit_message_service.dart';
import 'ai/draft_commit_message_service.dart';
import 'ai/error_help_service.dart';
import 'ai/ollama_client.dart';
import 'ai/ollama_commit_message_service.dart';
import 'ai/openai_client.dart';
import 'ai/remote_commit_message_service.dart';
import 'auth/demo_github_provider.dart';
import 'auth/git_provider.dart';
import 'auth/github_provider.dart';
import 'auth/github_pulls.dart';
import 'auth/token_store.dart';
import 'git/git_cli.dart';
import 'git/git_service.dart';
import 'git/repo_scanner.dart';
import 'storage/analytics_repository.dart';
import 'storage/local_store.dart';
import 'storage/repo_repository.dart';
import 'storage/settings_repository.dart';
import '../features/settings/settings_controller.dart';

/// Dependency wiring for the service layer. UI code depends on these
/// providers, never on concrete constructors, so services can be swapped or
/// overridden in tests.

/// Opened in `main()` before the app starts and injected via an override.
final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError(
    'localStoreProvider must be overridden in main()',
  ),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(localStoreProvider)),
);

final repoRepositoryProvider = Provider<RepoRepository>(
  (ref) => RepoRepository(ref.watch(localStoreProvider)),
);

final analyticsRepositoryProvider = Provider<AnalyticsRepository>(
  (ref) => AnalyticsRepository(ref.watch(localStoreProvider)),
);

// --- Git ----------------------------------------------------------------------

final gitServiceProvider = Provider<GitService>((ref) {
  final tokens = ref.watch(tokenStoreProvider);
  return GitService(
    GitCli(),
    // Lets git use the connected GitHub account when the user's own
    // credentials don't cover a github.com remote. Not used in demo mode.
    githubToken: githubClientId.isEmpty
        ? null
        : () => tokens.read(GitProviderKind.github.name),
  );
});

final repoScannerProvider = Provider<RepoScanner>((ref) => const RepoScanner());

final gitVersionProvider = FutureProvider<String?>(
  (ref) => ref.watch(gitServiceProvider).gitVersion(),
);

// --- Auth ---------------------------------------------------------------------

/// Gitty's GitHub OAuth App (Device Flow). Override with
/// `--dart-define=GITHUB_CLIENT_ID=...`; pass an empty value for demo mode.
const githubClientId = String.fromEnvironment(
  'GITHUB_CLIENT_ID',
  defaultValue: 'Ov23liNSfJZZX9slckxg',
);

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final githubProvider = Provider<GitHostingProvider>((ref) {
  if (githubClientId.isEmpty)
    return DemoGitHubProvider(ref.watch(localStoreProvider));
  return GitHubProvider(
    clientId: githubClientId,
    tokenStore: ref.watch(tokenStoreProvider),
  );
});

/// Pull requests on GitHub (uses the account connected in Settings).
final gitHubPullsProvider = Provider<GitHubPulls>(
  (ref) => GitHubPulls(tokens: ref.watch(tokenStoreProvider)),
);

// --- AI -----------------------------------------------------------------------

final ollamaClientProvider = Provider<OllamaClient>((ref) {
  final baseUrl = ref.watch(
    settingsControllerProvider.select((s) => s.ollamaBaseUrl),
  );
  return OllamaClient(baseUrl: baseUrl);
});

/// Saved API key for a cloud engine (null when none). Invalidate after
/// saving or removing a key.
final aiApiKeyProvider = FutureProvider.autoDispose.family<String?, AiEngine>(
  (ref, engine) => ref.watch(tokenStoreProvider).read(engine.keyId),
);

final claudeClientProvider = Provider<ClaudeClient>((ref) {
  final tokens = ref.watch(tokenStoreProvider);
  return ClaudeClient(apiKey: () => tokens.read(AiEngine.claude.keyId));
});

final openAiClientProvider = Provider<OpenAiCompatibleClient>((ref) {
  final tokens = ref.watch(tokenStoreProvider);
  final baseUrl = ref.watch(
    settingsControllerProvider.select((s) => s.openAiBaseUrl),
  );
  return OpenAiCompatibleClient(
    baseUrl: baseUrl,
    apiKey: () => tokens.read(AiEngine.openAi.keyId),
  );
});

final commitMessageServiceProvider = Provider<CommitMessageService>((ref) {
  final settings = ref.watch(settingsControllerProvider);

  // Local engine (and the fallback for cloud engines).
  final CommitMessageService local = settings.aiEnabled
      ? OllamaCommitMessageService(
          client: ref.watch(ollamaClientProvider),
          model: settings.ollamaModel,
        )
      : const DraftCommitMessageService();
  final CommitMessageService fallback = settings.aiFallbackToLocal
      ? local
      : const DraftCommitMessageService();

  return switch (settings.aiEngine) {
    AiEngine.ollama => local,
    AiEngine.claude => RemoteCommitMessageService(
      client: ref.watch(claudeClientProvider),
      model: settings.claudeModel,
      engineName: 'Claude',
      fallback: fallback,
    ),
    AiEngine.openAi => RemoteCommitMessageService(
      client: ref.watch(openAiClientProvider),
      model: settings.openAiModel,
      engineName: OpenAiCompatibleClient.friendlyName(settings.openAiBaseUrl),
      fallback: fallback,
    ),
  };
});

/// Explains errors in the "Help with this error" panel, with the same
/// engine that writes commit messages.
final errorHelpServiceProvider = Provider<ErrorHelpService>((ref) {
  final settings = ref.watch(settingsControllerProvider);
  return switch (settings.aiEngine) {
    AiEngine.ollama =>
      settings.aiEnabled
          ? OllamaErrorHelpService(
              client: ref.watch(ollamaClientProvider),
              model: settings.ollamaModel,
            )
          : const DisabledErrorHelpService(),
    AiEngine.claude => RemoteErrorHelpService(
      client: ref.watch(claudeClientProvider),
      model: settings.claudeModel,
      engineName: 'Claude',
    ),
    AiEngine.openAi => RemoteErrorHelpService(
      client: ref.watch(openAiClientProvider),
      model: settings.openAiModel,
      engineName: OpenAiCompatibleClient.friendlyName(settings.openAiBaseUrl),
    ),
  };
});

/// "Ask the AI for some text", with the engine picked in Settings.
final aiTextProvider = Provider<AiText>((ref) {
  final settings = ref.watch(settingsControllerProvider);
  return switch (settings.aiEngine) {
    AiEngine.ollama =>
      settings.aiEnabled
          ? OllamaAiText(
              client: ref.watch(ollamaClientProvider),
              model: settings.ollamaModel,
            )
          : const DisabledAiText(),
    AiEngine.claude => RemoteAiText(
      client: ref.watch(claudeClientProvider),
      model: settings.claudeModel,
      engineName: 'Claude',
    ),
    AiEngine.openAi => RemoteAiText(
      client: ref.watch(openAiClientProvider),
      model: settings.openAiModel,
      engineName: OpenAiCompatibleClient.friendlyName(settings.openAiBaseUrl),
    ),
  };
});

// --- Platform -------------------------------------------------------------------

final systemLauncherProvider = Provider<SystemLauncher>(
  (ref) => const SystemLauncher(),
);
