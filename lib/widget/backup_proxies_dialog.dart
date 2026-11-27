import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/t_text.dart';

class BackupPoolChoice {
  final String mode; // 'all' or 'selected'
  final List<String> proxyIds;

  const BackupPoolChoice({required this.mode, required this.proxyIds});
}

/// Sleek modal allowing power users to choose whether Stay connected can fail
/// over to all saved proxies or only selected backup proxies.
class BackupProxiesDialog extends StatefulWidget {
  final List<ProxyItem> proxies;
  final String initialMode;
  final List<String> initialSelectedIds;

  const BackupProxiesDialog({
    super.key,
    required this.proxies,
    required this.initialMode,
    required this.initialSelectedIds,
  });

  @override
  State<BackupProxiesDialog> createState() => _BackupProxiesDialogState();
}

class _BackupProxiesDialogState extends State<BackupProxiesDialog> {
  late String _mode;
  late Set<String> _selectedIds;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode == 'selected' ? 'selected' : 'all';
    _selectedIds = Set<String>.from(widget.initialSelectedIds);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardSurface = isDark ? const Color(0xFF0E131D) : const Color(0xFFF8FAFC);

    Widget modeOption({
      required String value,
      required String title,
      required String subtitle,
    }) {
      final active = _mode == value;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _mode = value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? tokens.cobalt.withValues(alpha: 0.11)
                : cardSurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active
                  ? tokens.cobalt.withValues(alpha: 0.45)
                  : tokens.hairline,
            ),
          ),
          child: Row(
            children: [
              Icon(
                active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 16,
                color: active ? tokens.cobalt : tokens.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TText(
                      title,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                        color: tokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 1),
                    TText(
                      subtitle,
                      style: TextStyle(fontSize: 11, color: tokens.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      title: Row(
        children: [
          Icon(Icons.backup_table_rounded, size: 18, color: tokens.cobalt),
          const SizedBox(width: 8),
          const Expanded(child: TText('Backup proxies')),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                modeOption(
                  value: 'all',
                  title: 'All saved proxies',
                  subtitle: 'Try any other saved proxy in list order when yours fails.',
                ),
                const SizedBox(height: 8),
                modeOption(
                  value: 'selected',
                  title: 'Only selected proxies',
                  subtitle: 'Restrict failover to the backups checked below.',
                ),
                if (_mode == 'selected') ...[
                  const SizedBox(height: 10),
                  if (widget.proxies.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: TText(
                        'No proxies configured',
                        style: TextStyle(fontSize: 12, color: tokens.textMuted),
                      ),
                    )
                  else
                    Material(
                      color: cardSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(color: tokens.hairline),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: widget.proxies.map((p) {
                          final checked = _selectedIds.contains(p.id);
                          final isPacOnly = (p.server ?? '').trim().isEmpty &&
                              (p.pacUrl?.trim().isNotEmpty ?? false);
                          final sub = isPacOnly
                              ? (p.pacUrl ?? 'PAC')
                              : '${p.server ?? ''}:${p.port ?? 0}';
                          final badge = isPacOnly
                              ? 'PAC'
                              : p.type.toUpperCase();
                          return CheckboxListTile(
                            value: checked,
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 8),
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selectedIds.add(p.id);
                              } else {
                                _selectedIds.remove(p.id);
                              }
                            }),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    p.name.isNotEmpty ? p.name : sub,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                      color: tokens.textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: tokens.subtlePillBg,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: tokens.hairline),
                                  ),
                                  child: Text(
                                    badge,
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w600,
                                      color: tokens.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Text(
                              sub,
                              style: luxMonoStyle(
                                fontSize: 11,
                                color: tokens.textMuted,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const TText('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            BackupPoolChoice(
              mode: _mode,
              proxyIds: _selectedIds.toList(),
            ),
          ),
          child: const TText('Save'),
        ),
      ],
    );
  }
}
