// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Filipino Pilipino (`fil`).
class AppLocalizationsFil extends AppLocalizations {
  AppLocalizationsFil([String locale = 'fil']) : super(locale);

  @override
  String get trayProxiesLabel => 'Switch Proxy';

  @override
  String get trayDashboardLabel => 'Buksan ang Dashboard';

  @override
  String get exit => 'Lumabas';

  @override
  String get noConnectionMsg => 'Walang available na network. Nadiskonekta';

  @override
  String get reconnectedMsg => 'Nakakonekta muli';

  @override
  String connectOnOpenErrMsg(Object msg) {
    return 'Hindi makakonekta sa pagbukas: $msg';
  }

  @override
  String setAutoLaunchErrMsg(Object msg) {
    return 'Hindi ma-set ang auto launch: $msg';
  }

  @override
  String get connectOnOpenMsg => 'Kumonekta sa pagbukas';

  @override
  String get proxyAllRuleLabel => 'Proxy Lahat';

  @override
  String get proxyGFWRuleLabel => 'Proxy GFW';

  @override
  String get bypassCNRuleLabel => 'I-bypass ang CN';

  @override
  String get bypassAllRuleLabel => 'I-bypass Lahat';

  @override
  String get goWebDashboardTip => 'Buksan ang web dashboard';

  @override
  String get tunModeLabel => 'TUN';

  @override
  String get systemModeLabel => 'System';

  @override
  String get mixedModeLabel => 'Mixed';

  @override
  String get proxyModeTooltip =>
      'Ang System proxy ay karaniwang sumusuporta lang sa TCP at hindi tinatanggap ng lahat ng apps, ngunit ang TUN ay kayang hawakan ang lahat ng trapiko. Ang Mixed ay nagpapagana ng parehong TUN at System nang sabay';

  @override
  String get newVersionMessage => 'May bagong bersyon! I-click para pumunta.';

  @override
  String get uploadLabel => 'upload';

  @override
  String get downloadLabel => 'download';

  @override
  String get proxyLabel => 'Proxy';

  @override
  String get bypassLabel => 'Direkta';

  @override
  String get launchAtStartUpMessage => 'Tumatakbo sa background';

  @override
  String get notElevated => 'Hindi tumatakbo nang may elevated permissions.';

  @override
  String get localServer => 'Lokal na Servers';

  @override
  String get coreRunError => 'Nakatagpo ng error sa pagsisimula ng lux_core';

  @override
  String get somethingWrong => 'May nangyaring mali';

  @override
  String get howToFix => 'Paano ayusin';

  @override
  String get elevateCoreStep =>
      'Hindi matagumpay na na-elevate ang lux_core. Subukan na gawin ito nang mano-mano:\n 1. Kopyahin ang sumusunod na command at patakbuhin sa terminal\n 2. I-restart ang Lux';

  @override
  String get bottomBarTip =>
      'I-hover ang bilis at mode text para makita ang karagdagang impormasyon';

  @override
  String get edit => 'I-edit';

  @override
  String get delete => 'I-delete';

  @override
  String get qrCode => 'QR Code';

  @override
  String get addProxyTip => 'Magdagdag ng bagong proxy';

  @override
  String get peekPassword => 'Ipakita ang Password';

  @override
  String get peekPasswordTitle => 'Password ng Proxy';

  @override
  String get peekPasswordElevationRequired =>
      'Kailangan ng admin credentials para makita ang password';

  @override
  String get peekPasswordNoPassword =>
      'Walang password na naka-configure para sa proxy na ito';

  @override
  String get peekPasswordElevationFailed =>
      'Nabigo ang elevation. Hindi maibunyag ang password.';

  @override
  String get peekPasswordCopied => 'Nakopya ang password sa clipboard';

  @override
  String get lockPassword => 'I-lock ang Password';

  @override
  String get passwordLockedLabel => 'Naka-lock ang Password';

  @override
  String get lockPasswordConfirmTitle => 'I-lock ang Password?';

  @override
  String get lockPasswordConfirmMessage =>
      'Permanenteng pipigilan nito ang sinuman sa pagtingin sa password na ito. Magpapatuloy na gumana ang proxy, ngunit hindi na maaaring ibunyag muli ang password. Hindi ito maaaring bawiin.';

  @override
  String get lockPasswordSuccess => 'Permanenteng naka-lock na ang password';
}
