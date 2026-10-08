import 'package:flutter/material.dart';

import '../../../core/utils/time_ago.dart';
import '../../../services/git/git_models.dart';

/// A picture of which branch grew from which — drawn like a real tree:
/// the trunk (main) at the top, lines to every branch that grew out of it,
/// and a plain sentence on each ("Grew from main 3 days ago · has 2 new
/// changes of its own").
class BranchTreeView extends StatelessWidget {
  const BranchTreeView({
    super.key,
    required this.tree,
    required this.onPick,
    this.query = '',
  });

  final BranchTree tree;
  final ValueChanged<BranchNode> onPick;

  /// When not empty, shows a flat list of matching branches instead.
  final String query;

  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      final matches = tree.nodes
          .where((n) => n.name.toLowerCase().contains(q))
          .toList();
      if (matches.isEmpty) {
        return const Center(child: Text('No branches match.'));
      }
      return ListView(
        children: [
          for (final n in matches)
            _BranchRow(
              node: n,
              depth: 0,
              isLast: true,
              continuing: const [],
              hasChildren: false,
              showLines: false,
              onTap: () => onPick(n),
            ),
        ],
      );
    }

    final rows = _flatten();
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final r = rows[i];
        return _BranchRow(
          node: r.node,
          depth: r.depth,
          isLast: r.isLast,
          continuing: r.continuing,
          hasChildren: tree.childrenOf(r.node.name).isNotEmpty,
          showLines: true,
          onTap: () => onPick(r.node),
        );
      },
    );
  }

  /// Depth-first walk from the trunk, remembering which lines continue.
  List<_Row> _flatten() {
    final rows = <_Row>[];
    final seen = <String>{};
    void visit(BranchNode node, int depth, bool isLast, List<bool> continuing) {
      if (!seen.add(node.name)) return;
      rows.add(_Row(node, depth, isLast, continuing));
      final kids = tree.childrenOf(node.name);
      for (var i = 0; i < kids.length; i++) {
        visit(kids[i], depth + 1, i == kids.length - 1, [
          ...continuing,
          if (depth > 0) !isLast,
        ]);
      }
    }

    final root = tree.root == null ? null : tree.node(tree.root!);
    if (root != null) visit(root, 0, true, const []);
    // Anything not reachable from the trunk (shouldn't happen) goes last.
    for (final n in tree.nodes) {
      if (!seen.contains(n.name)) visit(n, root == null ? 0 : 1, true, const []);
    }
    return rows;
  }
}

class _Row {
  const _Row(this.node, this.depth, this.isLast, this.continuing);

  final BranchNode node;
  final int depth;
  final bool isLast;
  final List<bool> continuing;
}

class _BranchRow extends StatelessWidget {
  const _BranchRow({
    required this.node,
    required this.depth,
    required this.isLast,
    required this.continuing,
    required this.hasChildren,
    required this.showLines,
    required this.onTap,
  });

  /// One tree column = one bubble wide, so lines sit under bubble centres.
  static const _indent = 30.0;
  final bool hasChildren;

  final BranchNode node;
  final int depth;
  final bool isLast;
  final List<bool> continuing;
  final bool showLines;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lineColor = scheme.outlineVariant;
    final current = node.isCurrent;

    final (IconData icon, Color bg, Color fg) = node.isRoot
        ? (Icons.park_rounded, scheme.primary, scheme.onPrimary)
        : current
        ? (Icons.place_rounded, scheme.tertiary, scheme.onTertiary)
        : node.isRemoteOnly
        ? (Icons.cloud_outlined, scheme.surfaceContainerHighest, scheme.onSurfaceVariant)
        : (Icons.eco_rounded, scheme.secondaryContainer, scheme.onSecondaryContainer);

    final bubble = Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: current ? Border.all(color: scheme.tertiary, width: 2) : null,
      ),
      child: Icon(icon, size: 17, color: fg),
    );

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showLines && depth > 0) SizedBox(width: depth * _indent),
        Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Material(
                color: current
                    ? scheme.tertiaryContainer.withValues(alpha: 0.55)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: current ? null : onTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 10, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        bubble,
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    node.name,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: current || node.isRoot
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                  if (current)
                                    _Tag(
                                      'You are here',
                                      bg: scheme.tertiary,
                                      fg: scheme.onTertiary,
                                    ),
                                  if (node.isRoot)
                                    _Tag(
                                      'Trunk',
                                      bg: scheme.primaryContainer,
                                      fg: scheme.onPrimaryContainer,
                                    ),
                                  if (node.isRemoteOnly)
                                    _Tag(
                                      'Only online',
                                      bg: scheme.surfaceContainerHighest,
                                      fg: scheme.onSurfaceVariant,
                                    ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _story(node),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!current)
                          Padding(
                            padding: const EdgeInsets.only(left: 6, top: 4),
                            child: Icon(
                              node.isRemoteOnly
                                  ? Icons.download_rounded
                                  : Icons.arrow_forward_rounded,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    return IntrinsicHeight(
      child: showLines
          ? CustomPaint(
              painter: _TreeLinesPainter(
                depth: depth,
                isLast: isLast,
                continuing: continuing,
                hasChildren: hasChildren,
                indent: _indent,
                color: lineColor,
              ),
              child: row,
            )
          : row,
    );
  }

  /// The plain-language sentence under each branch.
  static String _story(BranchNode n) {
    String changes(int count) => count == 1 ? '1 change' : '$count changes';
    if (n.isRoot) {
      return 'The trunk — the main version everyone shares. '
          'Other branches grow out of it.';
    }
    final parent = n.parent ?? 'the trunk';
    final when = n.forkedAt == null ? '' : ' ${timeAgo(n.forkedAt!)}';
    final parts = <String>[
      '${n.parentIsGuess ? 'Probably grew' : 'Grew'} from $parent$when.',
      n.ahead == 0
          ? 'Nothing new on it yet.'
          : 'Has ${changes(n.ahead)} of its own.',
      if (n.behind > 0) '$parent got ${changes(n.behind)} since.',
      if (n.isRemoteOnly) 'Tap to get a copy.',
    ];
    return parts.join(' ');
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {required this.bg, required this.fg});

  final String text;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Draws the "├─" / "└─" connectors, the vertical lines of ancestors, and
/// a stub down to this branch's own children.
///
/// Column c's line runs through x = c·indent + indent/2, which is exactly
/// the centre of the bubble of a branch at depth c.
class _TreeLinesPainter extends CustomPainter {
  _TreeLinesPainter({
    required this.depth,
    required this.isLast,
    required this.continuing,
    required this.hasChildren,
    required this.indent,
    required this.color,
  });

  final int depth;
  final bool isLast;
  final List<bool> continuing;
  final bool hasChildren;
  final double indent;
  final Color color;

  /// Row padding (3) + inner padding (8) + half the 30px bubble.
  static const nodeY = 26.0;
  static const bubbleRadius = 15.0;

  double _column(int c) => c * indent + indent / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Lines of ancestors that still have branches further down.
    for (var i = 0; i < continuing.length; i++) {
      if (continuing[i]) {
        final x = _column(i);
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
    }

    if (depth > 0) {
      // Elbow from the parent's line into this bubble.
      final x = _column(depth - 1);
      final bubbleLeft = depth * indent;
      final path = Path()
        ..moveTo(x, 0)
        ..lineTo(x, nodeY - 8)
        ..quadraticBezierTo(x, nodeY, x + 8, nodeY)
        ..lineTo(bubbleLeft, nodeY);
      canvas.drawPath(path, paint);
      // More siblings below: keep the parent's line going.
      if (!isLast) {
        canvas.drawLine(Offset(x, nodeY - 8), Offset(x, size.height), paint);
      }
    }

    // Stub from this bubble down to its first child.
    if (hasChildren) {
      final x = _column(depth);
      canvas.drawLine(
        Offset(x, nodeY + bubbleRadius),
        Offset(x, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TreeLinesPainter old) =>
      old.depth != depth ||
      old.isLast != isLast ||
      old.hasChildren != hasChildren ||
      old.color != color ||
      old.continuing.length != continuing.length;
}
