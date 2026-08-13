import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Rules list, addressed by rule id throughout.
///
/// The previous version identified rules by their raw string, which also encoded
/// enabled state. That made row keys change on toggle, forced a page-wide
/// mutation lock plus a timed reload guard to paper over the resulting races,
/// and made reorder compute its target index before a removal had shifted the
/// list. All of that goes away once identity is stable.
/// Applies a [ReorderableListView] move to [ids].
///
/// ReorderableListView reports newIndex against the list *before* the dragged
/// item is removed, so downward moves must decrement it. An earlier version got
/// this wrong and every downward drag landed one position short, which looked
/// like the list "snapping back" and made rule order untrustworthy.
///
/// Pure and top-level so the arithmetic can be tested without a gesture.
List<String> applyReorder(List<String> ids, int oldIndex, int newIndex) {
  if (oldIndex < 0 || oldIndex >= ids.length) return List.of(ids);
  final out = List.of(ids);
  if (newIndex > oldIndex) newIndex--;
  final moved = out.removeAt(oldIndex);
  out.insert(newIndex.clamp(0, out.length), moved);
  return out;
}

class RulesPage extends StatefulWidget {
  final CoreManager coreManager;
  const RulesPage({super.key, required this.coreManager});

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> with WindowListener {
  List<CustomizedRuleItem> _rules = [];
  List<RuleGroup> _groups = [];
  Map<String, RuleShadow> _shadows = {};

  bool _isLoading = true;

  /// Ids with a mutation in flight. Scoped per row so one slow request cannot
  /// freeze the whole page, which a single page-wide flag did.
  final Set<String> _busy = {};

  /// Collapsed group ids.
  final Set<String> _collapsed = {};

  String _search = '';
  final _searchCtrl = TextEditingController();

  List<String> _proxyNames = ['DIRECT', 'PROXY', 'REJECT'];

  static const _ruleTypes = [
    'DOMAIN',
    'DOMAIN-SUFFIX',
    'DOMAIN-KEYWORD',
    'DOMAIN-REGEX',
    'IP-CIDR',
    'PROCESS',
    'DNS-MAP',
  ];

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _load();
    _searchCtrl.addListener(
        () => setState(() => _search = _searchCtrl.text.toLowerCase()));
  }

  @override
  void onWindowFocus() {
    // Reload only when nothing is in flight. No timed guard is needed: ids are
    // stable, so a refresh cannot mistake one rule for another.
    if (_busy.isEmpty) _load();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rules = await widget.coreManager.getCustomizedRules();
      final groups = await widget.coreManager.getRuleGroups();
      final proxyList = await widget.coreManager.getProxyList();

      // Diagnostics are advisory; a failure must not block the list.
      Map<String, RuleShadow> shadows = {};
      try {
        final diag = await widget.coreManager.getRuleDiagnostics();
        shadows = diag.shadowById;
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _rules = rules;
        _groups = groups;
        _shadows = shadows;
        _proxyNames = [
          'DIRECT',
          'PROXY',
          'REJECT',
          ...proxyList.proxies.map((p) => p.name).where((n) => n.isNotEmpty),
        ];
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _error('Could not load rules: $e');
      }
    }
  }

  void _error(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  bool _matchesSearch(CustomizedRuleItem r) {
    if (_search.isEmpty) return true;
    return r.ruleType.toLowerCase().contains(_search) ||
        r.payload.toLowerCase().contains(_search) ||
        r.policy.toLowerCase().contains(_search) ||
        r.slug.toLowerCase().contains(_search);
  }

  /// Rules for one group, in order, honouring the search filter.
  List<CustomizedRuleItem> _rulesIn(String groupId) {
    final out = _rules
        .where((r) => r.groupId == groupId && _matchesSearch(r))
        .toList();
    out.sort((a, b) => a.order.compareTo(b.order));
    return out;
  }

  /// Runs [action] with the row marked busy, restoring state on failure.
  ///
  /// The optimistic update is applied by the caller; if the request fails we
  /// reload rather than trying to invert it, so the list always reflects what is
  /// actually stored.
  Future<void> _mutate(String id, Future<void> Function() action) async {
    setState(() => _busy.add(id));
    try {
      await action();
      await _load();
    } catch (e) {
      _error('$e');
      await _load();
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _toggle(CustomizedRuleItem item) async {
    setState(() {
      final i = _rules.indexWhere((r) => r.id == item.id);
      if (i >= 0) _rules[i] = item.copyWith(disabled: !item.disabled);
    });
    await _mutate(item.id, () => widget.coreManager.toggleRuleById(item.id));
  }

  Future<void> _delete(CustomizedRuleItem item) async {
    setState(() => _rules.removeWhere((r) => r.id == item.id));
    await _mutate(item.id, () => widget.coreManager.deleteRuleById(item.id));
  }

  /// Reorder within one group, sending ids rather than raw strings.
  ///
  /// Because the request carries ids scoped to a single group, a rule hidden by
  /// the search filter cannot be dropped: the core keeps anything it is not told
  /// about in its existing position.
  Future<void> _reorder(String groupId, int oldIdx, int newIdx) async {
    final visible = _rulesIn(groupId);
    if (oldIdx < 0 || oldIdx >= visible.length) return;
    final movedId = visible[oldIdx].id;

    final orderedIds =
        applyReorder(visible.map((r) => r.id).toList(), oldIdx, newIdx);

    setState(() {
      for (var i = 0; i < orderedIds.length; i++) {
        final at = _rules.indexWhere((r) => r.id == orderedIds[i]);
        if (at >= 0) _rules[at] = _rules[at].copyWith(order: i);
      }
    });

    await _mutate(
      movedId,
      () => widget.coreManager.reorderRuleIds(groupId, orderedIds),
    );
  }

  Future<void> _toggleGroup(RuleGroup g) async {
    await _mutate('group:${g.id}',
        () => widget.coreManager.toggleRuleGroup(g.id));
  }

  Future<void> _showAddEdit({CustomizedRuleItem? item}) async {
    String ruleType = item?.ruleType ?? 'DOMAIN';
    String payload = item?.payload ?? '';
    String policy = item?.policy ?? 'PROXY';
    String network = item?.network ?? '';

    // DNS-MAP splits payload into domain;ip
    String dnsMapDomain = '';
    String dnsMapIp = '';
    if (ruleType == 'DNS-MAP' && payload.contains(';')) {
      final parts = payload.split(';');
      dnsMapDomain = parts[0];
      dnsMapIp = parts.length > 1 ? parts[1] : '';
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(item == null ? 'Add Rule' : 'Edit Rule'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: ruleType,
                  decoration:
                      const InputDecoration(labelText: 'Type', isDense: true),
                  items: _ruleTypes
                      .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                      .toList(),
                  onChanged: (v) => setDialogState(() => ruleType = v!),
                ),
                const SizedBox(height: 12),
                if (ruleType == 'DNS-MAP') ...[
                  // Two intuitive fields instead of "example.com;127.0.0.1"
                  TextFormField(
                    initialValue: dnsMapDomain,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Domain',
                      hintText: 'example.com',
                      isDense: true,
                    ),
                    onChanged: (v) => dnsMapDomain = v,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: dnsMapIp,
                    decoration: const InputDecoration(
                      labelText: 'Resolve to IP',
                      hintText: '127.0.0.1',
                      isDense: true,
                    ),
                    onChanged: (v) => dnsMapIp = v,
                    onFieldSubmitted: (_) => Navigator.pop(ctx, true),
                  ),
                ] else ...[
                  TextFormField(
                    initialValue: payload,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Payload',
                      hintText: _payloadHint(ruleType),
                      isDense: true,
                    ),
                    onChanged: (v) => payload = v,
                    onFieldSubmitted: (_) => Navigator.pop(ctx, true),
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _proxyNames.contains(policy) ? policy : 'PROXY',
                  decoration:
                      const InputDecoration(labelText: 'Policy', isDense: true),
                  items: _proxyNames
                      .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                      .toList(),
                  onChanged: (v) => setDialogState(() => policy = v!),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: network.isEmpty ? 'both' : network,
                  decoration: const InputDecoration(
                      labelText: 'Protocol', isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'both', child: Text('TCP and UDP')),
                    DropdownMenuItem(value: 'tcp', child: Text('TCP only')),
                    DropdownMenuItem(value: 'udp', child: Text('UDP only')),
                  ],
                  onChanged: (v) =>
                      setDialogState(() => network = v == 'both' ? '' : v!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result != true) return;

    // Assemble the payload
    if (ruleType == 'DNS-MAP') {
      if (dnsMapDomain.trim().isEmpty || dnsMapIp.trim().isEmpty) return;
      payload = '${dnsMapDomain.trim()};${dnsMapIp.trim()}';
    } else {
      if (payload.trim().isEmpty) return;
    }

    final parts = [ruleType, payload.trim(), policy];
    if (network.isNotEmpty) parts.add(network);
    final newRaw = parts.join(',');

    if (item == null) {
      try {
        await widget.coreManager.addCustomizedRules([newRaw]);
      } catch (e) {
        _error('Could not add the rule: $e');
      }
      await _load();
    } else {
      try {
        await widget.coreManager.updateRuleById(
          item.id,
          ruleType: ruleType,
          payload: payload.trim(),
          policy: policy,
          network: network,
        );
      } catch (e) {
        _error('Could not save the rule: $e');
      }
      await _load();
    }
  }

  String _payloadHint(String ruleType) {
    switch (ruleType) {
      case 'DOMAIN':
        return 'example.com';
      case 'DOMAIN-SUFFIX':
        return 'example.com  (matches sub.example.com too)';
      case 'DOMAIN-KEYWORD':
        return 'example';
      case 'DOMAIN-REGEX':
        return r'^ads\..*\.com$';
      case 'IP-CIDR':
        return '10.0.0.0/8';
      case 'PROCESS':
        return 'RustDesk';
      case 'DNS-MAP':
        return 'example.com;127.0.0.1';
      default:
        return '';
    }
  }

  Color _policyColor(String policy) {
    switch (policy) {
      case 'PROXY':
        return Colors.blue;
      case 'DIRECT':
        return Colors.green;
      case 'REJECT':
        return Colors.red;
      default:
        // A named proxy.
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final visibleCount = _rules.where(_matchesSearch).length;
    final brokenCount = _rules.where((r) => r.isBroken).length;

    return Column(
      children: [
        _toolbar(visibleCount, brokenCount),
        const Divider(height: 1),
        Expanded(
          child: _rules.isEmpty
              ? const Center(child: Text('No rules yet'))
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: _buildGroupSections(),
                ),
        ),
      ],
    );
  }

  Widget _toolbar(int visibleCount, int brokenCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'Search rules',
                  prefixIcon: const Icon(Icons.search, size: 16),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: _search.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 14),
                          onPressed: () => _searchCtrl.clear(),
                        ),
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('$visibleCount of ${_rules.length}',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          if (brokenCount > 0) ...[
            const SizedBox(width: 10),
            Tooltip(
              message: '$brokenCount rule(s) reference a proxy that no longer '
                  'exists and cannot match',
              child: Row(children: [
                const Icon(Icons.error_outline, size: 14, color: Colors.red),
                const SizedBox(width: 3),
                Text('$brokenCount broken',
                    style: const TextStyle(fontSize: 11, color: Colors.red)),
              ]),
            ),
          ],
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: () => _showAddEdit(),
            icon: const Icon(Icons.add, size: 15),
            label: const Text('Add', style: TextStyle(fontSize: 12)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 32),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildGroupSections() {
    final sections = <Widget>[];
    final ordered = [..._groups]..sort((a, b) => a.order.compareTo(b.order));

    for (final g in ordered) {
      final rules = _rulesIn(g.id);
      // While searching, hide groups with nothing to show.
      if (rules.isEmpty && _search.isNotEmpty) continue;
      sections.add(_groupHeader(g, rules.length));
      if (!_collapsed.contains(g.id)) {
        sections.add(_groupBody(g.id, rules, groupEnabled: g.enabled));
      }
    }

    // Rules with no group are evaluated last, so show them last.
    final ungrouped = _rulesIn('');
    if (ungrouped.isNotEmpty) {
      sections.add(_ungroupedHeader(ungrouped.length));
      if (!_collapsed.contains('')) {
        sections.add(_groupBody('', ungrouped, groupEnabled: true));
      }
    }
    return sections;
  }

  Widget _groupHeader(RuleGroup g, int count) {
    final collapsed = _collapsed.contains(g.id);
    final busy = _busy.contains('group:${g.id}');
    return InkWell(
      onTap: () => setState(() {
        collapsed ? _collapsed.remove(g.id) : _collapsed.add(g.id);
      }),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 17),
            const SizedBox(width: 4),
            Text(
              g.name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: g.enabled ? null : Colors.grey,
              ),
            ),
            const SizedBox(width: 6),
            Text('$count',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const Spacer(),
            if (!g.enabled)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Text('group off',
                    style: TextStyle(fontSize: 10, color: Colors.grey)),
              ),
            busy
                ? const SizedBox(
                    width: 26,
                    child: Center(
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      ),
                    ),
                  )
                : Tooltip(
                    message: g.enabled
                        ? 'Disable every rule in this group'
                        : 'Enable this group',
                    child: Switch(
                      value: g.enabled,
                      onChanged: (_) => _toggleGroup(g),
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _ungroupedHeader(int count) {
    final collapsed = _collapsed.contains('');
    return InkWell(
      onTap: () => setState(() {
        collapsed ? _collapsed.remove('') : _collapsed.add('');
      }),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 17),
            const SizedBox(width: 4),
            const Text('Ungrouped',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Text('$count',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _groupBody(String groupId, List<CustomizedRuleItem> rules,
      {required bool groupEnabled}) {
    if (rules.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(24, 8, 0, 8),
        child: Text('No rules in this group',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
      );
    }

    // Reordering while a search filter is active would be misleading, since the
    // visible order is not the stored order.
    final canReorder = _search.isEmpty;

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: rules.length,
      onReorder: (o, n) => canReorder ? _reorder(groupId, o, n) : null,
      itemBuilder: (ctx, i) => _ruleRow(rules[i], groupEnabled: groupEnabled, index: i),
    );
  }

  /// Width of the trailing action column.
  ///
  /// Must fit three [_rowAction] buttons. A fixed 84 here was too narrow for
  /// Material's default 48x48 icon buttons, so the row overflowed by 60px and
  /// the delete button was laid out beyond the row's right edge, where it could
  /// not be clicked at all.
  static const double _actionsWidth = 100;

  /// Compact row action sized to the 38px row.
  ///
  /// 32x32 rather than Material's 48x48 default: the row cannot be 48 tall
  /// without halving the number of rules visible at once. 32 still clears the
  /// 24x24 minimum WCAG 2.2 asks for pointer targets, and every button carries a
  /// tooltip so the affordance is not icon-only.
  Widget _rowAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    double iconSize = 14,
  }) {
    return IconButton(
      icon: Icon(icon, size: iconSize),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        maximumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _ruleRow(CustomizedRuleItem rule, {required bool groupEnabled, required int index}) {
    // Key on the id: it survives edits and toggles, so Flutter never reuses one
    // row's state for another rule.
    final key = ValueKey(rule.id);
    final busy = _busy.contains(rule.id);
    final shadow = _shadows[rule.id];
    final inactive = rule.disabled || !groupEnabled || rule.isBroken;
    final canDrag = _search.isEmpty;

    return Container(
      key: key,
      height: 38,
      decoration: BoxDecoration(
        color: inactive
            ? Theme.of(context).colorScheme.surface.withValues(alpha: 0.5)
            : null,
        border: Border(
          bottom:
              BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Drag handle on the left — only active when not searching
          if (canDrag)
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.drag_indicator, size: 16, color: Colors.grey),
              ),
            )
          else
            const SizedBox(width: 24),
          SizedBox(
            width: 6,
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: rule.isBroken
                    ? Colors.red
                    : inactive
                        ? Colors.grey.withValues(alpha: 0.4)
                        : Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          SizedBox(
            width: 112,
            child: Text(
              rule.ruleType,
              style: TextStyle(
                fontSize: 11,
                color: inactive ? Colors.grey : null,
                decoration:
                    rule.disabled ? TextDecoration.lineThrough : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Tooltip
                (
              message: rule.slug.isEmpty ? rule.payload : rule.slug,
              child: Text(
                rule.ruleType == 'DNS-MAP' && rule.payload.contains(';')
                    ? '${rule.payload.split(';')[0]} → ${rule.payload.split(';')[1]}'
                    : rule.payload,
                style: TextStyle(
                  fontSize: 11,
                  color: inactive ? Colors.grey : null,
                  decoration:
                      rule.disabled ? TextDecoration.lineThrough : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (rule.network.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.blueGrey.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(rule.network.toUpperCase(),
                  style: const TextStyle(fontSize: 9)),
            ),
          if (rule.isBroken)
            Tooltip(
              message: rule.broken,
              child: const Padding(
                padding: EdgeInsets.only(right: 5),
                child: Icon(Icons.error_outline, size: 14, color: Colors.red),
              ),
            ),
          if (shadow != null)
            Tooltip(
              message: 'Never matches: ${shadow.reason}. '
                  'Shadowed by ${shadow.shadowedBySlug}.',
              child: const Padding(
                padding: EdgeInsets.only(right: 5),
                child: Icon(Icons.visibility_off_outlined,
                    size: 14, color: Colors.amber),
              ),
            ),
          Container(
            width: 96,
            alignment: Alignment.centerLeft,
            child: Text(
              rule.policy,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: inactive ? Colors.grey : _policyColor(rule.policy),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (busy)
            const SizedBox(
              width: _actionsWidth,
              child: Center(
                child: SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              ),
            )
          else
            SizedBox(
              width: _actionsWidth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _rowAction(
                    icon: rule.disabled
                        ? Icons.toggle_off_outlined
                        : Icons.toggle_on,
                    iconSize: 19,
                    tooltip: rule.disabled ? 'Enable' : 'Disable',
                    onPressed: () => _toggle(rule),
                  ),
                  _rowAction(
                    icon: Icons.edit_outlined,
                    tooltip: 'Edit',
                    onPressed: () => _showAddEdit(item: rule),
                  ),
                  _rowAction(
                    icon: Icons.delete_outline,
                    tooltip: 'Delete',
                    onPressed: () => _confirmDelete(rule),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(CustomizedRuleItem rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete rule'),
        content: Text('${rule.ruleType},${rule.payload} -> ${rule.policy}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await _delete(rule);
  }
}
