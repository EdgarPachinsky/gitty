import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../core/utils/time_ago.dart';
import '../../../core/widgets/state_views.dart';

/// Shown for a connected folder that isn't a Git repository yet.
/// One click runs `git init`; the user's files are never touched.
class InitRepositoryView extends StatefulWidget {
  const InitRepositoryView({
    super.key,
    required this.folderPath,
    required this.busy,
    required this.onInit,
  });

  final String folderPath;
  final bool busy;
  final VoidCallback onInit;

  @override
  State<InitRepositoryView> createState() => _InitRepositoryViewState();
}

class _InitRepositoryViewState extends State<InitRepositoryView> {
  /// Visible items in the folder (null while counting).
  int? _itemCount;

  static const _ignored = {'.DS_Store', 'Thumbs.db', 'desktop.ini'};

  @override
  void initState() {
    super.initState();
    _count();
  }

  Future<void> _count() async {
    var count = 0;
    try {
      await for (final entity in Directory(widget.folderPath).list()) {
        if (!_ignored.contains(p.basename(entity.path))) count++;
      }
    } catch (_) {
      // Unreadable folder — fall back to the generic message.
    }
    if (mounted) setState(() => _itemCount = count);
  }

  @override
  Widget build(BuildContext context) {
    final message = switch (_itemCount) {
      0 =>
        'It’s empty — a perfect fresh start. Initialize Git, then connect it to '
            'GitHub (or any remote) so your work is backed up.',
      final int n when n > 0 =>
        'It has ${plural(n, 'item')}. Initializing Git won’t move or change any '
            'of them — Git just starts keeping track, and you choose what to commit.',
      _ =>
        'Initialize Git to start keeping track of changes here. Nothing in the '
            'folder is moved or changed.',
    };

    return SingleChildScrollView(
      child: EmptyState(
        icon: Icons.eco_outlined,
        title: 'This folder isn’t using Git yet',
        message: message,
        actions: [
          FilledButton.icon(
            onPressed: widget.busy ? null : widget.onInit,
            icon: widget.busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: const Text('Initialize Git'),
          ),
        ],
      ),
    );
  }
}
