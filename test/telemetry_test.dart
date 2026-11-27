import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lux/util/telemetry.dart';

void main() {
  setUp(() {
    resetTelemetryForTest();
  });

  tearDown(() {
    resetTelemetryForTest();
  });

  test('off mode sends nothing and switching to off drops buffered events',
      () async {
    final payloads = <Map<String, dynamic>>[];
    telemetryPostOverride = (raw) async {
      payloads.add(jsonDecode(raw) as Map<String, dynamic>);
      return (ok: true, statusCode: 302, route: 'test', error: null);
    };

    await initTelemetry(
      uuid: '',
      level: TelemetryLevel.off,
      versionOverride: '1.50.133',
      osVersionOverride: 'macos 27.2',
    );
    telemetryOp('connect', 'should not queue');
    telemetryError('crash', 'should not queue');
    await flushTelemetry();
    expect(payloads, isEmpty);

    // Enable -> enqueue -> switch back to off -> buffered events must be cleared
    await setTelemetryLevel(TelemetryLevel.full, uuid: 'u-1');
    telemetryOp('connect', 'queued before off');
    telemetryConn('api.github.com:443', 'DOMAIN-SUFFIX,github.com', 'CorpProxy');
    await setTelemetryLevel(TelemetryLevel.off);
    await flushTelemetry();
    expect(payloads, isEmpty);
  });

  test('runtime opt-in populates uuid, version, and os immediately', () async {
    final payloads = <Map<String, dynamic>>[];
    telemetryPostOverride = (raw) async {
      payloads.add(jsonDecode(raw) as Map<String, dynamic>);
      return (ok: true, statusCode: 302, route: 'proxy', error: null);
    };

    await initTelemetry(
      uuid: '',
      level: TelemetryLevel.off,
      versionOverride: '1.50.133',
      osVersionOverride: 'macos 27.2',
    );
    await setTelemetryLevel(TelemetryLevel.ops, uuid: 'abc-123');
    final res = await sendTestTelemetry();

    expect(res.ok, isTrue);
    expect(res.statusCode, 302);
    expect(payloads, hasLength(1));
    final body = payloads.single;
    expect(body['uuid'], 'abc-123');
    expect(body['version'], '1.50.133');
    expect(body['os'], 'macos 27.2');
    final events = body['events'] as List;
    expect(events.any((e) => e['cat'] == 'TEST'), isTrue);
    expect(telemetryStatsNotifier.value.sentCount, events.length);
    expect(telemetryStatsNotifier.value.lastRoute, 'proxy');
    expect(telemetryStatsNotifier.value.lastError, isNull);
  });

  test('telemetryCrash redacts credentials and deduplicates identical bursts',
      () async {
    final payloads = <Map<String, dynamic>>[];
    telemetryPostOverride = (raw) async {
      payloads.add(jsonDecode(raw) as Map<String, dynamic>);
      return (ok: true, statusCode: 302, route: 'direct', error: null);
    };

    await initTelemetry(
      uuid: 'u-crash',
      level: TelemetryLevel.ops,
      versionOverride: '1.50.133',
      osVersionOverride: 'windows 11',
    );

    final stack = StackTrace.fromString(
      '#0 Widget.build (package:lux/pages/proxies_page.dart:42:5)\n'
      '#1 ComponentElement.performRebuild (package:flutter/widgets.dart:10:2)',
    );
    final err = StateError(
      'failed http://alice:supersecret@10.8.0.1:8082?token=abc123&password=xyz',
    );
    telemetryCrash('flutter-error', err, stack);
    telemetryCrash('flutter-error', err, stack); // duplicate within 5m
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(payloads, hasLength(1));
    final ev = (payloads.single['events'] as List).single as Map;
    expect(ev['event'], 'error');
    expect(ev['cat'], 'flutter-error');
    final msg = ev['msg'] as String;
    expect(msg, isNot(contains('supersecret')));
    expect(msg, isNot(contains('abc123')));
    expect(msg, isNot(contains('xyz')));
    expect(msg, contains('[redacted]'));
  });

  test('full-mode telemetryConn sanitizes destinations, strips proxy names, and deduplicates hits',
      () async {
    final payloads = <Map<String, dynamic>>[];
    telemetryPostOverride = (raw) async {
      payloads.add(jsonDecode(raw) as Map<String, dynamic>);
      return (ok: true, statusCode: 302, route: 'proxy', error: null);
    };

    await initTelemetry(
      uuid: 'u-full',
      level: TelemetryLevel.full,
      versionOverride: '1.50.133',
      osVersionOverride: 'macos 27.2',
    );

    // Private/internal addresses must be dropped completely.
    telemetryConn('10.8.0.1:8082', 'IP-CIDR,10.0.0.0/8', 'DIRECT');
    telemetryConn('192.168.1.5:443', 'MATCH', 'DIRECT');
    telemetryConn('127.0.0.1:8000', 'MATCH', 'DIRECT');
    telemetryConn('100.64.1.2:443', 'MATCH', 'DIRECT');
    telemetryConn('[::1]:443', 'MATCH', 'DIRECT');
    telemetryConn('printer.local:631', 'MATCH', 'DIRECT');
    telemetryConn('intranet.corp:443', 'MATCH', 'DIRECT');

    // Public destinations must reduce to registered domain / masked IP, strip
    // corporate proxy names, and roll up duplicate hits.
    telemetryConn('api.sub.github.com:443', 'DOMAIN-SUFFIX,github.com', 'Arautos Proxy');
    telemetryConn('raw.github.com:443', 'DOMAIN-SUFFIX,github.com', 'Arautos Proxy');
    telemetryConn('sub.portal.example.com.br:443', 'DOMAIN-SUFFIX,sub.portal.example.com.br', 'DIRECT');
    telemetryConn('1.1.1.1:443', 'FINAL', 'REJECT');

    await flushTelemetry();
    expect(payloads, hasLength(1));
    final events = (payloads.single['events'] as List).cast<Map<String, dynamic>>();
    expect(events, hasLength(3));

    final github = events.firstWhere((e) => (e['msg'] as String).startsWith('github.com:443'));
    expect(github['msg'], 'github.com:443 -> PROXY');
    expect((github['extra'] as Map)['hits'], 2);

    final br = events.firstWhere((e) => (e['msg'] as String).startsWith('example.com.br:443'));
    expect(br['msg'], 'example.com.br:443 -> DIRECT');

    final pubIp = events.firstWhere((e) => (e['msg'] as String).startsWith('x.x.x.x:443'));
    expect(pubIp['msg'], 'x.x.x.x:443 -> REJECT');

    // Same domain within the 10-minute dedupe window should not re-emit immediately.
    telemetryConn('api.github.com:443', 'DOMAIN-SUFFIX,github.com', 'Arautos Proxy');
    await flushTelemetry();
    expect(payloads, hasLength(1));
  });

  test('forwardBlackboxIncidents seeds watermark on first run then forwards only new incidents',
      () async {
    final payloads = <Map<String, dynamic>>[];
    telemetryPostOverride = (raw) async {
      payloads.add(jsonDecode(raw) as Map<String, dynamic>);
      return (ok: true, statusCode: 302, route: 'proxy', error: null);
    };

    await initTelemetry(
      uuid: 'u-bb',
      level: TelemetryLevel.ops,
      versionOverride: '1.50.133',
      osVersionOverride: 'macos 27.2',
    );

    final tmpDir = await Directory.systemTemp.createTemp('lux_telem_bb_');
    addTearDown(() => tmpDir.delete(recursive: true));
    final bbFile = File('${tmpDir.path}/blackbox.json');
    await bbFile.writeAsString(jsonEncode([
      {
        'time': '2026-11-27T10:00:00Z',
        'type': 'connectivity-lost',
        'message': 'old incident should not replay',
      },
      {
        'time': '2026-11-27T10:05:00Z',
        'type': 'manager-started',
        'message': 'proxy manager started',
      },
    ]));

    String? watermark;
    final firstCount = await forwardBlackboxIncidents(
      tmpDir.path,
      readWatermark: () async => watermark,
      writeWatermark: (v) async => watermark = v,
    );
    expect(firstCount, 0);
    expect(watermark, '2026-11-27T10:05:00Z');
    expect(payloads, isEmpty);

    // Append one routine entry (ignored) and one real incident (forwarded).
    await bbFile.writeAsString(jsonEncode([
      {
        'time': '2026-11-27T10:05:00Z',
        'type': 'manager-started',
        'message': 'proxy manager started',
      },
      {
        'time': '2026-11-27T10:10:00Z',
        'type': 'manager-stopped',
        'message': 'clean shutdown',
      },
      {
        'time': '2026-11-27T10:12:00Z',
        'type': 'proxy-auth-rejected',
        'message': 'HTTP 407 from upstream',
      },
    ]));

    final secondCount = await forwardBlackboxIncidents(
      tmpDir.path,
      readWatermark: () async => watermark,
      writeWatermark: (v) async => watermark = v,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(secondCount, 1);
    expect(watermark, '2026-11-27T10:12:00Z');
    expect(payloads, hasLength(1));
    final ev = (payloads.single['events'] as List).single as Map;
    expect(ev['event'], 'blackbox');
    expect(ev['cat'], 'proxy-auth-rejected');
  });

  test('single transient flush failure re-queues once and succeeds on retry',
      () async {
    var attempts = 0;
    telemetryPostOverride = (_) async {
      attempts++;
      if (attempts == 1) {
        return (
          ok: false,
          statusCode: null,
          route: 'proxy+direct',
          error: 'SocketException: offline',
        );
      }
      return (ok: true, statusCode: 302, route: 'proxy', error: null);
    };

    await initTelemetry(
      uuid: 'u-retry',
      level: TelemetryLevel.ops,
      versionOverride: '1.50.133',
      osVersionOverride: 'macos 27.2',
    );
    telemetryOp('connect', 'tunnel started');

    await flushTelemetry();
    expect(telemetryStatsNotifier.value.failedCount, 1);
    expect(telemetryStatsNotifier.value.sentCount, 0);
    expect(telemetryStatsNotifier.value.bufferedCount, 1);

    await flushTelemetry();
    expect(telemetryStatsNotifier.value.sentCount, 1);
    expect(telemetryStatsNotifier.value.bufferedCount, 0);
    expect(telemetryStatsNotifier.value.lastError, isNull);
  });
}
