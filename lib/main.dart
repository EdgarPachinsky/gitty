import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'services/service_providers.dart';
import 'services/storage/local_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Open local storage before the first frame so settings (theme, onboarding
  // state) are available synchronously — no flash of the wrong screen.
  final store = await LocalStore.open();

  runApp(
    ProviderScope(
      overrides: [localStoreProvider.overrideWithValue(store)],
      // Git and network errors are shown to the user with a "Try again"
      // button; don't silently auto-retry them.
      retry: (retryCount, error) => null,
      child: const GittyApp(),
    ),
  );
}
