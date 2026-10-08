import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/service_providers.dart';
import '../../services/storage/settings_repository.dart';

/// App-wide settings. Loaded synchronously (the Hive box is opened before the
/// app starts) and persisted on every change.
class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsRepositoryProvider).load();

  Future<void> change(AppSettings Function(AppSettings current) edit) async {
    state = edit(state);
    await ref.read(settingsRepositoryProvider).save(state);
  }
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
