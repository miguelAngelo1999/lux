/// Anonymous usage reporting, off unless the user opts in.
///
/// Three levels, stored in lux_prefs.json:
///
///   off   nothing is sent, and no device id is generated
///   ops   app health, crashes, connection lifecycle, mode/proxy switches,
///         core incidents, and update outcomes — never any websites or domains
///   full  everything in ops, plus deduplicated registered domains (e.g.
///         "github.com:443 -> DIRECT") to help diagnose routing issues
///
/// Events are buffered and flushed periodically rather than sent per event, so a
/// slow or unreachable endpoint never blocks the app. Flushes route through
/// Lux's local HTTP proxy first (for corporate networks where direct internet
/// access is blocked) and fall back to DIRECT automatically.
///
/// The device id is a random UUID with no link to any account or identity. It
/// exists so a user can quote it when reporting a problem.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_log.dart';

/// Endpoint receiving batches. Empty disables sending entirely, which is the
/// default for a build that has not been configured.
const _telemetryUrl =
    'https://script.google.com/macros/s/AKfycbwWUZPchIiZgKExLuPOS9LVucUrMSa_PDq2TNpe-FtGpSy4oJz7hWZUTWizxJQVx0C3nQ/exec';

const _flushIntervalSec = 60;
const _maxBuffer = 40;

/// Cap on retained events. Without this a long offline period would grow the
/// buffer without bound.
const _hardCap = 300;

/// Maximum unique domain aggregations emitted per flush in `full` mode so heavy
/// browsing produces crisp summaries rather than flooding the Sheet.
const _maxConnEntriesPerFlush = 30;

/// Deduplication window for identical crash signatures and domain rollups.
const _crashDedupeWindow = Duration(minutes: 5);
const _connDedupeWindow = Duration(minutes: 10);

/// Routine blackbox entries that are high-volume and already covered by
/// Flutter's own `connect`/`disconnect` telemetry events.
const _routineBlackboxTypes = {
  'manager-started',
  'manager-stopped',
};

enum TelemetryLevel { off, ops, full }

TelemetryLevel telemetryLevelFromString(String? s) {
  switch (s) {
    case 'ops':
      return TelemetryLevel.ops;
    case 'full':
      return TelemetryLevel.full;
    default:
      // Default off. Reporting is opt-in.
      return TelemetryLevel.off;
  }
}

String telemetryLevelToString(TelemetryLevel l) {
  switch (l) {
    case TelemetryLevel.ops:
      return 'ops';
    case TelemetryLevel.full:
      return 'full';
    case TelemetryLevel.off:
      return 'off';
  }
}

String telemetryLevelLabel(TelemetryLevel l) {
  switch (l) {
    case TelemetryLevel.off:
      return 'Off';
    case TelemetryLevel.ops:
      return 'Basic (Ops & Errors)';
    case TelemetryLevel.full:
      return 'Full (incl. Domains)';
  }
}

String telemetryLevelDescription(TelemetryLevel l) {
  switch (l) {
    case TelemetryLevel.off:
      return 'Nothing is sent. No device id, no events.';
    case TelemetryLevel.ops:
      return 'App health, crashes, connection lifecycle, mode switches, and core incidents — never any websites or domains.';
    case TelemetryLevel.full:
      return 'Everything in Basic, plus deduplicated registered domains (e.g. github.com) and routing outcomes to diagnose rule issues.';
  }
}

/// Live in-memory telemetry delivery metrics shown in Settings → Privacy.
@immutable
class TelemetryStats {
  final int sentCount;
  final int failedCount;
  final int bufferedCount;
  final DateTime? lastFlushAt;
  final int? lastStatusCode;
  final String? lastRoute;
  final String? lastError;

  const TelemetryStats({
    this.sentCount = 0,
    this.failedCount = 0,
    this.bufferedCount = 0,
    this.lastFlushAt,
    this.lastStatusCode,
    this.lastRoute,
    this.lastError,
  });

  TelemetryStats copyWith({
    int? sentCount,
    int? failedCount,
    int? bufferedCount,
    DateTime? lastFlushAt,
    int? lastStatusCode,
    String? lastRoute,
    String? lastError,
    bool clearLastError = false,
  }) {
    return TelemetryStats(
      sentCount: sentCount ?? this.sentCount,
      failedCount: failedCount ?? this.failedCount,
      bufferedCount: bufferedCount ?? this.bufferedCount,
      lastFlushAt: lastFlushAt ?? this.lastFlushAt,
      lastStatusCode: lastStatusCode ?? this.lastStatusCode,
      lastRoute: lastRoute ?? this.lastRoute,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }
}

final ValueNotifier<TelemetryStats> telemetryStatsNotifier =
    ValueNotifier<TelemetryStats>(const TelemetryStats());

/// Result of a single batch HTTP delivery attempt.
typedef TelemetryPostResult = ({
  bool ok,
  int? statusCode,
  String route,
  String? error,
});

/// Optional test hook to intercept HTTP POST delivery without hitting the web.
@visibleForTesting
Future<TelemetryPostResult> Function(String payload)? telemetryPostOverride;

class _ConnAgg {
  final String dest;
  final String rule;
  final String outcome;
  int hits;
  int? lastMs;
  DateTime firstSeen;

  _ConnAgg({
    required this.dest,
    required this.rule,
    required this.outcome,
    required this.hits,
    required this.firstSeen,
    this.lastMs,
  });
}

TelemetryLevel _level = TelemetryLevel.off;
String _uuid = '';
String _version = '';
String _osVersion = '';
int _proxyPort = 1090;
bool _initialised = false;
bool _flushing = false;
int _consecutiveFailures = 0;
Timer? _flushTimer;

final _buffer = <Map<String, dynamic>>[];
final _crashSeen = <String, DateTime>{};
final _connAggs = <String, _ConnAgg>{};
final _connReportedAt = <String, DateTime>{};

/// Whether an endpoint is configured. Without one the UI should say so rather
/// than implying data is being sent.
bool get telemetryConfigured => _telemetryUrl.isNotEmpty;

String get telemetryUuid => _uuid;
TelemetryLevel get telemetryLevel => _level;

/// Sync the local Lux HTTP proxy port (default 1090) used by telemetry flushes.
void setTelemetryProxyPort(int port) {
  if (port > 0 && port <= 65535) {
    _proxyPort = port;
  }
}

Future<void> _ensureMetadata() async {
  if (_version.isEmpty) {
    try {
      _version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
  }
  if (_osVersion.isEmpty) {
    _osVersion = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  }
}

void _publishBufferedCount() {
  final cur = telemetryStatsNotifier.value;
  final total = _buffer.length + _connAggs.length;
  if (cur.bufferedCount != total) {
    telemetryStatsNotifier.value = cur.copyWith(bufferedCount: total);
  }
}

Future<void> initTelemetry({
  required String uuid,
  required TelemetryLevel level,
  String? versionOverride,
  String? osVersionOverride,
}) async {
  _uuid = uuid;
  _level = level;
  if (versionOverride != null) _version = versionOverride;
  if (osVersionOverride != null) _osVersion = osVersionOverride;

  if (_level == TelemetryLevel.off || !telemetryConfigured) {
    _initialised = false;
    _flushTimer?.cancel();
    return;
  }

  await _ensureMetadata();
  _initialised = true;
  _startTimer();
}

void _startTimer() {
  _flushTimer?.cancel();
  _flushTimer = Timer.periodic(
    const Duration(seconds: _flushIntervalSec),
    (_) => _flush(),
  );
}

/// Change the level at runtime.
///
/// Switching to `off` drops anything buffered (including domain aggregations),
/// so disabling reporting cannot leak events recorded while it was on.
/// Switching from `off` to `ops` or `full` populates version/OS/UUID metadata
/// immediately so batches never carry blank headers until the next restart.
Future<void> setTelemetryLevel(
  TelemetryLevel level, {
  String? uuid,
}) async {
  final prev = _level;
  _level = level;
  if (uuid != null && uuid.isNotEmpty) {
    _uuid = uuid;
  }

  if (level == TelemetryLevel.off) {
    _buffer.clear();
    _connAggs.clear();
    _connReportedAt.clear();
    _flushTimer?.cancel();
    _initialised = false;
    _publishBufferedCount();
    return;
  }

  if (level != TelemetryLevel.full) {
    _connAggs.clear();
    _connReportedAt.clear();
  }

  if (telemetryConfigured) {
    await _ensureMetadata();
    if (!_initialised) {
      _initialised = true;
      _startTimer();
    }
    if (prev != level) {
      telemetryOp(
        'telemetry-level',
        'changed ${telemetryLevelToString(prev)} -> ${telemetryLevelToString(level)}',
      );
    }
  }
  _publishBufferedCount();
}

/// Record an operational event. Sent at both `ops` and `full`.
void telemetryOp(String category, String message,
    {Map<String, dynamic>? extra}) {
  if (_level == TelemetryLevel.off) return;
  _enqueue(event: 'op', cat: category, msg: message, extra: extra);
}

/// Record a deduplicated routing decision. Sent only at `full`, and only after
/// the destination has been reduced to a registered domain (or masked public IP)
/// and private proxy names have been stripped.
void telemetryConn(String destination, String rule, String proxy,
    {int? resultMs}) {
  if (_level != TelemetryLevel.full || !_initialised) return;
  final sanitized = _sanitizeDest(destination);
  if (sanitized == null) return;
  final safeRule = _sanitizeRule(rule);
  final outcome = _sanitizeOutcome(proxy);
  final key = '$sanitized|$safeRule|$outcome';

  final now = DateTime.now();
  final lastSent = _connReportedAt[key];
  if (lastSent != null && now.difference(lastSent) < _connDedupeWindow) {
    return;
  }

  final existing = _connAggs[key];
  if (existing != null) {
    existing.hits++;
    if (resultMs != null) existing.lastMs = resultMs;
  } else if (_connAggs.length < _maxConnEntriesPerFlush * 3) {
    _connAggs[key] = _ConnAgg(
      dest: sanitized,
      rule: safeRule,
      outcome: outcome,
      hits: 1,
      firstSeen: now,
      lastMs: resultMs,
    );
  }
  _publishBufferedCount();
}

/// Report an error/incident. Always sent (at any level except `off`) so crashes
/// and broken states are visible even at Basic telemetry.
void telemetryError(String category, String message,
    {Map<String, dynamic>? extra}) {
  if (_level == TelemetryLevel.off) return;
  _enqueue(event: 'error', cat: category, msg: message, extra: extra);
  // Flush immediately — errors should not sit in a buffer for 60s.
  unawaited(_flush());
}

/// Report an uncaught Dart/Flutter exception with deduplication so render or
/// stream error loops cannot spam the telemetry Sheet.
void telemetryCrash(String source, Object error, StackTrace? stack) {
  if (_level == TelemetryLevel.off || !_initialised) return;

  final frames = _compactStack(stack);
  final firstFrame = frames.isNotEmpty ? frames.first : '';
  final sig = '$source|${error.runtimeType}|$firstFrame';
  final now = DateTime.now();
  final prev = _crashSeen[sig];
  if (prev != null && now.difference(prev) < _crashDedupeWindow) {
    return;
  }
  _crashSeen[sig] = now;
  if (_crashSeen.length > 64) {
    _crashSeen.removeWhere((_, t) => now.difference(t) >= _crashDedupeWindow);
  }

  telemetryError(
    source,
    '${error.runtimeType}: $error',
    extra: frames.isEmpty ? null : {'stack': frames.join(' | ')},
  );
}

/// Forward a blackbox event to telemetry.
void telemetryBlackboxEvent(String type, String message,
    {Map<String, dynamic>? data, String? timestamp}) {
  if (_level == TelemetryLevel.off) return;
  _enqueue(
    event: 'blackbox',
    cat: type,
    msg: message,
    extra: data,
    timestamp: timestamp,
  );
}

/// Scan `<homeDir>/blackbox.json` for new incident entries since the stored
/// watermark and enqueue them via [telemetryBlackboxEvent].
///
/// On the very first run (no watermark persisted yet), sets the watermark to
/// the latest timestamp in the file without replaying historical incidents.
Future<int> forwardBlackboxIncidents(
  String homeDir, {
  required Future<String?> Function() readWatermark,
  required Future<void> Function(String) writeWatermark,
}) async {
  if (_level == TelemetryLevel.off || !_initialised || homeDir.isEmpty) {
    return 0;
  }

  try {
    final file = File('$homeDir${Platform.pathSeparator}blackbox.json');
    if (!await file.exists()) return 0;
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return 0;
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.isEmpty) return 0;

    DateTime? latestTime;
    String? latestRawTime;
    for (final item in decoded) {
      if (item is! Map) continue;
      final tStr = item['time']?.toString();
      if (tStr == null || tStr.isEmpty) continue;
      final parsed = DateTime.tryParse(tStr);
      if (parsed != null &&
          (latestTime == null || parsed.isAfter(latestTime))) {
        latestTime = parsed;
        latestRawTime = tStr;
      }
    }

    final storedWatermarkStr = await readWatermark();
    if (storedWatermarkStr == null || storedWatermarkStr.isEmpty) {
      // Seed watermark without replaying months of past blackbox history.
      await writeWatermark(
        latestRawTime ?? DateTime.now().toUtc().toIso8601String(),
      );
      return 0;
    }

    final watermark = DateTime.tryParse(storedWatermarkStr);
    if (watermark == null) {
      await writeWatermark(
        latestRawTime ?? DateTime.now().toUtc().toIso8601String(),
      );
      return 0;
    }

    final incidents = <Map<String, dynamic>>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final type = item['type']?.toString() ?? '';
      if (type.isEmpty || _routineBlackboxTypes.contains(type)) continue;
      final tStr = item['time']?.toString() ?? '';
      final parsed = DateTime.tryParse(tStr);
      if (parsed == null || !parsed.isAfter(watermark)) continue;
      incidents.add({
        'time': parsed.toUtc().toIso8601String(),
        'type': type,
        'message': item['message']?.toString() ?? '',
      });
    }

    if (latestRawTime != null &&
        latestTime != null &&
        latestTime.isAfter(watermark)) {
      await writeWatermark(latestRawTime);
    }

    if (incidents.isEmpty) return 0;

    // Cap to the 25 most recent incidents so a burst never floods a single batch.
    final toSend = incidents.length > 25
        ? incidents.sublist(incidents.length - 25)
        : incidents;
    for (final inc in toSend) {
      telemetryBlackboxEvent(
        inc['type'] as String,
        inc['message'] as String,
        timestamp: inc['time'] as String,
      );
    }
    unawaited(_flush());
    return toSend.length;
  } catch (e) {
    appLog('TELEM', 'blackbox scan skipped: $e');
    return 0;
  }
}

/// Immediately send a single test event to verify end-to-end delivery from
/// Settings → Privacy.
Future<TelemetryPostResult> sendTestTelemetry() async {
  if (!telemetryConfigured) {
    return (
      ok: false,
      statusCode: null,
      route: 'none',
      error: 'No telemetry endpoint configured',
    );
  }
  if (_level == TelemetryLevel.off) {
    return (
      ok: false,
      statusCode: null,
      route: 'none',
      error: 'Telemetry is turned off',
    );
  }
  await _ensureMetadata();
  if (!_initialised) {
    _initialised = true;
    _startTimer();
  }
  _enqueue(
    event: 'op',
    cat: 'TEST',
    msg: 'manual test from Settings (level=${telemetryLevelToString(_level)})',
  );
  return _flush(forceReturnResult: true);
}

/// Flush pending events immediately (e.g. before app exit or update restart).
Future<void> flushTelemetry({bool stopTimer = false}) async {
  if (stopTimer) {
    _flushTimer?.cancel();
  }
  await _flush();
}

void _drainConnAggsIntoBuffer() {
  if (_connAggs.isEmpty || _level != TelemetryLevel.full) {
    _connAggs.clear();
    return;
  }
  final now = DateTime.now();
  // Prune expired dedupe keys periodically.
  _connReportedAt.removeWhere((_, t) => now.difference(t) >= _connDedupeWindow);

  // Pick top N by hit count so the most active domains surface first.
  final entries = _connAggs.entries.toList()
    ..sort((a, b) => b.value.hits.compareTo(a.value.hits));
  final take = entries.take(_maxConnEntriesPerFlush).toList();
  for (final e in take) {
    final agg = e.value;
    _connReportedAt[e.key] = now;
    _buffer.add({
      'ts': agg.firstSeen.toUtc().toIso8601String(),
      'event': 'conn',
      'cat': 'CONN',
      'msg': '${agg.dest} -> ${agg.outcome}',
      'extra': {
        'rule': agg.rule,
        'hits': agg.hits,
        if (agg.lastMs != null) 'ms': agg.lastMs,
      },
    });
  }
  _connAggs.clear();
  if (_buffer.length > _hardCap) {
    _buffer.removeRange(0, _buffer.length - _hardCap);
  }
}

void _enqueue({
  required String event,
  required String cat,
  required String msg,
  Map<String, dynamic>? extra,
  String? timestamp,
}) {
  if (!_initialised) return;
  _buffer.add({
    'ts': timestamp ?? DateTime.now().toUtc().toIso8601String(),
    'event': event,
    'cat': cat,
    'msg': _redact(msg),
    if (extra != null) 'extra': _redactExtra(extra),
  });
  if (_buffer.length > _hardCap) {
    _buffer.removeRange(0, _buffer.length - _hardCap);
  }
  _publishBufferedCount();
  if (_buffer.length >= _maxBuffer) {
    unawaited(_flush());
  }
}

Future<TelemetryPostResult> _flush({bool forceReturnResult = false}) async {
  if (!telemetryConfigured) {
    return (
      ok: false,
      statusCode: null,
      route: 'none',
      error: 'Endpoint not configured',
    );
  }
  if (_flushing) {
    return (
      ok: false,
      statusCode: null,
      route: 'busy',
      error: 'Flush already in progress',
    );
  }

  _drainConnAggsIntoBuffer();
  if (_buffer.isEmpty) {
    _publishBufferedCount();
    return (ok: true, statusCode: 200, route: 'empty', error: null);
  }

  _flushing = true;
  final batch = List<Map<String, dynamic>>.from(_buffer);
  _buffer.clear();
  _publishBufferedCount();

  try {
    await _ensureMetadata();
    final payload = jsonEncode({
      'uuid': _uuid,
      'version': _version,
      'os': _osVersion,
      'events': batch,
    });

    final result = await (telemetryPostOverride != null
        ? telemetryPostOverride!(payload)
        : _deliverPayload(payload));

    final cur = telemetryStatsNotifier.value;
    if (result.ok) {
      _consecutiveFailures = 0;
      telemetryStatsNotifier.value = cur.copyWith(
        sentCount: cur.sentCount + batch.length,
        bufferedCount: _buffer.length + _connAggs.length,
        lastFlushAt: DateTime.now(),
        lastStatusCode: result.statusCode,
        lastRoute: result.route,
        clearLastError: true,
      );
      appLog(
        'TELEM',
        'flushed ${batch.length} event(s) via ${result.route} (status=${result.statusCode})',
      );
      return result;
    }

    _consecutiveFailures++;
    // Re-queue once on transient failure (e.g. brief wake/network hiccup);
    // drop after 2 consecutive failures so offline buffers never loop forever.
    if (_consecutiveFailures < 2 && _level != TelemetryLevel.off) {
      _buffer.insertAll(0, batch);
      if (_buffer.length > _hardCap) {
        _buffer.removeRange(0, _buffer.length - _hardCap);
      }
    }
    telemetryStatsNotifier.value = cur.copyWith(
      failedCount: cur.failedCount + 1,
      bufferedCount: _buffer.length + _connAggs.length,
      lastStatusCode: result.statusCode,
      lastRoute: result.route,
      lastError: result.error ?? 'HTTP ${result.statusCode}',
    );
    appLog(
      'TELEM',
      'flush failed (${batch.length} event(s), retry=$_consecutiveFailures): '
          '${result.error ?? "HTTP ${result.statusCode}"}',
    );
    return result;
  } finally {
    _flushing = false;
    _publishBufferedCount();
  }
}

/// Delivers [payload] via Lux's local HTTP proxy first (so corporate networks
/// where direct internet is blocked still deliver), falling back to `DIRECT`.
Future<TelemetryPostResult> _deliverPayload(String payload) async {
  final proxyAttempt = await _postOnce(
    payload,
    findProxy: (_) => 'PROXY 127.0.0.1:$_proxyPort; DIRECT',
    routeLabel: 'proxy',
    timeout: const Duration(seconds: 12),
  );
  if (proxyAttempt.ok) return proxyAttempt;

  final directAttempt = await _postOnce(
    payload,
    findProxy: (_) => 'DIRECT',
    routeLabel: 'direct',
    timeout: const Duration(seconds: 10),
  );
  if (directAttempt.ok) return directAttempt;

  return (
    ok: false,
    statusCode: directAttempt.statusCode ?? proxyAttempt.statusCode,
    route: 'proxy+direct',
    error: directAttempt.error ?? proxyAttempt.error ?? 'delivery failed',
  );
}

Future<TelemetryPostResult> _postOnce(
  String payload, {
  required String Function(Uri) findProxy,
  required String routeLabel,
  required Duration timeout,
}) async {
  HttpClient? client;
  try {
    client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    client.badCertificateCallback = (_, __, ___) => true;
    client.findProxy = findProxy;

    final req = await client.postUrl(Uri.parse(_telemetryUrl)).timeout(timeout);
    req.followRedirects = false; // Apps Script returns 302 on success
    req.headers.contentType = ContentType.json;
    req.write(payload);
    final resp = await req.close().timeout(timeout);
    await resp.drain<void>();
    final code = resp.statusCode;
    // 302 from Google Apps Script = doPost succeeded (redirects to echo URL).
    final ok = code == 200 || code == 302;
    return (
      ok: ok,
      statusCode: code,
      route: routeLabel,
      error: ok ? null : 'HTTP $code',
    );
  } catch (e) {
    return (
      ok: false,
      statusCode: null,
      route: routeLabel,
      error: e.toString(),
    );
  } finally {
    client?.close(force: true);
  }
}

List<String> _compactStack(StackTrace? stack) {
  if (stack == null) return const [];
  final lines = stack
      .toString()
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .take(5)
      .map((l) => l.length > 140 ? '${l.substring(0, 140)}…' : l)
      .toList();
  return lines;
}

/// Remove anything token-, credential-, or secret-shaped from a message and cap
/// length so oversized error bodies never bloat a Sheet row.
String _redact(String msg) {
  var out = msg
      .replaceAllMapped(
        RegExp(r'(token=|secret=|password=|passwd=|apikey=|Bearer\s+)[^\s&",}]+',
            caseSensitive: false),
        (m) => '${m.group(1)}[redacted]',
      )
      .replaceAllMapped(
        RegExp(r'://[^/\s:@]+:[^/\s@]+@'),
        (_) => '://[redacted]@',
      )
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .trim();
  if (out.length > 400) {
    out = '${out.substring(0, 400)}…';
  }
  return out;
}

Map<String, dynamic> _redactExtra(Map<String, dynamic> extra) {
  final out = <String, dynamic>{};
  for (final e in extra.entries) {
    final k = e.key.toLowerCase();
    if (k.contains('password') ||
        k.contains('secret') ||
        k.contains('token') ||
        k.contains('auth')) {
      out[e.key] = '[redacted]';
    } else if (e.value is String) {
      out[e.key] = _redact(e.value as String);
    } else {
      out[e.key] = e.value;
    }
  }
  return out;
}

String _sanitizeOutcome(String proxy) {
  final upper = proxy.trim().toUpperCase();
  if (upper == 'DIRECT') return 'DIRECT';
  if (upper == 'REJECT' || upper == 'BLOCK') return 'REJECT';
  if (upper.isEmpty) return 'UNKNOWN';
  return 'PROXY';
}

String _sanitizeRule(String rule) {
  final trimmed = rule.trim();
  if (trimmed.isEmpty) return 'NONE';
  final parts = trimmed.split(',');
  if (parts.length == 1) {
    return trimmed.length > 40 ? trimmed.substring(0, 40) : trimmed;
  }
  final kind = parts.first.trim().toUpperCase();
  final payload = parts[1].trim();
  // Preserve safe generic rule types; sanitize domains/IPs inside custom rules.
  if (kind == 'GEOIP' || kind == 'FINAL' || kind == 'MATCH') {
    return '$kind,$payload';
  }
  if (kind.contains('CIDR') || kind.contains('IP')) {
    return kind;
  }
  if (kind.contains('PROCESS')) {
    return '$kind,$payload';
  }
  final safeDest = _sanitizeDest(payload);
  return safeDest != null ? '$kind,$safeDest' : kind;
}

/// Reduce a destination to something safe to report, or null to suppress it.
///
/// Private addresses, loopback, link-local, .local names and single-label hosts
/// are dropped: they describe the user's own network. Public IPs are masked
/// entirely, and public hostnames are cut back to the registered domain, so
/// "relay.abc.anydesk.com" reports as "anydesk.com".
String? _sanitizeDest(String dest) {
  final cleaned = dest.trim();
  if (cleaned.isEmpty) return null;

  // Handle bracketed IPv6 like [::1]:443 or [2606:4700::]:443.
  if (cleaned.startsWith('[')) {
    final endBracket = cleaned.indexOf(']');
    if (endBracket <= 1) return null;
    final ip6 = cleaned.substring(1, endBracket).toLowerCase();
    final port = endBracket + 2 <= cleaned.length &&
            cleaned[endBracket + 1] == ':'
        ? cleaned.substring(endBracket + 2)
        : '';
    if (ip6 == '::1' ||
        ip6.startsWith('fe80:') ||
        ip6.startsWith('fc') ||
        ip6.startsWith('fd')) {
      return null;
    }
    return 'ipv6${port.isNotEmpty ? ":$port" : ""}';
  }

  final lastColon = cleaned.lastIndexOf(':');
  final hasSingleColon = lastColon > 0 && cleaned.indexOf(':') == lastColon;
  final host = hasSingleColon ? cleaned.substring(0, lastColon) : cleaned;
  final port = hasSingleColon ? cleaned.substring(lastColon + 1) : '';

  final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
  final m = ipv4.firstMatch(host);
  if (m != null) {
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2)!);
    final isPrivate = a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127); // CGNAT / Tailscale
    if (isPrivate) return null;
    return 'x.x.x.x${port.isNotEmpty ? ":$port" : ""}';
  }

  final lower = host.toLowerCase();
  if (!lower.contains('.') ||
      lower.endsWith('.local') ||
      lower.endsWith('.lan') ||
      lower.endsWith('.internal') ||
      lower.endsWith('.home') ||
      lower.endsWith('.corp') ||
      lower.endsWith('.localdomain')) {
    return null;
  }

  final suffix = _registeredDomain(lower.split('.'));
  return '$suffix${port.isNotEmpty ? ":$port" : ""}';
}

/// Reduce hostname labels to the registered domain, handling the common
/// multi-part suffixes so "example.co.uk" is not cut to "co.uk".
String _registeredDomain(List<String> labels) {
  if (labels.length <= 2) return labels.join('.');

  const multiPartTlds = {
    'co.uk',
    'com.au',
    'com.br',
    'net.au',
    'org.uk',
    'gov.uk',
    'co.nz',
    'co.za',
    'com.ar',
    'com.mx',
    'net.br',
    'org.br',
    'co.jp',
    'co.kr',
    'com.cn',
    'com.tr',
    'co.in',
  };

  final last2 = '${labels[labels.length - 2]}.${labels[labels.length - 1]}';
  if (multiPartTlds.contains(last2) && labels.length >= 3) {
    return '${labels[labels.length - 3]}.$last2';
  }
  return last2;
}

/// Resets in-memory telemetry state for deterministic unit tests.
@visibleForTesting
void resetTelemetryForTest() {
  _flushTimer?.cancel();
  _flushTimer = null;
  _level = TelemetryLevel.off;
  _uuid = '';
  _version = '';
  _osVersion = '';
  _proxyPort = 1090;
  _initialised = false;
  _flushing = false;
  _consecutiveFailures = 0;
  _buffer.clear();
  _crashSeen.clear();
  _connAggs.clear();
  _connReportedAt.clear();
  telemetryPostOverride = null;
  telemetryStatsNotifier.value = const TelemetryStats();
}
