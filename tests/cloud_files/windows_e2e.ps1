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
  Step "FAILED within $seconds s: $what"
  if (Test-Path (Join-Path $Work 'export.code')) {
    Step "last export exited $(Get-Content (Join-Path $Work 'export.code')), saying:"
    Get-Content (Join-Path $Work 'export.out'), (Join-Path $Work 'export.err') -ErrorAction Ignore
    Step "published: $((Published) -join ', ')"
  }
  Step 'status:'; & $tsync status 2>&1 | Out-String | Write-Host
  throw "FAILED within $seconds s: $what"
}

# The domain's published files, by relative path, from a fresh export; null
# while a change is unpublished, which export refuses.
function Exported {
  $dir = Join-Path $Work "export-$([guid]::NewGuid())"
  # Its output stays out of this function's value, which is only the folder.
  & $tsync export --domain docs $dir > (Join-Path $Work 'export.out') 2> (Join-Path $Work 'export.err')
  $code = $LASTEXITCODE
  Set-Content (Join-Path $Work 'export.code') $code
  if ($code -ne 0) { return $null }
  $dir
}

function Published {
  $dir = Exported
  if ($null -eq $dir) { return $null }
  @(Get-ChildItem -Recurse -File $dir | ForEach-Object {
    $_.FullName.Substring($dir.Length + 1).Replace('\', '/') }) | Sort-Object
}

# The published content of one domain file, or null.
function PublishedText($rel) {
  $dir = Exported
  if ($null -eq $dir) { return $null }
  $file = Join-Path $dir $rel
  if (Test-Path $file) { Get-Content -Raw $file } else { $null }
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
  # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS: its content is the provider's to fetch.
  Check 'a.txt is a dehydrated placeholder of its size' ((([int]$a.Attributes) -band 0x400000) -and $a.Length -eq 5)
  $sub = @(Get-ChildItem -Force (Join-Path $root 'sub') | ForEach-Object Name)
  Check 'sub lists b.txt on its first enumeration' ($sub -contains 'b.txt')

  Step 'reading through the sync root'
  Check 'a.txt reads its content' ((Get-Content -Raw (Join-Path $root 'a.txt')) -eq 'alpha')
  Check 'sub\b.txt reads its content' ((Get-Content -Raw (Join-Path $root 'sub\b.txt')) -eq 'bravo')

  Step 'changing the sync root'
  Rename-Item (Join-Path $root 'a.txt') 'c.txt'
  Until 'a rename in the sync root reaches the domain' {
    $p = Published; ($p -contains 'c.txt') -and -not ($p -contains 'a.txt')
  }
  Remove-Item (Join-Path $root 'sub\b.txt')
  Until 'a delete in the sync root reaches the domain' {
    $p = Published; ($null -ne $p) -and -not ($p -contains 'sub/b.txt')
  }

  Step 'creating and editing in the sync root'
  Set-Content -NoNewline -Path (Join-Path $root 'new.txt') -Value 'created'
  Until 'a file created in the sync root reaches the domain' {
    (PublishedText 'new.txt') -eq 'created'
  } 90
  Set-Content -NoNewline -Path (Join-Path $root 'c.txt') -Value 'changed'
  Until 'an edit in the sync root reaches the domain' {
    (PublishedText 'c.txt') -eq 'changed'
  } 90
  New-Item -ItemType Directory (Join-Path $root 'made') | Out-Null
  Set-Content -NoNewline -Path (Join-Path $root 'made\inner.txt') -Value 'inside'
  Until 'a folder created with a file in it reaches the domain' {
    (PublishedText 'made\inner.txt') -eq 'inside'
  } 90

  Step 'saving through a temporary file'
  $temporary = Join-Path $root 'new.txt.saving'
  Set-Content -NoNewline -Path $temporary -Value 'saved whole'
  Move-Item -Force $temporary (Join-Path $root 'new.txt')
  Until 'a save renamed over the original reaches it as one content' {
    $p = Published
    ((PublishedText 'new.txt') -eq 'saved whole') -and
      -not ($p -match 'conflicted copy') -and -not ($p -contains 'new.txt.saving')
  } 90

  Step 'changing the domain outside the sync root'
  $elsewhere = Join-Path $Work 'elsewhere'
  New-Item -ItemType Directory -Force $elsewhere | Out-Null
  Set-Content -NoNewline -Path (Join-Path $elsewhere 'peer.txt') -Value 'from elsewhere'
  & $tsync import $elsewhere --domain docs
  Check 'an import beside the running owner exits 0' ($LASTEXITCODE -eq 0)
  Until 'a domain change appears in the sync root' {
    (Test-Path (Join-Path $root 'peer.txt')) -and
      ((Get-Content -Raw (Join-Path $root 'peer.txt')) -eq 'from elsewhere')
  } 90

  Step 'pinning'
  $c = Join-Path $root 'c.txt'
  # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS: the content is not on disk.
  function Dehydrated($path) { (([int](Get-Item $path).Attributes) -band 0x400000) -ne 0 }
  attrib -P +U $c
  Until 'free up space drops a file''s local content' { Dehydrated $c } 60
  attrib -U +P $c
  Until 'always keep on this device brings it back' { -not (Dehydrated $c) } 60
  $read = try { Get-Content -Raw $c } catch { "error: $_" }
  Step "  c.txt reads: $read ($((Get-Item $c).Length) bytes)"
  Check 'it still reads its content' ($read -eq 'changed')

  Step 'uninstalling'
  $p = Start-Process (Join-Path $programs 'unins000.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES' -Wait -PassThru
  Check 'the uninstaller exits 0' ($p.ExitCode -eq 0)
  Check 'a file whole on disk stays, as a plain file' (
    (Test-Path $c) -and -not (Dehydrated $c) -and ((Get-Content -Raw $c) -eq 'changed'))
  Check 'the local state is removed' (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'tsync\data')))
  Check 'the config stays' (Test-Path $configPath)
  $checks = 22
} catch {
  Step $_
  if (Test-Path $log) { Step 'service log:'; Get-Content $log -Tail 80 }
  throw
} finally {
  if ($s3Process) { Stop-Process -Id $s3Process.Id -Force -ErrorAction SilentlyContinue }
}

# 09 §10.1: a pass names how many checks ran.
if ($checks -ne 22) { throw "only $checks of 22 checks ran" }
Step "cloud files end to end: $checks checks passed"
