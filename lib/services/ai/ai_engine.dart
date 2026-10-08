/// Where commit messages are written. Local stays the default; cloud engines
/// are opt-in and need an API key (kept in the system keychain).
enum AiEngine {
  ollama('Local (Ollama)', isLocal: true),
  claude('Claude'),
  openAi('OpenAI-compatible');

  const AiEngine(this.label, {this.isLocal = false});

  final String label;

  /// Runs on this computer — nothing is sent anywhere.
  final bool isLocal;

  /// Keychain entry for this engine's API key (see TokenStore).
  String get keyId => 'ai.$name';

  static AiEngine fromName(String? name) {
    for (final e in values) {
      if (e.name == name) return e;
    }
    return AiEngine.ollama;
  }
}
