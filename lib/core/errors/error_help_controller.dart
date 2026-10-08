import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'gitty_exception.dart';

/// An error the user wants help with, shown in the side panel.
class ErrorHelpRequest {
  const ErrorHelpRequest({
    required this.id,
    required this.error,
    required this.askAi,
  });

  final int id;
  final GittyException error;

  /// Start the AI explanation right away (the toast's "Ask AI").
  final bool askAi;
}

/// Opens and closes the "Help with this error" side panel.
class ErrorHelpController extends Notifier<ErrorHelpRequest?> {
  /// How many panel hosts are on screen (the main shell). Without one,
  /// errors fall back to the plain details dialog.
  static int hosts = 0;

  int _nextId = 0;

  @override
  ErrorHelpRequest? build() => null;

  void open(GittyException error, {bool askAi = false}) =>
      state = ErrorHelpRequest(id: _nextId++, error: error, askAi: askAi);

  void close() => state = null;
}

final errorHelpProvider =
    NotifierProvider<ErrorHelpController, ErrorHelpRequest?>(
      ErrorHelpController.new,
    );

/// Opens the side panel for [error] when one is available. Returns false
/// when there's no panel on screen (the caller shows a dialog instead).
bool openErrorHelp(
  BuildContext context,
  GittyException error, {
  bool askAi = false,
}) {
  if (ErrorHelpController.hosts == 0) return false;
  ProviderScope.containerOf(
    context,
    listen: false,
  ).read(errorHelpProvider.notifier).open(error, askAi: askAi);
  return true;
}
