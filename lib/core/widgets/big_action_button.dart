import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Large, friendly action tile: icon, label and a one-line explanation.
/// Shows a spinner while [busy] and a small count badge if [badge] is set.
class BigActionButton extends StatelessWidget {
  const BigActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.caption,
    required this.onPressed,
    this.busy = false,
    this.badge,
    this.emphasized = false,
    this.help,
    this.command,
  });

  final IconData icon;
  final String label;
  final String caption;
  final VoidCallback? onPressed;
  final bool busy;
  final String? badge;

  /// Highlights the button as the suggested next step.
  final bool emphasized;

  /// Longer explanation, shown from a small "?" in the top-right corner
  /// (hover or tap) so the card itself stays calm.
  final String? help;

  /// The git command this runs, shown at the bottom with a copy button —
  /// so you learn the real thing as you go.
  final String? command;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final enabled = onPressed != null && !busy;

    final background = emphasized
        ? scheme.primaryContainer
        : scheme.surfaceContainer;
    final foreground = emphasized
        ? scheme.onPrimaryContainer
        : scheme.onSurface;

    final tile = Material(
      color: background,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? onPressed : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: onPressed == null ? 0.45 : 1,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              // With a command, fill the tile so it sits at the bottom.
              mainAxisSize: command == null
                  ? MainAxisSize.min
                  : MainAxisSize.max,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: busy
                          ? Padding(
                              padding: const EdgeInsets.all(3),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: foreground,
                              ),
                            )
                          : Icon(icon, size: 26, color: scheme.primary),
                    ),
                    const Spacer(),
                    if (badge != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          badge!,
                          style: text.labelSmall?.copyWith(
                            color: scheme.onPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    if (help != null) ...[
                      if (badge != null) const SizedBox(width: 6),
                      Tooltip(
                        message: help!,
                        triggerMode: TooltipTriggerMode.tap,
                        waitDuration: const Duration(milliseconds: 150),
                        showDuration: const Duration(seconds: 12),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.help,
                          child: Icon(
                            Icons.help_outline_rounded,
                            size: 18,
                            color: foreground.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: text.titleSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: foreground.withValues(alpha: 0.7),
                  ),
                ),
                if (command != null) ...[
                  const Spacer(),
                  _CommandLine(command: command!, foreground: foreground),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    return tile;
  }
}

/// "\$ git fetch --all --prune" in a small console-style strip, with copy.
class _CommandLine extends StatefulWidget {
  const _CommandLine({required this.command, required this.foreground});

  final String command;
  final Color foreground;

  @override
  State<_CommandLine> createState() => _CommandLineState();
}

class _CommandLineState extends State<_CommandLine> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.command));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = widget.foreground;
    final mono = theme.textTheme.labelSmall?.copyWith(
      fontFamily: 'monospace',
      color: fg.withValues(alpha: 0.85),
      height: 1.2,
    );
    return Container(
      height: 26,
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: fg.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          Text('\$', style: mono?.copyWith(color: fg.withValues(alpha: 0.45))),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: widget.command,
              waitDuration: const Duration(milliseconds: 500),
              child: Text(
                widget.command,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono,
              ),
            ),
          ),
          IconButton(
            tooltip: _copied ? 'Copied' : 'Copy command',
            onPressed: _copy,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            iconSize: 13,
            icon: Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              color: fg.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
