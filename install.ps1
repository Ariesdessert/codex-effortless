# Installs codex-effortless for Codex on Windows (the CLI in PowerShell or cmd, and Codex Desktop):
#   %USERPROFILE%\.codex\effortless\{judge.ps1,effortless.conf}  and a UserPromptSubmit entry in
#   %USERPROFILE%\.codex\hooks.json. Codex inside WSL has its own ~/.codex: install there with install.sh.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1              install
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall   remove (settings and log kept)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Purge       remove, settings and log too
param([switch]$Uninstall, [switch]$Purge)
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$Dest = Join-Path $CodexHome 'effortless'
$Hooks = Join-Path $CodexHome 'hooks.json'
$Mark = 'effortless\\+judge\.ps1'   # a regex: hooks.json stores the backslash escaped

# Codex runs a hook as cmd.exe /C "<command>". -ExecutionPolicy Bypass lets the script run under an
# AllSigned or RemoteSigned policy without changing it for anything else.
$command = '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $Dest 'judge.ps1') + '"'
$entry = [ordered]@{
  hooks = [ordered]@{
    UserPromptSubmit = @(
      [ordered]@{
        hooks = @(
          [ordered]@{ type = 'command'; command = $command; timeout = 30; statusMessage = 'effortless: Luna 正在判断档位…' }
        )
      }
    )
  }
}
$entryJson = $entry | ConvertTo-Json -Depth 10

if ($Uninstall -or $Purge) {
  if (Test-Path -LiteralPath $Hooks) {
    $text = [IO.File]::ReadAllText($Hooks, $Utf8)
    if ($text -match $Mark) {
      $groups = @(($text | ConvertFrom-Json).hooks.PSObject.Properties | ForEach-Object { @($_.Value) })
      if ($groups.Count -eq 1) { Remove-Item -LiteralPath $Hooks; "Removed $Hooks" }
      else { "$Hooks has other hooks too: remove the entry that runs judge.ps1 by hand." }
    }
  }
  Remove-Item -LiteralPath (Join-Path $Dest 'judge.ps1') -ErrorAction SilentlyContinue
  if ($Purge) { Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue }
  'codex-effortless uninstalled.'
  exit 0
}

$codex = Get-Command codex.exe, codex.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
$desktop = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue
if (-not $codex -and -not $desktop) { Write-Warning 'Neither the codex CLI nor Codex Desktop was found; the judge needs one of them (or an API, see README).' }

[void](New-Item -ItemType Directory -Force -Path $Dest)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'judge.ps1') -Destination (Join-Path $Dest 'judge.ps1') -Force
$conf = Join-Path $Dest 'effortless.conf'
if (Test-Path -LiteralPath $conf) { "Kept your existing $conf" }
else { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'effortless.conf') -Destination $conf }

if (-not (Test-Path -LiteralPath $Hooks)) {
  [IO.File]::WriteAllText($Hooks, $entryJson + "`n", $Utf8)
  "Wrote $Hooks"
} elseif ([IO.File]::ReadAllText($Hooks, $Utf8) -match $Mark) {
  "$Hooks already runs effortless."
} else {
  "$Hooks already exists with other hooks. Add this UserPromptSubmit entry to it by hand:"
  $entryJson
}

@"

Next:
  1. Trust the hook: start the CLI (codex.cmd in PowerShell if your execution policy blocks codex.ps1)
     and run /hooks. Codex Desktop reads the same %USERPROFILE%\.codex, so it is trusted there too.
  2. Send a prompt: while "effortless: Luna 正在判断档位…" shows, Luna is judging (about 10 s).
  3. powershell -ExecutionPolicy Bypass -File "$Dest\judge.ps1" -Stats   shows what it has suggested.
"@
