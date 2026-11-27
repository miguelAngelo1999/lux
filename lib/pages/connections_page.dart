import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/widget/lux_icons.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class ConnectionEntry {
  final String id;
  final String network;
  final String host;
  final String rule;
  final String process;
  final int upload;
  final int download;

  ConnectionEntry({
    required this.id,
    required this.network,
    required this.host,
    required this.rule,
    required this.process,
    required this.upload,
    required this.download,
  });

  factory ConnectionEntry.fromJson(Map<String, dynamic> j) {
    final meta = j['metadata'] as Map<String, dynamic>? ?? {};
    final domain = j['domain'] as String? ?? '';
    final host = domain.isNotEmpty
        ? domain
        : (meta['host'] as String? ?? '').isNotEmpty
            ? '${meta['host']}:${meta['destinationPort'] ?? ''}'
            : '${meta['destinationIP'] ?? ''}:${meta['destinationPort'] ?? ''}';
    final rule = j['rule'] as Map<String, dynamic>? ?? {};
    final rawProcess = meta['processPath'] as String? ?? '';
    final processName =
        rawProcess.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).lastOrNull ?? '';
    return ConnectionEntry(
      id: (j['id'] as String? ?? '').toString(),
      network: meta['network'] as String? ?? '',
      host: host,
      rule: '${rule['ruleType'] ?? rule['type'] ?? ''} ${rule['payload'] ?? ''}'
          .trim(),
      process: processName,
      upload: (j['upload'] as num? ?? 0).toInt(),
      download: (j['download'] as num? ?? 0).toInt(),
    );
  }

  /// Extracts a clean hostname/IP without trailing `:port` for 1-click rules.
  String get cleanHost {
    final h = host.trim();
    if (h.startsWith('[')) {
      final end = h.indexOf(']');
      return end > 1 ? h.substring(1, end) : h;
    }
    final colon = h.lastIndexOf(':');
    if (colon > 0 && int.tryParse(h.substring(colon + 1)) != null) {
      return h.substring(0, colon);
    }
    return h;
  }

  bool get isIpHost =>
      RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(cleanHost);
}

class ConnectionsPage extends StatefulWidget {
  final CoreManager coreManager;
  const ConnectionsPage({super.key, required this.coreManager});

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  final List<ConnectionEntry> _conns = [];
  WebSocketChannel? _channel;
  final _searchCtrl = TextEditingController();
  String _search = '';

  Timer? _retry;
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    _connect();
    _searchCtrl.addListener(
        () => setState(() => _search = _searchCtrl.text.toLowerCase()));
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), () {
      if (mounted) _connect();
    });
  }

  Future<void> _connect() async {
    try {
      final channel = await widget.coreManager.getConnectionsChannel();
      await channel.ready;
      if (!mounted) {
        await channel.sink.close();
        return;
      }
      setState(() => _channel = channel);
      await _sub?.cancel();
      _sub = channel.stream.listen(
        (raw) {
          try {
            final data = json.decode(raw as String);
            List<dynamic> connList;
            if (data is List) {
              connList = data;
            } else if (data is Map) {
              connList = data['connections'] as List? ?? [];
            } else {
              return;
            }
            final conns = connList
                .map((e) => ConnectionEntry.fromJson(e as Map<String, dynamic>))
                .toList();
            if (mounted) {
              setState(() {
                _conns
                  ..clear()
                  ..addAll(conns);
              });
            }
          } catch (_) {}
        },
        onError: (e) {
          debugPrint('Connections WS error: $e');
          if (mounted) _scheduleRetry();
        },
        onDone: () {
          if (mounted) _scheduleRetry();
        },
      );
    } catch (e) {
      debugPrint('Connections connect error: $e');
      if (mounted) _scheduleRetry();
    }
  }

  List<ConnectionEntry> get _filtered {
    if (_search.isEmpty) return _conns;
    return _conns
        .where((c) =>
            c.host.toLowerCase().contains(_search) ||
            c.rule.toLowerCase().contains(_search) ||
            c.process.toLowerCase().contains(_search))
        .toList();
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}M';
  }

  Future<void> _createQuickRule(
      ConnectionEntry c, String targetKind, String policy) async {
    String ruleRaw;
    String label;
    if (targetKind == 'process' && c.process.isNotEmpty) {
      ruleRaw = 'PROCESS,${c.process},$policy';
      label = '${c.process} → $policy';
    } else {
      final host = c.cleanHost;
      if (host.isEmpty) return;
      final type = c.isIpHost ? 'IP-CIDR' : 'DOMAIN-SUFFIX';
      final payload = c.isIpHost ? '$host/32' : host;
      ruleRaw = '$type,$payload,$policy';
      label = '$payload → $policy';
    }
    try {
      await widget.coreManager.addCustomizedRules([ruleRaw]);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${tl(context, 'Rule added')}: $label'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not add rule: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final filtered = _filtered;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _searchCtrl,
                    style: TextStyle(fontSize: 12, color: tokens.textPrimary),
                    decoration: InputDecoration(
                      hintText: tl(context, 'Search connections...'),
                      hintStyle:
                          TextStyle(fontSize: 12, color: tokens.textMuted),
                      isDense: true,
                      filled: true,
                      fillColor: tokens.cardBg,
                      prefixIcon: Padding(
                        padding: const EdgeInsets.only(left: 10, right: 6),
                        child: LuxIcon(LuxGlyph.search,
                            size: 13.5, color: tokens.textMuted),
                      ),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 30, minHeight: 30),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
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
                          : IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 28, minHeight: 28),
                              icon: LuxIcon(LuxGlyph.close,
                                  size: 12, color: tokens.textMuted),
                              onPressed: () => _searchCtrl.clear(),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: tokens.subtlePillBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: tokens.hairline, width: 0.75),
                ),
                child: Text(
                  _search.isEmpty
                      ? '${_conns.length} connections'
                      : '${filtered.length} of ${_conns.length}',
                  style: luxMonoStyle(
                      fontSize: 10.5, color: tokens.textSecondary),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: tl(context, 'Close all connections'),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => widget.coreManager.closeAllConnections(),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: tokens.cardBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: tokens.hairlineStrong, width: 0.75),
                      ),
                      child: Center(
                        child: LuxIcon(LuxGlyph.xCircle,
                            size: 14, color: tokens.textSecondary),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Material(
              color: tokens.cardBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
                side: BorderSide(color: tokens.hairline, width: 0.75),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                    // Table header
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      color: tokens.subtlePillBg,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: TText(
                              'Net',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                                color: tokens.textMuted,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: TText(
                              'Host',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                                color: tokens.textMuted,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: TText(
                              'Rule',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                                color: tokens.textMuted,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: TText(
                              'Process',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                                color: tokens.textMuted,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 82,
                            child: Text(
                              '↑↓',
                              style: luxMonoStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                                color: tokens.textMuted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 28),
                        ],
                      ),
                    ),
                    Container(height: 0.75, color: tokens.hairline),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: TText(
                                'No active connections',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: tokens.textMuted,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemExtent: 34,
                              itemBuilder: (ctx, i) {
                                final c = filtered[i];
                                return Container(
                                  decoration: BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(
                                        color: tokens.hairline,
                                        width: 0.5,
                                      ),
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 48,
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 5, vertical: 1.5),
                                            decoration: BoxDecoration(
                                              color: tokens.subtlePillBg,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              c.network.toUpperCase(),
                                              style: luxMonoStyle(
                                                fontSize: 9.5,
                                                color: tokens.textSecondary,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 3,
                                        child: Tooltip(
                                          message: c.host,
                                          child: Text(
                                            c.host,
                                            style: luxMonoStyle(
                                              fontSize: 11,
                                              color: tokens.textPrimary,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 2,
                                        child: Text(
                                          c.rule,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: tokens.cobalt,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Expanded(
                                        flex: 2,
                                        child: Text(
                                          c.process.isEmpty ? '-' : c.process,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: tokens.textSecondary,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      SizedBox(
                                        width: 82,
                                        child: Text(
                                          '↑${_fmt(c.upload)} ↓${_fmt(c.download)}',
                                          style: luxMonoStyle(
                                            fontSize: 10,
                                            color: tokens.textMuted,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      // 1-click "+ Rule" creation straight from any connection
                                      SizedBox(
                                        width: 28,
                                        child: Tooltip(
                                          message:
                                              tl(context, 'Create rule from connection'),
                                          child: PopupMenuButton<(String, String)>(
                                            tooltip: '',
                                            padding: EdgeInsets.zero,
                                            onSelected: (pair) =>
                                                _createQuickRule(
                                                    c, pair.$1, pair.$2),
                                            itemBuilder: (ctx) => [
                                              if (c.cleanHost.isNotEmpty) ...[
                                                PopupMenuItem(
                                                  value: ('host', 'DIRECT'),
                                                  height: 34,
                                                  child: Text(
                                                    'Always Direct · ${c.cleanHost}',
                                                    style: TextStyle(
                                                        fontSize: 11.5,
                                                        color: tokens.emerald),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                PopupMenuItem(
                                                  value: ('host', 'PROXY'),
                                                  height: 34,
                                                  child: Text(
                                                    'Always Proxy · ${c.cleanHost}',
                                                    style: TextStyle(
                                                        fontSize: 11.5,
                                                        color: tokens.cobalt),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                PopupMenuItem(
                                                  value: ('host', 'REJECT'),
                                                  height: 34,
                                                  child: Text(
                                                    'Reject · ${c.cleanHost}',
                                                    style: TextStyle(
                                                        fontSize: 11.5,
                                                        color: tokens.danger),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                              if (c.process.isNotEmpty) ...[
                                                const PopupMenuDivider(height: 6),
                                                PopupMenuItem(
                                                  value: ('process', 'DIRECT'),
                                                  height: 34,
                                                  child: Text(
                                                    'Always Direct app · ${c.process}',
                                                    style: TextStyle(
                                                        fontSize: 11.5,
                                                        color: tokens.emerald),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                PopupMenuItem(
                                                  value: ('process', 'PROXY'),
                                                  height: 34,
                                                  child: Text(
                                                    'Always Proxy app · ${c.process}',
                                                    style: TextStyle(
                                                        fontSize: 11.5,
                                                        color: tokens.cobalt),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ],
                                            child: Center(
                                              child: LuxIcon(
                                                LuxGlyph.plus,
                                                size: 12.5,
                                                color: tokens.textMuted,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
            ),
          ),
        ),
      ],
    );
  }
}
