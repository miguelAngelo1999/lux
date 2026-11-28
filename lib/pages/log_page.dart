import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/widget/lux_icons.dart';
import 'package:lux/widget/lux_scroll_edge_fade.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum LogCategory { all, proxyDenied, blocked, errors }

enum LogBadgeKind { normal, danger, amber, cobalt }

class LogBadge {
  final String label;
  final LogBadgeKind kind;
  const LogBadge(this.label, this.kind);
}

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

  /// True when an upstream proxy explicitly rejected/denied the connection
  /// (HTTP 403/407/405/502+, SOCKS5 REP/auth) or dropped it immediately after
  /// TLS ClientHello (`[PROXY_RESET]`).
  bool get isProxyDenied {
    final m = message;
    if (m.contains('[PROXY_DENIED]') || m.contains('[PROXY_RESET]')) {
      return true;
    }
    final lower = m.toLowerCase();
    return lower.contains('upstream proxy denied') ||
        lower.contains('upstream proxy rejected') ||
        lower.contains('upstream proxy authentication required') ||
        lower.contains('upstream proxy gateway error');
  }

  /// True when a local Lux rule (`REJECT`) blocked the connection.
  bool get isRuleBlocked {
    if (isProxyDenied) return false;
    return message.contains('[RULE_REJECT]') || message.contains('[DENY]');
  }

  /// True for warnings, errors, dial failures, or denials.
  bool get isErrorOrFail {
    return level == 'error' ||
        level == 'warning' ||
        message.contains('[DIAL_FAIL]') ||
        isProxyDenied ||
        isRuleBlocked;
  }

  /// High-signal short pill label for the log row, or null to show the raw level.
  LogBadge? get eventBadge {
    final m = message;
    if (m.contains('[PROXY_RESET]')) {
      return const LogBadge('TLS DROP', LogBadgeKind.amber);
    }
    if (m.contains('[AUTO_SPLICE]')) {
      return const LogBadge('AUTO-SPLICE', LogBadgeKind.amber);
    }
    if (isProxyDenied) {
      if (m.contains('[HTTP 403]') || m.contains('HTTP 403')) {
        return const LogBadge('403 DENY', LogBadgeKind.danger);
      }
      if (m.contains('[HTTP 407]') ||
          m.contains('HTTP 407') ||
          m.contains('[AUTH LATCHED]')) {
        return const LogBadge('407 AUTH', LogBadgeKind.amber);
      }
      if (m.contains('[HTTP 405]') || m.contains('HTTP 405')) {
        return const LogBadge('405 DENY', LogBadgeKind.danger);
      }
      if (m.contains('[HTTP 502]') || m.contains('HTTP 502')) {
        return const LogBadge('502 ERR', LogBadgeKind.amber);
      }
      if (m.contains('[HTTP 503]') || m.contains('HTTP 503')) {
        return const LogBadge('503 ERR', LogBadgeKind.amber);
      }
      if (m.contains('[HTTP 504]') || m.contains('HTTP 504')) {
        return const LogBadge('504 ERR', LogBadgeKind.amber);
      }
      if (m.contains('[SOCKS5 AUTH]')) {
        return const LogBadge('S5 AUTH', LogBadgeKind.amber);
      }
      if (m.contains('[SOCKS5 DENY]')) {
        return const LogBadge('S5 DENY', LogBadgeKind.danger);
      }
      if (m.contains('[SOCKS5 ERR]')) {
        return const LogBadge('S5 ERR', LogBadgeKind.amber);
      }
      return const LogBadge('PROXY DENY', LogBadgeKind.danger);
    }
    if (isRuleBlocked) {
      return const LogBadge('BLOCKED', LogBadgeKind.amber);
    }
    if (m.contains('[DIAL_FAIL]')) {
      return const LogBadge('DIAL FAIL', LogBadgeKind.danger);
    }
    if (m.contains('[MITM]')) {
      return const LogBadge('MITM', LogBadgeKind.cobalt);
    }
    if (m.contains('[net-switch]')) {
      return const LogBadge('SWITCH', LogBadgeKind.cobalt);
    }
    return null;
  }

  /// Extracts a clean URL (stripped of redacted `?…` suffix) from MITM / HTTP
  /// log lines so users can create 1-click `URL-PREFIX` rules directly from logs.
  String? get extractedUrl {
    final m = RegExp(r'(?:https?|wss?)://[^\s\]]+', caseSensitive: false)
        .firstMatch(message);
    if (m == null) return null;
    var raw = m.group(0)!.trim();
    if (raw.endsWith('?…')) {
      raw = raw.substring(0, raw.length - 2);
    } else if (raw.endsWith('?...')) {
      raw = raw.substring(0, raw.length - 4);
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || !_isUsableHost(uri.host)) return null;
    return raw;
  }

  /// Extracts a clean hostname or IP from denial/failure/MITM log lines
  /// so users can create a 1-click bypass/routing rule directly from the log.
  String? get extractedHost {
    if (!isProxyDenied &&
        !isRuleBlocked &&
        !message.contains('[DIAL_FAIL]') &&
        !message.contains('[MITM]') &&
        !message.contains('[AUTO_SPLICE]')) {
      return null;
    }

    // 1. Check full http(s):// or ws(s):// URL first.
    final urlMatch =
        RegExp(r'(?:https?|wss?)://([^/\s:]+)(?::\d+)?', caseSensitive: false)
            .firstMatch(message);
    if (urlMatch != null) {
      final h = urlMatch.group(1)?.trim() ?? '';
      if (_isUsableHost(h)) return h;
    }

    // 2. Strip leading prefixes/tags like "[TCP], [DENY] [PROXY_DENIED] [HTTP 403] ".
    final afterTags = message.replaceFirst(
      RegExp(r'^(\s*\[[^\]]+\],?\s*)+'),
      '',
    );

    // 3. Look for "host:port" (domain or IPv4) near the start or after "to ".
    final hostPortPattern = RegExp(
      r'(?:^|\bto\s+|\bfor\s+|\s)([a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}|\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})\b',
    );
    final hpMatch = hostPortPattern.firstMatch(afterTags);
    if (hpMatch != null) {
      final h = hpMatch.group(1)?.trim() ?? '';
      if (_isUsableHost(h)) return h;
    }

    return null;
  }

  bool get isExtractedHostIp {
    final h = extractedHost;
    if (h == null) return false;
    return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h);
  }

  static bool _isUsableHost(String h) {
    if (h.isEmpty) return false;
    final lower = h.toLowerCase();
    if (lower == 'localhost' ||
        lower == '127.0.0.1' ||
        lower == '0.0.0.0' ||
        lower.startsWith('127.')) {
      return false;
    }
    return true;
  }

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
  List<ProxyItem> _proxies = [];
  WebSocketChannel? _channel;
  String _levelFilter = 'info';
  LogCategory _category = LogCategory.all;
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
    _loadProxies();
    _searchCtrl.addListener(
        () => setState(() => _searchText = _searchCtrl.text.toLowerCase()));
  }

  Future<void> _loadProxies() async {
    try {
      final list = await widget.coreManager.getProxyList();
      if (mounted) {
        setState(() => _proxies = list.proxies);
      }
    } catch (_) {}
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
      var isFirstBatchOnConnection = true;
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
            if (batch.isEmpty) return;
            final parsed = <LogEntry>[];
            for (final item in batch) {
              try {
                final data = json.decode(item as String) as Map<String, dynamic>;
                final ts = data['time'];
                final timeStr = ts is int
                    ? DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String()
                    : ts?.toString() ?? '';
                parsed.add(LogEntry(
                  level: data['level'] as String? ?? 'info',
                  time: timeStr,
                  message: data['msg'] as String? ?? '',
                ));
              } catch (_) {}
            }
            if (parsed.isEmpty || !mounted) return;
            setState(() {
              if (isFirstBatchOnConnection && _logs.isNotEmpty) {
                // Reconnect replays the log file tail — replace cleanly to avoid duplicates.
                _logs.clear();
              }
              isFirstBatchOnConnection = false;
              _logs.addAll(parsed);
              if (_logs.length > 2500) {
                _logs.removeRange(0, _logs.length - 2500);
              }
            });
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

  int get _proxyDeniedCount => _logs.where((e) => e.isProxyDenied).length;
  int get _ruleBlockedCount => _logs.where((e) => e.isRuleBlocked).length;
  int get _errorCount => _logs.where((e) => e.isErrorOrFail).length;

  List<LogEntry> get _filtered {
    final levelIdx = _levels.indexOf(_levelFilter);
    return _logs.where((e) {
      // Category filter takes priority for warning-level denial/error events
      // so clicking "Proxy Denied" or "Rule Blocked" never gets hidden by ERR level.
      switch (_category) {
        case LogCategory.proxyDenied:
          if (!e.isProxyDenied) return false;
          break;
        case LogCategory.blocked:
          if (!e.isRuleBlocked) return false;
          break;
        case LogCategory.errors:
          if (!e.isErrorOrFail) return false;
          break;
        case LogCategory.all:
          final eIdx = _levels.indexOf(e.level);
          if (eIdx < levelIdx) return false;
          break;
      }

      if (_searchText.isNotEmpty) {
        final msg = e.message.toLowerCase();
        if (_searchText == '[deny]') {
          if (!e.isProxyDenied &&
              !e.isRuleBlocked &&
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

  Color _badgeColor(LuxTokens tokens, LogBadgeKind kind) {
    switch (kind) {
      case LogBadgeKind.danger:
        return tokens.danger;
      case LogBadgeKind.amber:
        return tokens.amber;
      case LogBadgeKind.cobalt:
        return tokens.cobalt;
      case LogBadgeKind.normal:
        return tokens.textSecondary;
    }
  }

  Future<void> _createRuleFromLog(
      LogEntry entry, String policy, String policyLabel) async {
    final host = entry.extractedHost;
    if (host == null || host.isEmpty) return;
    final type = entry.isExtractedHostIp ? 'IP-CIDR' : 'DOMAIN-SUFFIX';
    final payload = entry.isExtractedHostIp ? '$host/32' : host;
    final raw = '$type,$payload,$policy';
    try {
      await widget.coreManager.addCustomizedRules([raw]);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${tl(context, 'Rule added')}: $payload → $policyLabel'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${tl(context, 'Could not add rule')}: $e'),
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

  Widget _categoryChip({
    required LuxTokens tokens,
    required LogCategory category,
    required String label,
    required String tooltip,
    required Color accent,
    int count = 0,
    Key? chipKey,
  }) {
    final active = _category == category;
    final hasAlert = count > 0 && category != LogCategory.all;
    final bgColor = active
        ? accent.withValues(alpha: 0.15)
        : (hasAlert && category == LogCategory.proxyDenied)
            ? accent.withValues(alpha: 0.08)
            : tokens.cardBg;
    final borderColor = active
        ? accent.withValues(alpha: 0.55)
        : (hasAlert && category == LogCategory.proxyDenied)
            ? accent.withValues(alpha: 0.35)
            : tokens.hairline;
    final textColor = active
        ? accent
        : (hasAlert && category == LogCategory.proxyDenied)
            ? accent
            : tokens.textSecondary;

    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: chipKey,
          borderRadius: BorderRadius.circular(7),
          onTap: () => setState(() => _category = category),
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: borderColor, width: 0.75),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: active || hasAlert
                        ? FontWeight.w500
                        : FontWeight.w400,
                    color: textColor,
                  ),
                ),
                if (count > 0 && category != LogCategory.all) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 0.5),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: active ? 0.22 : 0.16),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '$count',
                      style: luxMonoStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _createUrlRuleFromLog(
      String rawUrl, String policy, String policyLabel) async {
    final raw = 'URL-PREFIX,$rawUrl,$policy';
    try {
      await widget.coreManager.addCustomizedRules([raw]);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${tl(context, 'Rule added')}: $rawUrl → $policyLabel'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${tl(context, 'Could not add rule')}: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _quickRuleMenu(BuildContext context, LuxTokens tokens, LogEntry e) {
    final host = e.extractedHost;
    final fullUrl = e.extractedUrl;
    if (host == null || host.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: tl(context, 'Create rule for this host'),
      child: PopupMenuButton<(String, String)>(
        tooltip: '',
        padding: EdgeInsets.zero,
        onSelected: (pair) {
          if (pair.$1 == '__copy__') {
            Clipboard.setData(ClipboardData(text: host));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${tl(context, 'Copied')}: $host'),
                duration: const Duration(seconds: 2),
              ),
            );
            return;
          }
          if (pair.$1 == '__url_reject__' && fullUrl != null) {
            _createUrlRuleFromLog(fullUrl, 'REJECT', 'REJECT');
            return;
          }
          if (pair.$1 == '__url_direct__' && fullUrl != null) {
            _createUrlRuleFromLog(fullUrl, 'DIRECT', 'DIRECT');
            return;
          }
          _createRuleFromLog(e, pair.$1, pair.$2);
        },
        itemBuilder: (ctx) => [
          if (fullUrl != null) ...[
            PopupMenuItem(
              value: ('__url_reject__', 'REJECT'),
              height: 34,
              child: Text(
                '${tl(ctx, 'Block URL')} · $fullUrl',
                style: TextStyle(fontSize: 11.5, color: tokens.danger),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            PopupMenuItem(
              value: ('__url_direct__', 'DIRECT'),
              height: 34,
              child: Text(
                '${tl(ctx, 'Direct URL')} · $fullUrl',
                style: TextStyle(fontSize: 11.5, color: tokens.emerald),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const PopupMenuDivider(height: 6),
          ],
          PopupMenuItem(
            value: ('DIRECT', 'DIRECT'),
            height: 34,
            child: Text(
              '${tl(ctx, 'Always Direct')} · $host',
              style: TextStyle(fontSize: 11.5, color: tokens.emerald),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          PopupMenuItem(
            value: ('PROXY', 'PROXY'),
            height: 34,
            child: Text(
              '${tl(ctx, 'Always Proxy')} · $host',
              style: TextStyle(fontSize: 11.5, color: tokens.cobalt),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (final p in _proxies.where((p) => p.name.isNotEmpty).take(5))
            PopupMenuItem(
              value: (p.id, p.name),
              height: 34,
              child: Text(
                '${tl(ctx, 'Route via')} ${p.name} · $host',
                style: TextStyle(fontSize: 11.5, color: tokens.textPrimary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          PopupMenuItem(
            value: ('REJECT', 'REJECT'),
            height: 34,
            child: Text(
              '${tl(ctx, 'Reject')} · $host',
              style: TextStyle(fontSize: 11.5, color: tokens.danger),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const PopupMenuDivider(height: 6),
          PopupMenuItem(
            value: ('__copy__', host),
            height: 32,
            child: Text(
              '${tl(ctx, 'Copy host')} · $host',
              style: TextStyle(fontSize: 11.5, color: tokens.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        child: SizedBox(
          width: 22,
          height: 20,
          child: Center(
            child: LuxIcon(
              LuxGlyph.plus,
              size: 11.5,
              color: tokens.textMuted,
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
    final proxyDeniedCount = _proxyDeniedCount;
    final ruleBlockedCount = _ruleBlockedCount;
    final errorCount = _errorCount;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
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
                            if (v != null) {
                              setState(() {
                                _levelFilter = v;
                                _category = LogCategory.all;
                              });
                            }
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
                              onTap: () => setState(() {
                                _levelFilter = l;
                                _category = LogCategory.all;
                              }),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 4),
                                decoration: BoxDecoration(
                                  color: _category == LogCategory.all &&
                                          _levelFilter == l
                                      ? tokens.cardBg
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: _category == LogCategory.all &&
                                            _levelFilter == l
                                        ? tokens.hairlineStrong
                                        : Colors.transparent,
                                    width: 0.75,
                                  ),
                                ),
                                child: Text(
                                  _shortLevel(l),
                                  style: luxMonoStyle(
                                    fontSize: 10,
                                    fontWeight: _category == LogCategory.all &&
                                            _levelFilter == l
                                        ? FontWeight.w500
                                        : FontWeight.w400,
                                    color: _category == LogCategory.all &&
                                            _levelFilter == l
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
        // Smart category filter strip — highlights upstream proxy denials at a glance.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _categoryChip(
                      tokens: tokens,
                      category: LogCategory.all,
                      label: tl(context, 'All'),
                      tooltip: tl(context, 'Show all logs matching selected level'),
                      accent: tokens.cobalt,
                      chipKey: const Key('log-filter-all'),
                    ),
                    _categoryChip(
                      tokens: tokens,
                      category: LogCategory.proxyDenied,
                      label: tl(context, 'Proxy Denied'),
                      tooltip: tl(context,
                          'Connections denied, auth-rejected, or dropped by an upstream proxy (HTTP 403/407/405/502, SOCKS5, SNI reset)'),
                      accent: tokens.danger,
                      count: proxyDeniedCount,
                      chipKey: const Key('log-filter-proxy-denied'),
                    ),
                    _categoryChip(
                      tokens: tokens,
                      category: LogCategory.blocked,
                      label: tl(context, 'Rule Blocked'),
                      tooltip: tl(context,
                          'Connections blocked locally by a Lux REJECT rule'),
                      accent: tokens.amber,
                      count: ruleBlockedCount,
                      chipKey: const Key('log-filter-rule-blocked'),
                    ),
                    _categoryChip(
                      tokens: tokens,
                      category: LogCategory.errors,
                      label: tl(context, 'Errors'),
                      tooltip: tl(context,
                          'All warnings, errors, dial failures, and denials'),
                      accent: tokens.amber,
                      count: errorCount,
                      chipKey: const Key('log-filter-errors'),
                    ),
                  ],
                ),
              ),
              if (_logs.isNotEmpty)
                Text(
                  '${filtered.length}/${_logs.length}',
                  style: luxMonoStyle(
                    fontSize: 10,
                    color: tokens.textMuted,
                  ),
                ),
            ],
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
                            _category == LogCategory.proxyDenied
                                ? tl(context,
                                    'No connections denied by upstream proxy')
                                : _category == LogCategory.blocked
                                    ? tl(context, 'No connections blocked by rules')
                                    : _connected
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
                                final badge = e.eventBadge;
                                final badgeLabel =
                                    badge?.label ?? _shortLevel(e.level);
                                final badgeColor = badge != null
                                    ? _badgeColor(tokens, badge.kind)
                                    : lvlColor;
                                final isProxyDeny = e.isProxyDenied;
                                final isRuleBlock = e.isRuleBlocked;

                                Color? rowBg;
                                Color? leftAccent;
                                if (isProxyDeny) {
                                  rowBg = badgeColor.withValues(alpha: 0.06);
                                  leftAccent = badgeColor.withValues(alpha: 0.65);
                                } else if (isRuleBlock) {
                                  rowBg = tokens.amber.withValues(alpha: 0.05);
                                  leftAccent =
                                      tokens.amber.withValues(alpha: 0.55);
                                }

                                return Container(
                                  decoration: rowBg != null
                                      ? BoxDecoration(
                                          color: rowBg,
                                          border: Border(
                                            left: BorderSide(
                                              color: leftAccent!,
                                              width: 2,
                                            ),
                                          ),
                                        )
                                      : null,
                                  padding: EdgeInsets.fromLTRB(
                                      leftAccent != null ? 8 : 10, 3, 8, 3),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 60,
                                        child: Text(
                                          _formatTime(e.time),
                                          style: luxMonoStyle(
                                            fontSize: 10.5,
                                            color: tokens.textMuted,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        constraints: const BoxConstraints(
                                            minWidth: 56),
                                        alignment: Alignment.center,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: badgeColor.withValues(
                                              alpha: 0.14),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          badgeLabel,
                                          style: luxMonoStyle(
                                            fontSize: 9,
                                            color: badgeColor,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          e.message,
                                          style: luxMonoStyle(
                                            fontSize: 11,
                                            fontWeight: isProxyDeny || isRuleBlock
                                                ? FontWeight.w500
                                                : FontWeight.w400,
                                            color: isProxyDeny
                                                ? tokens.textPrimary
                                                : isRuleBlock
                                                    ? tokens.amber
                                                    : lvlColor,
                                          ),
                                        ),
                                      ),
                                      if (e.extractedHost != null) ...[
                                        const SizedBox(width: 4),
                                        _quickRuleMenu(ctx, tokens, e),
                                      ],
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
