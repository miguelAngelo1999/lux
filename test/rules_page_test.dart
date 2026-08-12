// Rules page behaviour, driven against a fake core.
//
// These cover the specific failures reported against the previous version:
// deleting a rule appeared to duplicate it, a disabled rule could not be
// deleted at all, downward drags landed one position short, and a rule whose
// policy was a named proxy was treated as the built-in PROXY.
//
// No device and no running lux_core: CoreManager is subclassed and every call
// the page makes is recorded, so the assertions are about what the page asked
// the core to do, not about what a live core happened to be storing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/pages/rules_page.dart';

/// Records every mutation the page issues and serves a fixed rule set.
class FakeCore extends CoreManager {
  FakeCore({
    required this.rules,
    required this.groups,
    this.proxyNames = const [],
    this.diagnostics,
    this.failNext = false,
  }) : super('127.0.0.1:1', null, 'test-token', _noop);

  static void _noop() {}

  List<CustomizedRuleItem> rules;
  List<RuleGroup> groups;
  List<String> proxyNames;
  RuleDiagnostics? diagnostics;

  /// Makes the next mutation throw, to check the page reloads rather than
  /// leaving an optimistic edit on screen.
  bool failNext;

  final List<String> toggledIds = [];
  final List<String> deletedIds = [];
  final List<String> toggledGroupIds = [];
  final List<(String groupId, List<String> ids)> reorders = [];
  int loadCount = 0;

  @override
  Future<List<CustomizedRuleItem>> getCustomizedRules() async {
    loadCount++;
    return List.of(rules);
  }

  @override
  Future<List<RuleGroup>> getRuleGroups() async => List.of(groups);

  @override
  Future<ProxyList> getProxyList() async => ProxyList(
        [
          for (final n in proxyNames)
            ProxyItem('id-$n', n, 'example.com', 443, null, 'http'),
        ],
        'local',
      );

  @override
  Future<RuleDiagnostics> getRuleDiagnostics() async =>
      diagnostics ?? const RuleDiagnostics(shadowed: [], broken: []);

  @override
  Future<void> toggleRuleById(String id) async {
    if (failNext) {
      failNext = false;
      throw Exception('core refused the toggle');
    }
    toggledIds.add(id);
    final i = rules.indexWhere((r) => r.id == id);
    if (i >= 0) rules[i] = rules[i].copyWith(disabled: !rules[i].disabled);
  }

  @override
  Future<void> deleteRuleById(String id) async {
    if (failNext) {
      failNext = false;
      throw Exception('core refused the delete');
    }
    deletedIds.add(id);
    rules.removeWhere((r) => r.id == id);
  }

  @override
  Future<void> toggleRuleGroup(String groupId) async {
    toggledGroupIds.add(groupId);
    final i = groups.indexWhere((g) => g.id == groupId);
    if (i >= 0) {
      final g = groups[i];
      groups[i] = RuleGroup(
          id: g.id, name: g.name, enabled: !g.enabled, order: g.order);
    }
  }

  @override
  Future<void> reorderRuleIds(String groupId, List<String> ids) async {
    reorders.add((groupId, List.of(ids)));
    for (var i = 0; i < ids.length; i++) {
      final at = rules.indexWhere((r) => r.id == ids[i]);
      if (at >= 0) rules[at] = rules[at].copyWith(order: i);
    }
  }
}

CustomizedRuleItem rule(
  String id, {
  String type = 'DOMAIN',
  String payload = 'example.com',
  String policy = 'PROXY',
  String groupId = '',
  bool disabled = false,
  String network = '',
  String broken = '',
  int order = 0,
}) =>
    CustomizedRuleItem(
      id: id,
      slug: '$type-$payload',
      groupId: groupId,
      ruleType: type,
      payload: payload,
      policy: policy,
      disabled: disabled,
      raw: '${disabled ? '#' : ''}$type,$payload,$policy',
      network: network,
      broken: broken,
      order: order,
    );

RuleGroup ruleGroup(String id, String name, int order, {bool enabled = true}) =>
    RuleGroup(id: id, name: name, enabled: enabled, order: order);

Future<void> pumpRules(WidgetTester tester, FakeCore core) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: RulesPage(coreManager: core)),
  ));
  // One frame for the loading spinner, then let the fake's futures settle.
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('applyReorder', () {
    test('a downward move lands where it was dropped', () {
      // ReorderableListView reports newIndex against the pre-removal list, so
      // moving a->index 2 must produce [b, a, c], not [b, c, a].
      expect(applyReorder(['a', 'b', 'c'], 0, 2), ['b', 'a', 'c']);
    });

    test('a move to the very end keeps every id', () {
      expect(applyReorder(['a', 'b', 'c'], 0, 3), ['b', 'c', 'a']);
    });

    test('an upward move needs no adjustment', () {
      expect(applyReorder(['a', 'b', 'c'], 2, 0), ['c', 'a', 'b']);
    });

    test('a move onto itself is a no-op', () {
      expect(applyReorder(['a', 'b', 'c'], 1, 1), ['a', 'b', 'c']);
    });

    test('an out-of-range index is ignored rather than throwing', () {
      expect(applyReorder(['a', 'b'], 5, 0), ['a', 'b']);
      expect(applyReorder([], 0, 0), isEmpty);
    });

    test('no id is ever lost or duplicated', () {
      final ids = ['a', 'b', 'c', 'd', 'e'];
      for (var o = 0; o < ids.length; o++) {
        for (var n = 0; n <= ids.length; n++) {
          final out = applyReorder(ids, o, n);
          expect(out.length, ids.length, reason: 'move $o -> $n changed length');
          expect(out.toSet(), ids.toSet(), reason: 'move $o -> $n lost an id');
        }
      }
    });
  });

  group('rules page rendering', () {
    testWidgets('groups render in stored order, not insertion order',
        (tester) async {
      // Deny rules must be evaluated before allow rules, so Blocked sits first
      // even though it is added last.
      final core = FakeCore(
        rules: [
          rule('r1', payload: 'a.com', groupId: 'g-other', order: 0),
          rule('r2', payload: 'ads.com', policy: 'REJECT', groupId: 'g-blocked'),
        ],
        groups: [
          ruleGroup('g-other', 'Other', 9),
          ruleGroup('g-blocked', 'Blocked', 0),
        ],
      );
      await pumpRules(tester, core);

      final blocked = tester.getTopLeft(find.text('Blocked')).dy;
      final other = tester.getTopLeft(find.text('Other')).dy;
      expect(blocked, lessThan(other));
    });

    testWidgets('a named-proxy policy is shown verbatim', (tester) async {
      // A proxy literally named "Proxy" is not the built-in PROXY policy.
      // Collapsing the two is what silently rerouted rules before.
      final core = FakeCore(
        rules: [rule('r1', policy: 'Proxy', groupId: 'g1')],
        groups: [ruleGroup('g1', 'Work', 0)],
        proxyNames: const ['Proxy'],
      );
      await pumpRules(tester, core);
      expect(find.text('Proxy'), findsOneWidget);
      expect(find.text('PROXY'), findsNothing);
    });

    testWidgets('the toolbar counts broken rules', (tester) async {
      final core = FakeCore(
        rules: [
          rule('r1', groupId: 'g1'),
          rule('r2',
              payload: 'b.com',
              policy: 'GoneProxy',
              groupId: 'g1',
              broken: 'proxy GoneProxy no longer exists'),
        ],
        groups: [ruleGroup('g1', 'Work', 0)],
      );
      await pumpRules(tester, core);
      expect(find.text('1 broken'), findsOneWidget);
      expect(find.text('2 of 2'), findsOneWidget);
    });

    testWidgets('a shadowed rule is flagged', (tester) async {
      final core = FakeCore(
        rules: [
          rule('r1', type: 'DOMAIN-SUFFIX', payload: 'example.com', groupId: 'g1'),
          rule('r2',
              payload: 'sub.example.com', policy: 'DIRECT', groupId: 'g1', order: 1),
        ],
        groups: [ruleGroup('g1', 'Work', 0)],
        diagnostics: const RuleDiagnostics(
          shadowed: [
            RuleShadow(
              ruleId: 'r2',
              ruleSlug: 'DOMAIN-sub.example.com',
              shadowedById: 'r1',
              shadowedBySlug: 'DOMAIN-SUFFIX-example.com',
              reason: 'an earlier suffix rule already covers it',
            )
          ],
          broken: [],
        ),
      );
      await pumpRules(tester, core);
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    });

    testWidgets('collapsing a group hides its rules', (tester) async {
      final core = FakeCore(
        rules: [rule('r1', payload: 'only.com', groupId: 'g1')],
        groups: [ruleGroup('g1', 'Work', 0)],
      );
      await pumpRules(tester, core);
      expect(find.text('only.com'), findsOneWidget);

      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      expect(find.text('only.com'), findsNothing);
      expect(find.text('Work'), findsOneWidget);
    });

    testWidgets('search filters rules and hides empty groups', (tester) async {
      final core = FakeCore(
        rules: [
          rule('r1', payload: 'keepme.com', groupId: 'g1'),
          rule('r2', payload: 'other.com', groupId: 'g2'),
        ],
        groups: [ruleGroup('g1', 'Work', 0), ruleGroup('g2', 'Home', 1)],
      );
      await pumpRules(tester, core);
      expect(find.text('Home'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'keepme');
      await tester.pumpAndSettle();

      expect(find.text('keepme.com'), findsOneWidget);
      expect(find.text('other.com'), findsNothing);
      expect(find.text('Home'), findsNothing);
      expect(find.text('1 of 2'), findsOneWidget);
    });

    testWidgets('ungrouped rules are listed last', (tester) async {
      final core = FakeCore(
        rules: [
          rule('r1', payload: 'grouped.com', groupId: 'g1'),
          rule('r2', payload: 'loose.com'),
        ],
        groups: [ruleGroup('g1', 'Work', 0)],
      );
      await pumpRules(tester, core);
      final work = tester.getTopLeft(find.text('Work')).dy;
      final ungrouped = tester.getTopLeft(find.text('Ungrouped')).dy;
      expect(work, lessThan(ungrouped));
    });
  });

  group('rules page mutations', () {
    testWidgets('deleting targets the row id and removes exactly one row',
        (tester) async {
      // The reported symptom was a delete that appeared to duplicate the rule.
      // Addressing by id makes the request unambiguous.
      final core = FakeCore(
        rules: [
          rule('r1', payload: 'first.com', groupId: 'g1', order: 0),
          rule('r2', payload: 'second.com', groupId: 'g1', order: 1),
        ],
        groups: [ruleGroup('g1', 'Work', 0)],
      );
      await pumpRules(tester, core);

      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(core.deletedIds, ['r1']);
      expect(find.text('first.com'), findsNothing);
      expect(find.text('second.com'), findsOneWidget);
    });

    testWidgets('a disabled rule can be deleted', (tester) async {
      // Previously the raw string carried the '#' disabled marker and the
      // delete path parsed it before matching, so it never found the rule.
      final core = FakeCore(
        rules: [rule('r1', payload: 'off.com', groupId: 'g1', disabled: true)],
        groups: [ruleGroup('g1', 'Work', 0)],
      );
      await pumpRules(tester, core);

      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(core.deletedIds, ['r1']);
      expect(find.text('off.com'), findsNothing);
    });

    testWidgets('cancelling the delete dialog changes nothing', (tester) async {
      final core = FakeCore(
        rules: [rule('r1', payload: 'keep.com', groupId: 'g1')],
        groups: [ruleGroup('g1', 'Work', 0)],
      );
      await pumpRules(tester, core);

      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(core.deletedIds, isEmpty);
      expect(find.text('keep.com'), findsOneWidget);
    });

    testWidgets('toggling targets the row id', (tester) async {
      final core = FakeCore(
        rules: [
          rule('r1', payload: 'first.com', groupId: 'g1', order: 0),
          rule('r2', payload: 'second.com', groupId: 'g1', order: 1),
        ],
        groups: [ruleGroup('g1', 'Work', 0)],
      );
      await pumpRules(tester, core);

      await tester.tap(find.byTooltip('Disable').at(1));
      await tester.pumpAndSettle();
      expect(core.toggledIds, ['r2']);
    });

    testWidgets('a failed mutation reloads instead of keeping the optimistic edit',
        (tester) async {
      final core = FakeCore(
        rules: [rule('r1', payload: 'stays.com', groupId: 'g1')],
        groups: [ruleGroup('g1', 'Work', 0)],
        failNext: true,
      );
      await pumpRules(tester, core);

      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(core.deletedIds, isEmpty);
      // The row is optimistically dropped, then restored by the reload.
      expect(find.text('stays.com'), findsOneWidget);
    });

    testWidgets('toggling a group targets the group id', (tester) async {
      final core = FakeCore(
        rules: [rule('r1', groupId: 'g1')],
        groups: [ruleGroup('g1', 'Work', 0)],
      );
      await pumpRules(tester, core);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(core.toggledGroupIds, ['g1']);
    });

    testWidgets('a disabled group greys its rules without disabling them',
        (tester) async {
      final core = FakeCore(
        rules: [rule('r1', payload: 'in-off-group.com', groupId: 'g1')],
        groups: [ruleGroup('g1', 'Work', 0, enabled: false)],
      );
      await pumpRules(tester, core);

      expect(find.text('group off'), findsOneWidget);
      final text = tester.widget<Text>(find.text('in-off-group.com'));
      expect(text.style?.color, Colors.grey);
      // The rule itself is still enabled, so no strikethrough.
      expect(text.style?.decoration, isNot(TextDecoration.lineThrough));
    });

    testWidgets('drag handles are withheld while a search filter is active',
        (tester) async {
      final core = FakeCore(
        rules: [
          rule('r1', payload: 'aaa.com', groupId: 'g1', order: 0),
          rule('r2', payload: 'aab.com', groupId: 'g1', order: 1),
        ],
        groups: [ruleGroup('g1', 'Work', 0)],
      );
      await pumpRules(tester, core);
      // When not searching, drag indicators should be visible
      expect(find.byIcon(Icons.drag_indicator), findsWidgets);

      await tester.enterText(find.byType(TextField), 'aa');
      await tester.pumpAndSettle();

      // While searching, drag indicators should be hidden
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
    });
  });
}
