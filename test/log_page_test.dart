import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/model/app.dart';
import 'package:lux/pages/log_page.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/t_text.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'test_env.dart';

class _FakeWebSocketSink implements WebSocketSink {
  final StreamController<dynamic> _ctrl;
  _FakeWebSocketSink(this._ctrl);
  @override
  void add(dynamic data) => _ctrl.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _ctrl.addError(error, stackTrace);
  @override
  Future addStream(Stream stream) => _ctrl.addStream(stream);
  @override
  Future close([int? closeCode, String? closeReason]) => _ctrl.close();
  @override
  Future get done => _ctrl.done;
}

class _FakeWebSocketChannel implements WebSocketChannel {
  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast();
  final StreamController<dynamic> _outgoing =
      StreamController<dynamic>.broadcast();

  void pushBatch(List<Map<String, dynamic>> entries) {
    final encoded = entries.map((e) => json.encode(e)).toList();
    _incoming.add(json.encode(encoded));
  }

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeWebSocketSink(_outgoing);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> dispose() async {
    await _incoming.close();
    await _outgoing.close();
  }
}

class _FakeLogCoreManager extends CoreManager {
  final _FakeWebSocketChannel channel;
  final List<String> addedRules = [];

  _FakeLogCoreManager(this.channel, AppStateModel appState)
      : super(
          '127.0.0.1:1',
          null,
          'test-token',
          _noop,
          appState: appState,
          connectivityStream: const Stream.empty(),
          checkConnectivity: () async => [ConnectivityResult.wifi],
        );

  static void _noop() {}

  @override
  Future<WebSocketChannel> getLogChannel() async => channel;

  @override
  Future<ProxyList> getProxyList() async => ProxyList(
        [
          ProxyItem.fromJson({
            'id': 'p1',
            'name': 'Office Proxy',
            'type': 'http',
            'server': '10.8.0.1',
            'port': 8082,
          }),
        ],
        'p1',
      );

  @override
  Future<void> addCustomizedRules(List<String> rules) async {
    addedRules.addAll(rules);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    installTestEnv();
    await TranslationCache.load();
  });

  group('LogEntry classification and host extraction', () {
    test('detects upstream HTTP 403/407/502 denials and extracts host', () {
      final e403 = LogEntry(
        level: 'warning',
        time: '2026-11-27T18:00:00Z',
        message:
            '[TCP], [DENY] [PROXY_DENIED] [HTTP 403] youtube.com:443 [Chrome] via PROXY (Office) — upstream proxy Office (10.8.0.1:8082) denied connection (HTTP 403 Forbidden) [ERR_ACCESS_DENIED 0]',
      );
      expect(e403.isProxyDenied, isTrue);
      expect(e403.isRuleBlocked, isFalse);
      expect(e403.eventBadge?.label, '403 DENY');
      expect(e403.extractedHost, 'youtube.com');

      final e407 = LogEntry(
        level: 'warning',
        time: '2026-11-27T18:00:00Z',
        message:
            '[TCP], [DENY] [PROXY_DENIED] [HTTP 407] example.com:443 via PROXY — upstream proxy authentication required (HTTP 407)',
      );
      expect(e407.isProxyDenied, isTrue);
      expect(e407.eventBadge?.label, '407 AUTH');
      expect(e407.extractedHost, 'example.com');

      final eReset = LogEntry(
        level: 'warning',
        time: '2026-11-27T18:00:00Z',
        message:
            '[TCP], [PROXY_RESET] tiktok.com:443 (1.2.3.4) [Safari] via PROXY (Office) — upstream closed right after handshake (possible SNI/TLS block, ↑517B ↓0B)',
      );
      expect(eReset.isProxyDenied, isTrue);
      expect(eReset.eventBadge?.label, 'TLS DROP');
      expect(eReset.extractedHost, 'tiktok.com');
    });

    test('distinguishes local RULE_REJECT from upstream proxy denial', () {
      final localDeny = LogEntry(
        level: 'warning',
        time: '2026-11-27T18:00:00Z',
        message:
            '[TCP], [DENY] [RULE_REJECT] ads.tracker.com:443 [Chrome] matched DOMAIN-SUFFIX:tracker.com → REJECT',
      );
      expect(localDeny.isProxyDenied, isFalse);
      expect(localDeny.isRuleBlocked, isTrue);
      expect(localDeny.eventBadge?.label, 'BLOCKED');
      expect(localDeny.extractedHost, 'ads.tracker.com');
    });

    test('extracts host from plain HTTP proxy denial URL', () {
      final plainHttp = LogEntry(
        level: 'warning',
        time: '2026-11-27T18:00:00Z',
        message:
            '[TCP], [DENY] [PROXY_DENIED] [HTTP 403] GET http://blocked.org/video/123 — upstream proxy returned 403 Forbidden [ERR_ACCESS_DENIED]',
      );
      expect(plainHttp.isProxyDenied, isTrue);
      expect(plainHttp.extractedHost, 'blocked.org');
    });
  });

  testWidgets('LogPage filters Proxy Denied entries and adds 1-click Direct rule',
      (tester) async {
    final ws = _FakeWebSocketChannel();
    final appState = AppStateModel(ThemeMode.dark, const Locale('en'));
    final core = _FakeLogCoreManager(ws, appState);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: LogPage(coreManager: core)),
    ));
    await tester.pumpAndSettle();

    ws.pushBatch([
      {
        'level': 'info',
        'time': 1795800000000,
        'msg': '[TCP], github.com:443 [git] → PROXY (Office)',
      },
      {
        'level': 'warning',
        'time': 1795800001000,
        'msg':
            '[TCP], [DENY] [PROXY_DENIED] [HTTP 403] blocked.example.com:443 [Chrome] via PROXY (Office) — upstream proxy Office denied connection (HTTP 403 Forbidden) [ERR_ACCESS_DENIED]',
      },
      {
        'level': 'warning',
        'time': 1795800002000,
        'msg':
            '[TCP], [DENY] [RULE_REJECT] ads.bad.com:443 matched DOMAIN-SUFFIX:bad.com → REJECT',
      },
    ]);
    await tester.pumpAndSettle();

    // All 3 visible initially
    expect(find.textContaining('github.com:443'), findsOneWidget);
    expect(find.textContaining('blocked.example.com:443'), findsOneWidget);
    expect(find.textContaining('ads.bad.com:443'), findsOneWidget);
    expect(find.text('403 DENY'), findsOneWidget);
    expect(find.text('BLOCKED'), findsOneWidget);

    // Filter to Proxy Denied only
    await tester.tap(find.byKey(const Key('log-filter-proxy-denied')));
    await tester.pumpAndSettle();
    expect(find.textContaining('github.com:443'), findsNothing);
    expect(find.textContaining('ads.bad.com:443'), findsNothing);
    expect(find.textContaining('blocked.example.com:443'), findsOneWidget);

    // Trigger 1-click "+ Rule" → Always Direct
    await tester.tap(find.byType(PopupMenuButton<(String, String)>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Always Direct'));
    await tester.pumpAndSettle();

    expect(core.addedRules, ['DOMAIN-SUFFIX,blocked.example.com,DIRECT']);

    // Unmount LogPage before closing the fake stream so onDone cannot schedule a retry timer.
    await tester.pumpWidget(const SizedBox.shrink());
    await ws.dispose();
  });
}
