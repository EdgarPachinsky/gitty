import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/settings/settings_controller.dart';
import 'features/shell/home_shell.dart';

class GittyApp extends ConsumerWidget {
  const GittyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(
      settingsControllerProvider.select((s) => s.themeMode),
    );
    final onboarded = ref.watch(
      settingsControllerProvider.select((s) => s.onboardingComplete),
    );

    return MaterialApp(
      title: 'Gitty',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        child: onboarded ? const HomeShell() : const OnboardingScreen(),
      ),
    );
  }
}
