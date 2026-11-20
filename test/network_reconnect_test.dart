import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/home.dart';
import 'package:lux/model/app.dart';

class _TestCoreManager extends CoreManager {
  _TestCoreManager({
    required AppStateModel appState,
    required Stream<List<ConnectivityResult>> connectivityStream,
    required Future<List<ConnectivityResult>> Function() checkConnectivity,
    VoidCallback? onConnectionStateChanged,
    void Function(String msg)? showNotification,
  }) : super(
          '127.0.0.1:1',
          null,
          'test-token',
          _noop,
          appState: appState,
          connectivityStream: connectivityStream,
          checkConnectivity: checkConnectivity,
          disconnectDebounce: const Duration(milliseconds: 30),
          resumeDebounce: const Duration(milliseconds: 30),
          resumeRetryDelay: const Duration(milliseconds: 20),
          onConnectionStateChanged: onConnectionStateChanged,
          showNotification: showNotification,
        );

  static void _noop() {}

  ProxyMode mode = ProxyMode.tun;
  bool isStartedValue = true;
  int failStartCount = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int restartCoreCalls = 0;

  @override
  Future<bool> getIsStarted() async => isStartedValue;

  @override
  Future<Setting> getSetting() async => Setting(mode: mode);

  @override
  Future<void> start() async {
    startCalls++;
    if (failStartCount > 0) {
      failStartCount--;
      throw Exception('DHCP settling');
    }
    isStartedValue = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    isStartedValue = false;
  }

  @override
  Future<void> restartCore() async {
    restartCoreCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Network disconnect/reconnect & sleep/wake auto-resume', () {
    late StreamController<List<ConnectivityResult>> connectivityController;
    late List<ConnectivityResult> currentConnectivity;
    late AppStateModel appState;
    late int trayRefreshCount;
    late List<String> notifications;
    late _TestCoreManager core;

    setUp(() {
      connectivityController =
          StreamController<List<ConnectivityResult>>.broadcast();
      currentConnectivity = [ConnectivityResult.wifi];
      appState = AppStateModel(ThemeMode.light, const Locale('en'));
      appState.userWantsRunning = true;
      appState.updateIsStarted(true);
      trayRefreshCount = 0;
      notifications = [];
      core = _TestCoreManager(
        appState: appState,
        connectivityStream: connectivityController.stream,
        checkConnectivity: () async => currentConnectivity,
        onConnectionStateChanged: () => trayRefreshCount++,
        showNotification: (msg) => notifications.add(msg),
      );
    });

    tearDown(() async {
      core.dispose();
      await connectivityController.close();
    });

    test('disconnect in tun mode sets pausedForNoNetwork while keeping userWantsRunning',
        () async {
      currentConnectivity = [ConnectivityResult.none];
      connectivityController.add([ConnectivityResult.none]);

      await Future.delayed(const Duration(milliseconds: 80));

      expect(core.stopCalls, 1);
      expect(appState.pausedForNoNetwork, isTrue);
      expect(appState.userWantsRunning, isTrue);
      expect(appState.isStarted, isFalse);
      expect(trayRefreshCount, greaterThanOrEqualTo(1));
    });

    test('disconnect in mixed mode sets pausedForNoNetwork and stops core',
        () async {
      core.mode = ProxyMode.mixed;
      currentConnectivity = [ConnectivityResult.none];
      connectivityController.add([ConnectivityResult.none]);

      await Future.delayed(const Duration(milliseconds: 80));

      expect(core.stopCalls, 1);
      expect(appState.pausedForNoNetwork, isTrue);
      expect(appState.userWantsRunning, isTrue);
      expect(notifications, contains('No available network. Disconnected'));
    });

    test('disconnect in system mode does not stop core or set pausedForNoNetwork',
        () async {
      core.mode = ProxyMode.system;
      currentConnectivity = [ConnectivityResult.none];
      connectivityController.add([ConnectivityResult.none]);

      await Future.delayed(const Duration(milliseconds: 80));

      expect(core.stopCalls, 0);
      expect(appState.pausedForNoNetwork, isFalse);
      expect(appState.userWantsRunning, isTrue);
    });

    test('transient disconnect cancelled by quick wifi recovery does not stop core',
        () async {
      currentConnectivity = [ConnectivityResult.none];
      connectivityController.add([ConnectivityResult.none]);
      await Future.delayed(const Duration(milliseconds: 10));

      currentConnectivity = [ConnectivityResult.wifi];
      connectivityController.add([ConnectivityResult.wifi]);
      await Future.delayed(const Duration(milliseconds: 80));

      expect(core.stopCalls, 0);
      expect(appState.pausedForNoNetwork, isFalse);
      expect(appState.userWantsRunning, isTrue);
    });

    for (final onlineType in [
      ConnectivityResult.wifi,
      ConnectivityResult.ethernet,
      ConnectivityResult.mobile,
      ConnectivityResult.vpn,
      ConnectivityResult.other,
    ]) {
      test('auto-resumes on $onlineType reconnect after pausedForNoNetwork',
          () async {
        // 1. Disconnect
        currentConnectivity = [ConnectivityResult.none];
        connectivityController.add([ConnectivityResult.none]);
        await Future.delayed(const Duration(milliseconds: 80));
        expect(appState.pausedForNoNetwork, isTrue);
        expect(appState.isStarted, isFalse);

        final trayBeforeResume = trayRefreshCount;

        // 2. Reconnect on onlineType
        currentConnectivity = [onlineType];
        connectivityController.add([onlineType]);
        await Future.delayed(const Duration(milliseconds: 100));

        expect(core.startCalls, 1);
        expect(appState.pausedForNoNetwork, isFalse);
        expect(appState.userWantsRunning, isTrue);
        expect(appState.isStarted, isTrue);
        expect(trayRefreshCount, greaterThan(trayBeforeResume));
      });
    }

    test('auto-resume retries up to 2 times when DHCP is still settling',
        () async {
      core.failStartCount = 2; // first 2 start() attempts fail, 3rd succeeds

      currentConnectivity = [ConnectivityResult.none];
      connectivityController.add([ConnectivityResult.none]);
      await Future.delayed(const Duration(milliseconds: 80));
      expect(appState.pausedForNoNetwork, isTrue);

      currentConnectivity = [ConnectivityResult.ethernet];
      connectivityController.add([ConnectivityResult.ethernet]);
      await Future.delayed(const Duration(milliseconds: 160));

      expect(core.startCalls, 3);
      expect(appState.pausedForNoNetwork, isFalse);
      expect(appState.isStarted, isTrue);
    });

    test('manualStop clears both pausedForNoNetwork and userWantsRunning and prevents auto-resume',
        () async {
      // Disconnect -> pausedForNoNetwork = true
      currentConnectivity = [ConnectivityResult.none];
      connectivityController.add([ConnectivityResult.none]);
      await Future.delayed(const Duration(milliseconds: 80));
      expect(appState.pausedForNoNetwork, isTrue);
      expect(appState.userWantsRunning, isTrue);

      // User manually turns Lux OFF
      await core.manualStop();
      expect(appState.pausedForNoNetwork, isFalse);
      expect(appState.userWantsRunning, isFalse);

      // Network reconnects later -> must NOT auto-resume
      currentConnectivity = [ConnectivityResult.wifi];
      connectivityController.add([ConnectivityResult.wifi]);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(core.startCalls, 0);
      expect(appState.isStarted, isFalse);
      expect(appState.pausedForNoNetwork, isFalse);
      expect(appState.userWantsRunning, isFalse);
    });

    test('manualStop during resume debounce aborts pending resume', () async {
      appState.pausedForNoNetwork = true;
      appState.userWantsRunning = true;
      core.isStartedValue = false;
      appState.updateIsStarted(false);

      currentConnectivity = [ConnectivityResult.wifi];
      connectivityController.add([ConnectivityResult.wifi]);
      await Future.delayed(const Duration(milliseconds: 10));

      await core.manualStop();
      await Future.delayed(const Duration(milliseconds: 80));

      expect(core.startCalls, 0);
      expect(appState.pausedForNoNetwork, isFalse);
      expect(appState.userWantsRunning, isFalse);
    });

    test('watchdog preserves userWantsRunning and does not increment restartFails while offline',
        () async {
      core.isStartedValue = false;
      appState.updateIsStarted(false);
      appState.userWantsRunning = true;
      currentConnectivity = [ConnectivityResult.none];

      final watchdog = WatchdogController(
        checkConnectivity: () async => currentConnectivity,
        retryDelayBase: const Duration(milliseconds: 5),
      );

      // Run more ticks than maxRestarts (3) while offline
      for (int i = 0; i < 5; i++) {
        await watchdog.tick(core, appState);
      }

      expect(watchdog.restartFails, 0);
      expect(appState.userWantsRunning, isTrue);
      expect(core.startCalls, 0);
    });

    test('watchdog safety net triggers auto-resume when online with pausedForNoNetwork=true',
        () async {
      core.isStartedValue = false;
      appState.updateIsStarted(false);
      appState.userWantsRunning = true;
      appState.pausedForNoNetwork = true;
      currentConnectivity = [ConnectivityResult.wifi];

      final watchdog = WatchdogController(
        checkConnectivity: () async => currentConnectivity,
        retryDelayBase: const Duration(milliseconds: 5),
      );

      await watchdog.tick(core, appState);

      expect(core.startCalls, 1);
      expect(appState.pausedForNoNetwork, isFalse);
      expect(appState.isStarted, isTrue);
    });

    test('wake while offline sets pausedForNoNetwork=true and resumes when Wi-Fi associates',
        () async {
      core.isStartedValue = false;
      appState.updateIsStarted(false);
      appState.userWantsRunning = true;
      currentConnectivity = [ConnectivityResult.none];

      final resumedImmediately = await handlePowerWake(
        coreManager: core,
        appState: appState,
        needRestart: true,
        checkConnectivity: () async => currentConnectivity,
      );

      expect(resumedImmediately, isFalse);
      expect(appState.pausedForNoNetwork, isTrue);
      expect(appState.userWantsRunning, isTrue);
      expect(core.startCalls, 0);

      // Wi-Fi associates after wake
      currentConnectivity = [ConnectivityResult.wifi];
      connectivityController.add([ConnectivityResult.wifi]);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(core.startCalls, 1);
      expect(appState.pausedForNoNetwork, isFalse);
      expect(appState.isStarted, isTrue);
    });
  });
}
