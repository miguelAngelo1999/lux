[Setup]
AppId={{80DF132E-434A-4DAB-9BC8-48A79C8383B9}
AppVersion=1.50.101
AppName=Lux
AppPublisher=igoogolx
AppPublisherURL=https://github.com/leanflutter/flutter_distributor
AppSupportURL=https://github.com/leanflutter/flutter_distributor
AppUpdatesURL=https://github.com/leanflutter/flutter_distributor
DefaultDirName={autopf}\lux
DisableProgramGroupPage=yes
OutputDir=C:\lux-build\dist2
OutputBaseFilename=lux-1.50.101-setup
Compression=lzma
SolidCompression=yes
SetupIconFile=assets\app_icon.ico
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableFinishedPage=yes
; Do NOT set AppMutex - it makes Inno show a blocking "please close Lux" prompt
; and refuses to continue while Lux is running, BEFORE our kill logic can
; run. Instead we kill Lux in InitializeSetup() (runs first, before any prompt).
; Do NOT use CloseApplications=force - it shows a "please close" dialog for
; lux_core.exe because Inno cannot kill a SYSTEM-owned process.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "C:\temp\dll\*"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\Lux"; Filename: "{app}\lux.exe"
Name: "{autodesktop}\Lux"; Filename: "{app}\lux.exe"; Tasks: desktopicon

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
