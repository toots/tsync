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
var
  LinkPage: TInputQueryWizardPage;

function PowerShell(Script: String; var Code: Integer): Boolean;
begin
  Result := Exec('powershell.exe',
    '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\' + Script) +
    '" -ProgramDir "' + ExpandConstant('{app}') + '"',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

{ The running service and tray hold the programs open, so they stop before the programs are replaced. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  if FileExists(ExpandConstant('{app}\tsync.exe')) then
    Exec(ExpandConstant('{app}\tsync.exe'), 'stop', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec('taskkill.exe', '/IM tsync-tray.exe /F', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;

{ setup-link §6.3: after the programs are in place, so the CLI can join; /LINK= gives it unattended. }
procedure InitializeWizard;
begin
  LinkPage := CreateInputQueryPage(wpInstalling, 'Setup link',
    'Were you given a tsync setup link?',
    'Paste it to set up the folders it names. Leave it blank to set tsync up later.');
  LinkPage.Add('Setup link:', False);
  LinkPage.Values[0] := ExpandConstant('{param:LINK}');
end;

{ 07 §2.7: a changed config takes effect when the service starts again. }
function Join(Link: String; var Output: String): Boolean;
var
  Code: Integer;
  LogFile: String;
  Text: AnsiString;
begin
  StringChangeEx(Link, '"', '', True);
  LogFile := ExpandConstant('{tmp}\join.log');
  Result := Exec(ExpandConstant('{cmd}'),
    '/C ""' + ExpandConstant('{app}\tsync.exe') + '" config join "' + Link + '" > "' + LogFile + '" 2>&1"',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
  if LoadStringFromFile(LogFile, Text) then
    Output := String(Text)
  else
    Output := 'tsync config join failed (exit ' + IntToStr(Code) + ')';
  if Result then
  begin
    Exec(ExpandConstant('{app}\tsync.exe'), 'stop', '', SW_HIDE, ewWaitUntilTerminated, Code);
    Exec('schtasks.exe', '/Run /TN \tsync\service', '', SW_HIDE, ewWaitUntilTerminated, Code);
  end;
  Log(Output);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Output: String;
begin
  Result := True;
  if (CurPageID = LinkPage.ID) and (Trim(LinkPage.Values[0]) <> '') then
  begin
    Result := Join(Trim(LinkPage.Values[0]), Output);
    if not Result then
      MsgBox(Output, mbError, MB_OK);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
  Output: String;
begin
  if (CurStep = ssPostInstall) and not PowerShell('install.ps1', Code) then
    RaiseException('Registering tsync failed (exit ' + IntToStr(Code) + '); see the setup log.');
  if (CurStep = ssDone) and WizardSilent and (Trim(LinkPage.Values[0]) <> '') then
    Join(Trim(LinkPage.Values[0]), Output);
end;
