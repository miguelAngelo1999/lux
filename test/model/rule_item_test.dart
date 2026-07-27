import 'package:flutter_test/flutter_test.dart';
import 'package:lux/model/rule_item.dart';

void main() {
  group('RuleItem.parse()', () {
    // Requirement 8.1 — populate all fields from a valid rule string
    test('parses a 3-field rule correctly', () {
      final item = RuleItem.parse('DOMAIN-SUFFIX,example.com,DIRECT');
      expect(item.ruleType, 'DOMAIN-SUFFIX');
      expect(item.match, 'example.com');
      expect(item.action, 'DIRECT');
      expect(item.protocol, isNull); // Requirement 8.3 — null when absent
      expect(item.isDisabled, isFalse);
      expect(item.raw, 'DOMAIN-SUFFIX,example.com,DIRECT');
    });

    // Requirement 8.2 — protocol field set to normalized lowercase
    test('parses a 4-field rule with tcp protocol', () {
      final item = RuleItem.parse('DOMAIN-SUFFIX,whatsapp.net,PROXY,tcp');
      expect(item.ruleType, 'DOMAIN-SUFFIX');
      expect(item.match, 'whatsapp.net');
      expect(item.action, 'PROXY');
      expect(item.protocol, 'tcp');
      expect(item.isDisabled, isFalse);
    });

    // Requirement 8.2 — protocol field normalized to lowercase
    test('parses a 4-field rule with udp protocol', () {
      final item = RuleItem.parse('DOMAIN-SUFFIX,whatsapp.net,DIRECT,udp');
      expect(item.protocol, 'udp');
    });

    // Requirement 8.2 — case-insensitive normalization to lowercase
    test('normalizes protocol field to lowercase', () {
      final item = RuleItem.parse('DOMAIN,foo.com,DIRECT,TCP');
      expect(item.protocol, 'tcp');
    });

    test('normalizes protocol field from mixed case', () {
      final item = RuleItem.parse('DOMAIN,foo.com,DIRECT,Udp');
      expect(item.protocol, 'udp');
    });

    // Requirement 8.1 — ruleType normalized to uppercase
    test('normalizes ruleType to uppercase', () {
      final item = RuleItem.parse('domain-suffix,foo.com,DIRECT');
      expect(item.ruleType, 'DOMAIN-SUFFIX');
    });

    // Requirement 8.6 — disabled rules: isDisabled=true, '#' preserved in raw
    test('parses a disabled rule with # prefix', () {
      final item = RuleItem.parse('#DOMAIN,disabled.example.com,REJECT');
      expect(item.isDisabled, isTrue);
      expect(item.raw, '#DOMAIN,disabled.example.com,REJECT');
      expect(item.ruleType, 'DOMAIN');
      expect(item.match, 'disabled.example.com');
      expect(item.action, 'REJECT');
      expect(item.protocol, isNull);
    });

    test('parses a disabled 4-field rule with # prefix', () {
      final item = RuleItem.parse('#DOMAIN-SUFFIX,whatsapp.net,DIRECT,udp');
      expect(item.isDisabled, isTrue);
      expect(item.raw, '#DOMAIN-SUFFIX,whatsapp.net,DIRECT,udp');
      expect(item.protocol, 'udp');
    });

    // DST-PORT rule type
    test('parses a DST-PORT rule', () {
      final item = RuleItem.parse('DST-PORT,993,LP');
      expect(item.ruleType, 'DST-PORT');
      expect(item.match, '993');
      expect(item.action, 'LP');
      expect(item.protocol, isNull);
    });

    test('parses a DST-PORT rule with protocol', () {
      final item = RuleItem.parse('DST-PORT,5060,DIRECT,udp');
      expect(item.ruleType, 'DST-PORT');
      expect(item.match, '5060');
      expect(item.action, 'DIRECT');
      expect(item.protocol, 'udp');
    });

    // Named proxy action
    test('parses a rule with named proxy action', () {
      final item = RuleItem.parse('IP-CIDR,17.0.0.0/8,LP,udp');
      expect(item.action, 'LP');
      expect(item.protocol, 'udp');
    });

    // Malformed rule (fewer than 3 fields)
    test('handles malformed rule with fewer than 3 fields', () {
      final item = RuleItem.parse('DOMAIN,only-two');
      expect(item.ruleType, '');
      expect(item.match, '');
      expect(item.action, '');
      expect(item.protocol, isNull);
    });

    test('handles single-field rule', () {
      final item = RuleItem.parse('DOMAIN');
      expect(item.ruleType, '');
      expect(item.raw, 'DOMAIN');
    });

    // Disabled malformed rule
    test('handles disabled malformed rule', () {
      final item = RuleItem.parse('#bad-rule');
      expect(item.isDisabled, isTrue);
      expect(item.raw, '#bad-rule');
      expect(item.ruleType, '');
    });

    // Whitespace trimming
    test('trims whitespace from fields', () {
      final item = RuleItem.parse('DOMAIN , foo.com , DIRECT ');
      expect(item.ruleType, 'DOMAIN');
      expect(item.match, 'foo.com');
      expect(item.action, 'DIRECT');
    });

    test('preserves raw field exactly as given', () {
      const raw = 'DOMAIN-SUFFIX,example.com,DIRECT,tcp';
      final item = RuleItem.parse(raw);
      expect(item.raw, raw);
    });
  });

  group('RuleItem.serialize()', () {
    // Requirement 8.5 — null protocol produces 3-field string
    test('serializes 3-field rule when protocol is null', () {
      final item = RuleItem.parse('DOMAIN-SUFFIX,example.com,DIRECT');
      expect(item.serialize(), 'DOMAIN-SUFFIX,example.com,DIRECT');
    });

    // Requirement 8.4 — non-null protocol included as 4th field
    test('serializes 4-field rule when protocol is present', () {
      final item = RuleItem.parse('DOMAIN-SUFFIX,whatsapp.net,DIRECT,udp');
      expect(item.serialize(), 'DOMAIN-SUFFIX,whatsapp.net,DIRECT,udp');
    });

    test('serializes tcp protocol correctly', () {
      final item = RuleItem.parse('DOMAIN-SUFFIX,whatsapp.net,PROXY,tcp');
      expect(item.serialize(), 'DOMAIN-SUFFIX,whatsapp.net,PROXY,tcp');
    });

    // Requirement 8.7 — disabled rule serializes with # prefix
    test('serializes disabled rule with # prefix', () {
      final item = RuleItem.parse('#DOMAIN,disabled.example.com,REJECT');
      expect(item.serialize(), '#DOMAIN,disabled.example.com,REJECT');
    });

    test('serializes disabled 4-field rule with # prefix', () {
      final item = RuleItem.parse('#DST-PORT,5060,DIRECT,udp');
      expect(item.serialize(), '#DST-PORT,5060,DIRECT,udp');
    });

    // DST-PORT serialization
    test('serializes DST-PORT rule without protocol', () {
      final item = RuleItem.parse('DST-PORT,993,LP');
      expect(item.serialize(), 'DST-PORT,993,LP');
    });
  });

  group('RuleItem equality and equality', () {
    test('two items parsed from the same string are equal', () {
      final a = RuleItem.parse('DOMAIN-SUFFIX,example.com,DIRECT,tcp');
      final b = RuleItem.parse('DOMAIN-SUFFIX,example.com,DIRECT,tcp');
      expect(a, equals(b));
    });

    test('items with different protocols are not equal', () {
      final a = RuleItem.parse('DOMAIN,foo.com,DIRECT,tcp');
      final b = RuleItem.parse('DOMAIN,foo.com,DIRECT,udp');
      expect(a, isNot(equals(b)));
    });
  });
}
