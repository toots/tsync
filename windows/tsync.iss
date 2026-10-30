; cloud-files §14: the per-user installer, built by CI with
;   iscc /DVersion=<a.b.c.d> /DSource=<programs folder> /DOutput=<folder> [/DSign] tsync.iss
; where /DSign expects a sign tool named tsync on the command line (/Stsync=...).

#ifndef Version
  #error Version is required
#endif
#ifndef Source
  #error Source is required
#endif
#ifndef Output
  #define Output "."
#endif

[Setup]
AppId=org.feverdreamtv.tsync
AppName=tsync
AppVersion={#Version}
AppPublisher=tsync
AppPublisherURL=https://github.com/toots/tsync
DefaultDirName={localappdata}\Programs\tsync
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
ChangesEnvironment=yes
OutputDir={#Output}
OutputBaseFilename=tsync-setup
UninstallDisplayIcon={app}\tsyncd.exe
WizardStyle=modern
#ifdef Sign
SignTool=tsync
SignedUninstaller=yes
#endif

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Flags: ignoreversion
Source: "install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -ProgramDir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "tsync-uninstall"

[Code]
function PowerShell(Script: String; var Code: Integer): Boolean;
begin
  Result := Exec('powershell.exe',
    '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\' + Script) +
    '" -ProgramDir "' + ExpandConstant('{app}') + '"',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

{ The running service holds the programs open, so it stops before they are replaced. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  if FileExists(ExpandConstant('{app}\tsync.exe')) then
    Exec(ExpandConstant('{app}\tsync.exe'), 'stop', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
begin
  if (CurStep = ssPostInstall) and not PowerShell('install.ps1', Code) then
    RaiseException('Registering tsync failed (exit ' + IntToStr(Code) + '); see the setup log.');
end;
