# End-to-end smoke test for the PowerShell wrapper (scripts/bd.ps1).
#
# Usage: e2e-smoke.ps1 [-CoreBin <path to bd-core>] [-Hook auto|prompt]
#
# Runs under Windows PowerShell 5.1 and PowerShell 7+ on any OS. Keep this file
# ASCII-only so Windows PowerShell 5.1 parses it the same way everywhere.
param(
  [string]$CoreBin = '',
  [ValidateSet('auto', 'prompt')]
  [string]$Hook = 'auto'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$rootDir = Split-Path -Parent $PSScriptRoot
$onWindows = ($env:OS -eq 'Windows_NT')
if (-not $CoreBin) {
  $exe = 'bd-core'
  if ($onWindows) { $exe = 'bd-core.exe' }
  $CoreBin = Join-Path (Join-Path (Join-Path $rootDir 'target') 'release') $exe
}
if (-not (Test-Path -LiteralPath $CoreBin -PathType Leaf)) {
  throw "bd-core binary not found at $CoreBin"
}
$CoreBin = (Resolve-Path -LiteralPath $CoreBin).ProviderPath

function Assert-Equal {
  param($Actual, $Expected, [string]$What)
  if ($Actual -cne $Expected) {
    throw "${What}: expected '$Expected', got '$Actual'"
  }
}

function Assert-True {
  param([bool]$Condition, [string]$What)
  if (-not $Condition) {
    throw $What
  }
}

# Runs the prompt hook the way an interactive shell would between commands.
function Invoke-PromptHook {
  if ($global:BD_HOOK -eq 'prompt') {
    $null = prompt
  }
}

function Enter-Dir {
  param([string]$Path)
  Set-Location -LiteralPath $Path
  Invoke-PromptHook
  return (Get-Location).ProviderPath
}

$startDir = (Get-Location).ProviderPath
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bd-e2e-" + [System.Guid]::NewGuid().ToString('N'))
$savedEnv = @{}
foreach ($name in 'XDG_STATE_HOME', 'BD_CORE_BIN', 'BD_SESSION_ID', 'BD_HOOK', 'LOCALAPPDATA') {
  $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
  # A non-ASCII name with a space: U+65E5 U+672C U+8A9E.
  $unicodeName = 'dir ' + [char]0x65E5 + [char]0x672C + [char]0x8A9E
  $stateDir = Join-Path $tmpDir 'state'
  foreach ($name in 'state', 'a', 'b', $unicodeName) {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $tmpDir $name)
  }

  $env:XDG_STATE_HOME = $stateDir
  $env:BD_CORE_BIN = $CoreBin
  $env:BD_SESSION_ID = "e2e-powershell-$Hook"
  if ($Hook -eq 'prompt') {
    $env:BD_HOOK = 'prompt'
  } else {
    $env:BD_HOOK = $null
  }

  # The embedded wrapper must be the one in the repository.
  $embedded = (& $CoreBin init powershell | Out-String) -replace "`r", ''
  $source = ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'bd.ps1'))) -replace "`r", ''
  Assert-Equal $embedded.TrimEnd() $source.TrimEnd() 'bd-core init powershell output'

  # Load the wrapper the way the documented profile line does.
  Invoke-Expression (& $CoreBin init powershell | Out-String)
  Assert-True ($null -ne (Get-Command bd -CommandType Function -ErrorAction SilentlyContinue)) 'bd function is not defined'

  $expectedHook = 'prompt'
  if ($Hook -eq 'auto' -and $PSVersionTable.PSVersion.Major -ge 6) {
    $expectedHook = 'location'
  }
  Assert-Equal $global:BD_HOOK $expectedHook 'hook mode'

  $a = Enter-Dir (Join-Path $tmpDir 'a')
  $b = Enter-Dir (Join-Path $tmpDir 'b')

  bd 1
  Assert-Equal (Get-Location).ProviderPath $a 'bd 1'
  Assert-Equal $LASTEXITCODE 0 'bd 1 exit code'
  Invoke-PromptHook

  bd c
  Assert-Equal (Get-Location).ProviderPath $b 'bd c'
  Invoke-PromptHook

  $listing = @(bd ls)
  Assert-Equal $LASTEXITCODE 0 'bd ls exit code'
  Assert-True ($listing.Count -ge 1) 'bd ls printed nothing'
  Assert-True ($listing[-1] -match '^\[ *1\] ') "unexpected bd ls output: $($listing -join ' | ')"

  # Non-ASCII paths with spaces must survive the round trip through bd-core.
  $u = Enter-Dir (Join-Path $tmpDir $unicodeName)
  $null = Enter-Dir $b
  bd
  Assert-Equal (Get-Location).ProviderPath $u 'bd into a non-ASCII directory'
  Invoke-PromptHook
  bd cancel
  Assert-Equal (Get-Location).ProviderPath $b 'bd cancel'
  Invoke-PromptHook

  # History is now a, b, <unicode>, b, a: two steps back from a is <unicode>.
  $null = Enter-Dir $a
  bd 2
  Assert-Equal (Get-Location).ProviderPath $u 'bd 2'
  Invoke-PromptHook

  $out = @(bd c; bd c)
  Assert-Equal $LASTEXITCODE 1 'second bd c exit code'

  foreach ($case in @(
      @{ Args = @('0'); Text = 'bd: usage: bd [N|c|ls|h]' },
      @{ Args = @('x'); Text = 'bd: usage: bd [N|c|ls|h]' },
      @{ Args = @('1000'); Text = 'bd: max is 999' },
      @{ Args = @('1', '2'); Text = 'bd: too many arguments' },
      @{ Args = @('ls', '0'); Text = 'bd: usage: bd ls [N]' },
      @{ Args = @('ls', '1', '2'); Text = 'bd: too many arguments' },
      @{ Args = @('optimize', 'unexpected'); Text = 'bd: usage: bd optimize' },
      @{ Args = @('vacuum', '--yes', 'unexpected'); Text = 'bd: usage: bd vacuum [--yes|--y]' },
      @{ Args = @('vacuum', '--no'); Text = 'bd: usage: bd vacuum [--yes|--y]' }
    )) {
    $caseArgs = $case.Args
    $out = @(bd @caseArgs)
    Assert-Equal $LASTEXITCODE 1 "bd $caseArgs exit code"
    Assert-Equal ($out -join "`n") $case.Text "bd $caseArgs message"
  }

  $help = (@(bd --help) -join "`n") -split "`r?`n"
  Assert-Equal $help[0] 'usage: bd [N|c|ls|doctor|optimize|vacuum|h]' 'bd --help'

  $doctor = (@(bd doctor --json) -join '') | ConvertFrom-Json
  Assert-Equal $LASTEXITCODE 0 'bd doctor exit code'
  $dbPath = Join-Path (Join-Path $stateDir 'back-directory') 'bd.sqlite3'
  Assert-Equal $doctor.database $dbPath 'doctor database path'
  Assert-True (Test-Path -LiteralPath $dbPath -PathType Leaf) "database not found at $dbPath"
  Assert-True ($doctor.events -ge 4) "expected recorded events, got $($doctor.events)"

  bd optimize
  Assert-Equal $LASTEXITCODE 0 'bd optimize exit code'
  bd vacuum --yes
  Assert-Equal $LASTEXITCODE 0 'bd vacuum exit code'
  $doctor = (@(bd doctor --json) -join '') | ConvertFrom-Json
  Assert-Equal $doctor.events 0 'events after vacuum'

  if ($onWindows) {
    # Without XDG_STATE_HOME the database lives under %LOCALAPPDATA%.
    $localAppData = Join-Path $tmpDir 'localappdata'
    $null = New-Item -ItemType Directory -Force -Path $localAppData
    $env:XDG_STATE_HOME = $null
    $env:LOCALAPPDATA = $localAppData
    $doctor = (@(& $CoreBin doctor --json) -join '') | ConvertFrom-Json
    $expected = Join-Path (Join-Path $localAppData 'back-directory') 'bd.sqlite3'
    Assert-Equal $doctor.database $expected 'default Windows database path'
    Assert-True (Test-Path -LiteralPath $expected -PathType Leaf) "database not found at $expected"
  }

  Write-Output "e2e-smoke.ps1: ok (PowerShell $($PSVersionTable.PSVersion), hook=$($global:BD_HOOK))"
} finally {
  Set-Location -LiteralPath $startDir
  foreach ($name in $savedEnv.Keys) {
    [Environment]::SetEnvironmentVariable($name, $savedEnv[$name])
  }
  if (Test-Path -LiteralPath $tmpDir) {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
