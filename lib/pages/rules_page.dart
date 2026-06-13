import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:window_manager/window_manager.dart';

class RulesPage extends StatefulWidget {
  final CoreManager coreManager;
  const RulesPage({super.key, required this.coreManager});

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> with WindowListener {
  List<CustomizedRuleItem> _rules = [];
  bool _isLoading = true;
  String _search = '';
  final _searchCtrl = TextEditingController();

  // Proxy names for policy dropdown
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
    _searchCtrl.addListener(() => setState(() => _search = _searchCtrl.text.toLowerCase()));
  }

  @override
  void onWindowFocus() => _load();

  @override
  void dispose() {
    windowManager.removeListener(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rules = await widget.coreManager.getCustomizedRules();
      final proxyList = await widget.coreManager.getProxyList();
      if (mounted) {
        setState(() {
          _rules = rules;
          _proxyNames = [
            'DIRECT',
            'PROXY',
            'REJECT',
            ...proxyList.proxies.map((p) => p.name).where((n) => n.isNotEmpty),
          ];
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<CustomizedRuleItem> get _filtered {
    if (_search.isEmpty) return _rules;
    return _rules.where((r) =>
        r.ruleType.toLowerCase().contains(_search) ||
        r.payload.toLowerCase().contains(_search) ||
        r.policy.toLowerCase().contains(_search)).toList();
  }

  Future<void> _toggle(CustomizedRuleItem item) async {
    // Optimistic update
    setState(() {
      final idx = _rules.indexOf(item);
      if (idx >= 0) {
        _rules[idx] = item.copyWith(
          disabled: !item.disabled,
          raw: item.disabled ? item.toRawString() : '#${item.toRawString()}',
        );
      }
    });
    try {
      await widget.coreManager.toggleCustomizedRule(item.raw);
    } catch (_) {
      _load(); // rollback on error
    }
  }

  Future<void> _delete(CustomizedRuleItem item) async {
    // Optimistic update
    setState(() => _rules.remove(item));
    try {
      await widget.coreManager.deleteCustomizedRules([item.raw]);
    } catch (_) {
      _load();
    }
  }

  Future<void> _moveUp(int filteredIdx) async {
    final item = _filtered[filteredIdx];
    final fullIdx = _rules.indexOf(item);
    if (fullIdx <= 0) return;
    setState(() {
      _rules.removeAt(fullIdx);
      _rules.insert(fullIdx - 1, item);
    });
    await widget.coreManager.reorderCustomizedRules(
        _rules.map((r) => r.raw).toList());
  }

  Future<void> _moveDown(int filteredIdx) async {
    final item = _filtered[filteredIdx];
    final fullIdx = _rules.indexOf(item);
    if (fullIdx >= _rules.length - 1) return;
    setState(() {
      _rules.removeAt(fullIdx);
      _rules.insert(fullIdx + 1, item);
    });
    await widget.coreManager.reorderCustomizedRules(
        _rules.map((r) => r.raw).toList());
  }

  Future<void> _showAddEdit({CustomizedRuleItem? item}) async {
    String ruleType = item?.ruleType ?? 'DOMAIN';
    String payload = item?.payload ?? '';
    String policy = item?.policy ?? 'PROXY';

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(item == null ? 'Add Rule' : 'Edit Rule'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: ruleType,
                  decoration: const InputDecoration(
                      labelText: 'Type', isDense: true),
                  items: _ruleTypes
                      .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                      .toList(),
                  onChanged: (v) => setDialogState(() => ruleType = v!),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: payload,
                  decoration: InputDecoration(
                    labelText: 'Payload',
                    hintText: ruleType == 'IP-CIDR'
                        ? '192.168.0.0/24'
                        : ruleType == 'PROCESS'
                            ? 'App.app'
                            : 'example.com',
                    isDense: true,
                  ),
                  onChanged: (v) => payload = v,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _proxyNames.contains(policy) ? policy : _proxyNames.first,
                  decoration: const InputDecoration(
                      labelText: 'Policy', isDense: true),
                  items: [
                    // Include current policy even if not in list
                    if (!_proxyNames.contains(policy))
                      DropdownMenuItem(value: policy, child: Text(policy)),
                    ..._proxyNames.map((p) =>
                        DropdownMenuItem(value: p, child: Text(p))),
                  ],
                  onChanged: (v) => setDialogState(() => policy = v!),
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

    if (result != true || payload.isEmpty) return;

    final newRaw = '$ruleType,$payload,$policy';
    if (item == null) {
      setState(() => _rules.insert(0, CustomizedRuleItem(
            ruleType: ruleType,
            payload: payload,
            policy: policy,
            disabled: false,
            raw: newRaw,
          )));
      try {
        await widget.coreManager.addCustomizedRules([newRaw]);
      } catch (_) {
        _load();
      }
    } else {
      setState(() {
        final idx = _rules.indexOf(item);
        if (idx >= 0) {
          _rules[idx] = CustomizedRuleItem(
            ruleType: ruleType,
            payload: payload,
            policy: policy,
            disabled: false,
            raw: newRaw,
          );
        }
      });
      try {
        await widget.coreManager.editCustomizedRule(item.raw, newRaw);
      } catch (_) {
        _load();
      }
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
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    final filtered = _filtered;

    return Column(
      children: [
        // Toolbar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Search rules...',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 16),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Text('${filtered.length} rules',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _showAddEdit(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Rule', style: TextStyle(fontSize: 12)),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Row(
            children: [
              SizedBox(width: 32),
              SizedBox(width: 100, child: Text('Type', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(child: Text('Payload', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
              SizedBox(width: 80, child: Text('Policy', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
              SizedBox(width: 96),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('No customized rules',
                          style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: () => _showAddEdit(),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add first rule'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemExtent: 36,
                  itemBuilder: (ctx, i) {
                    final rule = filtered[i];
                    final isDisabled = rule.disabled;
                    return Container(
                      decoration: BoxDecoration(
                        color: isDisabled
                            ? Theme.of(ctx).colorScheme.surface.withAlpha(128)
                            : null,
                        border: Border(
                          bottom: BorderSide(
                              color: Theme.of(ctx).dividerColor, width: 0.5),
                        ),
                      ),
                      child: Row(
                        children: [
                          // Enabled toggle
                          SizedBox(
                            width: 32,
                            child: Checkbox(
                              value: !isDisabled,
                              onChanged: (_) => _toggle(rule),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          // Type
                          SizedBox(
                            width: 100,
                            child: Text(
                              rule.ruleType,
                              style: TextStyle(
                                fontSize: 12,
                                color: isDisabled ? Colors.grey : null,
                                decoration: isDisabled ? TextDecoration.lineThrough : null,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // Payload
                          Expanded(
                            child: Text(
                              rule.payload,
                              style: TextStyle(
                                fontSize: 12,
                                color: isDisabled ? Colors.grey : null,
                                decoration: isDisabled ? TextDecoration.lineThrough : null,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // Policy badge
                          SizedBox(
                            width: 80,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: _policyColor(rule.policy).withAlpha(30),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                rule.policy,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _policyColor(rule.policy),
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          // Actions
                          SizedBox(
                            width: 96,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.arrow_upward, size: 14),
                                  onPressed: i > 0 ? () => _moveUp(i) : null,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                  tooltip: 'Move up',
                                ),
                                IconButton(
                                  icon: const Icon(Icons.arrow_downward, size: 14),
                                  onPressed: i < filtered.length - 1 ? () => _moveDown(i) : null,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                  tooltip: 'Move down',
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit, size: 14),
                                  onPressed: () => _showAddEdit(item: rule),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                  tooltip: 'Edit',
                                ),
                                IconButton(
                                  icon: Icon(Icons.delete_outline, size: 14,
                                      color: Theme.of(ctx).colorScheme.error),
                                  onPressed: () => _delete(rule),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                  tooltip: 'Delete',
                                ),
                              ],
                            ),
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
}
