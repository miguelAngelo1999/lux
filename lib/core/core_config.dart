import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/util/utils.dart';
import 'package:path/path.dart' as path;

import '../const/const.dart';

Future<Map<String, dynamic>> readConfig() async {
  try {
    var homeDir = await getHomeDir();
    var configPath = path.join(homeDir, 'config.json');
    return await readJsonFile(configPath);
  } catch (e) {
    return {};
  }
}

// ── Local app preferences (lux_prefs.json) ──────────────────────────────────
// Separate from config.json (managed by lux_core) so we never corrupt it.

Future<String> _prefsPath() async {
  final homeDir = await getHomeDir();
  return path.join(homeDir, 'lux_prefs.json');
}

Future<Map<String, dynamic>> _readPrefs() async {
  try {
    final p = await _prefsPath();
    final f = File(p);
    if (!f.existsSync()) return {};
    final raw = f.readAsStringSync();
    final decoded = jsonDecode(raw);
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

Future<Set<String>> readDismissedProxies() async {
  final prefs = await _readPrefs();
  final raw = prefs['dismissedProxies'];
  if (raw is List) return raw.cast<String>().toSet();
  return {};
}

Future<void> addDismissedProxy(String address) async {
  final prefs = await _readPrefs();
  final existing = (prefs['dismissedProxies'] as List?)?.cast<String>() ?? [];
  if (!existing.contains(address)) {
    existing.add(address);
    prefs['dismissedProxies'] = existing;
    await _writePrefs(prefs);
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

  ProxyItem(
      this.id, this.name, this.server, this.port, this.subscription, this.type,
      {this.password, this.passwordLocked = false});

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
        passwordLocked = (json['passwordLocked'] is bool ? json['passwordLocked'] : false);

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

class CustomizedRuleItem {
  final String ruleType;
  final String payload;
  final String policy;
  final bool disabled;
  final String raw;
  /// Optional protocol filter: "tcp", "udp", or null (matches both).
  final String? protocol;

  const CustomizedRuleItem({
    required this.ruleType,
    required this.payload,
    required this.policy,
    required this.disabled,
    required this.raw,
    this.protocol,
  });

  factory CustomizedRuleItem.fromJson(Map<String, dynamic> json) {
    final raw = json['raw'] as String? ?? '';
    // Parse protocol from the raw string's optional 4th field
    String? protocol;
    final parts = raw.replaceFirst(RegExp(r'^#'), '').split(',');
    if (parts.length >= 4) {
      final p = parts[3].trim().toLowerCase();
      if (p == 'tcp' || p == 'udp') protocol = p;
    }
    return CustomizedRuleItem(
      ruleType: json['ruleType'] as String? ?? '',
      payload: json['payload'] as String? ?? '',
      policy: json['policy'] as String? ?? '',
      disabled: json['disabled'] as bool? ?? false,
      raw: raw,
      protocol: protocol,
    );
  }

  CustomizedRuleItem copyWith({
    String? ruleType,
    String? payload,
    String? policy,
    bool? disabled,
    String? raw,
    Object? protocol = _sentinel,
  }) =>
      CustomizedRuleItem(
        ruleType: ruleType ?? this.ruleType,
        payload: payload ?? this.payload,
        policy: policy ?? this.policy,
        disabled: disabled ?? this.disabled,
        raw: raw ?? this.raw,
        protocol: protocol == _sentinel ? this.protocol : protocol as String?,
      );

  /// Produces the raw rule string, including optional protocol suffix.
  String toRawString() {
    final base = protocol != null
        ? '$ruleType,$payload,$policy,$protocol'
        : '$ruleType,$payload,$policy';
    return disabled ? '#$base' : base;
  }
}

// Sentinel for copyWith optional nullable field
const Object _sentinel = Object();

/// Human-readable fields extracted from an intercepting CA certificate.
class CertInfo {
  final String subject;
  final String issuer;
  final String organizationName;
  final String notBefore;
  final String notAfter;
  final String sha256Fingerprint;
  final bool isCA;

  const CertInfo({
    required this.subject,
    required this.issuer,
    required this.organizationName,
    required this.notBefore,
    required this.notAfter,
    required this.sha256Fingerprint,
    required this.isCA,
  });

  factory CertInfo.fromJson(Map<String, dynamic> json) {
    return CertInfo(
      subject: json['subject'] as String? ?? '',
      issuer: json['issuer'] as String? ?? '',
      organizationName: json['organizationName'] as String? ?? '',
      notBefore: json['notBefore'] as String? ?? '',
      notAfter: json['notAfter'] as String? ?? '',
      sha256Fingerprint: json['sha256Fingerprint'] as String? ?? '',
      isCA: json['isCA'] as bool? ?? false,
    );
  }
}

/// Result of the SSL bump detection probe from the backend.
class SslBumpStatus {
  /// Whether an intercepting/inspecting proxy was detected.
  final bool detected;

  /// Whether a CA cert is available for download.
  final bool hasCert;

  /// RFC3339 timestamp of the last check (may be empty on first load).
  final String checkedAt;

  /// Error message if the probe failed.
  final String? error;

  /// Parsed metadata about the intercepting CA cert, if available.
  final CertInfo? certInfo;

  const SslBumpStatus({
    required this.detected,
    required this.hasCert,
    this.checkedAt = '',
    this.error,
    this.certInfo,
  });

  factory SslBumpStatus.fromJson(Map<String, dynamic> json) {
    return SslBumpStatus(
      detected: json['detected'] as bool? ?? false,
      hasCert: json['hasCert'] as bool? ?? false,
      checkedAt: json['checkedAt'] as String? ?? '',
      error: json['error'] as String?,
      certInfo: json['certInfo'] is Map<String, dynamic>
          ? CertInfo.fromJson(json['certInfo'] as Map<String, dynamic>)
          : null,
    );
  }
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

/// Result of a network proxy auto-detection probe.
class DetectedProxy {
  final String host;
  final String port;
  final String scheme;
  final bool needsAuth;
  final String source;

  const DetectedProxy({
    required this.host,
    required this.port,
    required this.scheme,
    required this.needsAuth,
    required this.source,
  });

  factory DetectedProxy.fromJson(Map<String, dynamic> json) => DetectedProxy(
        host: json['host'] as String? ?? '',
        port: json['port'] as String? ?? '8080',
        scheme: json['scheme'] as String? ?? 'http',
        needsAuth: (json['requiresAuth'] as bool? ?? json['needsAuth'] as bool?) ?? false,
        source: json['source'] as String? ?? '',
      );

  String get address => '$host:$port';
}
