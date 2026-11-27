import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/util/updater.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateStateNotifier tests', () {
    test('initial state is idle and not downloading', () {
      final state = const UpdateState();
      expect(state.stage, equals(UpdateStage.idle));
      expect(state.isDownloading, isFalse);
      expect(state.isFailed, isFalse);
      expect(state.progress, isNull);
    });

    test('downloading, verifying, and installing states report isDownloading = true', () {
      expect(const UpdateState(stage: UpdateStage.downloading).isDownloading, isTrue);
      expect(const UpdateState(stage: UpdateStage.verifying).isDownloading, isTrue);
      expect(const UpdateState(stage: UpdateStage.installing).isDownloading, isTrue);
      expect(const UpdateState(stage: UpdateStage.available).isDownloading, isFalse);
      expect(const UpdateState(stage: UpdateStage.failed).isDownloading, isFalse);
    });

    test('failed state reports isFailed = true', () {
      expect(const UpdateState(stage: UpdateStage.failed).isFailed, isTrue);
      expect(const UpdateState(stage: UpdateStage.downloading).isFailed, isFalse);
    });
  });

  group('Translations for updater strings', () {
    setUpAll(() async {
      await TranslationCache.load();
    });

    test('Portuguese translations exist and match user expectations', () {
      expect(TranslationCache.translate('Update', 'pt'), equals('Atualizar'));
      expect(TranslationCache.translate('Update available', 'pt'), equals('Atualização disponível'));
      expect(TranslationCache.translate('Updating...', 'pt'), equals('Atualizando...'));
      expect(TranslationCache.translate('Update Now', 'pt'), equals('Atualizar agora'));
      expect(TranslationCache.translate('Downloading update...', 'pt'), equals('Baixando atualização...'));
      expect(TranslationCache.translate('Installing...', 'pt'), equals('Instalando...'));
      expect(TranslationCache.translate('Hide to background', 'pt'), equals('Ocultar em segundo plano'));
      expect(TranslationCache.translate('Download failed', 'pt'), equals('Falha no download'));
      expect(TranslationCache.translate('Later', 'pt'), equals('Mais tarde'));
    });

    test('Spanish translations exist', () {
      expect(TranslationCache.translate('Update', 'es'), equals('Actualizar'));
      expect(TranslationCache.translate('Update available', 'es'), equals('Actualización disponible'));
      expect(TranslationCache.translate('Updating...', 'es'), equals('Actualizando...'));
    });
  });

  group('Update UI widget tests', () {
    testWidgets('shows progress indicator when update is downloading', (tester) async {
      const testInfo = UpdateInfo(
        latestVersion: '1.50.108',
        currentVersion: '1.50.107',
        notes: 'test notes',
        macOSUrl: 'https://example.com/dmg',
        windowsUrl: 'https://example.com/exe',
        hasUpdate: true,
      );

      updateStateNotifier.value = const UpdateState(
        stage: UpdateStage.downloading,
        progress: 0.45,
        status: 'Downloading update... 45%',
        updateInfo: testInfo,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<UpdateState>(
            valueListenable: updateStateNotifier,
            builder: (ctx, state, _) {
              final isDownloading = state.isDownloading;
              final pct = state.progress != null ? (state.progress! * 100).toInt() : null;
              return ListTile(
                title: Text(isDownloading ? 'Updating...' : 'Update available'),
                subtitle: isDownloading
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LinearProgressIndicator(value: state.progress),
                          Text(state.status),
                        ],
                      )
                    : null,
                trailing: isDownloading
                    ? FilledButton.icon(
                        icon: const CircularProgressIndicator(),
                        label: Text('$pct%'),
                        onPressed: () {},
                      )
                    : FilledButton(
                        onPressed: () {},
                        child: const Text('Update'),
                      ),
              );
            },
          ),
        ),
      ));

      await tester.pump();

      expect(find.text('Updating...'), findsOneWidget);
      expect(find.text('Downloading update... 45%'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Reset notifier
      updateStateNotifier.value = const UpdateState();
    });
  });

  group('Stale appcast hash & Retry refresh tests', () {
    test('verifyDownloadedFileHash refreshes appcast when cached hash is stale',
        () async {
      final tmpDir = await Directory.systemTemp.createTemp('lux_hash_test_');
      addTearDown(() => tmpDir.delete(recursive: true));
      final file = File('${tmpDir.path}/installer.bin');
      final bytes = List<int>.generate(1024, (i) => i % 256);
      await file.writeAsBytes(bytes);
      final actualDigest = sha256.convert(bytes).toString();

      const staleInfo = UpdateInfo(
        latestVersion: '1.50.113',
        currentVersion: '1.50.76',
        notes: 'stale',
        macOSUrl: 'https://example.com/mac',
        windowsUrl: 'https://example.com/win',
        hasUpdate: true,
        sha256: '0000000000000000000000000000000000000000000000000000000000000000',
        size: 1024,
      );

      final freshInfo = UpdateInfo(
        latestVersion: '1.50.114',
        currentVersion: '1.50.76',
        notes: 'fresh',
        macOSUrl: 'https://example.com/mac',
        windowsUrl: 'https://example.com/win',
        hasUpdate: true,
        sha256: actualDigest,
        size: 1024,
      );

      var fetchCalls = 0;
      final verified = await verifyDownloadedFileHash(
        file,
        staleInfo,
        appcastFetcher: () async {
          fetchCalls++;
          return freshInfo;
        },
      );

      expect(fetchCalls, 1);
      expect(verified, isNotNull);
      expect(verified!.latestVersion, '1.50.114');
      expect(verified.sha256, actualDigest);

      // Still mismatches fresh appcast -> refuses (returns null).
      final rejected = await verifyDownloadedFileHash(
        file,
        staleInfo,
        appcastFetcher: () async => staleInfo,
      );
      expect(rejected, isNull);
    });

    testWidgets('Retry button in progress dialog fetches fresh UpdateInfo',
        (tester) async {
      const staleInfo = UpdateInfo(
        latestVersion: '1.50.113',
        currentVersion: '1.50.76',
        notes: 'stale',
        macOSUrl: 'https://example.com/mac',
        windowsUrl: 'https://example.com/win',
        hasUpdate: true,
        sha256: 'stale-hash',
        size: 1000,
      );
      const freshInfo = UpdateInfo(
        latestVersion: '1.50.114',
        currentVersion: '1.50.76',
        notes: 'fresh',
        macOSUrl: 'https://example.com/mac',
        windowsUrl: 'https://example.com/win',
        hasUpdate: true,
        sha256: 'fresh-hash',
        size: 2000,
      );

      var fetchCalls = 0;
      UpdateInfo? startedWith;

      debugAppcastFetcher = () async {
        fetchCalls++;
        return freshInfo;
      };
      debugRetryStartUpdate = (ctx, info, {bool showDialog = false}) async {
        startedWith = info;
        updateStateNotifier.value = UpdateState(
          stage: UpdateStage.downloading,
          progress: 0.2,
          status: 'Downloading update... 20%',
          updateInfo: info,
        );
      };
      addTearDown(() {
        debugAppcastFetcher = null;
        debugRetryStartUpdate = null;
        updateStateNotifier.value = const UpdateState();
      });

      updateStateNotifier.value = const UpdateState(
        stage: UpdateStage.failed,
        status: 'Download failed',
        errorMessage: 'Download or installation did not complete.',
        updateInfo: staleInfo,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showUpdateProgressDialog(context, staleInfo),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Lux 1.50.113'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(fetchCalls, 1);
      expect(startedWith, isNotNull);
      expect(startedWith!.latestVersion, '1.50.114');
      expect(startedWith!.sha256, 'fresh-hash');

      // Dialog visibility notifier stays true while open, false once dismissed.
      expect(updateProgressDialogOpenNotifier.value, isTrue);
      await tester.tap(find.text('Hide to background'));
      await tester.pumpAndSettle();
      expect(updateProgressDialogOpenNotifier.value, isFalse);
    });

    test('pickNewestUpdate picks newer stable release when beta is behind stable', () {
      const betaInfo = UpdateInfo(
        latestVersion: '1.50.118',
        currentVersion: '1.50.118',
        notes: 'beta',
        macOSUrl: 'https://example.com/beta.dmg',
        windowsUrl: 'https://example.com/beta.exe',
        hasUpdate: false,
      );
      const stableInfo = UpdateInfo(
        latestVersion: '1.50.119',
        currentVersion: '1.50.118',
        notes: 'stable',
        macOSUrl: 'https://example.com/stable.dmg',
        windowsUrl: 'https://example.com/stable.exe',
        hasUpdate: true,
      );

      final picked = pickNewestUpdate([betaInfo, stableInfo]);
      expect(picked, isNotNull);
      expect(picked!.latestVersion, '1.50.119');
      expect(picked.hasUpdate, isTrue);

      final pickedReverse = pickNewestUpdate([stableInfo, betaInfo]);
      expect(pickedReverse!.latestVersion, '1.50.119');

      // When beta is newer than stable, beta wins.
      const newerBeta = UpdateInfo(
        latestVersion: '1.50.120',
        currentVersion: '1.50.119',
        notes: 'newer beta',
        macOSUrl: 'https://example.com/beta120.dmg',
        windowsUrl: 'https://example.com/beta120.exe',
        hasUpdate: true,
      );
      expect(pickNewestUpdate([newerBeta, stableInfo])!.latestVersion, '1.50.120');
    });

    test('macOS DMG mount uses private mountpoint without touching /Volumes',
        () async {
      final tmp = await Directory.systemTemp.createTemp('lux_dmg_mount_test_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      final args = buildMacOsDmgAttachArgs('/tmp/Lux-1.50.126.dmg', tmp.path);
      expect(args, containsAllInOrder(['attach', '/tmp/Lux-1.50.126.dmg']));
      expect(args, containsAllInOrder(['-mountpoint', tmp.path]));
      expect(args, contains('-nobrowse'));
      expect(args.join(' '), isNot(contains('/Volumes')));

      // Missing Lux.app returns null
      expect(await findMacOsAppInMountPoint(tmp.path), isNull);

      // Direct Lux.app at mount root is found without scanning /Volumes
      final appDir = Directory('${tmp.path}/Lux.app');
      await appDir.create();
      expect(await findMacOsAppInMountPoint(tmp.path), appDir.path);
    });
  });
}
