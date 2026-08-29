// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get trayDashboardLabel => 'Abrir Painel';

  @override
  String get exit => 'Sair';

  @override
  String get noConnectionMsg => 'Nenhuma rede disponível. Desconectado';

  @override
  String get reconnectedMsg => 'Reconectado';

  @override
  String connectOnOpenErrMsg(Object msg) {
    return 'Falha ao conectar ao abrir: $msg';
  }

  @override
  String setAutoLaunchErrMsg(Object msg) {
    return 'Falha ao configurar inicialização automática: $msg';
  }

  @override
  String get connectOnOpenMsg => 'Conectar ao abrir';

  @override
  String get proxyAllRuleLabel => 'Proxy Tudo';

  @override
  String get proxyGFWRuleLabel => 'Proxy GFW';

  @override
  String get bypassCNRuleLabel => 'Ignorar CN';

  @override
  String get bypassAllRuleLabel => 'Ignorar Tudo';

  @override
  String get goWebDashboardTip => 'Abrir painel web';

  @override
  String get tunModeLabel => 'Tun';

  @override
  String get systemModeLabel => 'Sistema';

  @override
  String get mixedModeLabel => 'Misto';

  @override
  String get proxyModeTooltip =>
      'O proxy do sistema geralmente só suporta TCP e não é aceito por todos os aplicativos, mas o Tun pode lidar com todo o tráfego. O modo Misto ativa Tun e Sistema ao mesmo tempo';

  @override
  String get newVersionMessage =>
      'Nova versão disponível! Clique para acessar.';

  @override
  String get uploadLabel => 'envio';

  @override
  String get downloadLabel => 'download';

  @override
  String get proxyLabel => 'Proxy';

  @override
  String get bypassLabel => 'Direto';

  @override
  String get launchAtStartUpMessage => 'Executando em segundo plano';

  @override
  String get notElevated => 'Não está em execução com permissões elevadas.';

  @override
  String get localServer => 'Servidores Locais';

  @override
  String get coreRunError => 'Ocorreu um erro ao iniciar o lux_core';

  @override
  String get somethingWrong => 'Algo deu errado';

  @override
  String get howToFix => 'Como corrigir';

  @override
  String get elevateCoreStep =>
      'O lux_core não foi elevado com sucesso. Tente fazê-lo manualmente: \n 1. Copie o comando a seguir e execute no terminal \n 2. Reinicie o Lux';

  @override
  String get bottomBarTip =>
      'Passe o mouse sobre a velocidade e o modo para ver mais informações';

  @override
  String get edit => 'Editar';

  @override
  String get delete => 'Excluir';

  @override
  String get qrCode => 'Código QR';

  @override
  String get addProxyTip => 'Adicionar novo proxy';

  @override
  String get peekPassword => 'Mostrar Senha';

  @override
  String get peekPasswordTitle => 'Senha do Proxy';

  @override
  String get peekPasswordElevationRequired =>
      'Credenciais de administrador necessárias para ver a senha';

  @override
  String get peekPasswordNoPassword =>
      'Nenhuma senha configurada para este proxy';

  @override
  String get peekPasswordElevationFailed =>
      'Elevação falhou. Não é possível revelar a senha.';

  @override
  String get peekPasswordCopied => 'Senha copiada para a área de transferência';

  @override
  String get lockPassword => 'Bloquear Senha';

  @override
  String get passwordLockedLabel => 'Senha Bloqueada';

  @override
  String get lockPasswordConfirmTitle => 'Bloquear Senha?';

  @override
  String get lockPasswordConfirmMessage =>
      'Isso impedirá permanentemente que qualquer pessoa veja esta senha. O proxy continuará funcionando, mas a senha nunca poderá ser revelada novamente. Isso não pode ser desfeito.';

  @override
  String get lockPasswordSuccess => 'Senha bloqueada permanentemente';
}
