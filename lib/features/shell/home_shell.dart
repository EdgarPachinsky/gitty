import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/error_help_controller.dart';
import '../dashboard/dashboard_screen.dart';
import '../dashboard/tracked_repos_controller.dart';
import '../help/error_help_panel.dart';
import '../repository/repository_screen.dart';
import '../settings/settings_screen.dart';
import '../sync/live_sync.dart';
import 'open_tabs.dart';
import 'repo_tabs.dart';

/// Main layout: navigation rail + content. Selecting a repository opens its
/// detail view in place, keeping the rail visible.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _section = 0;

  /// Settings is only built once it has been visited (it's kept alive after
  /// that, like the repository tabs).
  bool _settingsVisited = false;

  OpenTabsController get _tabs => ref.read(openTabsProvider.notifier);

  @override
  void initState() {
    super.initState();
    ErrorHelpController.hosts++; // errors can open the help side panel
  }

  @override
  void dispose() {
    ErrorHelpController.hosts--;
    super.dispose();
  }

  void _notify(RemoteNotice notice) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final scheme = Theme.of(context).colorScheme;
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Row(
          children: [
            Icon(
              Icons.notifications_active_outlined,
              color: scheme.inversePrimary,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(notice.message)),
          ],
        ),
        action: SnackBarAction(
          label: 'Show',
          onPressed: () {
            if (!ref
                .read(trackedReposProvider)
                .any((r) => r.path == notice.repoPath)) {
              return;
            }
            setState(() => _section = 0);
            _openRepository(notice.repoPath);
          },
        ),
      ),
    );
  }

  void _openRepository(String path) {
    ref.read(trackedReposProvider.notifier).markOpened(path);
    _tabs.open(path);
    if (_section != 0) setState(() => _section = 0);
  }

  /// ⌘/Ctrl+W close tab, Ctrl+Tab next, ⌘/Ctrl+1 list, ⌘/Ctrl+2…9 tabs.
  Map<ShortcutActivator, VoidCallback> _shortcuts(List<String> open, String? active) {
    void show(String? path) {
      if (_section != 0) setState(() => _section = 0);
      _tabs.activate(path);
    }

    return {
      for (final meta in [true, false]) ...{
        SingleActivator(LogicalKeyboardKey.keyW, meta: meta, control: !meta):
            () {
              if (active != null) _tabs.close(active);
            },
        SingleActivator(LogicalKeyboardKey.digit1, meta: meta, control: !meta):
            () => show(null),
        for (final (i, key) in [
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit4,
          LogicalKeyboardKey.digit5,
          LogicalKeyboardKey.digit6,
          LogicalKeyboardKey.digit7,
          LogicalKeyboardKey.digit8,
          LogicalKeyboardKey.digit9,
        ].indexed)
          SingleActivator(key, meta: meta, control: !meta): () {
            if (i < open.length) show(open[i]);
          },
      },
      const SingleActivator(LogicalKeyboardKey.tab, control: true): () {
        if (_section != 0) setState(() => _section = 0);
        _tabs.cycle(1);
      },
      const SingleActivator(
        LogicalKeyboardKey.tab,
        control: true,
        shift: true,
      ): () {
        if (_section != 0) setState(() => _section = 0);
        _tabs.cycle(-1);
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    // Keep background fetching alive while the main UI is shown.
    ref.watch(autoFetchProvider);
    ref.watch(appResumeRefreshProvider);

    // Pop up a notice when a teammate pushes something that matters to you.
    ref.listen<List<RemoteNotice>>(remoteUpdatesProvider, (previous, next) {
      final seen = {for (final n in previous ?? const <RemoteNotice>[]) n.id};
      for (final notice in next) {
        if (!seen.contains(notice.id) && notice.isImportant) _notify(notice);
      }
    });

    // Open tabs (repositories removed from Gitty drop out).
    final tracked = {for (final r in ref.watch(trackedReposProvider)) r.path};
    final tabState = ref.watch(openTabsProvider);
    final open = tabState.paths.where(tracked.contains).toList();
    final openRepo = tracked.contains(tabState.active) ? tabState.active : null;
    if (open.length != tabState.paths.length || openRepo != tabState.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tabs.retainOnly(tracked);
      });
    }
    final stillTracked = openRepo != null;

    final help = ref.watch(errorHelpProvider);
    if (_section == 1) _settingsVisited = true;

    // Every open tab stays alive (switching is instant and keeps what you
    // typed); hidden ones are paused and can't take keyboard focus.
    Widget page(bool visible, Widget child) => TickerMode(
      enabled: visible,
      child: ExcludeFocus(excluding: !visible, child: child),
    );
    final repositories = Column(
      children: [
        if (open.isNotEmpty) RepoTabStrip(paths: open, active: openRepo),
        Expanded(
          child: IndexedStack(
            index: openRepo == null ? 0 : open.indexOf(openRepo) + 1,
            sizing: StackFit.expand,
            children: [
              page(
                _section == 0 && openRepo == null,
                DashboardScreen(onOpen: _openRepository),
              ),
              for (final path in open)
                KeyedSubtree(
                  key: ValueKey(path),
                  child: page(
                    _section == 0 && path == openRepo,
                    RepositoryScreen(
                      repoPath: path,
                      onBack: () => _tabs.activate(null),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    final content = IndexedStack(
      index: _section,
      sizing: StackFit.expand,
      children: [
        page(_section == 0, repositories),
        _settingsVisited
            ? page(_section == 1, const SettingsScreen())
            : const SizedBox.shrink(),
      ],
    );

    return CallbackShortcuts(
      bindings: _shortcuts(open, openRepo),
      child: Focus(
        autofocus: true,
        child: _scaffold(context, content, help, openRepo, stillTracked),
      ),
    );
  }

  Widget _scaffold(
    BuildContext context,
    Widget content,
    ErrorHelpRequest? help,
    String? openRepo,
    bool stillTracked,
  ) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _section,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => setState(() {
              // Tapping "Repositories" again returns to the list.
              if (i == 0 && _section == 0) _tabs.activate(null);
              _section = i;
            }),
            leading: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 20),
              child: Tooltip(
                message: 'Gitty',
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Icon(
                    Icons.eco_rounded,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              ),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.folder_copy_outlined),
                selectedIcon: Icon(Icons.folder_copy),
                label: Text('Repositories'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: content,
          ),
          // "Help with this error" — docked on the right, so the app stays
          // usable while following the steps.
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerLeft,
            child: help == null
                ? const SizedBox.shrink()
                : SizedBox(
                    width: 400,
                    height: double.infinity,
                    child: Row(
                      children: [
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: ErrorHelpPanel(
                            key: ValueKey(help.id),
                            request: help,
                            repoPath: stillTracked ? openRepo : null,
                            onClose: () =>
                                ref.read(errorHelpProvider.notifier).close(),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
