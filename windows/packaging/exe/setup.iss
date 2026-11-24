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
CloseApplications=no
RestartApplications=no
; Do NOT set AppMutex — it makes Inno show a blocking "please close Lux" prompt
; and refuses to continue while Lux is running, BEFORE our [Code] kill logic can
; run. Instead we kill Lux in InitializeSetup() (runs first, before any prompt).
; CloseApplications=no and RestartApplications=no prevent Windows Restart Manager
; from blocking on headless/elevated daemon processes like lux_core.exe.
; The [Code] section handles bulletproof process termination and file unlocking.

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

Source: "C:\temp\dll\*"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist restartreplace uninsrestartdelete

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if CREATE_DESKTOP_ICON != true %}unchecked{% else %}checkedonce{% endif %}

[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs restartreplace uninsrestartdelete
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

// Safely unlocks a file. If locked by OS handle or lingering process,
// renames it to a .old backup so the original path is immediately free
// for Inno Setup to create the new binary without error or retry prompt.
procedure ForceUnlockFile(const FilePath: string);
var
  OldPath: string;
  I: Integer;
begin
  if not FileExists(FilePath) then
    Exit;

  // 1. Direct delete if process already let go
  if DeleteFile(FilePath) then
    Exit;

  // 2. File is in use: Windows allows RENAMING an active/locked executable.
  // Renaming moves the file out of the destination path so Inno Setup can
  // write the new file directly without error or retry prompt.
  for I := 1 to 10 do
  begin
    OldPath := FilePath + '.old_' + IntToStr(I);
    DeleteFile(OldPath);
    if RenameFile(FilePath, OldPath) then
    begin
      // Path is now freed! Try to delete old path if handle is closing
      DeleteFile(OldPath);
      Exit;
    end;
    Sleep(100);
  end;
end;

procedure UnlockAllLuxBinaries(const BaseDir: string);
begin
  if (BaseDir = '') or (not DirExists(BaseDir)) then
    Exit;
  ForceUnlockFile(BaseDir + '\lux.exe');
  ForceUnlockFile(BaseDir + '\lux_launcher.exe');
  ForceUnlockFile(BaseDir + '\admin_lux.exe');
  ForceUnlockFile(BaseDir + '\admin_lux_tray.exe');
  ForceUnlockFile(BaseDir + '\admin_lux_tray_handler.exe');
  ForceUnlockFile(BaseDir + '\data\flutter_assets\assets\bin\lux_core.exe');
  ForceUnlockFile(BaseDir + '\data\flutter_assets\assets\bin\lux_core_arm64.exe');
  ForceUnlockFile(BaseDir + '\data\flutter_assets\assets\bin\lux_core');
  ForceUnlockFile(BaseDir + '\data\flutter_assets\assets\bin\lux-dialog.exe');
  ForceUnlockFile(BaseDir + '\data\flutter_assets\assets\bin\lux-dialog-slim.exe');
end;

procedure CleanupOldBinaries(const BaseDir: string);
var
  I: Integer;
begin
  if (BaseDir = '') or (not DirExists(BaseDir)) then
    Exit;
  for I := 1 to 10 do
  begin
    DeleteFile(BaseDir + '\lux.exe.old_' + IntToStr(I));
    DeleteFile(BaseDir + '\lux_launcher.exe.old_' + IntToStr(I));
    DeleteFile(BaseDir + '\data\flutter_assets\assets\bin\lux_core.exe.old_' + IntToStr(I));
    DeleteFile(BaseDir + '\data\flutter_assets\assets\bin\lux_core_arm64.exe.old_' + IntToStr(I));
  end;
  DeleteFile(BaseDir + '\lux.exe.old');
  DeleteFile(BaseDir + '\lux_launcher.exe.old');
  DeleteFile(BaseDir + '\data\flutter_assets\assets\bin\lux_core.exe.old');
  DeleteFile(BaseDir + '\data\flutter_assets\assets\bin\lux_core.exe.bak');
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
  if (Pos('{app}', ExePath) > 0) or (not FileExists(ExePath)) then
    ExePath := ExpandConstant('{localappdata}') + '\Programs\lux\lux.exe';
  UserAccount := GetUserNameString();
  if WithComputerName and (Pos('\', UserAccount) = 0) then
    UserAccount := GetComputerNameString() + '\' + UserAccount;
  Xml :=
    '<?xml version="1.0" encoding="UTF-16"?>' + #13#10 +
    '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' + #13#10 +
    '  <RegistrationInfo><Description>Lux proxy — start first at logon</Description></RegistrationInfo>' + #13#10 +
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
  if (Pos('{app}', ExePath) > 0) or (not FileExists(ExePath)) then
    ExePath := ExpandConstant('{localappdata}') + '\Programs\lux\lux.exe';
  Xml :=
    '<?xml version="1.0" encoding="UTF-16"?>' + #13#10 +
    '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' + #13#10 +
    '  <RegistrationInfo><Description>Lux proxy — start first at logon</Description></RegistrationInfo>' + #13#10 +
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

// Bulletproof termination and unlock. Kills scheduled tasks, kills lux.exe first
// (preventing watchdog respawn), kills lux_core, executes PowerShell CIM kill,
// verifies via polling loop, and unlocks/renames any locked files to .old.
procedure KillLux(IsAtInstallStep: Boolean);
var
  ResultCode: Integer;
  I: Integer;
  StillRunning: Boolean;
begin
  // Step 1: Stop LuxCoreService (if installed) and scheduled tasks to prevent auto-restart
  Exec(ExpandConstant('{sys}\sc.exe'), 'stop LuxCoreService', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(500);
  Exec(ExpandConstant('{sys}\schtasks.exe'), '/end /tn LuxApp', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\schtasks.exe'), '/end /tn LuxCore', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\schtasks.exe'), '/end /tn LuxInstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\schtasks.exe'), '/end /tn TestLuxApp', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Step 2: Kill lux.exe and launchers FIRST — watchdog inside lux.exe restarts lux_core if killed first!
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux_launcher.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM admin_lux.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM admin_lux_tray.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM admin_lux_tray_handler.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Step 3: Kill lux_core.exe and helpers
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux_core.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux_core_arm64.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux-dialog.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux-dialog-slim.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Step 4: Aggressive PowerShell process termination (Stop-Process + CIM/WMI)
  // Use exact regex match to avoid accidentally matching the installer itself (e.g. Lux-Setup.exe)
  Exec('powershell.exe',
    '-NoProfile -NonInteractive -Command "' +
    'Stop-Process -Name lux,lux_core,lux_launcher,admin_lux,admin_lux_tray,admin_lux_tray_handler,lux-dialog,lux-dialog-slim -Force -ErrorAction SilentlyContinue; ' +
    'Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match ''^(lux|lux_core|lux_core_arm64|lux_launcher|admin_lux|admin_lux_tray|admin_lux_tray_handler|lux-dialog|lux-dialog-slim)\.exe$'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Step 5: Bounded verification loop — wait up to 3s for OS handles to fully release
  for I := 1 to 10 do
  begin
    StillRunning := False;
    Exec(ExpandConstant('{cmd}'),
      '/c tasklist /FI "IMAGENAME eq lux_core.exe" 2>nul | findstr /i "lux_core.exe"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if ResultCode = 0 then StillRunning := True;

    Exec(ExpandConstant('{cmd}'),
      '/c tasklist /FI "IMAGENAME eq lux.exe" 2>nul | findstr /i "lux.exe"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if ResultCode = 0 then StillRunning := True;

    if not StillRunning then
      break;

    // If still alive, fire taskkill again and wait 300ms
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux_core.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(300);
  end;

  // Step 6: Force unlock all binaries by direct delete or renaming locked files to .old
  // Note: {app} cannot be expanded during InitializeSetup, so only expand {app}
  // when IsAtInstallStep is True.
  UnlockAllLuxBinaries(ExpandConstant('{localappdata}') + '\Programs\lux');
  UnlockAllLuxBinaries(ExpandConstant('{autopf}') + '\lux');
  if IsAtInstallStep then
  begin
    UnlockAllLuxBinaries(ExpandConstant('{app}'));
  end;
end;

function InitializeSetup(): Boolean;
begin
  KillLux(False);
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    // Safety net: kill and unlock again right before files are written, in case
    // the user delayed on wizard pages and something auto-started.
    KillLux(True);
  end;

  if CurStep = ssPostInstall then
  begin
    // Clean up any .old files created during file unlocking
    CleanupOldBinaries(ExpandConstant('{app}'));
    CleanupOldBinaries(ExpandConstant('{localappdata}') + '\Programs\lux');

    // Delete and recreate the LuxApp task ONLY if running in real user context (not SYSTEM).
    // If running as SYSTEM, creating a task pointing to systemprofile launches into Session 0
    // which breaks Flutter ANGLE/DirectX and crashes ucrtbase.dll.
    if not IsSystemContext() then
    begin
      Exec(ExpandConstant('{sys}\schtasks.exe'), '/delete /tn LuxApp /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      WriteLuxTaskXml();
      Exec(ExpandConstant('{sys}\schtasks.exe'),
        '/create /tn LuxApp /xml "' + ExpandConstant('{tmp}') + '\luxapp_task.xml" /f',
        '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      if ResultCode <> 0 then
      begin
        WriteLuxTaskXmlEx(True);
        Exec(ExpandConstant('{sys}\schtasks.exe'),
          '/create /tn LuxApp /xml "' + ExpandConstant('{tmp}') + '\luxapp_task.xml" /f',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      end;
      if ResultCode <> 0 then
        Exec(ExpandConstant('{sys}\schtasks.exe'),
          '/create /tn LuxApp /tr "\"' + ExpandConstant('{app}') +
          '\lux.exe\" --enable-software-rendering" /sc ONLOGON /rl HIGHEST /f',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end
    else
    begin
      Exec(ExpandConstant('{sys}\schtasks.exe'), '/delete /tn LuxApp /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;

    // Remove legacy single-purpose tasks
    Exec(ExpandConstant('{sys}\schtasks.exe'), '/delete /tn LuxCore /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec(ExpandConstant('{sys}\schtasks.exe'), '/delete /tn LuxInstall /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    DeleteFile(ExpandConstant('{app}') + '\lux_core_launcher.ps1');

    // If LuxCoreService is already installed and we are running elevated (e.g.
    // via the in-app updater), update the protected service binaries in-place
    // and restart LuxCoreService so the updated Lux never prompts UAC again.
    Exec(ExpandConstant('{sys}\sc.exe'), 'query LuxCoreService', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if (ResultCode = 0) and IsAdmin() then
    begin
      Exec(ExpandConstant('{sys}\sc.exe'), 'stop LuxCoreService', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Sleep(800);
      Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux_service.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux_core.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Sleep(300);
      ForceUnlockFile('C:\Program Files\LuxService\lux_service.exe');
      ForceUnlockFile('C:\Program Files\LuxService\lux_core.exe');
      FileCopy(
        ExpandConstant('{app}') + '\data\flutter_assets\assets\bin\lux_core.exe',
        'C:\Program Files\LuxService\lux_service.exe',
        False
      );
      FileCopy(
        ExpandConstant('{app}') + '\data\flutter_assets\assets\bin\lux_core.exe',
        'C:\Program Files\LuxService\lux_core.exe',
        False
      );
      Exec(ExpandConstant('{sys}\sc.exe'), 'start LuxCoreService', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;

    // Relaunch Lux in the interactive user session via the LuxApp scheduled task.
    // Trigger the task as long as not running in SYSTEM context (which would launch into Session 0),
    // ensuring both interactive and silent updates (including updates from legacy versions
    // that lack relaunch in their .bat) auto-start Lux cleanly.
    if not IsSystemContext() then
    begin
      Exec(ExpandConstant('{sys}\schtasks.exe'), '/end /tn LuxApp', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Sleep(500);
      Exec(ExpandConstant('{sys}\schtasks.exe'), '/run /tn LuxApp', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    KillLux(False);
    if IsAdmin() then
    begin
      Exec(ExpandConstant('{sys}\sc.exe'), 'stop LuxCoreService', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Sleep(500);
      Exec(ExpandConstant('{sys}\sc.exe'), 'delete LuxCoreService', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM lux_service.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      DelTree('C:\Program Files\LuxService', True, True, True);
      DelTree('C:\ProgramData\LuxService', True, True, True);
    end;
  end;
end;
