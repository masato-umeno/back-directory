# back-directory (bd) - PowerShell wrapper for bd-core
#
# Load it from your PowerShell profile with one of:
#   Invoke-Expression (& bd-core init powershell | Out-String)
#   . "C:\path\to\bd.ps1"
#
# Supports Windows PowerShell 5.1 and PowerShell 7+. Keep this file ASCII-only:
# Windows PowerShell 5.1 reads BOM-less scripts in the system ANSI code page.

# Skip initialization when this file is loaded more than once.
if (-not (Get-Variable -Name BD_LOADED -Scope Global -ErrorAction SilentlyContinue)) {
  $global:BD_LOADED = $true
  $global:BD_MAX_BACK = 999
  $global:BD_SUPPRESS_RECORD = $false
  $global:BD_LAST_PWD = $null

  function global:_bd_default_core_bin {
    $cmd = Get-Command -Name 'bd-core' -CommandType Application -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($cmd) {
      return $cmd.Path
    }
    return 'bd-core'
  }

  # BD_CORE_BIN and BD_SESSION_ID can be set as environment variables before loading.
  if ($env:BD_CORE_BIN) {
    $global:BD_CORE_BIN = $env:BD_CORE_BIN
  } else {
    $global:BD_CORE_BIN = _bd_default_core_bin
  }

  function global:_bd_sanitize_session_key {
    param([string]$Key)
    return ($Key -replace '[^A-Za-z0-9._-]', '_')
  }

  function global:_bd_compute_session_id {
    # PowerShell has no tty name, and Windows reuses process ids quickly, so the
    # key combines the process id with the process start time.
    $started = 0
    try {
      $started = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    } catch {
      $started = 0
    }
    return (_bd_sanitize_session_key "ps-$PID-$started")
  }

  if ($env:BD_SESSION_ID) {
    $global:BD_SESSION_ID = $env:BD_SESSION_ID
  } else {
    $global:BD_SESSION_ID = _bd_compute_session_id
  }

  function global:_bd_require_core {
    if (Get-Command -Name $global:BD_CORE_BIN -CommandType Application -ErrorAction SilentlyContinue) {
      return $true
    }
    return $false
  }

  # Returns the current file system directory, or $null in other providers
  # (registry, certificate store, ...), which bd does not track.
  function global:_bd_current_path {
    $location = $ExecutionContext.SessionState.Path.CurrentLocation
    if ($null -eq $location -or $null -eq $location.Provider) {
      return $null
    }
    if ($location.Provider.Name -ne 'FileSystem') {
      return $null
    }
    return $location.ProviderPath
  }

  # Runs bd-core and decodes its output as UTF-8. Without this, Windows decodes
  # captured output in the OEM code page and breaks non-ASCII paths.
  function global:_bd_invoke_core {
    $ErrorActionPreference = 'Continue'
    $previous = $null
    try {
      $previous = [Console]::OutputEncoding
      [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    } catch {
      $previous = $null
    }
    try {
      & $global:BD_CORE_BIN @args
    } finally {
      if ($null -ne $previous) {
        try { [Console]::OutputEncoding = $previous } catch { $null = $_ }
      }
    }
  }

  function global:_bd_record {
    $ErrorActionPreference = 'Continue'
    if (-not (_bd_require_core)) {
      return
    }
    $path = _bd_current_path
    if ($null -eq $path) {
      return
    }
    $saved = $global:LASTEXITCODE
    try {
      & $global:BD_CORE_BIN record --session $global:BD_SESSION_ID --pwd $path *> $null
    } catch {
      $null = $_
    }
    $global:LASTEXITCODE = $saved
  }

  function global:_bd_on_location_changed {
    if ($global:BD_SUPPRESS_RECORD) {
      return
    }
    $path = _bd_current_path
    if ($null -ne $path -and $path -cne $global:BD_LAST_PWD) {
      $global:BD_LAST_PWD = $path
      _bd_record
    }
  }

  # Moves to a directory chosen by bd-core without recording the move itself.
  function global:_bd_cd {
    param([string]$Target)
    $global:BD_SUPPRESS_RECORD = $true
    try {
      Set-Location -LiteralPath $Target -ErrorAction Stop
      $global:BD_LAST_PWD = _bd_current_path
      $global:LASTEXITCODE = 0
    } catch {
      Write-Output "bd: $($_.Exception.Message)"
      $global:LASTEXITCODE = 1
    } finally {
      $global:BD_SUPPRESS_RECORD = $false
    }
  }

  function global:_bd_fail {
    param([string]$Message)
    Write-Output $Message
    $global:LASTEXITCODE = 1
  }

  # Parses a positive count. Returns 0 for invalid input and -1 when over the max.
  function global:_bd_parse_count {
    param([string]$Text)
    if ($Text -notmatch '^[0-9]+$') {
      return 0
    }
    $digits = $Text.TrimStart('0')
    if ($digits.Length -eq 0) {
      return 0
    }
    if ($digits.Length -gt 3) {
      return -1
    }
    $value = [int]$digits
    if ($value -gt $global:BD_MAX_BACK) {
      return -1
    }
    return $value
  }

  function global:bd {
    $ErrorActionPreference = 'Continue'
    $argv = @($args | ForEach-Object { [string]$_ })
    $count = $argv.Count

    $arg = '1'
    if ($count -ge 1 -and $argv[0] -ne '') {
      $arg = $argv[0]
    }

    if ($arg -ceq 'h' -or $arg -ceq 'help' -or $arg -ceq '-h' -or $arg -ceq '--help') {
      Write-Output @'
usage: bd [N|c|ls|doctor|optimize|vacuum|h]

Commands:
  bd                 go back 1 directory
  bd N               go back N directories (1 <= N <= 999)
  bd c               cancel the last bd command
  bd ls [N]          list recent targets with their N values (default 10)
  bd doctor [opts]   show database status
  bd optimize        rebuild SQLite DB to reclaim space (can be slow)
  bd vacuum          reset SQLite DB (deletes all history)
  bd h               show this help

Aliases:
  bd cancel          same as: bd c
  bd list [N]        same as: bd ls [N]
  bd help            same as: bd h
  bd -h, bd --help   show this help

Options:
  bd doctor --integrity   run SQLite integrity check (can be slow)
  bd doctor --json        output machine-readable JSON
  bd vacuum --yes|--y     skip confirmation prompt (deletes all history)

Note:
  back-directory uses a local SQLite database.
'@
      $global:LASTEXITCODE = 0
      return
    }

    if ($arg -ceq 'doctor') {
      if (-not (_bd_require_core)) { _bd_fail 'bd: bd-core not found'; return }
      $rest = @()
      if ($count -gt 1) {
        $rest = @($argv[1..($count - 1)])
      }
      _bd_invoke_core doctor @rest
      return
    }

    if ($arg -ceq 'optimize') {
      if ($count -ne 1) { _bd_fail 'bd: usage: bd optimize'; return }
      if (-not (_bd_require_core)) { _bd_fail 'bd: bd-core not found'; return }
      _bd_invoke_core optimize
      return
    }

    if ($arg -ceq 'vacuum') {
      $confirmed = $false
      if ($count -gt 2) { _bd_fail 'bd: usage: bd vacuum [--yes|--y]'; return }
      if ($count -eq 2) {
        if ($argv[1] -cne '--yes' -and $argv[1] -cne '--y') {
          _bd_fail 'bd: usage: bd vacuum [--yes|--y]'
          return
        }
        $confirmed = $true
      }
      if (-not (_bd_require_core)) { _bd_fail 'bd: bd-core not found'; return }
      if (-not $confirmed) {
        Write-Host -NoNewline 'bd: vacuum deletes all history. Continue? [y/N] '
        $reply = Read-Host
        if ($reply -ne 'y') {
          $global:LASTEXITCODE = 1
          return
        }
      }
      _bd_invoke_core vacuum --yes
      return
    }

    if ($arg -ceq 'c' -or $arg -ceq 'cancel') {
      if (-not (_bd_require_core)) { _bd_fail 'bd: bd-core not found'; return }
      $output = @(_bd_invoke_core cancel --session $global:BD_SESSION_ID)
      if ($global:LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
        return
      }
      _bd_cd ([string]$output[0])
      return
    }

    if ($arg -ceq 'ls' -or $arg -ceq 'list') {
      if ($count -gt 2) { _bd_fail 'bd: too many arguments'; return }
      $limit = 10
      if ($count -eq 2 -and $argv[1] -ne '') {
        $limit = _bd_parse_count $argv[1]
      }
      if ($limit -eq 0) { _bd_fail 'bd: usage: bd ls [N]'; return }
      if ($limit -lt 0) { _bd_fail "bd: max is $($global:BD_MAX_BACK)"; return }
      if (-not (_bd_require_core)) { _bd_fail 'bd: bd-core not found'; return }
      _bd_invoke_core list --session $global:BD_SESSION_ID --limit $limit
      return
    }

    if ($count -gt 1) { _bd_fail 'bd: too many arguments'; return }

    $steps = _bd_parse_count $arg
    if ($steps -eq 0) { _bd_fail 'bd: usage: bd [N|c|ls|h]'; return }
    if ($steps -lt 0) { _bd_fail "bd: max is $($global:BD_MAX_BACK)"; return }

    if (-not (_bd_require_core)) { _bd_fail 'bd: bd-core not found'; return }
    $output = @(_bd_invoke_core back --print-path --session $global:BD_SESSION_ID --n $steps)
    if ($global:LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
      return
    }
    _bd_cd ([string]$output[0])
  }

  # Record directory changes. PowerShell 7+ reports every location change
  # (like zsh chpwd); Windows PowerShell 5.1 has no such event, so the prompt
  # function is wrapped instead (like bash PROMPT_COMMAND). Set the environment
  # variable BD_HOOK=prompt before loading to force the prompt hook.
  $global:BD_HOOK = 'prompt'
  $bdInvokeCommand = $ExecutionContext.SessionState.InvokeCommand
  if ($env:BD_HOOK -ne 'prompt' -and $bdInvokeCommand.PSObject.Properties['LocationChangedAction']) {
    $bdAction = [System.EventHandler[System.Management.Automation.LocationChangedEventArgs]] {
      param($bdSender, $bdEventArgs)
      $null = $bdSender, $bdEventArgs
      try { _bd_on_location_changed } catch { $null = $_ }
    }
    $bdPrevious = $bdInvokeCommand.LocationChangedAction
    if ($bdPrevious) {
      $bdInvokeCommand.LocationChangedAction = [Delegate]::Combine($bdPrevious, $bdAction)
    } else {
      $bdInvokeCommand.LocationChangedAction = $bdAction
    }
    $global:BD_HOOK = 'location'
    Remove-Variable -Name bdAction, bdPrevious -ErrorAction SilentlyContinue
  } else {
    $global:_bd_original_prompt = $function:prompt
    function global:prompt {
      $bdExitCode = $global:LASTEXITCODE
      try { _bd_on_location_changed } catch { $null = $_ }
      $global:LASTEXITCODE = $bdExitCode
      if ($global:_bd_original_prompt) {
        & $global:_bd_original_prompt
      } else {
        "PS $($ExecutionContext.SessionState.Path.CurrentLocation)> "
      }
    }
  }
  Remove-Variable -Name bdInvokeCommand -ErrorAction SilentlyContinue

  $global:BD_LAST_PWD = _bd_current_path
  _bd_record
}
