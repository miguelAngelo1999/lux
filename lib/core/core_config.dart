import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';

import 'package:lux/util/utils.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../const/const.dart';

// ── Local app preferences (lux_prefs.json) ──────────────────────────────────
// Deliberately separate from config.json, which lux_core owns and rewrites.
// Keeping Flutter-only settings here means we can never corrupt core config
// (notably the DNS server lists) by writing our own keys into it.

Future<String> _prefsPath() async {
  final homeDir = await getHomeDir();
  return path.join(homeDir, 'lux_prefs.json');
}

Future<Map<String, dynamic>> _readPrefs() async {
  try {
    final p = await _prefsPath();
    final f = File(p);
    if (!f.existsSync()) return {};
    final decoded = jsonDecode(f.readAsStringSync());
    return decoded is Map<String, dynamic> ? decoded : {};
  } catch (_) {
    return {};
  }
}

Future<void> _writePrefs(Map<String, dynamic> prefs) async {
  try {
    final p = await _prefsPath();
    File(p).writeAsStringSync(jsonEncode(prefs));
  } catch (_) {}
}

/// Custom appcast URL — overrides [appcastUrl] when set.
/// Stored in local prefs so it survives app updates.
Future<String?> readCustomAppcastUrl() async {
  final prefs = await _readPrefs();
  final v = prefs['customAppcastUrl'];
  return v is String && v.isNotEmpty ? v : null;
}

Future<void> writeCustomAppcastUrl(String? url) async {
  final prefs = await _readPrefs();
  if (url == null || url.isEmpty) {
    prefs.remove('customAppcastUrl');
  } else {
    prefs['customAppcastUrl'] = url;
  }
  await _writePrefs(prefs);
}

/// Usage-reporting level: "off", "ops" or "full". Absent means off, so a build
/// that has never been configured reports nothing.
Future<String> readTelemetryLevel() async {
  final prefs = await _readPrefs();
  final v = prefs['telemetryLevel'];
  return v is String && v.isNotEmpty ? v : 'off';
}

Future<void> writeTelemetryLevel(String level) async {
  final prefs = await _readPrefs();
  prefs['telemetryLevel'] = level;
  await _writePrefs(prefs);
}

/// Stable anonymous device id, generated on first read.
///
/// Random and unrelated to any account; it exists so a user can quote it when
/// reporting a problem. Stored in lux_prefs.json so it survives app updates.
Future<String> readOrCreateTelemetryUuid() async {
  final prefs = await _readPrefs();
  final existing = prefs['telemetryUuid'];
  if (existing is String && existing.isNotEmpty) return existing;
  final generated = const Uuid().v4();
  prefs['telemetryUuid'] = generated;
  await _writePrefs(prefs);
  return generated;
}

/// Shared secret for the local core API, generated on first read.
///
/// Persisted rather than regenerated per launch so a CoreManager captured by
/// a widget keeps working after the core or the app restarts. A fresh secret
/// each time left held references pointing at a token the core had retired,
/// which surfaced as WebSocket upgrades failing with 401.
Future<String> readOrCreateApiSecret() async {
  final prefs = await _readPrefs();
  final existing = prefs['apiSecret'];
  if (existing is String && existing.isNotEmpty) return existing;
  final generated = const Uuid().v4();
  prefs['apiSecret'] = generated;
  await _writePrefs(prefs);
  return generated;
}

/// Selected UI language: "system", "en", or a language code such as "pt".
///
/// Stored in lux_prefs.json, but falls back to the `language` field in
/// config.json so an existing choice made through the web dashboard is honoured.
/// Writing goes only to prefs, because config.json belongs to lux_core and a
/// partial write there risks clobbering fields it owns.
Future<String> readLocale() async {
  final prefs = await _readPrefs();
  final v = prefs['language'];
  if (v is String && v.isNotEmpty) return v;
  return readLanguage();
}

Future<void> setLocale(String code) async {
  final prefs = await _readPrefs();
  prefs['language'] = code;
  await _writePrefs(prefs);
}

/// Persist the theme choice alongside the other Flutter-only preferences.
Future<void> writeTheme(ThemeMode mode) async {
  final prefs = await _readPrefs();
  prefs['theme'] = switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };
  await _writePrefs(prefs);
}

Future<String> getAppVersionString() async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    return 'unknown';
  }
}

Future<Map<String, dynamic>> readConfig() async {
  try {
    var homeDir = await getHomeDir();
    var configPath = path.join(homeDir, 'config.json');
    return await readJsonFile(configPath);
  } catch (e) {
    return {};
  }
}

Future<Map<String, dynamic>> readSetting() async {
  try {
    final config = await readConfig();
    if (config.containsKey('setting') &&
        config['setting'] is Map<String, dynamic>) {
      return config['setting'] as Map<String, dynamic>;
    }
    return {};
  } catch (e) {
    return {};
  }
}

ThemeMode convertTheme(String theme) {
  switch (theme) {
    case 'dark':
      return ThemeMode.dark;
    case 'light':
      return ThemeMode.light;
    default:
      return ThemeMode.system;
  }
}

Future<ThemeMode> readTheme() async {
  var setting = await readSetting();
  if (setting.containsKey('theme') && setting['theme'] is String) {
    return convertTheme(setting['theme']);
  }
  return ThemeMode.system;
}

enum ClientMode {
  light,
  webview,
}

Future<ClientMode> readClientMode() async {
  var setting = await readSetting();
  if (setting.containsKey('lightClientMode') &&
      setting['lightClientMode'] is bool) {
    if (setting['lightClientMode']) {
      return ClientMode.light;
    }
  }
  return ClientMode.webview;
}

Future<bool> readAutoLaunch() async {
  var setting = await readSetting();
  if (setting.containsKey('autoLaunch') && setting['autoLaunch'] is bool) {
    return setting['autoLaunch'] as bool;
  }
  return false;
}

Future<bool> readAutoConnect() async {
  var setting = await readSetting();
  if (setting.containsKey('autoConnect') && setting['autoConnect'] is bool) {
    return setting['autoConnect'] as bool;
  }
  return false;
}

Future<String> readLanguage() async {
  var setting = await readSetting();
  if (setting.containsKey('language') && setting['language'] is String) {
    return setting['language'] as String;
  }
  return 'system';
}

enum ProxyMode { tun, system, mixed }

Future<ProxyMode> readProxyMode() async {
  var setting = await readSetting();
  if (setting.containsKey('mode') && setting['mode'] is String) {
    var mode = setting['mode'] as String;
    switch (mode) {
      case 'system':
        return ProxyMode.system;
      case 'tun':
        return ProxyMode.tun;
      case 'mixed':
        return ProxyMode.mixed;
    }
  }
  return ProxyMode.system;
}

List<ProxyList> sortProxyList(
    List<ProxyList> groups, List<SubscriptionItem> subscriptions) {
  final sortedIds = <String>[localServersGroupKey];
  for (var i = subscriptions.length - 1; i >= 0; i--) {
    sortedIds.add(subscriptions[i].id);
  }
  final newGroups = <ProxyList>[];
  for (var sortedId in sortedIds) {
    var filteredGroups = groups.where((g) => g.id == sortedId);
    var group = filteredGroups.firstOrNull;
    if (group != null) {
      newGroups.add(group);
    }
  }
  return newGroups;
}

List<ProxyList> convertProxyListToGroup(
    List<ProxyItem> items, List<SubscriptionItem> subscriptions) {
  Map<String, List<ProxyItem>> groupMap = {};
  for (var item in items) {
    if (item.subscription is String) {
      var groupName = item.subscription as String;
      if (!groupMap.containsKey(groupName)) {
        groupMap[groupName] = [];
      }
      groupMap[groupName]!.add(item);
    } else {
      if (!groupMap.containsKey(localServersGroupKey)) {
        groupMap[localServersGroupKey] = [];
      }
      groupMap[localServersGroupKey]!.add(item);
    }
  }

  List<ProxyList> groups = [];
  groupMap.forEach((groupName, proxies) {
    groups.add(ProxyList(proxies, groupName));
  });

  return sortProxyList(groups, subscriptions);
}

class ProxyItem {
  final String id;
  final String name;
  final String type;
  final String? server;
  final int? port;
  final String? subscription;
  final String? password;
  final bool passwordLocked;
  final String? pacUrl;

  ProxyItem(
      this.id, this.name, this.server, this.port, this.subscription, this.type,
      {this.password, this.passwordLocked = false, this.pacUrl});

  ProxyItem.fromJson(Map<String, dynamic> json)
      : id = (json['id'] as String),
        name = (json['name'] as String),
        type = (json['type'] as String),
        server = (json['server'] is String ? json['server'] as String : null),
        subscription = (json['subscription'] is String
            ? json['subscription'] as String
            : null),
        port = (json['port'] is int ? json['port'] as int : null),
        password = (json['password'] is String ? json['password'] : null),
        passwordLocked = (json['passwordLocked'] is bool ? json['passwordLocked'] : false),
        pacUrl = (json['pacUrl'] is String ? json['pacUrl'] as String : null);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
      };
}

/// Detailed proxy configuration including sensitive fields like password.
class ProxyDetail {
  final String id;
  final String name;
  final String type;
  final String? server;
  final int? port;
  final String? password;
  final Map<String, dynamic> raw;

  ProxyDetail({
    required this.id,
    required this.name,
    required this.type,
    this.server,
    this.port,
    this.password,
    required this.raw,
  });

  factory ProxyDetail.fromJson(Map<String, dynamic> json) {
    return ProxyDetail(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? '',
      server: json['server'] as String?,
      port: json['port'] as int?,
      password: json['password'] as String?,
      raw: json,
    );
  }
}

class ProxyList {
  final List<ProxyItem> proxies;
  final String id;

  ProxyList(this.proxies, this.id);

  ProxyList.fromJson(Map<String, dynamic> json)
      : proxies = json['proxies'] != null
            ? (json['proxies'] as List)
                .map((asset) =>
                    ProxyItem.fromJson(asset as Map<String, dynamic>))
                .toList()
            : <ProxyItem>[],
        id = (json['selectedId'] as String);

  Map<String, dynamic> toJson() =>
      {'proxies': proxies.map((asset) => asset.toJson()).toList(), id: id};
}

class SubscriptionItem {
  final String id;
  final String url;
  final String name;
  final String remark;

  SubscriptionItem(
    this.id,
    this.url,
    this.name,
    this.remark,
  );

  SubscriptionItem.fromJson(Map<String, dynamic> json)
      : id = (json['id'] as String),
        url = (json['url'] as String),
        name = (json['name'] as String),
        remark = (json['remark'] as String);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'remark': remark,
      };
}

class SubscriptionList {
  late List<SubscriptionItem> value;

  SubscriptionList(this.value);

  SubscriptionList.fromJson(Map<String, dynamic> json) {
    value = json['subscriptions'] != null
        ? (json['subscriptions'] as List)
            .map((asset) =>
                SubscriptionItem.fromJson(asset as Map<String, dynamic>))
            .toList()
        : <SubscriptionItem>[];
  }

  Map<String, dynamic> toJson() => {'value': value};
}

class ProxyListGroup {
  final List<ProxyItem> allProxies;
  final List<SubscriptionItem> subscriptions;
  late String selectedId;

  late List<ProxyList> groups;

  ProxyListGroup(
      {required this.allProxies,
      required this.subscriptions,
      required this.selectedId})
      : groups = convertProxyListToGroup(allProxies, subscriptions);
}

class RuleList {
  final List<String> rules;
  String selectedId;

  RuleList(this.rules, this.selectedId);

  RuleList.fromJson(Map<String, dynamic> json)
      : rules = json['rules'] != null
            ? (json['rules'] as List).map((asset) => asset as String).toList()
            : <String>[],
        selectedId = (json['selectedId'] as String);

  Map<String, dynamic> toJson() => {'rules': rules};
}

/// A rule that can never match, because an earlier rule with a different policy
/// already covers everything it would.
///
/// Ordered first-match evaluation makes this the most common misrouting cause,
/// and it is invisible without tooling: the rule looks correct in the list.
class RuleShadow {
  final String ruleId;
  final String ruleSlug;
  final String shadowedById;
  final String shadowedBySlug;
  final String reason;

  const RuleShadow({
    required this.ruleId,
    required this.ruleSlug,
    required this.shadowedById,
    required this.shadowedBySlug,
    required this.reason,
  });

  factory RuleShadow.fromJson(Map<String, dynamic> json) => RuleShadow(
        ruleId: json['ruleId'] as String? ?? '',
        ruleSlug: json['ruleSlug'] as String? ?? '',
        shadowedById: json['shadowedById'] as String? ?? '',
        shadowedBySlug: json['shadowedBySlug'] as String? ?? '',
        reason: json['reason'] as String? ?? '',
      );
}

/// A rule that cannot be applied, typically because its target proxy is gone.
class RuleBroken {
  final String ruleId;
  final String ruleSlug;
  final String reason;

  const RuleBroken({
    required this.ruleId,
    required this.ruleSlug,
    required this.reason,
  });

  factory RuleBroken.fromJson(Map<String, dynamic> json) => RuleBroken(
        ruleId: json['ruleId'] as String? ?? '',
        ruleSlug: json['ruleSlug'] as String? ?? '',
        reason: json['reason'] as String? ?? '',
      );
}

class RuleDiagnostics {
  final List<RuleShadow> shadowed;
  final List<RuleBroken> broken;

  const RuleDiagnostics({required this.shadowed, required this.broken});

  factory RuleDiagnostics.fromJson(Map<String, dynamic> json) =>
      RuleDiagnostics(
        shadowed: ((json['shadowed'] as List?) ?? [])
            .map((e) => RuleShadow.fromJson(e as Map<String, dynamic>))
            .toList(),
        broken: ((json['broken'] as List?) ?? [])
            .map((e) => RuleBroken.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Shadow keyed by the shadowed rule's id, for quick row lookup.
  Map<String, RuleShadow> get shadowById =>
      {for (final s in shadowed) s.ruleId: s};
}

/// A single rule parsed from a PAC script.
class PACRuleItem {
  final String ruleType; // DOMAIN, DOMAIN-SUFFIX, IP-CIDR
  final String payload;  // e.g. "example.com", "10.0.0.0/8"
  final String policy;   // DIRECT or PROXY

  const PACRuleItem({
    required this.ruleType,
    required this.payload,
    required this.policy,
  });

  factory PACRuleItem.fromJson(Map<String, dynamic> json) => PACRuleItem(
        ruleType: json['ruleType'] as String? ?? '',
        payload:  json['payload']  as String? ?? '',
        policy:   json['policy']   as String? ?? '',
      );
}

/// Result of fetching and parsing a proxy's PAC URL.
class PACRulesResult {
  final String pacUrl;
  final List<PACRuleItem> rules;
  final String? error;

  const PACRulesResult({
    required this.pacUrl,
    required this.rules,
    this.error,
  });

  factory PACRulesResult.fromJson(Map<String, dynamic> json) => PACRulesResult(
        pacUrl: json['pacUrl'] as String? ?? '',
        rules: ((json['rules'] as List?) ?? [])
            .map((e) => PACRuleItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        error: json['error'] as String?,
      );
}

/// A display grouping for rules. Groups do not nest.
class RuleGroup {
  final String id;
  final String name;
  final bool enabled;
  final int order;

  const RuleGroup({
    required this.id,
    required this.name,
    required this.enabled,
    required this.order,
  });

  factory RuleGroup.fromJson(Map<String, dynamic> json) => RuleGroup(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
        order: json['order'] as int? ?? 0,
      );
}

class CustomizedRuleItem {
  /// Stable, opaque, assigned once by the core. Every mutation targets this.
  ///
  /// Rules used to be addressed by their raw string, which also encoded
  /// enabled state, so toggling a rule changed its identity and operations
  /// keyed on it acted on the wrong rule or none at all.
  final String id;

  /// Readable label derived from the rule's content, regenerated whenever the
  /// content changes. For display and logs only; never an identity.
  final String slug;

  /// Empty for rules in the implicit default group.
  final String groupId;

  final String ruleType;
  final String payload;
  final String policy;
  final bool disabled;
  final String raw;

  /// "tcp", "udp", or empty for both.
  final String network;

  /// Set when the rule cannot be applied, typically because the proxy it
  /// targets was deleted. Such a rule is kept and shown rather than dropped.
  final String broken;

  final int order;

  const CustomizedRuleItem({
    required this.id,
    required this.slug,
    required this.groupId,
    required this.ruleType,
    required this.payload,
    required this.policy,
    required this.disabled,
    required this.raw,
    this.network = '',
    this.broken = '',
    this.order = 0,
  });

  bool get isBroken => broken.isNotEmpty;

  factory CustomizedRuleItem.fromJson(Map<String, dynamic> json) =>
      CustomizedRuleItem(
        id: json['id'] as String? ?? '',
        slug: json['slug'] as String? ?? '',
        groupId: json['groupId'] as String? ?? '',
        ruleType: json['ruleType'] as String? ?? '',
        payload: json['payload'] as String? ?? '',
        policy: json['policy'] as String? ?? '',
        disabled: json['disabled'] as bool? ?? false,
        raw: json['raw'] as String? ?? '',
        network: json['network'] as String? ?? '',
        broken: json['broken'] as String? ?? '',
        order: json['order'] as int? ?? 0,
      );

  CustomizedRuleItem copyWith({
    String? id,
    String? slug,
    String? groupId,
    String? ruleType,
    String? payload,
    String? policy,
    bool? disabled,
    String? raw,
    String? network,
    String? broken,
    int? order,
  }) =>
      CustomizedRuleItem(
        id: id ?? this.id,
        slug: slug ?? this.slug,
        groupId: groupId ?? this.groupId,
        ruleType: ruleType ?? this.ruleType,
        payload: payload ?? this.payload,
        policy: policy ?? this.policy,
        disabled: disabled ?? this.disabled,
        raw: raw ?? this.raw,
        network: network ?? this.network,
        broken: broken ?? this.broken,
        order: order ?? this.order,
      );

  String toRawString() => network.isEmpty
      ? '$ruleType,$payload,$policy'
      : '$ruleType,$payload,$policy,$network';

  /// Identity is the id, so a list can key rows on it and survive edits.
  @override
  bool operator ==(Object other) =>
      other is CustomizedRuleItem && other.id == id && id.isNotEmpty;

  @override
  int get hashCode => id.hashCode;
}

// Define the data classes
class Speed {
  final Proxy proxy;
  final Direct direct;

  Speed({required this.proxy, required this.direct});

  factory Speed.fromJson(Map<String, dynamic> json) {
    return Speed(
      proxy: Proxy.fromJson(json['proxy']),
      direct: Direct.fromJson(json['direct']),
    );
  }
}

class Total {
  final Proxy proxy;
  final Direct direct;

  Total({required this.proxy, required this.direct});

  factory Total.fromJson(Map<String, dynamic> json) {
    return Total(
      proxy: Proxy.fromJson(json['proxy']),
      direct: Direct.fromJson(json['direct']),
    );
  }
}

class Proxy {
  final int upload;
  final int download;

  Proxy({required this.upload, required this.download});

  factory Proxy.fromJson(Map<String, dynamic> json) {
    return Proxy(
      upload: json['upload'],
      download: json['download'],
    );
  }
}

class Direct {
  final int upload;
  final int download;

  Direct({required this.upload, required this.download});

  factory Direct.fromJson(Map<String, dynamic> json) {
    return Direct(
      upload: json['upload'],
      download: json['download'],
    );
  }
}

class TrafficData {
  final Speed speed;
  final Total total;

  TrafficData({required this.speed, required this.total});

  factory TrafficData.fromJson(Map<String, dynamic> json) {
    return TrafficData(
      speed: Speed.fromJson(json['speed']),
      total: Total.fromJson(json['total']),
    );
  }
}

class RuntimeStatus {
  final String addr;
  final String name;
  final bool isStarted;

  RuntimeStatus(
      {required this.addr, required this.name, required this.isStarted});

  factory RuntimeStatus.fromJson(Map<String, dynamic> json) {
    return RuntimeStatus(
      addr: json['addr'] is String ? json['addr'] : '',
      name: json['name'] is String ? json['name'] : '',
      isStarted: json['isStarted'] is bool ? json['isStarted'] : false,
    );
  }
}

class Setting {
  final ProxyMode mode;
  final bool autoLaunch;
  final bool autoConnect;
  final String defaultInterface;
  final int localServerPort;
  final bool allowLan;
  final bool? blockQuic;
  final bool? shouldFindProcess;
  final bool? fakeIp;
  final bool? disableDnsCache;
  final bool hijackDns;
  final bool autoModeEnabled;
  final String autoModeType;
  final String autoModeUrl;
  final bool? sensitiveInfoMode;

  const Setting({
    this.mode = ProxyMode.mixed,
    this.autoLaunch = false,
    this.autoConnect = true,
    this.defaultInterface = '',
    this.localServerPort = 1090,
    this.allowLan = false,
    this.blockQuic,
    this.shouldFindProcess,
    this.fakeIp,
    this.disableDnsCache,
    this.hijackDns = false,
    this.autoModeEnabled = false,
    this.autoModeType = 'fallback',
    this.autoModeUrl = 'https://google.com',
    this.sensitiveInfoMode,
  });

  Setting.fromJson(Map<String, dynamic> json)
      : mode = _parseMode(json['mode'] as String? ?? 'mixed'),
        autoLaunch = json['autoLaunch'] as bool? ?? false,
        autoConnect = json['autoConnect'] as bool? ?? true,
        defaultInterface = json['defaultInterface'] as String? ?? '',
        localServerPort = (json['localServer'] as Map?)?['port'] as int? ?? 1090,
        allowLan = (json['localServer'] as Map?)?['allowLan'] as bool? ?? false,
        blockQuic = json['blockQuic'] as bool?,
        shouldFindProcess = json['shouldFindProcess'] as bool?,
        fakeIp = (json['dns'] as Map?)?['fakeIp'] as bool?,
        disableDnsCache = (json['dns'] as Map?)?['disableCache'] as bool?,
        hijackDns = (json['hijackDns'] as Map?)?['enabled'] as bool? ?? false,
        autoModeEnabled = (json['autoMode'] as Map?)?['enabled'] as bool? ?? false,
        autoModeType = (json['autoMode'] as Map?)?['type'] as String? ?? 'fallback',
        autoModeUrl = (json['autoMode'] as Map?)?['url'] as String? ?? 'https://google.com',
        sensitiveInfoMode = json['sensitiveInfoMode'] as bool?;

  Map<String, dynamic> toJson() => {
        'mode': mode == ProxyMode.tun ? 'tun' : mode == ProxyMode.system ? 'system' : 'mixed',
        'autoLaunch': autoLaunch,
        'autoConnect': autoConnect,
        'defaultInterface': defaultInterface,
        'localServer': {'port': localServerPort, 'allowLan': allowLan},
        if (blockQuic != null) 'blockQuic': blockQuic,
        if (shouldFindProcess != null) 'shouldFindProcess': shouldFindProcess,
        if (fakeIp != null || disableDnsCache != null)
          'dns': {
            if (fakeIp != null) 'fakeIp': fakeIp,
            if (disableDnsCache != null) 'disableCache': disableDnsCache,
          },
        'hijackDns': {'enabled': hijackDns},
        'autoMode': {
          'enabled': autoModeEnabled,
          'type': autoModeType,
          'url': autoModeUrl,
        },
        if (sensitiveInfoMode != null) 'sensitiveInfoMode': sensitiveInfoMode,
      };

  Setting copyWith({
    ProxyMode? mode,
    bool? autoLaunch,
    bool? autoConnect,
    String? defaultInterface,
    int? localServerPort,
    bool? allowLan,
    bool? blockQuic,
    bool? shouldFindProcess,
    bool? fakeIp,
    bool? disableDnsCache,
    bool? hijackDns,
    bool? autoModeEnabled,
    String? autoModeType,
    String? autoModeUrl,
    bool? sensitiveInfoMode,
  }) =>
      Setting(
        mode: mode ?? this.mode,
        autoLaunch: autoLaunch ?? this.autoLaunch,
        autoConnect: autoConnect ?? this.autoConnect,
        defaultInterface: defaultInterface ?? this.defaultInterface,
        localServerPort: localServerPort ?? this.localServerPort,
        allowLan: allowLan ?? this.allowLan,
        blockQuic: blockQuic ?? this.blockQuic,
        shouldFindProcess: shouldFindProcess ?? this.shouldFindProcess,
        fakeIp: fakeIp ?? this.fakeIp,
        disableDnsCache: disableDnsCache ?? this.disableDnsCache,
        hijackDns: hijackDns ?? this.hijackDns,
        autoModeEnabled: autoModeEnabled ?? this.autoModeEnabled,
        autoModeType: autoModeType ?? this.autoModeType,
        autoModeUrl: autoModeUrl ?? this.autoModeUrl,
        sensitiveInfoMode: sensitiveInfoMode ?? this.sensitiveInfoMode,
      );

  static ProxyMode _parseMode(String s) {
    if (s == 'tun') return ProxyMode.tun;
    if (s == 'system') return ProxyMode.system;
    return ProxyMode.mixed;
  }
}


/// Result from POST /proxies/detect — discovered proxy entries from the network's PAC.
class DetectProxyResult {
  final String pacUrl;
  final List<DetectedProxy> proxies;
  final String message;

  const DetectProxyResult({
    required this.pacUrl,
    required this.proxies,
    required this.message,
  });

  factory DetectProxyResult.fromJson(Map<String, dynamic> json) =>
      DetectProxyResult(
        pacUrl: json['pacUrl'] as String? ?? '',
        proxies: ((json['proxies'] as List?) ?? [])
            .map((e) => DetectedProxy.fromJson(e as Map<String, dynamic>))
            .toList(),
        message: json['message'] as String? ?? '',
      );
}

class DetectedProxy {
  final String host;
  final String port;
  final String pacUrl;

  const DetectedProxy({required this.host, required this.port, required this.pacUrl});

  factory DetectedProxy.fromJson(Map<String, dynamic> json) => DetectedProxy(
        host: json['host'] as String? ?? '',
        port: json['port'] as String? ?? '8080',
        pacUrl: json['pacUrl'] as String? ?? '',
      );

  String get displayName => '$host:$port';
}


/// Result from POST /proxies/check-cert — reports whether SSL interception is present.
class CertCheckResult {
  final bool intercepted;
  final String issuer;
  final String subject;
  final String notBefore;
  final String notAfter;
  final String sha256;
  final String pem;
  final String error;

  const CertCheckResult({
    this.intercepted = false,
    this.issuer = '',
    this.subject = '',
    this.notBefore = '',
    this.notAfter = '',
    this.sha256 = '',
    this.pem = '',
    this.error = '',
  });

  factory CertCheckResult.fromJson(Map<String, dynamic> json) => CertCheckResult(
        intercepted: json['intercepted'] as bool? ?? false,
        issuer: json['issuer'] as String? ?? '',
        subject: json['subject'] as String? ?? '',
        notBefore: json['notBefore'] as String? ?? '',
        notAfter: json['notAfter'] as String? ?? '',
        sha256: json['sha256'] as String? ?? '',
        pem: json['pem'] as String? ?? '',
        error: json['error'] as String? ?? '',
      );
}
