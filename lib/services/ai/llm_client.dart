/// A chat-style language model reachable over HTTP (Claude, OpenAI-compatible
/// servers, …). Ollama keeps its own richer client.
abstract interface class LlmClient {
  /// Models this key/server can use (newest first when the API says so).
  Future<List<AiModel>> listModels();

  /// One non-streaming completion; returns the model's text.
  Future<String> complete({
    required String model,
    required String system,
    required String prompt,
  });
}

class AiModel {
  const AiModel(this.id, {String? label}) : label = label ?? id;

  /// The id sent to the API, e.g. `claude-haiku-4-5-20251001`.
  final String id;

  /// Human-friendly name, e.g. "Claude Haiku 4.5".
  final String label;
}
