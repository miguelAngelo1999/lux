// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Italian (`it`).
class AppLocalizationsIt extends AppLocalizations {
  AppLocalizationsIt([String locale = 'it']) : super(locale);

  @override
  String get trayDashboardLabel => 'Apri Pannello';

  @override
  String get exit => 'Esci';

  @override
  String get noConnectionMsg => 'Nessuna rete disponibile. Disconnesso';

  @override
  String get reconnectedMsg => 'Riconnesso';

  @override
  String connectOnOpenErrMsg(Object msg) {
    return 'Impossibile connettersi all\'apertura: $msg';
  }

  @override
  String setAutoLaunchErrMsg(Object msg) {
    return 'Impossibile impostare l\'avvio automatico: $msg';
  }

  @override
  String get connectOnOpenMsg => 'Connetti all\'apertura';

  @override
  String get proxyAllRuleLabel => 'Proxy Tutto';

  @override
  String get proxyGFWRuleLabel => 'Proxy GFW';

  @override
  String get bypassCNRuleLabel => 'Ignora CN';

  @override
  String get bypassAllRuleLabel => 'Ignora Tutto';

  @override
  String get goWebDashboardTip => 'Apri pannello web';

  @override
  String get tunModeLabel => 'Tun';

  @override
  String get systemModeLabel => 'Sistema';

  @override
  String get mixedModeLabel => 'Misto';

  @override
  String get proxyModeTooltip =>
      'Il proxy di sistema di solito supporta solo TCP e non è accettato da tutte le applicazioni, ma Tun può gestire tutto il traffico. La modalità Mista abilita Tun e Sistema contemporaneamente';

  @override
  String get newVersionMessage =>
      'Nuova versione disponibile! Fai clic per andare.';

  @override
  String get uploadLabel => 'invio';

  @override
  String get downloadLabel => 'download';

  @override
  String get proxyLabel => 'Proxy';

  @override
  String get bypassLabel => 'Diretto';

  @override
  String get launchAtStartUpMessage => 'In esecuzione in background';

  @override
  String get notElevated => 'Non in esecuzione con autorizzazioni elevate.';

  @override
  String get localServer => 'Server Locali';

  @override
  String get coreRunError =>
      'Si è verificato un errore durante l\'avvio di lux_core';

  @override
  String get somethingWrong => 'Qualcosa è andato storto';

  @override
  String get howToFix => 'Come risolvere';

  @override
  String get elevateCoreStep =>
      'lux_core non è stato elevato correttamente. Prova a farlo manualmente: \n 1. Copia il seguente comando ed eseguilo nel terminale \n 2. Riavvia Lux';

  @override
  String get bottomBarTip =>
      'Passa il mouse sulla velocità e sulla modalità per vedere più informazioni';

  @override
  String get edit => 'Modifica';

  @override
  String get delete => 'Elimina';

  @override
  String get qrCode => 'Codice QR';

  @override
  String get addProxyTip => 'Aggiungi nuovo proxy';

  @override
  String get peekPassword => 'Mostra Password';

  @override
  String get peekPasswordTitle => 'Password del Proxy';

  @override
  String get peekPasswordElevationRequired =>
      'Credenziali di amministratore richieste per visualizzare la password';

  @override
  String get peekPasswordNoPassword =>
      'Nessuna password configurata per questo proxy';

  @override
  String get peekPasswordElevationFailed =>
      'Elevazione fallita. Impossibile rivelare la password.';

  @override
  String get peekPasswordCopied => 'Password copiata negli appunti';

  @override
  String get lockPassword => 'Blocca Password';

  @override
  String get passwordLockedLabel => 'Password Bloccata';

  @override
  String get lockPasswordConfirmTitle => 'Bloccare la Password?';

  @override
  String get lockPasswordConfirmMessage =>
      'Questo impedirà permanentemente a chiunque di visualizzare questa password. Il proxy continuerà a funzionare, ma la password non potrà mai più essere rivelata. Questa azione non può essere annullata.';

  @override
  String get lockPasswordSuccess => 'Password bloccata permanentemente';
}
