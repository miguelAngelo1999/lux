import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A compact mode selector for the header.
///
/// - Clicking the main body CYCLES to the next mode (icon + name update in
///   place), so a user can tap-tap-tap through modes without opening anything.
/// - Clicking the little chevron FANS the modes out in a stacked arc — like the
///   macOS Dock "fan" when you click a folder — and tapping one jumps straight
///   to it.
///
/// It is presentation-only: it renders whatever ordered [modes] it is given and
/// calls [onSelected] with the chosen mode id. Label/description/icon come from
/// the caller so this widget stays agnostic of the rule set.
class ModeFanButton extends StatefulWidget {
  const ModeFanButton({
    super.key,
    required this.modes,
    required this.selected,
    required this.labelOf,
    required this.descriptionOf,
    required this.iconOf,
    required this.onSelected,
    this.enabled = true,
    this.width = 184,
  });

  /// Ordered list of mode ids (the cycle order).
  final List<String> modes;

  /// Currently-selected mode id.
  final String selected;

  final String Function(String id) labelOf;
  final String Function(String id) descriptionOf;
  final IconData Function(String id) iconOf;

  /// Called with the newly chosen mode id (on cycle or fan pick).
  final ValueChanged<String> onSelected;

  final bool enabled;
  final double width;

  @override
  State<ModeFanButton> createState() => _ModeFanButtonState();
}

class _ModeFanButtonState extends State<ModeFanButton>
    with SingleTickerProviderStateMixin {
  final LayerLink _link = LayerLink();
  final GlobalKey _buttonKey = GlobalKey();
  OverlayEntry? _overlay;
  late final AnimationController _fan = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  bool get _isOpen => _overlay != null;

  @override
  void dispose() {
    _removeFan(immediate: true);
    _fan.dispose();
    super.dispose();
  }

  void _cycle() {
    if (!widget.enabled || widget.modes.isEmpty) return;
    final i = widget.modes.indexOf(widget.selected);
    final next = widget.modes[(i + 1) % widget.modes.length];
    widget.onSelected(next);
  }

  void _toggleFan() {
    if (!widget.enabled || widget.modes.isEmpty) return;
    if (_isOpen) {
      _removeFan();
    } else {
      _openFan();
    }
  }

  void _openFan() {
    final overlay = Overlay.of(context);
    _overlay = OverlayEntry(builder: _buildFan);
    overlay.insert(_overlay!);
    _fan.forward(from: 0);
    setState(() {});
  }

  void _removeFan({bool immediate = false}) {
    if (_overlay == null) return;
    final entry = _overlay!;
    _overlay = null;
    if (immediate) {
      entry.remove();
      if (mounted) setState(() {});
      return;
    }
    _fan.reverse().whenComplete(() {
      entry.remove();
      if (mounted) setState(() {});
    });
  }

  void _pick(String id) {
    widget.onSelected(id);
    _removeFan();
  }

  // ── fan overlay ────────────────────────────────────────────────────────────

  Widget _buildFan(BuildContext context) {
    // The modes other than the current one fan upward from the button.
    final others = widget.modes.where((m) => m != widget.selected).toList();
    final box = _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    final buttonSize = box?.size ?? Size(widget.width, 36);

    return Stack(
      children: [
        // Tap-outside scrim to dismiss.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _removeFan,
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          // The button lives in the AppBar at the TOP of the window, so the fan
          // must open DOWNWARD. Anchor the fan's top-center to the button's
          // bottom-center.
          targetAnchor: Alignment.bottomCenter,
          followerAnchor: Alignment.topCenter,
          offset: const Offset(0, 8),
          child: AnimatedBuilder(
            animation: _fan,
            builder: (context, _) {
              return SizedBox(
                width: buttonSize.width,
                child: _FanStack(
                  progress: Curves.easeOutBack.transform(_fan.value.clamp(0, 1)),
                  children: [
                    for (final id in others)
                      _FanChip(
                        icon: widget.iconOf(id),
                        label: widget.labelOf(id),
                        description: widget.descriptionOf(id),
                        onTap: () => _pick(id),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── main button ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = widget.selected.isEmpty ? '' : widget.labelOf(widget.selected);
    final icon = widget.selected.isEmpty
        ? Icons.rule
        : widget.iconOf(widget.selected);

    return CompositedTransformTarget(
      link: _link,
      child: SizedBox(
        key: _buttonKey,
        width: widget.width,
        height: 36,
        child: Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              // Main body — click to cycle to the next mode.
              Expanded(
                child: InkWell(
                  onTap: widget.enabled ? _cycle : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Icon(icon, size: 18, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Divider + chevron — click to fan out all modes.
              Container(width: 1, height: 20, color: theme.dividerColor),
              InkWell(
                onTap: widget.enabled ? _toggleFan : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: AnimatedRotation(
                    // Points down (fan opens downward); flips up when open.
                    turns: _isOpen ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.keyboard_arrow_down,
                        size: 20, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lays its [children] out in a vertical fan arc that rises from the base,
/// each child offset slightly horizontally so they splay like a Dock fan.
class _FanStack extends StatelessWidget {
  const _FanStack({required this.children, required this.progress});

  final List<Widget> children;
  final double progress;

  @override
  Widget build(BuildContext context) {
    const itemHeight = 46.0;
    const gap = 8.0;
    final n = children.length;
    if (n == 0) return const SizedBox.shrink();

    // Total height the fan occupies when fully open.
    final fullHeight = n * (itemHeight + gap);

    return SizedBox(
      height: fullHeight * progress + 0.1,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          for (int i = 0; i < n; i++)
            // Item 0 sits closest to the button; lower items drop further down.
            Positioned(
              top: (i * (itemHeight + gap)) * progress,
              // Slight horizontal splay like the Dock fan.
              left: math.sin(i * 0.6) * 6 * progress,
              right: -math.sin(i * 0.6) * 6 * progress,
              child: Opacity(
                opacity: progress.clamp(0, 1),
                child: Transform.scale(
                  scale: 0.85 + 0.15 * progress,
                  child: children[i],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FanChip extends StatelessWidget {
  const _FanChip({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 4,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    if (description.isNotEmpty)
                      Text(description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10, color: theme.hintColor)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
