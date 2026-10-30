# cloud-files §14.1: undoes install.ps1 before the uninstaller removes the
# programs; the user's config, data and sync roots stay.
param([Parameter(Mandatory)] [string] $ProgramDir)

& (Join-Path $ProgramDir 'tsync.exe') stop 2>$null
Unregister-ScheduledTask -TaskPath '\tsync\' -TaskName 'service' -Confirm:$false `
  -ErrorAction SilentlyContinue
Get-AppxPackage -Name 'org.feverdreamtv.tsync' | Remove-AppxPackage

$path = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @($path -split ';' | Where-Object { $_ -ne '' -and $_ -ne $ProgramDir })
[Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
