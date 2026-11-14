[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableFinishedPage=yes
; Do NOT set AppMutex - it makes Inno show a blocking "please close Lux" prompt
; and refuses to continue while Lux is running, BEFORE our [Code] kill logic can
; run. Instead we kill Lux in InitializeSetup() (runs first, before any prompt).
; Do NOT use CloseApplications=force - it shows a "please close" dialog for
; lux_core.exe because Inno cannot kill a SYSTEM-owned process. The [Code]
; section handles killing via schtasks /end (the only way to stop SYSTEM procs).

[Languages]
{% for locale in LOCALES %}
{% if locale == 'en' %}Name: "english"; MessagesFile: "compiler:Default.isl"{% endif %}
{% if locale == 'hy' %}Name: "armenian"; MessagesFile: "compiler:Languages\\Armenian.isl"{% endif %}
{% if locale == 'bg' %}Name: "bulgarian"; MessagesFile: "compiler:Languages\\Bulgarian.isl"{% endif %}
{% if locale == 'ca' %}Name: "catalan"; MessagesFile: "compiler:Languages\\Catalan.isl"{% endif %}
{% if locale == 'zh' %}Name: "chinesesimplified"; MessagesFile: "..\\..\\windows\\packaging\\exe\\ChineseSimplified.isl"{% endif %}
{% if locale == 'co' %}Name: "corsican"; MessagesFile: "compiler:Languages\\Corsican.isl"{% endif %}
{% if locale == 'cs' %}Name: "czech"; MessagesFile: "compiler:Languages\\Czech.isl"{% endif %}
{% if locale == 'da' %}Name: "danish"; MessagesFile: "compiler:Languages\\Danish.isl"{% endif %}
{% if locale == 'nl' %}Name: "dutch"; MessagesFile: "compiler:Languages\\Dutch.isl"{% endif %}
{% if locale == 'fi' %}Name: "finnish"; MessagesFile: "compiler:Languages\\Finnish.isl"{% endif %}
{% if locale == 'fr' %}Name: "french"; MessagesFile: "compiler:Languages\\French.isl"{% endif %}
{% if locale == 'de' %}Name: "german"; MessagesFile: "compiler:Languages\\German.isl"{% endif %}
{% if locale == 'he' %}Name: "hebrew"; MessagesFile: "compiler:Languages\\Hebrew.isl"{% endif %}
{% if locale == 'is' %}Name: "icelandic"; MessagesFile: "compiler:Languages\\Icelandic.isl"{% endif %}
{% if locale == 'it' %}Name: "italian"; MessagesFile: "compiler:Languages\\Italian.isl"{% endif %}
{% if locale == 'ja' %}Name: "japanese"; MessagesFile: "compiler:Languages\\Japanese.isl"{% endif %}
{% if locale == 'no' %}Name: "norwegian"; MessagesFile: "compiler:Languages\\Norwegian.isl"{% endif %}
{% if locale == 'pl' %}Name: "polish"; MessagesFile: "compiler:Languages\\Polish.isl"{% endif %}
{% if locale == 'pt' %}Name: "portuguese"; MessagesFile: "compiler:Languages\\Portuguese.isl"{% endif %}
{% if locale == 'ru' %}Name: "russian"; MessagesFile: "compiler:Languages\\Russian.isl"{% endif %}
{% if locale == 'sk' %}Name: "slovak"; MessagesFile: "compiler:Languages\\Slovak.isl"{% endif %}
{% if locale == 'sl' %}Name: "slovenian"; MessagesFile: "compiler:Languages\\Slovenian.isl"{% endif %}
{% if locale == 'es' %}Name: "spanish"; MessagesFile: "compiler:Languages\\Spanish.isl"{% endif %}
{% if locale == 'tr' %}Name: "turkish"; MessagesFile: "compiler:Languages\\Turkish.isl"{% endif %}
{% if locale == 'uk' %}Name: "ukrainian"; MessagesFile: "compiler:Languages\\Ukrainian.isl"{% endif %}
{% endfor %}

[Files]

Source: "C:\temp\dll\*"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if CREATE_DESKTOP_ICON != true %}unchecked{% else %}checkedonce{% endif %}

[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; Tasks: desktopicon

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\..\Roaming\com.github.igoogolx\lux"
; NOTE: delete any file cautiously

[Code]

function IsSystemContext(): Boolean;
var
  User: string;
  AppData: string;
begin
  User := Uppercase(GetUserNameString());
  AppData := Lowercase(ExpandConstant('{localappdata}'));
  Result := (User = 'SYSTEM') or (Pos('SYSTEMPROFILE', AppData) > 0);
end;

(* Writes the LuxApp scheduled-task XML to {tmp}\luxapp_task.xml.
  - LogonTrigger with no <Delay> -> runs immediately at logon
  - <Priority>4</Priority> -> higher than the default 7 so Lux starts first
  - RunLevel=HighestAvailable -> lux_core elevates
  - Battery/idle conditions disabled so it always runs *)
procedure WriteLuxTaskXmlEx(WithComputerName: Boolean);
var
  Xml: string;
  ExePath: string;
  UserAccount: string;
begin
  ExePath := ExpandConstant('{app}') + '\lux.exe';
  UserAccount := GetUserNameString();
  if WithComputerName and (Pos('\', UserAccount) = 0) then
    UserAccount := GetComputerNameString() + '\' + UserAccount;
  Xml :=
    '<?xml version="1.0" encoding="UTF-8"?>' + #13#10 +
    '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' + #13#10 +
    '  <RegistrationInfo><Description>Lux proxy - start first at logon</Description></RegistrationInfo>' + #13#10 +
    '  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>' + #13#10 +
    '  <Principals><Principal id="Author"><UserId>' + UserAccount + '</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>' + #13#10 +
    '  <Settings>' + #13#10 +
    '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>' + #13#10 +
    '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>' + #13#10 +
    '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>' + #13#10 +
    '    <AllowHardTerminate>true</AllowHardTerminate>' + #13#10 +
    '    <StartWhenAvailable>true</StartWhenAvailable>' + #13#10 +
    '    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>' + #13#10 +
    '    <AllowStartOnDemand>true</AllowStartOnDemand>' + #13#10 +
    '    <Enabled>true</Enabled>' + #13#10 +
    '    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>' + #13#10 +
    '    <Priority>4</Priority>' + #13#10 +
    '  </Settings>' + #13#10 +
    '  <Actions Context="Author"><Exec><Command>' + ExePath + '</Command><Arguments>--enable-software-rendering</Arguments></Exec></Actions>' + #13#10 +
    '</Task>';
  SaveStringToFile(ExpandConstant('{tmp}') + '\luxapp_task.xml', Xml, False);
end;

procedure WriteLuxTaskXml();
var
  Xml: string;
  ExePath: string;
begin
  ExePath := ExpandConstant('{app}') + '\lux.exe';
  Xml :=
    '<?xml version="1.0" encoding="UTF-8"?>' + #13#10 +
    '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' + #13#10 +
    '  <RegistrationInfo><Description>Lux proxy - start first at logon</Description></RegistrationInfo>' + #13#10 +
    '  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>' + #13#10 +
    '  <Principals><Principal id="Author"><UserId>' + GetUserNameString() + '</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>' + #13#10 +
    '  <Settings>' + #13#10 +
    '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>' + #13#10 +
    '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>' + #13#10 +
    '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>' + #13#10 +
    '    <AllowHardTerminate>true</AllowHardTerminate>' + #13#10 +
    '    <StartWhenAvailable>true</StartWhenAvailable>' + #13#10 +
    '    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>' + #13#10 +
    '    <AllowStartOnDemand>true</AllowStartOnDemand>' + #13#10 +
    '    <Enabled>true</Enabled>' + #13#10 +
    '    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>' + #13#10 +
    '    <Priority>4</Priority>' + #13#10 +
    '  </Settings>' + #13#10 +
    '  <Actions Context="Author"><Exec><Command>' + ExePath + '</Command><Arguments>--enable-software-rendering</Arguments></Exec></Actions>' + #13#10 +
    '</Task>';
  SaveStringToFile(ExpandConstant('{tmp}') + '\luxapp_task.xml', Xml, False);
end;

{ Kills all running Lux processes. lux_core.exe runs as SYSTEM via the LuxApp
  scheduled task, and a user-level taskkill CANNOT kill a SYSTEM process, so we
  MUST stop the task first (schtasks /end), then kill the remaining processes.
  This order is permanent and must not be changed. }
procedure KillLux();
var ResultCode: Integer;
begin
  { Step 1: Stop the scheduled tasks - this terminates lux_core.exe. End BOTH
    the current LuxApp task AND the legacy LuxCore/LuxInstall tasks: a machine
    upgrading from the old scheme still has them, and a stale legacy task is
    what re-launched Lux in the wrong context after an update (the 1.50.87/88
    "stays off" reports - dual-scheme coexistence). }
  Exec('schtasks.exe', '/end /tn LuxApp', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('schtasks.exe', '/end /tn LuxCore', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('schtasks.exe', '/end /tn LuxInstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(2000);

  { Step 2: Kill any remaining process instances }
  Exec('taskkill.exe', '/F /IM lux_core.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /IM lux.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /IM lux_launcher.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(1000);

  { Step 3: Second pass in case anything restarted }
  Exec('taskkill.exe', '/F /IM lux_core.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /IM lux.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(500);
end;

{ Runs BEFORE the wizard shows anything. Killing Lux here (rather than at
  ssInstall) means there is no running instance to block the install - this is
  why we removed AppMutex, which would otherwise prompt "please close Lux". }
function InitializeSetup(): Boolean;
begin
  KillLux();
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  I: Integer;
  LuxUp: Boolean;
begin
  if CurStep = ssInstall then
  begin
    { Safety net: kill again right before files are written, in case the app
      auto-restarted between InitializeSetup and now. }
    KillLux();
  end;

  if CurStep = ssPostInstall then
  begin
    { Delete and recreate the LuxApp task ONLY if running in real user context (not SYSTEM).
      If running as SYSTEM, creating a task pointing to systemprofile launches into Session 0
      which breaks Flutter ANGLE/DirectX and crashes ucrtbase.dll. }
    if not IsSystemContext() then
    begin
      Exec('schtasks.exe', '/delete /tn LuxApp /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      WriteLuxTaskXml();
      Exec('schtasks.exe',
        '/create /tn LuxApp /xml "' + ExpandConstant('{tmp}') + '\luxapp_task.xml" /f',
        '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      { If XML import failed because schtasks requires domain/computer prefix for local account,
        retry XML import with COMPUTERNAME\GetUserNameString(). }
      if ResultCode <> 0 then
      begin
        WriteLuxTaskXmlEx(True);
        Exec('schtasks.exe',
          '/create /tn LuxApp /xml "' + ExpandConstant('{tmp}') + '\luxapp_task.xml" /f',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      end;
      { Fallback: if XML import failed (older Windows), use the plain command. }
      if ResultCode <> 0 then
        Exec('schtasks.exe',
          '/create /tn LuxApp /tr "\"' + ExpandConstant('{app}') +
          '\lux.exe\" --enable-software-rendering" /sc ONLOGON /rl HIGHEST /f',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end
    else
    begin
      { In SYSTEM context, delete any stale LuxApp task registered as SYSTEM so it cannot
        launch into Session 0 and crash. }
      Exec('schtasks.exe', '/delete /tn LuxApp /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;

    { Remove the legacy single-purpose tasks + launcher from the old scheme so
      only LuxApp remains. Harmless if they were never present. }
    Exec('schtasks.exe', '/delete /tn LuxCore /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec('schtasks.exe', '/delete /tn LuxInstall /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    DeleteFile(ExpandConstant('{app}') + '\lux_core_launcher.ps1');

    { Never relaunch GUI directly from elevated/Session 0 context or when running silently.
      During silent in-app update, the detached updater script (lux_updater.bat)
      relaunches Lux in the user's interactive desktop session.
      Only if running as an interactive wizard (WizardSilent = False) and not SYSTEM,
      trigger the scheduled task. }
    if not WizardSilent() and not IsSystemContext() then
    begin
      Exec('schtasks.exe', '/end /tn LuxApp', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Sleep(500);
      Exec('schtasks.exe', '/run /tn LuxApp', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;
  end;
end;
