import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lux/core/core_manager.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class LogEntry {
  final String level;
  final String time;
  final String message;
  LogEntry({required this.level, required this.time, required this.message});

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      level: json['level'] as String? ?? 'info',
      time: json['time'] as String? ?? '',
      message: json['msg'] as String? ?? '',
    );
  }

  Color levelColor(BuildContext context) {
    switch (level) {
      case 'error':
        return Colors.red;
      case 'warning':
        return Colors.orange;
      case 'debug':
        return Colors.grey;
      default:
        return Theme.of(context).colorScheme.onSurface;
    }
  }
}

class LogPage extends StatefulWidget {
  final CoreManager coreManager;
  const LogPage({super.key, required this.coreManager});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final List<LogEntry> _logs = [];
  WebSocketChannel? _channel;
  String _levelFilter = 'info';
  final _searchCtrl = TextEditingController();
  String _searchText = '';
  final _scrollCtrl = ScrollController();

  final _levels = ['debug', 'info', 'warning', 'error'];

  @override
  void initState() {
    super.initState();
    _connect();
    _searchCtrl.addListener(() {
      setState(() => _searchText = _searchCtrl.text.toLowerCase());
    });
  }

  void _connect() {
    widget.coreManager.getLogChannel().then((channel) {
      _channel = channel;
      _channel?.stream.listen((raw) {
        try {
          final data = json.decode(raw as String) as Map<String, dynamic>;
          final entry = LogEntry.fromJson(data);
          if (mounted) {
            setState(() {
              _logs.add(entry);
              if (_logs.length > 2000) _logs.removeAt(0);
            });
            // Auto-scroll to bottom
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollCtrl.hasClients) {
                _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
              }
            });
          }
        } catch (_) {}
      });
    });
  }

  List<LogEntry> get _filtered {
    final levelIdx = _levels.indexOf(_levelFilter);
    return _logs.where((e) {
      final eIdx = _levels.indexOf(e.level);
      if (eIdx < levelIdx) return false;
      if (_searchText.isNotEmpty &&
          !e.message.toLowerCase().contains(_searchText)) return false;
      return true;
    }).toList();
  }

  String _formatTime(String iso) {
    try {
      final t = DateTime.parse(iso).toLocal();
      return '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Column(
      children: [
        // Toolbar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              // Level filter
              DropdownButton<String>(
                value: _levelFilter,
                isDense: true,
                underline: const SizedBox(),
                items: _levels
                    .map((l) => DropdownMenuItem(
                          value: l,
                          child: Text(l.toUpperCase(),
                              style: const TextStyle(fontSize: 12)),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _levelFilter = v);
                },
              ),
              const SizedBox(width: 8),
              // Search
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Search logs...',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 16),
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              // Clear
              IconButton(
                tooltip: 'Clear logs',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => setState(() => _logs.clear()),
              ),
              // Copy all
              IconButton(
                tooltip: 'Copy all',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  final text = filtered
                      .map((e) =>
                          '[${_formatTime(e.time)}] [${e.level.toUpperCase()}] ${e.message}')
                      .join('\n');
                  Clipboard.setData(ClipboardData(text: text));
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Log list
        Expanded(
          child: filtered.isEmpty
              ? const Center(
                  child: Text('No logs', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  controller: _scrollCtrl,
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final e = filtered[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 1),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Time
                          SizedBox(
                            width: 68,
                            child: Text(
                              _formatTime(e.time),
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey),
                            ),
                          ),
                          // Level badge
                          Container(
                            width: 54,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: e.levelColor(ctx).withOpacity(0.12),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              e.level.toUpperCase(),
                              style: TextStyle(
                                  fontSize: 10,
                                  color: e.levelColor(ctx),
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // Message
                          Expanded(
                            child: SelectableText(
                              e.message,
                              style: TextStyle(
                                  fontSize: 12, color: e.levelColor(ctx)),
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
