import 'package:flutter/material.dart' show ThemeMode;

import '../ai/ai_engine.dart';
import '../ai/claude_client.dart';
import '../ai/commit_style.dart';
import '../ai/openai_client.dart';
import 'local_store.dart';

/// All user preferences. Immutable; update via [copyWith].
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.defaultCommitStyle = CommitStyle.conventional,
    this.aiEnabled = true,
    this.ollamaBaseUrl = 'http://localhost:11434',
    this.ollamaModel = 'llama3.2',
    this.aiEngine = AiEngine.ollama,
    this.claudeModel = ClaudeClient.defaultModel,
    this.openAiBaseUrl = OpenAiCompatibleClient.defaultBaseUrl,
    this.openAiModel = '',
    this.aiFallbackToLocal = true,
    this.pinnedSectionExpanded = true,
    this.otherSectionExpanded = true,
    this.syncReminders = true,
    this.autoFetch = true,
    this.autoFetchMinutes = 0,
    this.onboardingComplete = false,
  });

  final ThemeMode themeMode;
  final CommitStyle defaultCommitStyle;

  /// Use Ollama for commit messages. When off (or Ollama is unreachable) Gitty
  /// falls back to a simple on-device draft.
  final bool aiEnabled;
  final String ollamaBaseUrl;
  final String ollamaModel;

  /// Which engine writes commit messages. Local (Ollama) by default.
  final AiEngine aiEngine;
  final String claudeModel;
  final String openAiBaseUrl;
  final String openAiModel;

  /// When a cloud engine fails, try local Ollama before the offline draft.
  final bool aiFallbackToLocal;

  /// Dashboard sections, remembered between launches.
  final bool pinnedSectionExpanded;
  final bool otherSectionExpanded;

  /// Show gentle "you're behind" banners.
  final bool syncReminders;

  /// Periodically `git fetch` tracked repos in the background while Gitty is
  /// open, so ahead/behind counts stay accurate.
  final bool autoFetch;
  final int autoFetchMinutes;

  final bool onboardingComplete;

  AppSettings copyWith({
    ThemeMode? themeMode,
    CommitStyle? defaultCommitStyle,
    bool? aiEnabled,
    String? ollamaBaseUrl,
    String? ollamaModel,
    AiEngine? aiEngine,
    String? claudeModel,
    String? openAiBaseUrl,
    String? openAiModel,
    bool? aiFallbackToLocal,
    bool? pinnedSectionExpanded,
    bool? otherSectionExpanded,
    bool? syncReminders,
    bool? autoFetch,
    int? autoFetchMinutes,
    bool? onboardingComplete,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      defaultCommitStyle: defaultCommitStyle ?? this.defaultCommitStyle,
      aiEnabled: aiEnabled ?? this.aiEnabled,
      ollamaBaseUrl: ollamaBaseUrl ?? this.ollamaBaseUrl,
      ollamaModel: ollamaModel ?? this.ollamaModel,
      aiEngine: aiEngine ?? this.aiEngine,
      claudeModel: claudeModel ?? this.claudeModel,
      openAiBaseUrl: openAiBaseUrl ?? this.openAiBaseUrl,
      openAiModel: openAiModel ?? this.openAiModel,
      aiFallbackToLocal: aiFallbackToLocal ?? this.aiFallbackToLocal,
      pinnedSectionExpanded:
          pinnedSectionExpanded ?? this.pinnedSectionExpanded,
      otherSectionExpanded: otherSectionExpanded ?? this.otherSectionExpanded,
      syncReminders: syncReminders ?? this.syncReminders,
      autoFetch: autoFetch ?? this.autoFetch,
      autoFetchMinutes: autoFetchMinutes ?? this.autoFetchMinutes,
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
    );
  }

  Map<String, dynamic> toJson() => {
    'themeMode': themeMode.name,
    'defaultCommitStyle': defaultCommitStyle.name,
    'aiEnabled': aiEnabled,
    'ollamaBaseUrl': ollamaBaseUrl,
    'ollamaModel': ollamaModel,
    'aiEngine': aiEngine.name,
    'claudeModel': claudeModel,
    'openAiBaseUrl': openAiBaseUrl,
    'openAiModel': openAiModel,
    'aiFallbackToLocal': aiFallbackToLocal,
    'pinnedSectionExpanded': pinnedSectionExpanded,
    'otherSectionExpanded': otherSectionExpanded,
    'syncReminders': syncReminders,
    'autoFetch': autoFetch,
    'autoFetchMinutes': autoFetchMinutes,
    'onboardingComplete': onboardingComplete,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const d = AppSettings();
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == json['themeMode'],
        orElse: () => d.themeMode,
      ),
      defaultCommitStyle: CommitStyle.fromName(
        json['defaultCommitStyle'] as String?,
      ),
      aiEnabled: json['aiEnabled'] as bool? ?? d.aiEnabled,
      ollamaBaseUrl: json['ollamaBaseUrl'] as String? ?? d.ollamaBaseUrl,
      ollamaModel: json['ollamaModel'] as String? ?? d.ollamaModel,
      aiEngine: AiEngine.fromName(json['aiEngine'] as String?),
      claudeModel: json['claudeModel'] as String? ?? d.claudeModel,
      openAiBaseUrl: json['openAiBaseUrl'] as String? ?? d.openAiBaseUrl,
      openAiModel: json['openAiModel'] as String? ?? d.openAiModel,
      aiFallbackToLocal:
          json['aiFallbackToLocal'] as bool? ?? d.aiFallbackToLocal,
      pinnedSectionExpanded:
          json['pinnedSectionExpanded'] as bool? ?? d.pinnedSectionExpanded,
      otherSectionExpanded:
          json['otherSectionExpanded'] as bool? ?? d.otherSectionExpanded,
      syncReminders: json['syncReminders'] as bool? ?? d.syncReminders,
      autoFetch: json['autoFetch'] as bool? ?? d.autoFetch,
      autoFetchMinutes: json['autoFetchMinutes'] as int? ?? d.autoFetchMinutes,
      onboardingComplete:
          json['onboardingComplete'] as bool? ?? d.onboardingComplete,
    );
  }
}

class SettingsRepository {
  SettingsRepository(this._store);

  final LocalStore _store;

  AppSettings load() {
    final json = LocalStore.readJson(_store.settings, LocalStore.settingsKey);
    return json == null ? const AppSettings() : AppSettings.fromJson(json);
  }

  Future<void> save(AppSettings settings) => LocalStore.writeJson(
    _store.settings,
    LocalStore.settingsKey,
    settings.toJson(),
  );
}
