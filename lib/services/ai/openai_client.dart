import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/errors/gitty_exception.dart';
import 'llm_client.dart';

/// Any server speaking the OpenAI Chat Completions API: OpenAI itself,
/// OpenRouter, Groq, Mistral, or local apps like LM Studio and llama.cpp.
class OpenAiCompatibleClient implements LlmClient {
  OpenAiCompatibleClient({
    required this.baseUrl,
    required Future<String?> Function() apiKey,
    http.Client? client,
  }) : _apiKey = apiKey,
       _http = client ?? http.Client();

  static const defaultBaseUrl = 'https://api.openai.com/v1';

  /// "OpenAI", "OpenRouter", "a local server", … for labels and notes.
  static String friendlyName(String baseUrl) {
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase() ?? '';
    if (isLocalAddress(baseUrl)) return 'a local server';
    if (host.endsWith('openai.com')) return 'OpenAI';
    if (host.endsWith('openrouter.ai')) return 'OpenRouter';
    if (host.endsWith('groq.com')) return 'Groq';
    if (host.endsWith('mistral.ai')) return 'Mistral';
    if (host.endsWith('deepseek.com')) return 'DeepSeek';
    return host.isEmpty ? 'the AI server' : host;
  }

  /// True for servers on this computer (LM Studio, llama.cpp, …).
  static bool isLocalAddress(String baseUrl) {
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase() ?? '';
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  final String baseUrl;
  final Future<String?> Function() _apiKey;
  final http.Client _http;

  Uri _uri(String path) =>
      Uri.parse('${baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}$path');

  Future<Map<String, String>> _headers() async {
    final key = (await _apiKey())?.trim();
    return {
      'Content-Type': 'application/json',
      // Local servers usually don't need a key.
      if (key != null && key.isNotEmpty) 'Authorization': 'Bearer $key',
    };
  }

  @override
  Future<List<AiModel>> listModels() async {
    final res = await _http
        .get(_uri('/models'), headers: await _headers())
        .timeout(const Duration(seconds: 15));
    _throwIfError(res, model: null);
    final json = jsonDecode(res.body);
    final data = json is Map<String, dynamic> ? json['data'] : null;
    if (data is! List) return const [];
    return [
      for (final m in data.whereType<Map<String, dynamic>>())
        if (m['id'] is String) AiModel(m['id'] as String),
    ]..sort((a, b) => a.id.compareTo(b.id));
  }

  @override
  Future<String> complete({
    required String model,
    required String system,
    required String prompt,
  }) async {
    if (model.trim().isEmpty) {
      throw const GittyException(
        'Pick a model for the OpenAI-compatible engine first.',
        hint: 'Settings → Commit messages.',
      );
    }
    final res = await _http
        .post(
          _uri('/chat/completions'),
          headers: await _headers(),
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': prompt},
            ],
          }),
        )
        .timeout(const Duration(seconds: 90));
    _throwIfError(res, model: model);
    final json = jsonDecode(res.body);
    final choices = json is Map<String, dynamic> ? json['choices'] : null;
    final first = choices is List && choices.isNotEmpty ? choices.first : null;
    final message = first is Map<String, dynamic> ? first['message'] : null;
    final text = message is Map<String, dynamic> ? message['content'] : null;
    if (text is! String || text.trim().isEmpty) {
      throw GittyException(
        'The AI server sent back an empty answer.',
        details: res.body,
      );
    }
    return text;
  }

  static void _throwIfError(http.Response res, {required String? model}) {
    if (res.statusCode == 200) return;
    GittyException e(String text, String hint) =>
        GittyException(text, hint: hint, details: res.body);
    throw switch (res.statusCode) {
      401 || 403 => e(
        'The AI server didn’t accept that API key.',
        'Check the key in Settings → Commit messages.',
      ),
      404 => e(
        model == null
            ? 'That address doesn’t look like an OpenAI-compatible API.'
            : 'The model “$model” wasn’t found on that server.',
        'Check the address (it usually ends in /v1) and the model name.',
      ),
      429 => e(
        'The AI server’s rate limit was reached.',
        'Wait a moment and try again.',
      ),
      _ => e('The AI server returned an error.', 'See details for more.'),
    };
  }
}
