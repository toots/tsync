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
UninstallDisplayIcon={app}\tsync.ico
WizardStyle=modern
; Made by scripts/make-installer-images.sh.
SetupIconFile=installer\tsync.ico
WizardImageFile=installer\wizard-1.bmp,installer\wizard-2.bmp
WizardSmallImageFile=installer\wizard-small-1.bmp,installer\wizard-small-2.bmp
#ifdef Sign
SignTool=tsync
SignedUninstaller=yes
#endif

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Flags: ignoreversion
Source: "install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "tsync-development.cer"; DestDir: "{app}"; Flags: ignoreversion
Source: "installer\tsync.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -ProgramDir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "tsync-uninstall"

[Code]
var
  LinkPage: TInputQueryWizardPage;
  { What registering tsync printed when it failed, else empty. }
  RegisterFailure: String;

{ Runs a command line through cmd, its output in Output whether or not it succeeds. }
function Captured(CommandLine, Name: String; var Output: String): Boolean;
var
  Code: Integer;
  LogFile: String;
  Text: AnsiString;
begin
  LogFile := ExpandConstant('{tmp}\' + Name + '.log');
  Result := Exec(ExpandConstant('{cmd}'), '/C "' + CommandLine + ' > "' + LogFile + '" 2>&1"',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
  if LoadStringFromFile(LogFile, Text) then
    Output := Trim(String(Text))
  else
    Output := '';
  if (Output = '') and not Result then
    Output := Name + ' failed (exit ' + IntToStr(Code) + ')';
  Log(Output);
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
begin
  StringChangeEx(Link, '"', '', True);
  Result := Captured('"' + ExpandConstant('{app}\tsync.exe') + '" config join "' + Link + '"',
    'tsync config join', Output);
  if Result then
  begin
    Exec(ExpandConstant('{app}\tsync.exe'), 'stop', '', SW_HIDE, ewWaitUntilTerminated, Code);
    Exec('schtasks.exe', '/Run /TN \tsync\service', '', SW_HIDE, ewWaitUntilTerminated, Code);
  end;
end;

{ A silent install clicks through this page too: a refused link is logged and the install still finishes. }
function NextButtonClick(CurPageID: Integer): Boolean;
var
  Output: String;
begin
  Result := True;
  if (CurPageID = LinkPage.ID) and (Trim(LinkPage.Values[0]) <> '') then
    if not Join(Trim(LinkPage.Values[0]), Output) and not WizardSilent then
    begin
      MsgBox(Output, mbError, MB_OK);
      Result := False;
    end;
end;

{ The programs stay installed when registering fails, so running setup again retries it. }
procedure CurStepChanged(CurStep: TSetupStep);
var
  Output: String;
begin
  if (CurStep = ssPostInstall) and not Captured('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'
      + ExpandConstant('{app}\install.ps1') + '" -ProgramDir "' + ExpandConstant('{app}') + '"',
      'install.ps1', Output) then
  begin
    RegisterFailure := Output;
    if not WizardSilent then
      MsgBox('tsync could not be registered with Windows:' + #13#10#13#10 + Output
        + #13#10#13#10 + 'Run setup again to retry.', mbError, MB_OK);
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = LinkPage.ID) and (RegisterFailure <> '');
end;

{ The last page shows what this machine syncs, as tsync config --summary words it. }
procedure CurPageChanged(CurPageID: Integer);
var
  Summary: String;
begin
  if CurPageID <> wpFinished then
    Exit;
  if RegisterFailure <> '' then
    WizardForm.FinishedLabel.Caption := 'tsync was installed but could not be registered with Windows. Run setup again to retry.'
  else if Captured('"' + ExpandConstant('{app}\tsync.exe') + '" config --summary', 'tsync config', Summary) then
    WizardForm.FinishedLabel.Caption := 'tsync is installed and syncs:' + #13#10#13#10 + Summary
  else
    WizardForm.FinishedLabel.Caption := 'tsync is installed. No folders are set up yet: run setup again with a setup link.';
end;

function GetCustomSetupExitCode: Integer;
begin
  if RegisterFailure <> '' then
    Result := 1
  else
    Result := 0;
end;
