/// Anonymous usage reporting, off unless the user opts in.
///
/// Three levels, stored in lux_prefs.json:
///
///   off   nothing is sent, and no device id is generated
///   ops   operational events only, with no domain names
///   full  operational events plus domains reduced to their registered name
///
/// Events are buffered and flushed periodically rather than sent per event, so a
/// slow or unreachable endpoint never blocks the app. Nothing here is awaited on
/// a request path.
///
/// The device id is a random UUID with no link to any account or identity. It
/// exists so a user can quote it when reporting a problem.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Endpoint receiving batches. Empty disables sending entirely, which is the
/// default for a build that has not been configured.
const _telemetryUrl = 'https://script.google.com/macros/s/AKfycbwWUZPchIiZgKExLuPOS9LVucUrMSa_PDq2TNpe-FtGpSy4oJz7hWZUTWizxJQVx0C3nQ/exec';

const _flushIntervalSec = 60;
const _maxBuffer = 50;

/// Cap on retained events. Without this a long offline period would grow the
/// buffer without bound.
const _hardCap = 500;

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

String telemetryLevelDescription(TelemetryLevel l) {
  switch (l) {
    case TelemetryLevel.off:
      return 'Nothing is sent. No device id, no events.';
    case TelemetryLevel.ops:
      return 'Operational events only, with no domain names.';
    case TelemetryLevel.full:
      return 'Operational events plus domains reduced to their registered name.';
  }
}

TelemetryLevel _level = TelemetryLevel.off;
String _uuid = '';
String _version = '';
String _osVersion = '';
bool _initialised = false;
Timer? _flushTimer;

final _buffer = <Map<String, dynamic>>[];

/// Whether an endpoint is configured. Without one the UI should say so rather
/// than implying data is being sent.
bool get telemetryConfigured => _telemetryUrl.isNotEmpty;

String get telemetryUuid => _uuid;
TelemetryLevel get telemetryLevel => _level;

Future<void> initTelemetry({
  required String uuid,
  required TelemetryLevel level,
}) async {
  _uuid = uuid;
  _level = level;

  if (_level == TelemetryLevel.off || !telemetryConfigured) return;

  try {
    _version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {}
  _osVersion = Platform.operatingSystemVersion;

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
/// Switching to off drops anything buffered, so disabling reporting cannot leak
/// events recorded while it was on.
void setTelemetryLevel(TelemetryLevel level) {
  _level = level;
  if (level == TelemetryLevel.off) {
    _buffer.clear();
    _flushTimer?.cancel();
    _initialised = false;
    return;
  }
  if (!_initialised && telemetryConfigured) {
    _initialised = true;
    _startTimer();
  }
}

/// Record an operational event. Sent at both ops and full.
void telemetryOp(String category, String message,
    {Map<String, dynamic>? extra}) {
  if (_level == TelemetryLevel.off) return;
  _enqueue(event: 'op', cat: category, msg: message, extra: extra);
}

/// Record a routing decision. Sent only at full, and only after the destination
/// has been reduced to a registered domain.
void telemetryConn(String destination, String rule, String proxy,
    {int? resultMs}) {
  if (_level != TelemetryLevel.full) return;
  final sanitized = _sanitizeDest(destination);
  if (sanitized == null) return;
  _enqueue(
    event: 'conn',
    cat: 'CONN',
    msg: '$sanitized -> $proxy',
    extra: {'rule': rule, if (resultMs != null) 'ms': resultMs},
  );
}

/// Report an error/incident. Always sent (at any level except off) so crashes
/// and broken states are visible even with minimal telemetry.
void telemetryError(String category, String message,
    {Map<String, dynamic>? extra}) {
  if (_level == TelemetryLevel.off) return;
  _enqueue(event: 'error', cat: category, msg: message, extra: extra);
  // Flush immediately — errors should not sit in a buffer for 60s
  _flush();
}

/// Forward a blackbox event to telemetry. Called by the event channel listener
/// when the core emits an incident.
void telemetryBlackboxEvent(String type, String message,
    {Map<String, dynamic>? data}) {
  if (_level == TelemetryLevel.off) return;
  _enqueue(
    event: 'blackbox',
    cat: type,
    msg: message,
    extra: data,
  );
}

Future<void> flushTelemetry() async {
  _flushTimer?.cancel();
  await _flush();
}

void _enqueue({
  required String event,
  required String cat,
  required String msg,
  Map<String, dynamic>? extra,
}) {
  if (!_initialised) return;
  _buffer.add({
    'ts': DateTime.now().toUtc().toIso8601String(),
    'event': event,
    'cat': cat,
    'msg': _redact(msg),
    if (extra != null) 'extra': extra,
  });
  if (_buffer.length >= _maxBuffer) _flush();
  if (_buffer.length > _hardCap) {
    _buffer.removeRange(0, _buffer.length - _hardCap);
  }
}

Future<void> _flush() async {
  if (_buffer.isEmpty || !telemetryConfigured) return;

  // Take a copy and clear immediately, so events recorded during the request are
  // not lost and a failure does not resend the same batch forever.
  final batch = List<Map<String, dynamic>>.from(_buffer);
  _buffer.clear();

  final payload = jsonEncode({
    'uuid': _uuid,
    'version': _version,
    'os': _osVersion,
    'events': batch,
  });

  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final req = await client.postUrl(Uri.parse(_telemetryUrl));
    req.headers.contentType = ContentType.json;
    req.write(payload);
    final resp = await req.close().timeout(const Duration(seconds: 15));
    await resp.drain();
    client.close();
  } catch (e) {
    // Dropped rather than retried. Reporting must never degrade the app, and a
    // retry queue would risk unbounded growth.
    debugPrint('[Telemetry] flush failed, batch dropped: $e');
  }
}

/// Remove anything token-shaped from a message.
String _redact(String msg) => msg.replaceAllMapped(
      RegExp(r'(token=|secret=|password=|Bearer )[^\s&"]+',
          caseSensitive: false),
      (m) => '${m.group(1)}[redacted]',
    );

/// Reduce a destination to something safe to report, or null to suppress it.
///
/// Private addresses, loopback, link-local, .local names and single-label hosts
/// are dropped: they describe the user's own network. Public IPs are masked
/// entirely, and public hostnames are cut back to the registered domain, so
/// "relay.abc.anydesk.com" reports as "anydesk.com".
String? _sanitizeDest(String dest) {
  final lastColon = dest.lastIndexOf(':');
  final host = lastColon > 0 ? dest.substring(0, lastColon) : dest;
  final port = lastColon > 0 ? dest.substring(lastColon + 1) : '';

  final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
  final m = ipv4.firstMatch(host);
  if (m != null) {
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2)!);
    final isPrivate = a == 10 ||
        a == 127 ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
    if (isPrivate) return null;
    return 'x.x.x.x${port.isNotEmpty ? ":$port" : ""}';
  }

  if (!host.contains('.') || host.endsWith('.local')) return null;

  final suffix = _registeredDomain(host.split('.'));
  return '$suffix${port.isNotEmpty ? ":$port" : ""}';
}

/// Reduce hostname labels to the registered domain, handling the common
/// multi-part suffixes so "example.co.uk" is not cut to "co.uk".
String _registeredDomain(List<String> labels) {
  if (labels.length <= 2) return labels.join('.');

  const multiPartTlds = {
    'co.uk', 'com.au', 'com.br', 'net.au', 'org.uk', 'gov.uk',
    'co.nz', 'co.za', 'com.ar', 'com.mx', 'net.br', 'org.br',
    'co.jp', 'co.kr', 'com.cn', 'com.tr', 'co.in',
  };

  final last2 = '${labels[labels.length - 2]}.${labels[labels.length - 1]}';
  if (multiPartTlds.contains(last2) && labels.length >= 3) {
    return '${labels[labels.length - 3]}.$last2';
  }
  return last2;
}
