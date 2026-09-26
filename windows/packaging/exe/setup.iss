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
AppMutex=lux.app.mutex,Global\lux.app.mutex
; Do NOT use CloseApplications=force — it shows a "please close" dialog for
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

{ Writes the LuxApp scheduled-task XML to {tmp}\luxapp_task.xml.
  - LogonTrigger with no <Delay> → runs immediately at logon
  - <Priority>4</Priority> → higher than the default 7 so Lux starts first
  - RunLevel=HighestAvailable → lux_core elevates
  - Battery/idle conditions disabled so it always runs }
procedure WriteLuxTaskXml();
var
  Xml: string;
  ExePath: string;
begin
  ExePath := ExpandConstant('{localappdata}') + '\Programs\lux\lux.exe';
  Xml :=
    '<?xml version="1.0" encoding="UTF-16"?>' + #13#10 +
    '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' + #13#10 +
    '  <RegistrationInfo><Description>Lux proxy — start first at logon</Description></RegistrationInfo>' + #13#10 +
    '  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>' + #13#10 +
    '  <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>' + #13#10 +
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

procedure CurStepChanged(CurStep: TSetupStep);
var ResultCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    { ── Kill running Lux processes before installing ──────────────────────
      lux_core.exe runs as SYSTEM via the LuxApp scheduled task.
      A user-level taskkill CANNOT kill a SYSTEM process, so we MUST stop
      the task first, then kill the remaining processes.
      This order is permanent and must not be changed. }

    { Step 1: Stop the LuxApp scheduled task — this terminates lux_core.exe }
    Exec('schtasks.exe', '/end /tn LuxApp', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
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

  if CurStep = ssPostInstall then
  begin
    { Delete and recreate the LuxApp task pointing at the newly installed exe.
      Created from XML so we can set a high priority and NO start delay — Lux
      must come up first at logon because other services depend on the proxy.

      Priority 4 = interactive/high (default is 7; 0=highest, 10=lowest). The
      /create command line cannot set priority, so we import task XML. }
    Exec('schtasks.exe', '/delete /tn LuxApp /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    WriteLuxTaskXml();
    Exec('schtasks.exe',
      '/create /tn LuxApp /xml "' + ExpandConstant('{tmp}') + '\luxapp_task.xml" /f',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    { Fallback: if XML import failed (older Windows), use the plain command. }
    if ResultCode <> 0 then
      Exec('schtasks.exe',
        '/create /tn LuxApp /tr "\"' + ExpandConstant('{localappdata}') +
        '\Programs\lux\lux.exe\" --enable-software-rendering"' +
        ' /sc ONLOGON /rl HIGHEST /f',
        '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

    { Launch Lux after install }
    Exec(ExpandConstant('{localappdata}') + '\Programs\lux\lux.exe',
      '--enable-software-rendering', '', SW_HIDE, ewNoWait, ResultCode);
  end;
end;
