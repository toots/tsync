# The Windows host end to end (cloud-files §17): the installed service presents
# a domain on moto's local S3, and Explorer's view of its sync root is checked.
param(
  [Parameter(Mandatory)] [string] $Setup,
  [string] $Work = (Join-Path $env:RUNNER_TEMP 'cloud-files-e2e')
)
$ErrorActionPreference = 'Stop'

function Step($text) { Write-Host "$(Get-Date -Format 'HH:mm:ss') $text" }

function Check($what, [bool] $ok) {
  if (-not $ok) { throw "FAILED: $what" }
  Step "ok: $what"
}

function Until($what, [scriptblock] $test, [int] $seconds = 60) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if (& $test) { Step "ok: $what"; return }
    Start-Sleep -Milliseconds 500
  }
  throw "FAILED within $seconds s: $what"
}

$programs = Join-Path $env:LOCALAPPDATA 'Programs\tsync'
$tsync = Join-Path $programs 'tsync.exe'
$log = Join-Path $env:LOCALAPPDATA 'tsync\logs\tsync.log'
$root = Join-Path $env:USERPROFILE 'tsync\docs'
$checks = 0

try {
  Step 'starting the S3 server'
  New-Item -ItemType Directory -Force $Work | Out-Null
  $s3Process = Start-Process -FilePath python -PassThru `
    -ArgumentList '-m', 'moto.server', '-H', '127.0.0.1', '-p', '9000' `
    -RedirectStandardOutput (Join-Path $Work 's3.out') -RedirectStandardError (Join-Path $Work 's3.err')
  Until 'the S3 server answers' {
    try { (Invoke-WebRequest -UseBasicParsing http://127.0.0.1:9000/).StatusCode -eq 200 } catch { $false }
  }
  python -c "import boto3; boto3.client('s3', endpoint_url='http://127.0.0.1:9000', aws_access_key_id='tsyncci', aws_secret_access_key='tsyncci-secret-key', region_name='us-east-1').create_bucket(Bucket='tsync-ci')"
  Check 'the bucket exists' ($LASTEXITCODE -eq 0)

  Step 'writing the config'
  $config = @{
    name = 'ci'
    domains = @(@{
      name = 'docs'
      versioning = $true
      symlinks = 'skip'
      backends = @(@{
        type = 's3'; name = 'main'; role = 'main'; endpoint = 'http://127.0.0.1:9000'
        bucket = 'tsync-ci'; region = 'us-east-1'
        accessKeyId = 'tsyncci'; secretAccessKey = 'tsyncci-secret-key'
      })
      frontends = @('cloud_files')
    })
  } | ConvertTo-Json -Depth 6
  $configPath = Join-Path $env:LOCALAPPDATA 'tsync\config.json'
  New-Item -ItemType Directory -Force (Split-Path $configPath) | Out-Null
  # security-model §7.1: the config's folder grants the user alone.
  icacls (Split-Path $configPath) /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" | Out-Null
  Check 'the config folder is private' ($LASTEXITCODE -eq 0)
  Set-Content -Path $configPath -Value $config -Encoding utf8
  $acl = Get-Acl $configPath
  Step "  config owner $($acl.Owner); entries: $(($acl.Access | ForEach-Object { "$($_.IdentityReference) $($_.AccessControlType)" }) -join ', ')"

  Step 'installing'
  Import-Certificate -FilePath (Join-Path (Split-Path $Setup) 'tsync-development.cer') `
    -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
  $p = Start-Process $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', "/LOG=$Work\setup.log" -Wait -PassThru
  Check 'setup exits 0' ($p.ExitCode -eq 0)

  Step 'seeding the domain'
  & $tsync stop 2>$null
  $seed = Join-Path $Work 'seed'
  New-Item -ItemType Directory -Force (Join-Path $seed 'sub') | Out-Null
  Set-Content -NoNewline -Path (Join-Path $seed 'a.txt') -Value 'alpha'
  Set-Content -NoNewline -Path (Join-Path $seed 'sub\b.txt') -Value 'bravo'
  & $tsync import $seed --domain docs
  Check 'import exits 0' ($LASTEXITCODE -eq 0)

  Step 'starting the service'
  if (Test-Path $log) { Clear-Content $log }
  Start-ScheduledTask -TaskPath '\tsync\' -TaskName 'service'
  Until 'the sync root is presented' {
    (Test-Path $log) -and (Select-String -Quiet -Path $log -Pattern 'presented at')
  }

  Step 'browsing the sync root'
  $names = @(Get-ChildItem -Force $root | ForEach-Object Name) | Sort-Object
  Step "  root holds: $($names -join ', ')"
  Check 'the root lists a.txt and sub' (($names -contains 'a.txt') -and ($names -contains 'sub'))
  $a = Get-Item (Join-Path $root 'a.txt')
  Step "  a.txt: $($a.Attributes), $($a.Length) bytes"
  Check 'a.txt is a placeholder of its size' (($a.Attributes -match 'ReparsePoint') -and $a.Length -eq 5)
  $sub = @(Get-ChildItem -Force (Join-Path $root 'sub') | ForEach-Object Name)
  Check 'sub lists b.txt on its first enumeration' ($sub -contains 'b.txt')
  $checks = 5
} catch {
  Step $_
  if (Test-Path $log) { Step 'service log:'; Get-Content $log -Tail 80 }
  throw
} finally {
  if ($s3Process) { Stop-Process -Id $s3Process.Id -Force -ErrorAction SilentlyContinue }
}

# 09 §10.1: a pass names how many checks ran.
if ($checks -ne 5) { throw "only $checks of 5 browse checks ran" }
Step "cloud files end to end: $checks browse checks passed"
