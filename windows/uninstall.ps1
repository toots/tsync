# cloud-files §14.1: undoes install.ps1 before the uninstaller removes the
# programs; the user's config and sync root folders stay.
param([Parameter(Mandatory)] [string] $ProgramDir)

# cloud-files §13.3: purge releases every sync root, keeping the files that are
# whole on disk, and needs the identity tsyncd.exe carries.
$config = Join-Path $env:LOCALAPPDATA 'tsync\config.json'
if (Test-Path $config) {
  $domain = (Get-Content -Raw $config | ConvertFrom-Json).domains |
    Where-Object { @($_.frontends | Where-Object { $_ -eq 'cloud_files' -or $_.type -eq 'cloud_files' }).Count -gt 0 } |
    Select-Object -First 1
  if ($domain) {
    Start-Process -Wait -FilePath (Join-Path $ProgramDir 'tsyncd.exe') `
      -ArgumentList 'cloudfiles', 'purge', '--domain', $domain.name
  }
}
& (Join-Path $ProgramDir 'tsync.exe') stop 2>$null
Unregister-ScheduledTask -TaskPath '\tsync\' -TaskName 'service' -Confirm:$false `
  -ErrorAction SilentlyContinue
Get-AppxPackage -Name 'org.feverdreamtv.tsync' | Remove-AppxPackage

$path = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @($path -split ';' | Where-Object { $_ -ne '' -and $_ -ne $ProgramDir })
[Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
