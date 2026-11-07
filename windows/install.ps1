# cloud-files §14: run by the installer, as the user, once the programs are in
# place; each step replaces what an earlier install left.
param([Parameter(Mandatory)] [string] $ProgramDir)
$ErrorActionPreference = 'Stop'

# cloud-files §14.1: the identity package installs only once its certificate is
# trusted for the machine, which takes an administrator's consent.
$cer = Join-Path $ProgramDir 'tsync-development.cer'
$thumbprint = (New-Object Security.Cryptography.X509Certificates.X509Certificate2 $cer).Thumbprint
$trusted = "Cert:\LocalMachine\TrustedPeople\$thumbprint"
if (-not (Test-Path $trusted)) {
  try {
    $p = Start-Process certutil.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
      -ArgumentList '-addstore', 'TrustedPeople', "`"$cer`""
  } catch {
    throw "tsync's certificate was not trusted, so Windows refuses its package: $($_.Exception.Message)"
  }
  if ($p.ExitCode) { throw "Trusting tsync's certificate failed (certutil exited $($p.ExitCode)), so Windows refuses its package." }
  if (-not (Test-Path $trusted)) { throw "tsync's certificate ($thumbprint) is still not in the machine's TrustedPeople store, so Windows refuses its package." }
}

Add-AppxPackage -Path (Join-Path $ProgramDir 'tsync-identity.msix') `
  -ExternalLocation $ProgramDir -ForceUpdateFromAnyVersion

$path = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @($path -split ';' | Where-Object { $_ -ne '' })
if ($entries -notcontains $ProgramDir) {
  [Environment]::SetEnvironmentVariable('Path', (($entries + $ProgramDir) -join ';'), 'User')
}

$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute (Join-Path $ProgramDir 'tsyncd.exe') -Argument 'start'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskPath '\tsync\' -TaskName 'service' -Action $action `
  -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskPath '\tsync\' -TaskName 'service'

# cloud-files §15: the tray starts at each logon and now; a running one stays.
$tray = Join-Path $ProgramDir 'tsync-tray.exe'
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'tsync-tray' -Value "`"$tray`""
Start-Process -FilePath $tray
