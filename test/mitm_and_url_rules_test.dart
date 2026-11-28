import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/model/app.dart';
import 'package:lux/pages/log_page.dart';
import 'package:lux/pages/rules_page.dart';
import 'package:lux/pages/settings_page.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/t_text.dart';
import 'package:provider/provider.dart';

import 'test_env.dart';

class _FakeMitmCoreManager extends CoreManager {
  Setting setting;
  MitmStatus mitmStatus;
  MitmTelemetry mitmTelemetry;
  List<CustomizedRuleItem> customRules;
  bool installCalled = false;
  bool enableCalled = false;

  _FakeMitmCoreManager({
    Setting? setting,
    MitmStatus? mitmStatus,
    MitmTelemetry? mitmTelemetry,
    List<CustomizedRuleItem>? customRules,
  })  : setting = setting ?? const Setting(),
        mitmStatus = mitmStatus ?? const MitmStatus(),
        mitmTelemetry = mitmTelemetry ?? const MitmTelemetry(),
        customRules = customRules ?? const [],
        super(
          '127.0.0.1:0',
          null,
          'test-token',
          () {},
          connectivityStream: const Stream.empty(),
          checkConnectivity: () async => const [],
        );

  @override
  Future<Setting> getSetting() async => setting;

  @override
  Future<void> saveSetting(Setting updated) async {
    setting = updated;
  }

  @override
  Future<List<String>> getSettingInterfaces() async => const ['en0'];

  @override
  Future<MitmStatus> getMitmStatus() async => mitmStatus;

  @override
  Future<MitmTelemetry> getMitmTelemetry() async => mitmTelemetry;

  @override
  Future<MitmStatus> installMitmCA() async {
    installCalled = true;
    mitmStatus = MitmStatus(
      enabled: mitmStatus.enabled,
      active: mitmStatus.enabled,
      scope: mitmStatus.scope,
      caExists: true,
      caTrusted: true,
      caFingerprint: 'AA:BB:CC:DD',
    );
    return mitmStatus;
  }

  @override
  Future<MitmStatus> updateMitmConfig({
    bool? enabled,
    String? scope,
    bool? autoSplice,
    bool? protectRejectRules,
    bool? redactUrlQuery,
    List<String>? bypassDomains,
  }) async {
    if (enabled == true) enableCalled = true;
    final nextEnabled = enabled ?? mitmStatus.enabled;
    mitmStatus = MitmStatus(
      enabled: nextEnabled,
      active: nextEnabled && mitmStatus.caTrusted,
      scope: scope ?? mitmStatus.scope,
      autoSplice: autoSplice ?? mitmStatus.autoSplice,
      protectRejectRules: protectRejectRules ?? mitmStatus.protectRejectRules,
      redactUrlQuery: redactUrlQuery ?? mitmStatus.redactUrlQuery,
      caExists: true,
      caTrusted: mitmStatus.caTrusted,
      caFingerprint: mitmStatus.caFingerprint,
    );
    return mitmStatus;
  }

  @override
  Future<List<CustomizedRuleItem>> getCustomizedRules() async => customRules;

  @override
  Future<List<RuleGroup>> getRuleGroups() async => const [];

  @override
  Future<ProxyList> getProxyList() async => ProxyList(const [], '');

  @override
  Future<RuleDiagnostics> getRuleDiagnostics() async =>
      const RuleDiagnostics(shadowed: [], broken: []);
}

Widget _wrapWithAppState(Widget child, {required bool advancedMode}) {
  final model = AppStateModel(ThemeMode.dark, const Locale('en'));
  model.updateAdvancedMode(advancedMode);
  return ChangeNotifierProvider<AppStateModel>.value(
    value: model,
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(extensions: const [LuxTokens.dark]),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    installTestEnv();
    await TranslationCache.load();
  });

  test('Setting defaults sendAppIdentity to true and round-trips HMAC secret',
      () {
    final sDefault = Setting.fromJson(const {'mode': 'mixed'});
    expect(sDefault.sendAppIdentity, isTrue);
    expect(sDefault.appIdentitySecret, isEmpty);

    final sCustom = Setting.fromJson(const {
      'mode': 'mixed',
      'sendAppIdentity': false,
      'appIdentitySecret': 'my-hmac-key',
    });
    expect(sCustom.sendAppIdentity, isFalse);
    expect(sCustom.appIdentitySecret, 'my-hmac-key');
    expect(sCustom.toJson()['sendAppIdentity'], isFalse);
    expect(sCustom.toJson()['appIdentitySecret'], 'my-hmac-key');
  });

  test('MitmStatus and MitmTelemetry parse core JSON accurately', () {
    final st = MitmStatus.fromJson(jsonDecode('''
      {
        "enabled": true,
        "active": true,
        "scope": "targeted",
        "autoSplice": true,
        "protectRejectRules": true,
        "redactUrlQuery": true,
        "caExists": true,
        "caTrusted": true,
        "caSubject": "Lux Local MITM Root CA (A1B2C3)",
        "caFingerprint": "AA:BB:CC",
        "targetedHosts": ["youtube.com"],
        "protectedRejectHosts": ["youtube.com"],
        "hasUnanchoredRules": false,
        "activeAutoSpliceCount": 1
      }
    ''') as Map<String, dynamic>);
    expect(st.active, isTrue);
    expect(st.scope, 'targeted');
    expect(st.targetedHosts, ['youtube.com']);
    expect(st.activeAutoSpliceCount, 1);

    final tel = MitmTelemetry.fromJson(jsonDecode('''
      {
        "enabled": true,
        "activeAutoSplices": [
          {
            "host": "api.slack.com",
            "process": "Slack",
            "fails": 2,
            "spliceHits": 5,
            "ttlRemainingSeconds": 3600
          }
        ]
      }
    ''') as Map<String, dynamic>);
    expect(tel.activeAutoSplices.length, 1);
    expect(tel.activeAutoSplices.first.process, 'Slack');
    expect(tel.activeAutoSplices.first.host, 'api.slack.com');
  });

  test('LogEntry recognizes MITM, AUTO_SPLICE, and redacted URLs', () {
    final mitmAllow = LogEntry(
      level: 'info',
      time: '2026-11-28T12:00:00Z',
      message:
          '[TCP], [MITM] [H2] GET https://youtube.com/watch?… [Google Chrome] → DIRECT (URL-PREFIX:https://youtube.com/watch)',
    );
    expect(mitmAllow.eventBadge?.label, 'MITM');
    expect(mitmAllow.extractedUrl, 'https://youtube.com/watch');
    expect(mitmAllow.extractedHost, 'youtube.com');

    final autoSplice = LogEntry(
      level: 'warning',
      time: '2026-11-28T12:00:01Z',
      message:
          '[TCP], [AUTO_SPLICE] api.slack.com [Slack] — auto-spliced after 2 cert rejections (TTL 120m)',
    );
    expect(autoSplice.eventBadge?.label, 'AUTO-SPLICE');

    final mitmUpstream403 = LogEntry(
      level: 'warning',
      time: '2026-11-28T12:00:02Z',
      message:
          '[TCP], [DENY] [PROXY_DENIED] [HTTP 403] [MITM] GET https://blocked.corp.test/secret?… [curl] via PROXY (corp) — upstream proxy returned 403 Forbidden [ERR_ACCESS_DENIED]',
    );
    expect(mitmUpstream403.isProxyDenied, isTrue);
    expect(mitmUpstream403.eventBadge?.label, '403 DENY');
    expect(mitmUpstream403.extractedUrl, 'https://blocked.corp.test/secret');
    expect(mitmUpstream403.extractedHost, 'blocked.corp.test');
  });

  testWidgets('MITM settings stay hidden in Simple Mode and appear in Advanced Mode',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final mgr = _FakeMitmCoreManager(
      mitmStatus: const MitmStatus(
        enabled: false,
        active: false,
        scope: 'targeted',
        caExists: true,
        caTrusted: false,
        caFingerprint: 'AA:BB:CC:DD:EE:FF',
      ),
    );
    addTearDown(mgr.dispose);

    // Simple Mode: MITM and X-Lux-App controls must NOT clutter Network settings.
    await tester.pumpWidget(_wrapWithAppState(
      SettingsPage(coreManager: mgr, initialCategory: 'network'),
      advancedMode: false,
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-mitm-section')), findsNothing);
    expect(find.text('Send app identity to proxy'), findsNothing);

    // Advanced Mode: MITM controls + Send app identity appear cleanly.
    await tester.pumpWidget(_wrapWithAppState(
      SettingsPage(coreManager: mgr, initialCategory: 'network'),
      advancedMode: true,
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-mitm-section')), findsOneWidget);
    expect(find.byKey(const Key('settings-mitm-install-ca-btn')), findsOneWidget);
    expect(find.text('Send app identity to proxy'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('RulesPage shows inline MITM banner when HTTPS URL rules exist and MITM is off',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final mgr = _FakeMitmCoreManager(
      mitmStatus: const MitmStatus(enabled: false, active: false, caTrusted: false),
      customRules: const [
        CustomizedRuleItem(
          id: 'r1',
          slug: 'url-prefix-youtube',
          groupId: '',
          ruleType: 'URL-PREFIX',
          payload: 'https://youtube.com/shorts/',
          policy: 'REJECT',
          disabled: false,
          raw: 'URL-PREFIX,https://youtube.com/shorts/,REJECT',
        ),
      ],
    );
    addTearDown(mgr.dispose);

    await tester.pumpWidget(_wrapWithAppState(
      RulesPage(coreManager: mgr),
      advancedMode: true,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('rules-mitm-notice-banner')), findsOneWidget);
    expect(find.byKey(const Key('rules-mitm-enable-btn')), findsOneWidget);

    // Tapping "Install CA & Enable" installs CA, enables MITM, and hides banner!
    await tester.tap(find.byKey(const Key('rules-mitm-enable-btn')));
    await tester.pumpAndSettle();

    expect(mgr.installCalled, isTrue);
    expect(mgr.enableCalled, isTrue);
    expect(find.byKey(const Key('rules-mitm-notice-banner')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
