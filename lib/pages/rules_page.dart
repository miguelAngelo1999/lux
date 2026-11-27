import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/widget/lux_icons.dart';
import 'package:lux/widget/lux_scroll_edge_fade.dart';
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
  final VoidCallback? onOpenBypassCidrs;

  const RulesPage({
    super.key,
    required this.coreManager,
    this.onOpenBypassCidrs,
  });

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
  Map<String, String> _proxyNameToId = {};

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
        _proxyNameToId = {
          for (final p in proxyList.proxies)
            if (p.name.isNotEmpty) p.name: p.id,
        };
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _error('${tl(context, 'Could not load rules')}: ${_friendlyRuleError(e)}');
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
      _error(_friendlyRuleError(e));
      await _load();
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  /// Short, human message for a failed rule action. A 404 here means the UI
  /// acted on a rule/group that no longer exists on the core (stale list) — we
  /// reload right after, so the list self-heals; the user just needs a readable
  /// note, not the raw multi-line DioException dump.
  String _friendlyRuleError(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code == 404) {
        return tl(context, 'That rule no longer exists — the list was refreshed.');
      }
      // Prefer the core's JSON error message if present.
      final data = e.response?.data;
      if (data is Map && data['message'] is String) {
        return data['message'] as String;
      }
      if (code != null) {
        return tl(context, 'Could not apply the change (error $code).');
      }
      return tl(context, 'Could not reach the proxy engine. Please try again.');
    }
    return tl(context, 'Could not apply the change. Please try again.');
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

  Future<void> _showAddEdit({CustomizedRuleItem? item, String? initialPayload}) async {
    String ruleType = item?.ruleType ?? 'DOMAIN';
    // When creating a rule, seed the payload from the search term if given.
    String payload = item?.payload ?? initialPayload ?? '';
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
          title: TText(item == null ? 'Add Rule' : 'Edit Rule'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: ruleType,
                  decoration:
                      InputDecoration(labelText: tl(context, 'Type'), isDense: true),
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
                    decoration: InputDecoration(
                      labelText: tl(context, 'Domain'),
                      hintText: tl(context, 'example.com'),
                      isDense: true,
                    ),
                    onChanged: (v) => dnsMapDomain = v,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: dnsMapIp,
                    decoration: InputDecoration(
                      labelText: tl(context, 'Resolve to IP'),
                      hintText: tl(context, '127.0.0.1'),
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
                      labelText: tl(context, 'Payload'),
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
                      InputDecoration(labelText: tl(context, 'Policy'), isDense: true),
                  items: _proxyNames
                      .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                      .toList(),
                  onChanged: (v) => setDialogState(() => policy = v!),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: network.isEmpty ? 'both' : network,
                  decoration: InputDecoration(
                      labelText: tl(context, 'Protocol'), isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'both', child: TText('TCP and UDP')),
                    DropdownMenuItem(value: 'tcp', child: TText('TCP only')),
                    DropdownMenuItem(value: 'udp', child: TText('UDP only')),
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
              child: const TText('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const TText('Save'),
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
        _error(_friendlyRuleError(e));
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
          proxyId: _proxyNameToId[policy],
        );
      } catch (e) {
        _error(_friendlyRuleError(e));
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

  Color _policyColor(BuildContext context, String policy) {
    final tokens = LuxTokens.of(context);
    switch (policy) {
      case 'PROXY':
        return tokens.cobalt;
      case 'DIRECT':
        return tokens.emerald;
      case 'REJECT':
        return tokens.danger;
      default:
        return tokens.amber;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    final visibleCount = _rules.where(_matchesSearch).length;
    final brokenCount = _rules.where((r) => r.isBroken).length;

    return Column(
      children: [
        _toolbar(tokens, visibleCount, brokenCount),
        Container(height: 0.75, color: tokens.hairline),
        if (_search.isNotEmpty) _createFromSearchBanner(tokens, visibleCount),
        Expanded(
          child: _rules.isEmpty
              ? Center(
                  child: TText(
                    'No rules yet',
                    style: TextStyle(fontSize: 12.5, color: tokens.textMuted),
                  ),
                )
              : LuxScrollEdgeFade(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                    children: _buildGroupSections(tokens),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _createFromSearchBanner(LuxTokens tokens, int visibleCount) {
    final term = _searchCtrl.text.trim();
    if (term.isEmpty) return const SizedBox.shrink();
    final noMatches = visibleCount == 0;
    return Material(
      color: noMatches
          ? tokens.cobalt.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: () => _showAddEdit(initialPayload: term),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              LuxIcon(LuxGlyph.plus, size: 14, color: tokens.cobalt),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: tl(context, 'Create rule for ')),
                    TextSpan(
                      text: '"$term"',
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: tokens.textPrimary,
                      ),
                    ),
                    if (noMatches)
                      TextSpan(
                        text: '  (${tl(context, 'no matches')})',
                        style: TextStyle(
                          fontSize: 11,
                          color: tokens.textMuted,
                        ),
                      ),
                  ]),
                  style: TextStyle(fontSize: 12, color: tokens.textSecondary),
                ),
              ),
              LuxIcon(LuxGlyph.chevronRight, size: 14, color: tokens.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar(LuxTokens tokens, int visibleCount, int brokenCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 500;
          return Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _searchCtrl,
                    textAlignVertical: TextAlignVertical.center,
                    style: TextStyle(fontSize: 12, color: tokens.textPrimary),
                    decoration: InputDecoration(
                      hintText: tl(context, 'Search rules'),
                      hintStyle:
                          TextStyle(fontSize: 12, color: tokens.textMuted),
                      prefixIcon: Center(
                        child: LuxIcon(LuxGlyph.search,
                            size: 13.5, color: tokens.textMuted),
                      ),
                      prefixIconConstraints:
                          const BoxConstraints.tightFor(width: 32, height: 32),
                      suffixIconConstraints: const BoxConstraints(
                          minWidth: 30, minHeight: 32, maxHeight: 32),
                      isDense: true,
                      filled: true,
                      fillColor: tokens.cardBg,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 0),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: tokens.hairline, width: 0.75),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: tokens.cobalt, width: 1.0),
                      ),
                      suffixIcon: _search.isEmpty
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip:
                                      tl(context, 'Create rule for this term'),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 28, minHeight: 28),
                                  icon: LuxIcon(LuxGlyph.plus,
                                      size: 13, color: tokens.cobalt),
                                  onPressed: () {
                                    final term = _searchCtrl.text.trim();
                                    if (term.isEmpty) return;
                                    _showAddEdit(initialPayload: term);
                                  },
                                ),
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 28, minHeight: 28),
                                  icon: LuxIcon(LuxGlyph.close,
                                      size: 12, color: tokens.textMuted),
                                  onPressed: () => _searchCtrl.clear(),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                decoration: BoxDecoration(
                  color: tokens.subtlePillBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: tokens.hairline, width: 0.75),
                ),
                child: Text(
                  '$visibleCount ${tl(context, 'of')} ${_rules.length}',
                  style: luxMonoStyle(
                      fontSize: 10.5, color: tokens.textSecondary),
                ),
              ),
              if (brokenCount > 0) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message:
                      '$brokenCount rule(s) reference a proxy that no longer '
                      'exists and cannot match',
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: tokens.danger.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: tokens.danger.withValues(alpha: 0.35),
                          width: 0.75),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LuxIcon(LuxGlyph.alertCircle,
                            size: 12, color: tokens.danger),
                        const SizedBox(width: 4),
                        Text(
                          '$brokenCount ${tl(context, 'broken')}',
                          style: TextStyle(fontSize: 10.5, color: tokens.danger),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (widget.onOpenBypassCidrs != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: tl(context, 'Bypass CIDRs'),
                  child: SizedBox(
                    height: 32,
                    width: compact ? 32 : null,
                    child: OutlinedButton(
                      key: const Key('rules-bypass-cidrs-button'),
                      onPressed: widget.onOpenBypassCidrs,
                      style: OutlinedButton.styleFrom(
                        backgroundColor: tokens.cardBg,
                        foregroundColor: tokens.textPrimary,
                        padding: compact
                            ? EdgeInsets.zero
                            : const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: BorderSide(
                            color: tokens.hairlineStrong, width: 0.75),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          LuxIcon(LuxGlyph.route,
                              size: 12.5, color: tokens.textSecondary),
                          if (!compact) ...[
                            const SizedBox(width: 5),
                            const TText('Bypass CIDRs',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w400)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Tooltip(
                message: tl(context, 'Add Rule'),
                child: SizedBox(
                  height: 32,
                  width: compact ? 32 : null,
                  child: FilledButton(
                    onPressed: () => _showAddEdit(),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      padding: compact
                          ? EdgeInsets.zero
                          : const EdgeInsets.symmetric(horizontal: 11),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const LuxIcon(LuxGlyph.plus,
                            size: 12.5, color: Colors.white),
                        if (!compact) ...[
                          const SizedBox(width: 5),
                          const TText('Add',
                              style: TextStyle(
                                  fontSize: 11.5, fontWeight: FontWeight.w500)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildGroupSections(LuxTokens tokens) {
    final sections = <Widget>[];
    final ordered = [..._groups]..sort((a, b) => a.order.compareTo(b.order));

    for (final g in ordered) {
      final rules = _rulesIn(g.id);
      if (rules.isEmpty && _search.isNotEmpty) continue;
      sections.add(_groupCard(tokens, g: g, rules: rules));
      sections.add(const SizedBox(height: 10));
    }

    final ungrouped = _rulesIn('');
    if (ungrouped.isNotEmpty) {
      sections.add(_groupCard(tokens, g: null, rules: ungrouped));
    }
    return sections;
  }

  Widget _groupCard(
    LuxTokens tokens, {
    required RuleGroup? g,
    required List<CustomizedRuleItem> rules,
  }) {
    final groupId = g?.id ?? '';
    final collapsed = _collapsed.contains(groupId);
    final groupEnabled = g?.enabled ?? true;

    return Material(
      color: tokens.cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: BorderSide(color: tokens.hairline, width: 0.75),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (g != null)
            _groupHeader(tokens, g, rules.length)
          else
            _ungroupedHeader(tokens, rules.length),
          if (!collapsed) ...[
            Container(height: 0.75, color: tokens.hairline),
            _groupBody(tokens, groupId, rules, groupEnabled: groupEnabled),
          ],
        ],
      ),
    );
  }

  Widget _groupHeader(LuxTokens tokens, RuleGroup g, int count) {
    final collapsed = _collapsed.contains(g.id);
    final busy = _busy.contains('group:${g.id}');
    return InkWell(
      onTap: () => setState(() {
        collapsed ? _collapsed.remove(g.id) : _collapsed.add(g.id);
      }),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        color: tokens.subtlePillBg,
        child: Row(
          children: [
            LuxIcon(
              collapsed ? LuxGlyph.chevronRight : LuxGlyph.chevronDown,
              size: 13,
              color: tokens.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              g.name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: g.enabled ? tokens.textPrimary : tokens.textMuted,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: luxMonoStyle(fontSize: 10.5, color: tokens.textMuted),
            ),
            const Spacer(),
            if (!g.enabled)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: TText(
                  'group off',
                  style: TextStyle(fontSize: 10.5, color: tokens.textMuted),
                ),
              ),
            busy
                ? SizedBox(
                    width: 26,
                    child: Center(
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: tokens.cobalt,
                        ),
                      ),
                    ),
                  )
                : Tooltip(
                    message: g.enabled
                        ? 'Disable every rule in this group'
                        : 'Enable this group',
                    child: Transform.scale(
                      scale: 0.78,
                      child: Switch(
                        value: g.enabled,
                        onChanged: (_) => _toggleGroup(g),
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _ungroupedHeader(LuxTokens tokens, int count) {
    final collapsed = _collapsed.contains('');
    return InkWell(
      onTap: () => setState(() {
        collapsed ? _collapsed.remove('') : _collapsed.add('');
      }),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        color: tokens.subtlePillBg,
        child: Row(
          children: [
            LuxIcon(
              collapsed ? LuxGlyph.chevronRight : LuxGlyph.chevronDown,
              size: 13,
              color: tokens.textMuted,
            ),
            const SizedBox(width: 6),
            TText(
              'Ungrouped',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: tokens.textPrimary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: luxMonoStyle(fontSize: 10.5, color: tokens.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupBody(
    LuxTokens tokens,
    String groupId,
    List<CustomizedRuleItem> rules, {
    required bool groupEnabled,
  }) {
    if (rules.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 12, 10),
        child: TText(
          'No rules in this group',
          style: TextStyle(fontSize: 11, color: tokens.textMuted),
        ),
      );
    }

    final canReorder = _search.isEmpty;

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: rules.length,
      onReorder: (o, n) => canReorder ? _reorder(groupId, o, n) : null,
      itemBuilder: (ctx, i) =>
          _ruleRow(tokens, rules[i], groupEnabled: groupEnabled, index: i),
    );
  }

  static const double _actionsWidth = 100;

  Widget _rowAction({
    required Widget icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: icon,
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

  Widget _ruleRow(
    LuxTokens tokens,
    CustomizedRuleItem rule, {
    required bool groupEnabled,
    required int index,
  }) {
    final key = ValueKey(rule.id);
    final busy = _busy.contains(rule.id);
    final shadow = _shadows[rule.id];
    final inactive = rule.disabled || !groupEnabled || rule.isBroken;
    final canDrag = _search.isEmpty;
    final pColor = _policyColor(context, rule.policy);

    return Container(
      key: key,
      height: 38,
      decoration: BoxDecoration(
        color: inactive ? tokens.subtlePillBg.withValues(alpha: 0.45) : null,
        border: Border(
          bottom: BorderSide(color: tokens.hairline, width: 0.75),
        ),
      ),
      child: Row(
        children: [
          if (canDrag)
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Icon(Icons.drag_indicator,
                    size: 14, color: tokens.textMuted),
              ),
            )
          else
            const SizedBox(width: 24),
          Container(
            width: 5.5,
            height: 5.5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: rule.isBroken
                  ? tokens.danger
                  : inactive
                      ? tokens.textMuted.withValues(alpha: 0.4)
                      : tokens.cobalt,
            ),
          ),
          const SizedBox(width: 7),
          SizedBox(
            width: 108,
            child: Text(
              rule.ruleType,
              style: luxMonoStyle(
                fontSize: 10.5,
                color: inactive ? tokens.textMuted : tokens.textSecondary,
              ).copyWith(
                decoration:
                    rule.disabled ? TextDecoration.lineThrough : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Tooltip(
              message: rule.slug.isEmpty ? rule.payload : rule.slug,
              child: Text(
                rule.ruleType == 'DNS-MAP' && rule.payload.contains(';')
                    ? '${rule.payload.split(';')[0]} → ${rule.payload.split(';')[1]}'
                    : rule.payload,
                style: luxMonoStyle(
                  fontSize: 11,
                  color: inactive ? Colors.grey : tokens.textPrimary,
                ).copyWith(
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
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: tokens.subtlePillBg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: tokens.hairline, width: 0.5),
              ),
              child: Text(
                rule.network.toUpperCase(),
                style: luxMonoStyle(fontSize: 9, color: tokens.textSecondary),
              ),
            ),
          if (rule.isBroken)
            Tooltip(
              message: rule.broken,
              child: Padding(
                padding: const EdgeInsets.only(right: 5),
                child: LuxIcon(LuxGlyph.alertCircle,
                    size: 13.5, color: tokens.danger),
              ),
            ),
          if (shadow != null)
            Tooltip(
              message: 'Never matches: ${shadow.reason}. '
                  'Shadowed by ${shadow.shadowedBySlug}.',
              child: Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(Icons.visibility_off_outlined,
                    size: 14, color: tokens.amber),
              ),
            ),
          SizedBox(
            width: 94,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: (inactive ? tokens.textMuted : pColor)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  rule.policy,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    color: inactive ? tokens.textMuted : pColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          if (busy)
            SizedBox(
              width: _actionsWidth,
              child: Center(
                child: SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: tokens.cobalt),
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
                    icon: Icon(
                      rule.disabled
                          ? Icons.toggle_off_outlined
                          : Icons.toggle_on,
                      size: 18,
                      color:
                          rule.disabled ? tokens.textMuted : tokens.cobalt,
                    ),
                    tooltip: rule.disabled
                        ? tl(context, 'Enable')
                        : tl(context, 'Disable'),
                    onPressed: () => _toggle(rule),
                  ),
                  _rowAction(
                    icon: LuxIcon(LuxGlyph.edit,
                        size: 13, color: tokens.textSecondary),
                    tooltip: tl(context, 'Edit'),
                    onPressed: () => _showAddEdit(item: rule),
                  ),
                  _rowAction(
                    icon: LuxIcon(LuxGlyph.trash,
                        size: 13, color: tokens.textSecondary),
                    tooltip: tl(context, 'Delete'),
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
        title: const TText('Delete rule'),
        content: Text('${rule.ruleType},${rule.payload} -> ${rule.policy}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const TText('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const TText('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await _delete(rule);
  }
}
