# Installs codex-effortless for Codex on Windows: the CLI in PowerShell or cmd, and Codex Desktop. Codex inside WSL
# has its own ~/.codex: install there with install.sh.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1               install, asking a few setup questions
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Quiet        install with what is already set (updates use this)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Desktop      also turn on Auto in Codex Desktop
#   powershell -ExecutionPolicy Bypass -File install.ps1 -StatusLine   also show effort, context and limits in the status line
#   powershell -ExecutionPolicy Bypass -File install.ps1 -AddToPath    also put codex-auto on your user PATH
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall    remove it (settings and log kept; -Purge: those too)
#
# Builds effortless.exe from windows\effortless.cs with the C# compiler that comes with Windows (.NET Framework 4),
# and puts it with effortless.conf in %USERPROFILE%\.codex\effortless, a UserPromptSubmit entry in
# %USERPROFILE%\.codex\hooks.json, the $effortless skill in %USERPROFILE%\.codex\skills, and codex-auto.cmd in effortless\bin.
param([switch]$Quiet, [switch]$Desktop, [switch]$StatusLine, [switch]$AddToPath, [switch]$Uninstall, [switch]$Purge)
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$Dest = Join-Path $CodexHome 'effortless'
$Bin = Join-Path $Dest 'bin'
$Exe = Join-Path $Dest 'effortless.exe'
$Hooks = Join-Path $CodexHome 'hooks.json'
$Skill = Join-Path $CodexHome 'skills\effortless'
$Mark = 'effortless\\+(effortless\.exe|judge\.ps1)'   # a regex: hooks.json stores the backslash escaped
if ($Quiet -or -not [Environment]::UserInteractive) { $Quiet = $true }

# Codex runs a hook as cmd.exe /C "<command>".
$entry = [ordered]@{
  hooks = [ordered]@{
    UserPromptSubmit = @(
      [ordered]@{
        hooks = @(
          [ordered]@{ type = 'command'; command = "`"$Exe`" hook"; timeout = 30; statusMessage = 'effortless: Luna 正在判断档位…' }
        )
      }
    )
  }
}
$entryJson = $entry | ConvertTo-Json -Depth 10

function Only-Ours($text) {
  $groups = @(($text | ConvertFrom-Json).hooks.PSObject.Properties | ForEach-Object { @($_.Value) })
  return $groups.Count -eq 1
}
function Path-Without($path, $dir) { (@($path -split ';') | Where-Object { $_ -and $_.TrimEnd('\') -ne $dir.TrimEnd('\') }) -join ';' }

if ($Uninstall -or $Purge) {
  if (Test-Path -LiteralPath $Exe) { & $Exe desktop off | Out-Null }
  if (Test-Path -LiteralPath $Hooks) {
    $text = [IO.File]::ReadAllText($Hooks, $Utf8)
    if ($text -match $Mark) {
      if (Only-Ours $text) { Remove-Item -LiteralPath $Hooks; "Removed $Hooks" }
      else { "$Hooks has other hooks too: remove the entry that runs effortless.exe by hand." }
    }
  }
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath -and ($userPath -split ';') -contains $Bin) { [Environment]::SetEnvironmentVariable('Path', (Path-Without $userPath $Bin), 'User') }
  Remove-Item -LiteralPath $Skill, $Bin, (Join-Path $Dest 'bench') -Recurse -Force -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $Dest -Filter 'effortless*.exe' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath (Join-Path $Dest 'judge.ps1'), (Join-Path $Dest 'source'), (Join-Path $Dest 'effortless.cs') -ErrorAction SilentlyContinue
  if ($Purge) { Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue }
  'codex-effortless uninstalled. (A Codex Desktop that is open keeps Auto until it restarts.)'
  exit 0
}

# Build. A running effortless.exe (Codex Desktop holds one) cannot be overwritten, but it can be renamed away.
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw 'The .NET Framework 4 C# compiler (csc.exe) was not found.' }
[void](New-Item -ItemType Directory -Force -Path $Dest, $Bin, (Join-Path $Dest 'bench'), $Skill)
$new = Join-Path $Dest 'effortless.new.exe'
# Built from a local copy: compiling straight off a network path (such as \\wsl.localhost) looks like a dropper to
# behaviour-based antivirus.
$src = Join-Path $Dest 'effortless.cs'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows\effortless.cs') -Destination $src -Force
$out = & $csc /nologo /codepage:65001 /target:exe /optimize "/out:$new" /r:System.Web.Extensions.dll $src 2>&1
if ($LASTEXITCODE -ne 0) { $out; throw 'Building effortless.exe failed.' }
Get-ChildItem -LiteralPath $Dest -Filter 'effortless.old-*.exe' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath $Exe) {
  try { Remove-Item -LiteralPath $Exe -Force } catch { Rename-Item -LiteralPath $Exe -NewName ('effortless.old-{0}.exe' -f [DateTime]::Now.Ticks) }
}
Rename-Item -LiteralPath $new -NewName 'effortless.exe'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'bench\judge-cases.json') -Destination (Join-Path $Dest 'bench\judge-cases.json') -Force
[IO.File]::WriteAllText((Join-Path $Dest 'source'), $PSScriptRoot, $Utf8)
Remove-Item -LiteralPath (Join-Path $Dest 'judge.ps1') -ErrorAction SilentlyContinue   # the hook before effortless.exe

# Settings: a new install gets the template; an existing file keeps every value and gains the settings it lacks.
$conf = Join-Path $Dest 'effortless.conf'
$template = [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'effortless.conf'), $Utf8)
if (Test-Path -LiteralPath $conf) {
  $have = [IO.File]::ReadAllText($conf, $Utf8)
  $add = @($template | Where-Object { $_ -match '^(EFFORTLESS_[A-Z_]+)=' -and $have -notmatch ('(?m)^\s*' + $Matches[1] + '=') })
  if ($add.Count) { [IO.File]::AppendAllText($conf, (($add -join "`n") + "`n"), $Utf8) }
  "Kept your $conf" + $(if ($add.Count) { " (added $($add.Count) new settings)" } else { '' })
} else {
  [IO.File]::WriteAllText($conf, (($template -join "`n") + "`n"), $Utf8)
}

# The $effortless skill, with this machine's command in it.
$eff = "& `"$Exe`""
$save = "@'`n(the handoff)`n'@ | & `"$Exe`" handoff-save"
$md = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'skills\effortless\SKILL.md'), $Utf8)
[IO.File]::WriteAllText((Join-Path $Skill 'SKILL.md'), $md.Replace('{{EFFORTLESS}}', $eff).Replace('{{SAVE_EXAMPLE}}', $save), $Utf8)

# codex-auto: the Codex CLI with Auto. Your PATH is changed only with -AddToPath: a script that builds an exe and then
# edits PATH is what behaviour-based antivirus (Kaspersky's, for one) takes for a trojan, and rolls back.
[IO.File]::WriteAllText((Join-Path $Bin 'codex-auto.cmd'), "@echo off`r`nrem codex-effortless: the Codex CLI with Auto (every prompt runs at the effort the judge picks).`r`n`"%~dp0..\effortless.exe`" codex %*`r`n", [Text.Encoding]::ASCII)
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($AddToPath -and -not (($userPath -split ';') -contains $Bin)) {
  [Environment]::SetEnvironmentVariable('Path', ((@($userPath, $Bin) | Where-Object { $_ }) -join ';'), 'User')
  "Added $Bin to your PATH (new terminals see it)."
}

if (-not (Test-Path -LiteralPath $Hooks)) {
  [IO.File]::WriteAllText($Hooks, $entryJson + "`n", $Utf8)
  "Wrote $Hooks"
} else {
  $text = [IO.File]::ReadAllText($Hooks, $Utf8)
  if ($text -match $Mark -and (Only-Ours $text)) {
    if ($text -notmatch 'effortless\.exe') { [IO.File]::WriteAllText($Hooks, $entryJson + "`n", $Utf8); "Updated $Hooks to run effortless.exe (trust it again with /hooks)." }
    else { "$Hooks already runs effortless." }
  } elseif ($text -match $Mark) {
    "$Hooks runs effortless among other hooks: make sure its command is: `"$Exe`" hook"
  } else {
    "$Hooks already exists with other hooks. Add this UserPromptSubmit entry to it by hand:"
    $entryJson
  }
}

$cfg = Join-Path $CodexHome 'config.toml'
if (-not $Quiet) {
  ''
  'Setup (Enter keeps the choice in brackets; change any of it later with $effortless settings):'
  $j = Read-Host '  Judge: 1 Luna on your Codex login, 2 an OpenAI-compatible API, 3 add Jev (TypeSafe key) [1]'
  if ($j -eq '2') {
    $url = Read-Host '  API base URL (e.g. https://openrouter.ai/api/v1)'
    $kenv = Read-Host '  Name of the environment variable holding the key, set with setx (e.g. OPENROUTER_API_KEY)'
    $am = Read-Host '  Model name at that API [openai/gpt-5.6-luna]'
    if ($url) { & $Exe config set EFFORTLESS_API_URL $url | Out-Null }
    if ($kenv) { & $Exe config set EFFORTLESS_API_KEY_ENV $kenv | Out-Null }
    if ($am) { & $Exe config set EFFORTLESS_API_MODEL $am | Out-Null }
  } elseif ($j -eq '3') {
    $k = Read-Host '  TypeSafe key (not shown; saved in effortless.conf in your profile)' -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($k))
    if ($plain) { & $Exe config set EFFORTLESS_TYPESAFE_KEY $plain | Out-Null }
  }
  $b = Read-Host '  Lean: -2 cheapest ... 0 balanced ... 2 smartest [0]'
  if ($b) { & $Exe config set EFFORTLESS_BIAS $b | Out-Null }
  if (-not $StatusLine -and -not ((Test-Path -LiteralPath $cfg) -and ([IO.File]::ReadAllText($cfg, $Utf8) -match '(?m)^\s*status_line\s*='))) {
    $s = Read-Host '  Show effort, context and limits in the Codex CLI status line? [Y/n]'
    if ($s -eq '' -or $s -match '^[yY]') { $StatusLine = $true }
  }
  if (-not $Desktop) {
    '  Auto in Codex Desktop: Desktop then starts its app-server through effortless.exe, which sets each prompt''s'
    '  effort. Desktop runs it like the CLI does, without its own Windows sandbox service (see the README).'
    $d = Read-Host '  Turn on Auto in Codex Desktop? [y/N]'
    if ($d -match '^[yY]') { $Desktop = $true }
  }
}

# The status line shows what the original's bar did: the effort in use, how full the context is, the limits.
if ($StatusLine) {
  $text = if (Test-Path -LiteralPath $cfg) { [IO.File]::ReadAllText($cfg, $Utf8) } else { '' }
  if ($text -match '(?m)^\s*status_line\s*=') { 'Your config.toml already sets status_line; left as it is.' }
  else {
    if (Test-Path -LiteralPath $cfg) { Copy-Item -LiteralPath $cfg -Destination "$cfg.before-effortless" -Force }
    $line = 'status_line = ["model-with-reasoning", "context-used", "five-hour-limit", "weekly-limit", "current-dir"]'
    if ($text -match '(?m)^\s*\[tui\]\s*$') { $text = [regex]::Replace($text, '(?m)^(\s*\[tui\]\s*\r?\n)', "`$1$line`n", 1) }
    else { $text = $text.TrimEnd() + "`n`n[tui]`n$line`n" }
    [IO.File]::WriteAllText($cfg, $text, $Utf8)
    "Status line set in $cfg (backup: config.toml.before-effortless)."
  }
}
if ($Desktop) { & $Exe desktop on }

@"

Next:
  1. Trust the hook: start the CLI (codex.cmd if your execution policy blocks codex.ps1) and run /hooks.
     Codex Desktop reads the same %USERPROFILE%\.codex, so it is trusted there too.
  2. codex-auto starts Codex with Auto: every prompt runs at the effort the judge picks. It is
     $Bin\codex-auto.cmd (add that folder to PATH yourself, or install with -AddToPath).
     Plain codex works too: then the hook says which effort to switch to.
  3. `$effortless in Codex: stats, settings, save mode, handoff and the rest.
"@
