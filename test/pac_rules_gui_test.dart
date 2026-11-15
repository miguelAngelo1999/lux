import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/widget/pac_rules_dialog.dart';

class MockPacCoreManager extends Fake implements CoreManager {
  @override
  Future<PACRulesResult> getPACRules(String proxyId) async {
    return const PACRulesResult(
      pacUrl: 'http://wpad.corp.local/wpad.dat',
      rawScript: '''
function FindProxyForURL(url, host) {
    if (dnsDomainIs(host, "corp.local")) return "DIRECT";
    return "PROXY 10.8.0.1:8082; DIRECT";
}
''',
      upstream: 'PROXY 10.8.0.1:8082; DIRECT',
      rules: [
        PACRuleItem(
          ruleType: 'DOMAIN-SUFFIX',
          payload: 'corp.local',
          policy: 'DIRECT',
          function: 'dnsDomainIs',
        ),
      ],
    );
  }

  @override
  Future<PACTestResult> testPACUrl(String proxyId, String url) async {
    if (url.contains('corp.local')) {
      return const PACTestResult(
        directive: 'DIRECT',
        action: 'DIRECT',
        upstream: '',
      );
    }
    return const PACTestResult(
      directive: 'PROXY 10.8.0.1:8082; DIRECT',
      action: 'PROXY',
      upstream: '10.8.0.1:8082',
    );
  }
}

void main() {
  group('PAC Models Test', () {
    test('PACRuleItem parses json correctly', () {
      final json = {
        'ruleType': 'DOMAIN-SUFFIX',
        'payload': 'example.com',
        'policy': 'DIRECT',
        'function': 'dnsDomainIs',
      };
      final item = PACRuleItem.fromJson(json);
      expect(item.ruleType, 'DOMAIN-SUFFIX');
      expect(item.payload, 'example.com');
      expect(item.policy, 'DIRECT');
      expect(item.function, 'dnsDomainIs');
    });

    test('PACRulesResult parses json with script and upstream', () {
      final json = {
        'pacUrl': 'http://wpad/wpad.dat',
        'rawScript': 'function FindProxyForURL() {}',
        'upstream': 'PROXY 10.8.0.1:8082',
        'rules': [
          {
            'ruleType': 'IP-CIDR',
            'payload': '10.0.0.0/8',
            'policy': 'DIRECT',
          }
        ],
      };
      final result = PACRulesResult.fromJson(json);
      expect(result.pacUrl, 'http://wpad/wpad.dat');
      expect(result.rawScript, 'function FindProxyForURL() {}');
      expect(result.upstream, 'PROXY 10.8.0.1:8082');
      expect(result.rules.length, 1);
      expect(result.rules.first.payload, '10.0.0.0/8');
    });

    test('PACTestResult parses json correctly', () {
      final json = {
        'directive': 'PROXY 10.8.0.1:8082; DIRECT',
        'action': 'PROXY',
        'upstream': '10.8.0.1:8082',
      };
      final result = PACTestResult.fromJson(json);
      expect(result.directive, 'PROXY 10.8.0.1:8082; DIRECT');
      expect(result.action, 'PROXY');
      expect(result.upstream, '10.8.0.1:8082');
    });
  });

  group('PacRulesDialog Widget Test', () {
    testWidgets('renders PAC rules dialog, tabs, and rules table', (tester) async {
      final mock = MockPacCoreManager();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PacRulesDialog(
              coreManager: mock,
              proxyId: 'test-proxy-1',
              proxyName: 'Corp PAC Proxy',
              initialPacUrl: 'http://wpad.corp.local/wpad.dat',
            ),
          ),
        ),
      );

      // Initial load pump
      await tester.pumpAndSettle();

      // Check header and proxy name
      expect(find.text('Active PAC Rules'), findsOneWidget);
      expect(find.text('Corp PAC Proxy'), findsOneWidget);

      // Check PAC URL in info bar
      expect(find.text('http://wpad.corp.local/wpad.dat'), findsOneWidget);

      // Check rule displayed in rules table
      expect(find.text('corp.local'), findsOneWidget);
      expect(find.text('DIRECT'), findsWidgets);
      expect(find.text('dnsDomainIs(...)'), findsOneWidget);

      // Switch to Test URL tab
      await tester.tap(find.text('Test URL'));
      await tester.pumpAndSettle();

      expect(find.text('google.com'), findsOneWidget);
      expect(find.text('Resolve'), findsOneWidget);

      // Test a URL
      await tester.tap(find.text('google.com'));
      await tester.pumpAndSettle();

      // Result card should show PROXY and upstream
      expect(find.text('PROXY'), findsWidgets);
      expect(find.text('10.8.0.1:8082'), findsWidgets);

      // Switch to Raw Script tab
      await tester.tap(find.text('Raw Script'));
      await tester.pumpAndSettle();

      expect(find.textContaining('function FindProxyForURL'), findsOneWidget);
      expect(find.text('Copy Script'), findsOneWidget);
    });
  });
}
