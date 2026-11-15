import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/util/t_text.dart';

/// Modal dialog that inspects active PAC (Proxy Auto-Config) rules, displays
/// resolved upstreams, allows testing arbitrary URLs against the PAC evaluator,
/// and lets users inspect or copy the raw JavaScript source.
class PacRulesDialog extends StatefulWidget {
  final CoreManager coreManager;
  final String proxyId;
  final String proxyName;
  final String? initialPacUrl;

  const PacRulesDialog({
    super.key,
    required this.coreManager,
    required this.proxyId,
    required this.proxyName,
    this.initialPacUrl,
  });

  /// Opens the PAC Rules dialog.
  static Future<void> show({
    required BuildContext context,
    required CoreManager coreManager,
    required String proxyId,
    required String proxyName,
    String? initialPacUrl,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => PacRulesDialog(
        coreManager: coreManager,
        proxyId: proxyId,
        proxyName: proxyName,
        initialPacUrl: initialPacUrl,
      ),
    );
  }

  @override
  State<PacRulesDialog> createState() => _PacRulesDialogState();
}

enum _PacTab { rules, tester, rawScript }

class _PacRulesDialogState extends State<PacRulesDialog> {
  _PacTab _currentTab = _PacTab.rules;
  bool _isLoading = true;
  String? _errorMessage;

  String _pacUrl = '';
  String _rawScript = '';
  String _upstream = '';
  List<PACRuleItem> _rules = [];

  // Filter & Search
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchFilter = '';
  String _policyFilter = 'ALL'; // ALL, DIRECT, PROXY

  // URL Tester
  final TextEditingController _testUrlCtrl = TextEditingController();
  bool _isTesting = false;
  PACTestResult? _testResult;
  String? _testError;

  @override
  void initState() {
    super.initState();
    _pacUrl = widget.initialPacUrl ?? '';
    _loadPacRules();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _testUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPacRules() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await widget.coreManager.getPACRules(widget.proxyId);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _pacUrl = res.pacUrl.isNotEmpty ? res.pacUrl : _pacUrl;
        _rawScript = res.rawScript;
        _upstream = res.upstream;
        _rules = res.rules;
        _errorMessage = res.error;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _executeTestUrl([String? explicitUrl]) async {
    final target = (explicitUrl ?? _testUrlCtrl.text).trim();
    if (target.isEmpty) return;

    if (explicitUrl != null) {
      _testUrlCtrl.text = explicitUrl;
    }

    setState(() {
      _isTesting = true;
      _testError = null;
    });

    try {
      final result = await widget.coreManager.testPACUrl(widget.proxyId, target);
      if (!mounted) return;
      setState(() {
        _isTesting = false;
        _testResult = result;
        _testError = result.error;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isTesting = false;
        _testError = e.toString();
      });
    }
  }

  List<PACRuleItem> get _filteredRules {
    return _rules.where((r) {
      if (_policyFilter != 'ALL' &&
          r.policy.toUpperCase() != _policyFilter.toUpperCase()) {
        return false;
      }
      if (_searchFilter.isNotEmpty) {
        final q = _searchFilter.toLowerCase();
        final matchPayload = r.payload.toLowerCase().contains(q);
        final matchType = r.ruleType.toLowerCase().contains(q);
        final matchFunc = (r.function ?? '').toLowerCase().contains(q);
        final matchPolicy = r.policy.toLowerCase().contains(q);
        if (!matchPayload && !matchType && !matchFunc && !matchPolicy) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  void _copyToClipboard(String text, String successMsg) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(successMsg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 550,
          maxWidth: 680,
          minHeight: 480,
          maxHeight: 640,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ──
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: cs.primary.withAlpha(24),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.alt_route, color: cs.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tl(context, 'Active PAC Rules'),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          widget.proxyName,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.outline,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: _isLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 20),
                    tooltip: tl(context, 'Refresh PAC'),
                    onPressed: _isLoading ? null : _loadPacRules,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // ── Info Bar (PAC URL + Resolved Upstream) ──
              _buildInfoBar(context),
              const SizedBox(height: 14),

              // ── Tabs Navigation ──
              SegmentedButton<_PacTab>(
                segments: [
                  ButtonSegment<_PacTab>(
                    value: _PacTab.rules,
                    icon: const Icon(Icons.table_rows_outlined, size: 16),
                    label: Text(
                      _rules.isNotEmpty
                          ? '${tl(context, 'Rules')} (${_rules.length})'
                          : tl(context, 'Rules'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  ButtonSegment<_PacTab>(
                    value: _PacTab.tester,
                    icon: const Icon(Icons.play_arrow_outlined, size: 16),
                    label: Text(
                      tl(context, 'Test URL'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  ButtonSegment<_PacTab>(
                    value: _PacTab.rawScript,
                    icon: const Icon(Icons.code_outlined, size: 16),
                    label: Text(
                      tl(context, 'Raw Script'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
                selected: {_currentTab},
                onSelectionChanged: (val) {
                  setState(() => _currentTab = val.first);
                },
              ),
              const SizedBox(height: 12),

              // ── Tab Body ──
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : _errorMessage != null && _rules.isEmpty && _rawScript.isEmpty
                        ? _buildErrorView(context)
                        : _buildTabContent(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'PAC: ',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: cs.outline,
                ),
              ),
              Expanded(
                child: SelectableText(
                  _pacUrl.isNotEmpty ? _pacUrl : tl(context, '(None configured)'),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant,
                  ),
                  maxLines: 1,
                ),
              ),
              if (_pacUrl.isNotEmpty) ...[
                const SizedBox(width: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => _copyToClipboard(
                      _pacUrl, tl(context, 'PAC URL copied to clipboard')),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.copy, size: 14),
                  ),
                ),
              ],
            ],
          ),
          if (_upstream.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  tl(context, 'Resolved Upstream: '),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    color: cs.outline,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: _upstream.toUpperCase().contains('DIRECT')
                        ? Colors.green.withAlpha(30)
                        : cs.primary.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _upstream,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _upstream.toUpperCase().contains('DIRECT')
                          ? Colors.green
                          : cs.primary,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTabContent(BuildContext context) {
    switch (_currentTab) {
      case _PacTab.rules:
        return _buildRulesTab(context);
      case _PacTab.tester:
        return _buildTesterTab(context);
      case _PacTab.rawScript:
        return _buildRawScriptTab(context);
    }
  }

  Widget _buildRulesTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtered = _filteredRules;

    return Column(
      children: [
        // Filter bar
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 34,
                child: TextField(
                  controller: _searchCtrl,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: tl(context, 'Search rules by pattern or type...'),
                    hintStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.search, size: 16),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 14),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchFilter = '');
                            },
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: cs.outlineVariant),
                    ),
                    isDense: true,
                  ),
                  onChanged: (val) {
                    setState(() => _searchFilter = val.trim());
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Policy filter chips
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              segments: const [
                ButtonSegment(
                  value: 'ALL',
                  label: Text('All', style: TextStyle(fontSize: 11)),
                ),
                ButtonSegment(
                  value: 'DIRECT',
                  label: Text('DIRECT', style: TextStyle(fontSize: 11)),
                ),
                ButtonSegment(
                  value: 'PROXY',
                  label: Text('PROXY', style: TextStyle(fontSize: 11)),
                ),
              ],
              selected: {_policyFilter},
              onSelectionChanged: (val) {
                setState(() => _policyFilter = val.first);
              },
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Rules list/table
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.rule_folder_outlined,
                          size: 36, color: cs.outline.withAlpha(120)),
                      const SizedBox(height: 8),
                      Text(
                        _rules.isEmpty
                            ? tl(context, 'No static rules extracted from PAC')
                            : tl(context, 'No rules match filter'),
                        style: TextStyle(fontSize: 12.5, color: cs.outline),
                      ),
                      if (_rules.isEmpty && _rawScript.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          tl(context,
                              'You can test URLs or view the full script in the other tabs.'),
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (ctx, i) => Divider(
                        height: 1,
                        thickness: 1,
                        color: cs.outlineVariant.withAlpha(40),
                      ),
                      itemBuilder: (ctx, i) {
                        final rule = filtered[i];
                        final isDirect = rule.policy.toUpperCase() == 'DIRECT';
                        final badgeColor =
                            isDirect ? Colors.green : cs.primary;

                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          child: Row(
                            children: [
                              // Policy Badge
                              Container(
                                width: 58,
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                decoration: BoxDecoration(
                                  color: badgeColor.withAlpha(24),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: badgeColor.withAlpha(80)),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  rule.policy,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: badgeColor,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              // Payload / Domain
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SelectableText(
                                      rule.payload,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                    if ((rule.function ?? '').isNotEmpty) ...[
                                      const SizedBox(height: 1),
                                      Text(
                                        '${rule.function}(...)',
                                        style: TextStyle(
                                          fontSize: 9.5,
                                          color: cs.outline,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              // Rule Type Chip
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: cs.secondaryContainer.withAlpha(120),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  rule.ruleType,
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    color: cs.onSecondaryContainer,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.copy, size: 14),
                                tooltip: tl(context, 'Copy pattern'),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 24, minHeight: 24),
                                onPressed: () => _copyToClipboard(
                                  rule.payload,
                                  tl(context, 'Pattern copied'),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildTesterTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tl(context,
                'Test any URL, domain, or IP to see how this PAC evaluates it:'),
            style: TextStyle(fontSize: 12, color: cs.outline),
          ),
          const SizedBox(height: 10),

          // Input + Test Button
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _testUrlCtrl,
                    style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: tl(context, 'e.g. google.com or intranet.local'),
                      hintStyle:
                          const TextStyle(fontSize: 12, fontFamily: 'sans-serif'),
                      prefixIcon: const Icon(Icons.link, size: 18),
                      suffixIcon: _testUrlCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 16),
                              onPressed: () {
                                _testUrlCtrl.clear();
                                setState(() {
                                  _testResult = null;
                                  _testError = null;
                                });
                              },
                            )
                          : null,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _executeTestUrl(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: _isTesting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.play_arrow, size: 16),
                label: Text(tl(context, 'Resolve')),
                onPressed: _isTesting ? null : () => _executeTestUrl(),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Quick Pills
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${tl(context, 'Try')}:',
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
              _buildQuickPill('google.com'),
              _buildQuickPill('intranet.local'),
              _buildQuickPill('internal.corp'),
              _buildQuickPill('10.0.0.1'),
              _buildQuickPill('127.0.0.1'),
            ],
          ),
          const SizedBox(height: 16),

          // Result Card
          if (_testError != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.error.withAlpha(20),
                border: Border.all(color: cs.error.withAlpha(80)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _testError!,
                      style: TextStyle(fontSize: 12, color: cs.error),
                    ),
                  ),
                ],
              ),
            ),
          ] else if (_testResult != null) ...[
            _buildResultCard(context, _testResult!),
          ],
        ],
      ),
    );
  }

  Widget _buildQuickPill(String domain) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _executeTestUrl(domain),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          domain,
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
        ),
      ),
    );
  }

  Widget _buildResultCard(BuildContext context, PACTestResult res) {
    final cs = Theme.of(context).colorScheme;
    final isDirect = res.action.toUpperCase() == 'DIRECT';
    final resultColor = isDirect ? Colors.green : cs.primary;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: resultColor.withAlpha(16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: resultColor.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isDirect ? Icons.check_circle_outline : Icons.alt_route,
                color: resultColor,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                '${tl(context, 'Result')}: ',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: resultColor.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  res.action,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: resultColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (res.upstream.isNotEmpty) ...[
            Row(
              children: [
                Text(
                  '${tl(context, 'Selected Upstream')}: ',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.outline,
                  ),
                ),
                SelectableText(
                  res.upstream,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${tl(context, 'Directive')}: ',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.outline,
                ),
              ),
              Expanded(
                child: SelectableText(
                  res.directive.isNotEmpty
                      ? res.directive
                      : tl(context, 'DIRECT'),
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRawScriptTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_rawScript.isEmpty) {
      return Center(
        child: Text(
          tl(context, 'No JavaScript script found or downloaded yet.'),
          style: TextStyle(fontSize: 12, color: cs.outline),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              tl(context, 'JavaScript Source (FindProxyForURL)'),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: cs.outline,
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 14),
              label: Text(tl(context, 'Copy Script'),
                  style: const TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () => _copyToClipboard(
                _rawScript,
                tl(context, 'PAC Script copied to clipboard'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(40),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.outlineVariant.withAlpha(60)),
            ),
            child: SelectableText(
              _rawScript,
              style: const TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorView(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 36, color: cs.error),
            const SizedBox(height: 10),
            Text(
              tl(context, 'Failed to fetch or evaluate PAC script'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: cs.error,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _errorMessage ?? '',
              style: TextStyle(fontSize: 11, color: cs.outline),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(tl(context, 'Retry')),
              onPressed: _loadPacRules,
            ),
          ],
        ),
      ),
    );
  }
}
