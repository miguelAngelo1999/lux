import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/widget/lux_icons.dart';
import 'package:lux/widget/lux_scroll_edge_fade.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class LogEntry {
  final String level;
  final String time;
  final String message;
  LogEntry({required this.level, required this.time, required this.message});

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        level: json['level'] as String? ?? 'info',
        time: json['time'] as String? ?? '',
        message: json['msg'] as String? ?? '',
      );

  Color levelColor(BuildContext context) {
    final tokens = LuxTokens.of(context);
    switch (level) {
      case 'error':
        return tokens.danger;
      case 'warning':
        return tokens.amber;
      case 'debug':
        return tokens.textMuted;
      default:
        return tokens.textPrimary;
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
  final _logFocusNode = FocusNode();
  bool _connected = false;
  bool _paused = false;
  String? _error;

  Timer? _retry;
  StreamSubscription<dynamic>? _sub;

  static const _levels = ['debug', 'info', 'warning', 'error'];

  @override
  void initState() {
    super.initState();
    _connect();
    _searchCtrl.addListener(
        () => setState(() => _searchText = _searchCtrl.text.toLowerCase()));
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), () {
      if (mounted) _connect();
    });
  }

  Future<void> _connect() async {
    try {
      final channel = await widget.coreManager.getLogChannel();
      await channel.ready;
      if (!mounted) {
        await channel.sink.close();
        return;
      }
      setState(() {
        _channel = channel;
        _connected = true;
        _error = null;
      });
      await _sub?.cancel();
      _sub = channel.stream.listen(
        (raw) {
          try {
            final batch = json.decode(raw as String) as List<dynamic>;
            for (final item in batch) {
              try {
                final data = json.decode(item as String) as Map<String, dynamic>;
                final ts = data['time'];
                final timeStr = ts is int
                    ? DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String()
                    : ts?.toString() ?? '';
                final entry = LogEntry(
                  level: data['level'] as String? ?? 'info',
                  time: timeStr,
                  message: data['msg'] as String? ?? '',
                );
                if (mounted) {
                  setState(() {
                    _logs.add(entry);
                    if (_logs.length > 2000) _logs.removeAt(0);
                  });
                }
              } catch (_) {}
            }
            if (!_paused) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scrollCtrl.hasClients) {
                  _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
                }
              });
            }
          } catch (_) {}
        },
        onError: (e) {
          debugPrint('Log WS error: $e');
          if (!mounted) return;
          setState(() {
            _connected = false;
            _error = e.toString();
          });
          _scheduleRetry();
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _connected = false);
          _scheduleRetry();
        },
      );
    } catch (e) {
      debugPrint('Log connect error: $e');
      if (!mounted) return;
      setState(() {
        _connected = false;
        _error = e.toString();
      });
      _scheduleRetry();
    }
  }

  List<LogEntry> get _filtered {
    final levelIdx = _levels.indexOf(_levelFilter);
    return _logs.where((e) {
      final eIdx = _levels.indexOf(e.level);
      if (eIdx < levelIdx) return false;
      if (_searchText.isNotEmpty) {
        final msg = e.message.toLowerCase();
        if (_searchText == '[deny]') {
          if (!msg.contains('[deny]') &&
              !msg.contains('[proxy_denied]') &&
              !msg.contains('denied') &&
              !msg.contains('rejected')) {
            return false;
          }
        } else if (!msg.contains(_searchText)) {
          return false;
        }
      }
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
      return iso.length > 8 ? iso.substring(0, 8) : iso;
    }
  }

  String _shortLevel(String level) {
    switch (level) {
      case 'warning':
        return 'WARN';
      case 'error':
        return 'ERR';
      case 'debug':
        return 'DBG';
      default:
        return 'INFO';
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _logFocusNode.dispose();
    super.dispose();
  }

  Widget _toolbarIconButton({
    required LuxTokens tokens,
    required LuxGlyph glyph,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: active
                  ? tokens.cobalt.withValues(alpha: 0.14)
                  : tokens.cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active
                    ? tokens.cobalt.withValues(alpha: 0.45)
                    : tokens.hairlineStrong,
                width: 0.75,
              ),
            ),
            child: Center(
              child: LuxIcon(
                glyph,
                size: 13,
                color: active ? tokens.cobalt : tokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final filtered = _filtered;
    final denyActive = _searchText == '[deny]';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 540;
              return Row(
                children: [
                  Container(
                    width: 6.5,
                    height: 6.5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _connected ? tokens.emerald : tokens.amber,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (compact)
                    Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      decoration: BoxDecoration(
                        color: tokens.cardBg,
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: tokens.hairline, width: 0.75),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _levelFilter,
                          isDense: true,
                          items: _levels
                              .map((l) => DropdownMenuItem(
                                    value: l,
                                    child: Text(
                                      _shortLevel(l),
                                      style: luxMonoStyle(
                                        fontSize: 10.5,
                                        color: tokens.textPrimary,
                                      ),
                                    ),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _levelFilter = v);
                          },
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: tokens.subtlePillBg,
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: tokens.hairline, width: 0.75),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final l in _levels)
                            InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () => setState(() => _levelFilter = l),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 4),
                                decoration: BoxDecoration(
                                  color: _levelFilter == l
                                      ? tokens.cardBg
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: _levelFilter == l
                                        ? tokens.hairlineStrong
                                        : Colors.transparent,
                                    width: 0.75,
                                  ),
                                ),
                                child: Text(
                                  _shortLevel(l),
                                  style: luxMonoStyle(
                                    fontSize: 10,
                                    fontWeight: _levelFilter == l
                                        ? FontWeight.w500
                                        : FontWeight.w400,
                                    color: _levelFilter == l
                                        ? tokens.textPrimary
                                        : tokens.textMuted,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(width: 6),
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(7),
                      onTap: () {
                        setState(() {
                          _searchCtrl.text = denyActive ? '' : '[DENY]';
                        });
                      },
                      child: Container(
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: denyActive
                              ? tokens.amber.withValues(alpha: 0.14)
                              : tokens.cardBg,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                            color: denyActive
                                ? tokens.amber.withValues(alpha: 0.5)
                                : tokens.hairline,
                            width: 0.75,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'Denied',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight:
                                denyActive ? FontWeight.w500 : FontWeight.w400,
                            color: denyActive
                                ? tokens.amber
                                : tokens.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SizedBox(
                      height: 30,
                      child: TextField(
                        controller: _searchCtrl,
                        textAlignVertical: TextAlignVertical.center,
                        style:
                            TextStyle(fontSize: 12, color: tokens.textPrimary),
                        decoration: InputDecoration(
                          hintText: tl(context, 'Search logs...'),
                          hintStyle: TextStyle(
                              fontSize: 11.5, color: tokens.textMuted),
                          isDense: true,
                          filled: true,
                          fillColor: tokens.cardBg,
                          prefixIcon: Center(
                            child: LuxIcon(LuxGlyph.search,
                                size: 13, color: tokens.textMuted),
                          ),
                          prefixIconConstraints: const BoxConstraints.tightFor(
                              width: 30, height: 30),
                          suffixIconConstraints: const BoxConstraints.tightFor(
                              width: 28, height: 30),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 0),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(
                                color: tokens.hairline, width: 0.75),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide:
                                BorderSide(color: tokens.cobalt, width: 1.0),
                          ),
                          suffixIcon: _searchText.isEmpty
                              ? null
                              : IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                      width: 28, height: 30),
                                  icon: LuxIcon(LuxGlyph.close,
                                      size: 11.5, color: tokens.textMuted),
                                  onPressed: () => _searchCtrl.clear(),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _toolbarIconButton(
                    tokens: tokens,
                    glyph: _paused ? LuxGlyph.play : LuxGlyph.pause,
                    tooltip: _paused
                        ? tl(context, 'Resume auto-scroll')
                        : tl(context, 'Pause auto-scroll'),
                    active: _paused,
                    onTap: () => setState(() => _paused = !_paused),
                  ),
                  const SizedBox(width: 4),
                  _toolbarIconButton(
                    tokens: tokens,
                    glyph: LuxGlyph.trash,
                    tooltip: tl(context, 'Clear logs'),
                    onTap: () => setState(() => _logs.clear()),
                  ),
                  const SizedBox(width: 4),
                  _toolbarIconButton(
                    tokens: tokens,
                    glyph: LuxGlyph.copy,
                    tooltip: tl(context, 'Copy all'),
                    onTap: () {
                      final text = filtered
                          .map((e) =>
                              '[${_formatTime(e.time)}] [${e.level.toUpperCase()}] ${e.message}')
                          .join('\n');
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(tl(context, 'Logs copied')),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Container(
              decoration: BoxDecoration(
                color: tokens.cardBg,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: tokens.hairline, width: 0.75),
              ),
              child: _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TText(
                            'Connection error:',
                            style: TextStyle(color: tokens.danger, fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            _error!,
                            style: luxMonoStyle(
                                fontSize: 11, color: tokens.textMuted),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () {
                              setState(() => _error = null);
                              _connect();
                            },
                            child: const TText('Retry'),
                          ),
                        ],
                      ),
                    )
                  : filtered.isEmpty
                      ? Center(
                          child: Text(
                            _connected
                                ? tl(context, 'Waiting for logs...')
                                : tl(context, 'Connecting...'),
                            style:
                                TextStyle(fontSize: 12, color: tokens.textMuted),
                          ),
                        )
                      : SelectableRegion(
                          focusNode: _logFocusNode,
                          selectionControls: materialTextSelectionControls,
                          child: LuxScrollEdgeFade(
                            startFade: 14,
                            endFade: 22,
                            child: ListView.builder(
                              controller: _scrollCtrl,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              itemCount: filtered.length,
                              itemBuilder: (ctx, i) {
                              final e = filtered[i];
                              final lvlColor = e.levelColor(ctx);
                              final isDeny = e.message.contains('[DENY]') ||
                                  e.message.contains('[PROXY_DENIED]');
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 2),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 62,
                                      child: Text(
                                        _formatTime(e.time),
                                        style: luxMonoStyle(
                                          fontSize: 10.5,
                                          color: tokens.textMuted,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      width: 42,
                                      alignment: Alignment.center,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: lvlColor.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        _shortLevel(e.level),
                                        style: luxMonoStyle(
                                          fontSize: 9.5,
                                          color: lvlColor,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        e.message,
                                        style: luxMonoStyle(
                                          fontSize: 11,
                                          fontWeight: isDeny
                                              ? FontWeight.w500
                                              : FontWeight.w400,
                                          color: isDeny
                                              ? tokens.amber
                                              : lvlColor,
                                        ),
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
          ),
        ),
      ],
    );
  }
}
