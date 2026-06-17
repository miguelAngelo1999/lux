import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lux/core/core_manager.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class ConnectionEntry {
  final String id;
  final String network;
  final String host;
  final String rule;
  final String process;
  final int upload;
  final int download;
  final bool inspected;
  final String? fullUrl;

  ConnectionEntry({
    required this.id,
    required this.network,
    required this.host,
    required this.rule,
    required this.process,
    required this.upload,
    required this.download,
    this.inspected = false,
    this.fullUrl,
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
    return ConnectionEntry(
      id: (j['id'] as String? ?? '').toString(),
      network: meta['network'] as String? ?? '',
      host: host,
      rule: '${rule['ruleType'] ?? rule['type'] ?? ''} ${rule['payload'] ?? ''}'.trim(),
      process: (meta['processPath'] as String? ?? '').split('/').last,
      upload: (j['upload'] as num? ?? 0).toInt(),
      download: (j['download'] as num? ?? 0).toInt(),
      inspected: j['inspected'] as bool? ?? false,
      fullUrl: j['fullUrl'] as String?,
    );
  }
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
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _connect();
    _searchCtrl.addListener(() => setState(() => _search = _searchCtrl.text.toLowerCase()));
  }

  Future<void> _connect() async {
    try {
      final channel = await widget.coreManager.getConnectionsChannel();
      if (!mounted) return;
      // web_socket_channel 3.x requires awaiting ready before listening
      await channel.ready;
      if (!mounted) return;
      setState(() => _channel = channel);
      channel.stream.listen(
        (raw) {
          try {
            // WebSocket frames may arrive as String or binary Uint8List
            final String text;
            if (raw is Uint8List) {
              text = utf8.decode(raw);
            } else {
              text = raw as String;
            }
            final data = json.decode(text);
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
                _conns..clear()..addAll(conns);
              });
            }
          } catch (_) {}
        },
        onError: (e) {
          debugPrint('Connections WS error: $e');
          Future.delayed(const Duration(seconds: 3), () { if (mounted) _connect(); });
        },
        onDone: () {
          Future.delayed(const Duration(seconds: 3), () { if (mounted) _connect(); });
        },
      );
    } catch (e) {
      debugPrint('Connections connect error: $e');
      Future.delayed(const Duration(seconds: 3), () { if (mounted) _connect(); });
    }
  }

  List<ConnectionEntry> get _filtered {
    if (_search.isEmpty) return _conns;
    return _conns.where((c) =>
        c.host.toLowerCase().contains(_search) ||
        (c.fullUrl?.toLowerCase().contains(_search) ?? false) ||
        c.rule.toLowerCase().contains(_search) ||
        c.process.toLowerCase().contains(_search)
    ).toList();
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}M';
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Search connections...',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 16),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Text('${filtered.length} connections',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Close all connections',
                icon: const Icon(Icons.close_fullscreen, size: 18),
                onPressed: () => widget.coreManager.closeAllConnections(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Theme.of(context).colorScheme.surfaceVariant,
          child: const Row(
            children: [
              SizedBox(width: 60, child: Text('Net', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(flex: 3, child: Text('Host', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(flex: 2, child: Text('Rule', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(flex: 2, child: Text('Process', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
              SizedBox(width: 70, child: Text('↑↓', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: filtered.isEmpty
              ? const Center(
                  child: Text('No active connections',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemExtent: 32,
                  itemBuilder: (ctx, i) {
                    final c = filtered[i];
                    return Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                              color: Theme.of(ctx).dividerColor, width: 0.5),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 60,
                            child: Text(c.network.toUpperCase(),
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey)),
                          ),
                          Expanded(
                            flex: 3,
                            child: Row(
                              children: [
                                if (c.inspected)
                                  Tooltip(
                                    message: 'TLS inspected',
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 3),
                                      child: Icon(Icons.security_outlined, size: 11, color: Colors.blue),
                                    ),
                                  ),
                                Expanded(
                                  child: Text(
                                    c.inspected && c.fullUrl != null ? c.fullUrl! : c.host,
                                    style: const TextStyle(fontSize: 11),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(c.rule,
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.blue),
                                overflow: TextOverflow.ellipsis),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                                c.process.isEmpty
                                    ? '-'
                                    : c.process.split('/').last,
                                style: const TextStyle(fontSize: 11),
                                overflow: TextOverflow.ellipsis),
                          ),
                          SizedBox(
                            width: 70,
                            child: Text(
                                '↑${_fmt(c.upload)} ↓${_fmt(c.download)}',
                                style: const TextStyle(fontSize: 10)),
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
