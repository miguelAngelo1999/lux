// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get trayDashboardLabel => 'Abrir Panel';

  @override
  String get exit => 'Salir';

  @override
  String get noConnectionMsg => 'No hay red disponible. Desconectado';

  @override
  String get reconnectedMsg => 'Reconectado';

  @override
  String connectOnOpenErrMsg(Object msg) {
    return 'Error al conectar al abrir: $msg';
  }

  @override
  String setAutoLaunchErrMsg(Object msg) {
    return 'Error al configurar el inicio automático: $msg';
  }

  @override
  String get connectOnOpenMsg => 'Conectar al abrir';

  @override
  String get proxyAllRuleLabel => 'Proxy Todo';

  @override
  String get proxyGFWRuleLabel => 'Proxy GFW';

  @override
  String get bypassCNRuleLabel => 'Omitir CN';

  @override
  String get bypassAllRuleLabel => 'Omitir Todo';

  @override
  String get goWebDashboardTip => 'Abrir panel web';

  @override
  String get tunModeLabel => 'Tun';

  @override
  String get systemModeLabel => 'Sistema';

  @override
  String get mixedModeLabel => 'Mixto';

  @override
  String get proxyModeTooltip =>
      'El proxy del sistema generalmente solo admite TCP y no es aceptado por todas las aplicaciones, pero Tun puede manejar todo el tráfico. El modo Mixto habilita Tun y Sistema al mismo tiempo';

  @override
  String get newVersionMessage =>
      '¡Nueva versión disponible! Haga clic para ir.';

  @override
  String get uploadLabel => 'subida';

  @override
  String get downloadLabel => 'descarga';

  @override
  String get proxyLabel => 'Proxy';

  @override
  String get bypassLabel => 'Directo';

  @override
  String get launchAtStartUpMessage => 'Ejecutándose en segundo plano';

  @override
  String get notElevated => 'No se está ejecutando con permisos elevados.';

  @override
  String get localServer => 'Servidores Locales';

  @override
  String get coreRunError => 'Se produjo un error al iniciar lux_core';

  @override
  String get somethingWrong => 'Algo salió mal';

  @override
  String get howToFix => 'Cómo solucionarlo';

  @override
  String get elevateCoreStep =>
      'lux_core no se elevó correctamente. Intente hacerlo manualmente: \n 1. Copie el siguiente comando y ejecútelo en la terminal \n 2. Reinicie Lux';

  @override
  String get bottomBarTip =>
      'Pase el cursor sobre la velocidad y el modo para ver más información';

  @override
  String get edit => 'Editar';

  @override
  String get delete => 'Eliminar';

  @override
  String get qrCode => 'Código QR';

  @override
  String get addProxyTip => 'Agregar nuevo proxy';

  @override
  String get peekPassword => 'Mostrar Contraseña';

  @override
  String get peekPasswordTitle => 'Contraseña del Proxy';

  @override
  String get peekPasswordElevationRequired =>
      'Se requieren credenciales de administrador para ver la contraseña';

  @override
  String get peekPasswordNoPassword =>
      'No hay contraseña configurada para este proxy';

  @override
  String get peekPasswordElevationFailed =>
      'La elevación falló. No se puede revelar la contraseña.';

  @override
  String get peekPasswordCopied => 'Contraseña copiada al portapapeles';

  @override
  String get lockPassword => 'Bloquear Contraseña';

  @override
  String get passwordLockedLabel => 'Contraseña Bloqueada';

  @override
  String get lockPasswordConfirmTitle => '¿Bloquear Contraseña?';

  @override
  String get lockPasswordConfirmMessage =>
      'Esto impedirá permanentemente que alguien vea esta contraseña. El proxy seguirá funcionando, pero la contraseña nunca podrá revelarse de nuevo. Esto no se puede deshacer.';

  @override
  String get lockPasswordSuccess => 'Contraseña bloqueada permanentemente';
}
