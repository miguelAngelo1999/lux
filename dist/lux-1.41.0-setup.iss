#define MyAppVersion "1.41.0"
#define MyAppName "Lux"
#define BuildDir "C:\Users\virgoh\lux\build\windows\x64\runner\Release"
#define AssetsDir "C:\Users\virgoh\lux\assets"
#define OutDir "C:\Users\virgoh\lux\dist"

[Setup]
AppId={{80DF132E-434A-4DAB-9BC8-48A79C8383B9}
AppVersion={#MyAppVersion}
AppName={#MyAppName}
AppPublisher=miguelAngelo1999
AppPublisherURL=https://github.com/miguelAngelo1999/lux
DefaultDirName={localappdata}\Programs\lux
DisableProgramGroupPage=yes
OutputDir=C:\tmp
OutputBaseFilename=lux-{#MyAppVersion}-windows-setup-v9
Compression=lzma
SolidCompression=yes
SetupIconFile={#AssetsDir}\app_icon.ico
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableFinishedPage=no
MinVersion=10.0.18362

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "C:\Users\virgoh\lux\windows\packaging\exe\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "lux-dialog.exe,lux-dialog.pdb,lux-dialog-slim.exe,lux_core_arm64.exe,lux_core"
Source: "{#AssetsDir}\bin\lux_core.exe"; DestDir: "{app}\data\flutter_assets\assets\bin"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Lux"; Filename: "{app}\lux.exe"
Name: "{autodesktop}\Lux"; Filename: "{app}\lux.exe"; Tasks: desktopicon

[Run]
Filename: "reg.exe"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v lux /f"; Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "schtasks.exe"; Parameters: "/delete /tn LuxApp /f"; Flags: runhidden
Filename: "schtasks.exe"; Parameters: "/delete /tn LuxCore /f"; Flags: runhidden

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\..\Roaming\com.github.igoogolx\lux"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var ResultCode: Integer;
    LuxExe: String;
    PsCmd: String;
begin
  if CurStep = ssInstall then
  begin
    // Stop lux — try multiple methods in case one doesn't work
    // Method 1: graceful via scheduled task (works when lux runs elevated)
    Exec('schtasks.exe', '/end /tn LuxApp', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    // Method 2: force kill (works when lux is NOT elevated, e.g. first install)
    Exec('taskkill.exe', '/F /IM lux.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec('taskkill.exe', '/F /IM lux_core.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(3000);
  end;
  if CurStep = ssPostInstall then
  begin
    // Kill any orphan lux_core left from the previous session
    Exec('taskkill.exe', '/F /IM lux_core.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(1000);
    // Register scheduled task and launch lux
    LuxExe := ExpandConstant('{app}\lux.exe');
    // Register scheduled task so lux can auto-elevate for TUN mode
    PsCmd := '$a=New-ScheduledTaskAction -Execute ' + #39 + LuxExe + #39 + ';' +
             '$t=New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME;' +
             '$s=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew;' +
             '$p=New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive;' +
             'Register-ScheduledTask -TaskName ' + #39 + 'LuxApp' + #39 + ' -Action $a -Trigger $t -Settings $s -Principal $p -Force | Out-Null';
    Exec('powershell.exe',
      '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command "' + PsCmd + '"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(500);
    // Launch lux directly (don't wait — just fire and forget)
    Exec(LuxExe, '', '', SW_SHOW, ewNoWait, ResultCode);
  end;
end;



