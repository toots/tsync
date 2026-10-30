# cloud-files §14: run by the installer, as the user, once the programs are in
# place; each step replaces what an earlier install left.
param([Parameter(Mandatory)] [string] $ProgramDir)
$ErrorActionPreference = 'Stop'

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
