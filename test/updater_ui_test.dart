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
}
