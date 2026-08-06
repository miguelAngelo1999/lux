/// Anonymous telemetry for Lux.
///
/// Three levels (stored in lux_prefs.json as 'telemetryLevel'):
///   full  — op logs + sanitized domain/rule events  (default)
///   ops   — op logs only, no domain names
///   off   — nothing sent
///
/// Events are buffered in memory and flushed:
///   - every 60 seconds
///   - on app stop
///   - when buffer reaches 50 events
///
/// Each device has a stable anonymous UUID shown in Settings so users can
/// quote it when reporting issues. The UUID is never linked to any PII.
library telemetry;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

// ── Configuration ─────────────────────────────────────────────────────────────

/// Paste your Apps Script deployment URL here after deploying.
/// Format: https://script.google.com/macros/s/XXXX/exec
const _telemetryUrl =
    'https://script.google.com/macros/s/AKfycbwWUZPchIiZgKExLuPOS9LVucUrMSa_PDq2TNpe-FtGpSy4oJz7hWZUTWizxJQVx0C3nQ/exec';

const _flushIntervalSec = 60;
const _maxBuffer = 50;

// ── Telemetry level ───────────────────────────────────────────────────────────

enum TelemetryLevel {
  full, // op logs + sanitized domains
  ops,  // op logs only
  off,  // disabled
}

TelemetryLevel telemetryLevelFromString(String? s) {
  switch (s) {
    case 'ops': return TelemetryLevel.ops;
    case 'off': return TelemetryLevel.off;
    default:    return TelemetryLevel.full;
  }
}

String telemetryLevelToString(TelemetryLevel l) {
  switch (l) {
    case TelemetryLevel.ops: return 'ops';
    case TelemetryLevel.off: return 'off';
    default:                 return 'full';
  }
}

// ── State ─────────────────────────────────────────────────────────────────────

TelemetryLevel _level = TelemetryLevel.full;
String _uuid = '';
String _version = '';
String _osVersion = '';
bool _initialised = false;
Timer? _flushTimer;

final _buffer = <Map<String, dynamic>>[];

// Dio instance with SSL bypass — telemetry goes through corporate proxy
// which does SSL inspection. We don't want SSL errors to silently drop data.
final _dio = () {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    sendTimeout: const Duration(seconds: 10),
  ));
  (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  };
  return dio;
}();

// ── Public API ────────────────────────────────────────────────────────────────

/// Call once from app startup (after initAppLog).
/// [uuid] — the stable device UUID from prefs.
/// [level] — from stored prefs.
Future<void> initTelemetry({
  required String uuid,
  required TelemetryLevel level,
}) async {
  _uuid = uuid;
  _level = level;

  if (_level == TelemetryLevel.off) return;

  try {
    final info = await PackageInfo.fromPlatform();
    _version = info.version;
  } catch (_) {}

  _osVersion = Platform.operatingSystemVersion;

  _initialised = true;

  // Periodic flush
  _flushTimer?.cancel();
  _flushTimer = Timer.periodic(
    const Duration(seconds: _flushIntervalSec),
    (_) => _flush(),
  );
}

/// Update level at runtime (from Settings toggle).
void setTelemetryLevel(TelemetryLevel level) {
  _level = level;
  if (level == TelemetryLevel.off) {
    _buffer.clear();
    _flushTimer?.cancel();
    _initialised = false;
  } else if (!_initialised) {
    _initialised = true;
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(
      const Duration(seconds: _flushIntervalSec),
      (_) => _flush(),
    );
  }
}

/// Record an operational event (always sent if level != off).
/// [category] — e.g. APP, CORE, UPDATE, PROXY-CFG, WATCHDOG
/// [message]  — human-readable description
/// [extra]    — optional key/value payload (no PII)
void telemetryOp(String category, String message, {Map<String, dynamic>? extra}) {
  if (_level == TelemetryLevel.off) return;
  _enqueue(event: 'op', cat: category, msg: message, extra: extra);
}

/// Record a sanitized connection event (only sent when level == full).
/// [destination] — raw host:port string, will be sanitized before sending
/// [rule]        — matched rule, e.g. "DOMAIN-SUFFIX,anydesk.com,DIRECT"
/// [proxy]       — proxy name used, e.g. "DIRECT", "Squid"
/// [resultMs]    — connection outcome in ms, negative = failure
void telemetryConn(
  String destination,
  String rule,
  String proxy, {
  int? resultMs,
}) {
  if (_level != TelemetryLevel.full) return;
  final sanitized = _sanitizeDest(destination);
  if (sanitized == null) return; // private/suppressed
  _enqueue(
    event: 'conn',
    cat: 'CONN',
    msg: '$sanitized → $proxy',
    extra: {
      'rule': rule,
      if (resultMs != null) 'ms': resultMs,
    },
  );
}

/// Flush remaining buffer immediately. Call on app exit.
Future<void> flushTelemetry() async {
  _flushTimer?.cancel();
  await _flush();
}

/// Current UUID.
String get telemetryUuid => _uuid;

// ── Internal ──────────────────────────────────────────────────────────────────

void _enqueue({
  required String event,
  required String cat,
  required String msg,
  Map<String, dynamic>? extra,
}) {
  if (!_initialised) return;
  _buffer.add({
    'ts':    DateTime.now().toUtc().toIso8601String(),
    'event': event,
    'cat':   cat,
    'msg':   msg,
    if (extra != null) 'extra': extra,
  });
  if (_buffer.length >= _maxBuffer) _flush();
}

Future<void> _flush() async {
  if (_buffer.isEmpty) return;
  if (_telemetryUrl.contains('PLACEHOLDER')) {
    // Not configured yet — drop silently
    _buffer.clear();
    return;
  }

  final batch = List<Map<String, dynamic>>.from(_buffer);
  _buffer.clear();

  final payload = jsonEncode({
    'uuid':    _uuid,
    'version': _version,
    'macos':   _osVersion,
    'events':  batch,
  });

  try {
    // Apps Script redirects POST to script.googleusercontent.com.
    // Dio drops the body on redirect, so we follow the 302 manually.
    final resp = await _dio.post(
      _telemetryUrl,
      data: payload,
      options: Options(
        contentType: 'application/json',
        followRedirects: false,
        validateStatus: (s) => true,
      ),
    );

    if (resp.statusCode == 302 || resp.statusCode == 301) {
      final location = resp.headers.value('location');
      if (location != null) {
        // Re-POST to the redirect target with the same body
        await _dio.post(
          location,
          data: payload,
          options: Options(
            contentType: 'application/json',
            followRedirects: true,
            maxRedirects: 2,
            validateStatus: (s) => true,
          ),
        );
      }
    }
  } catch (e) {
    debugPrint('[Telemetry] flush failed: $e');
  }
}

/// Sanitize a destination host:port for telemetry.
/// Returns null if the destination should be suppressed (private IP, .local, etc).
String? _sanitizeDest(String dest) {
  // Split host and port
  final lastColon = dest.lastIndexOf(':');
  final host = lastColon > 0 ? dest.substring(0, lastColon) : dest;
  final port = lastColon > 0 ? dest.substring(lastColon + 1) : '';

  // Suppress private IPs (RFC1918 + loopback + link-local)
  final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
  final m = ipv4.firstMatch(host);
  if (m != null) {
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2)!);
    if (a == 10 || a == 127 || a == 169 && b == 254 ||
        a == 172 && b >= 16 && b <= 31 ||
        a == 192 && b == 168) {
      return null;
    }
    // Public IP — redact to x.x.x.x
    return 'x.x.x.x${port.isNotEmpty ? ":$port" : ""}';
  }

  // Suppress .local and single-label hostnames
  if (!host.contains('.') || host.endsWith('.local')) return null;

  // Keep only the registered domain (last 2 labels, or 3 for known TLDs like .co.uk)
  final labels = host.split('.');
  final suffix = _registeredDomain(labels);

  return '$suffix${port.isNotEmpty ? ":$port" : ""}';
}

/// Extract the registerable domain from a list of hostname labels.
/// e.g. ['relay', 'abc', 'anydesk', 'com'] → 'anydesk.com'
/// Handles common multi-part TLDs: .co.uk, .com.br, .net.au, etc.
String _registeredDomain(List<String> labels) {
  if (labels.length <= 2) return labels.join('.');

  const multiPartTlds = {
    'co.uk', 'com.au', 'com.br', 'net.au', 'org.uk', 'gov.uk',
    'co.nz', 'co.za', 'com.ar', 'com.mx', 'net.br', 'org.br',
  };

  if (labels.length >= 3) {
    final last2 = '${labels[labels.length - 2]}.${labels[labels.length - 1]}';
    if (multiPartTlds.contains(last2)) {
      return '${labels[labels.length - 3]}.$last2';
    }
  }

  return '${labels[labels.length - 2]}.${labels[labels.length - 1]}';
}
