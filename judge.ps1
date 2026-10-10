# codex-effortless for Windows (Codex CLI in PowerShell and Codex Desktop): the same UserPromptSubmit
# hook as judge.sh, in PowerShell 5.1+ so it needs nothing beyond Windows itself. GPT-5.6 Luna judges
# how much reasoning effort the prompt needs; when that differs from the effort Codex is on, the hook
# says so (or, in block mode, holds the prompt back). It never changes the effort itself.
#
#   judge.ps1            run as the hook (reads the hook payload on stdin)
#   judge.ps1 -Stats     summarise the local verdict log
param([switch]$Stats)
$ErrorActionPreference = 'Stop'

# The judge's own app-server has hooks disabled; this guards anything else that might call us back.
if ($env:EFFORTLESS_JUDGE) { exit 0 }

$Utf8 = New-Object System.Text.UTF8Encoding($false)
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }

# effortless.conf is shared with judge.sh: KEY=value or KEY=${KEY:-value}, # comments.
$conf = @{}
$confPath = Join-Path $PSScriptRoot 'effortless.conf'
if (Test-Path -LiteralPath $confPath) {
  foreach ($line in [IO.File]::ReadAllLines($confPath, $Utf8)) {
    if ($line -match '^\s*(EFFORTLESS_\w+)=(.*)$') {
      $name = $Matches[1]; $v = $Matches[2]
      if ($v -match '^\$\{\w+:-([^}]*)\}') { $v = $Matches[1] } else { $v = ($v -replace '\s+#.*$', '') }
      $conf[$name] = $v.Trim().Trim('"', "'")
    }
  }
}
function Setting($name, $default) {
  $e = [Environment]::GetEnvironmentVariable($name)
  if ($e) { return $e }
  if ($conf.ContainsKey($name) -and $conf[$name] -ne '') { return $conf[$name] }
  return $default
}

$MODE = Setting 'EFFORTLESS_MODE' 'warn'
$MODEL = Setting 'EFFORTLESS_MODEL' 'gpt-5.6-luna'
$MIN = Setting 'EFFORTLESS_MIN' 'medium'
$MAX = Setting 'EFFORTLESS_MAX' 'xhigh'
$BIAS = [int](Setting 'EFFORTLESS_BIAS' '0')
$BLOCK_GAP = [int](Setting 'EFFORTLESS_BLOCK_GAP' '1')
$BUDGET = [int](Setting 'EFFORTLESS_TIMEOUT' '20')
$API_URL = Setting 'EFFORTLESS_API_URL' ''
$API_KEY = Setting 'EFFORTLESS_API_KEY' ''
$keyEnv = Setting 'EFFORTLESS_API_KEY_ENV' ''
if (-not $API_KEY -and $keyEnv) {
  # A Codex Desktop started from the Start menu may not see a variable set in one terminal, so the
  # user-level variable (setx) is read as well.
  $API_KEY = [Environment]::GetEnvironmentVariable($keyEnv)
  if (-not $API_KEY) { $API_KEY = [Environment]::GetEnvironmentVariable($keyEnv, 'User') }
}
$API_MODEL = Setting 'EFFORTLESS_API_MODEL' 'openai/gpt-5.6-luna'
$API_STYLE = Setting 'EFFORTLESS_API_STYLE' 'chat'
$API_FORMAT = Setting 'EFFORTLESS_API_FORMAT' 'schema'
$API_REASONING = Setting 'EFFORTLESS_API_REASONING' ''
$FALLBACK = Setting 'EFFORTLESS_FALLBACK' 'codex'
$CODEX = Setting 'EFFORTLESS_CODEX' ''
$DATA = Setting 'EFFORTLESS_DATA' (Join-Path $CodexHome 'effortless\data')
[void](New-Item -ItemType Directory -Force -Path $DATA)
$LOG = Join-Path $DATA 'verdicts.tsv'

$LEVELS = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')
function Idx($level) { [array]::IndexOf($LEVELS, [string]$level) }

if ($Stats) {
  if (-not (Test-Path -LiteralPath $LOG) -or (Get-Item -LiteralPath $LOG).Length -eq 0) { "No verdicts yet ($LOG)."; exit 0 }
  $rows = @([IO.File]::ReadAllLines($LOG, $Utf8) | Where-Object { $_ } | ForEach-Object { , ($_ -split "`t") })
  "Verdicts: $($rows.Count)"
  foreach ($c in @(@{ n = 'By verdict'; i = 2 }, @{ n = 'Actions'; i = 6 }, @{ n = 'Judges'; i = 7 })) {
    "$($c.n):"
    $rows | ForEach-Object { $_[$c.i] } | Where-Object { $_ -and $_ -ne '-' } | Group-Object | Sort-Object Count -Descending |
      ForEach-Object { '{0,7} {1}' -f $_.Count, $_.Name }
  }
  $timed = @($rows | Where-Object { [int]$_[4] -gt 0 })
  if ($timed.Count) {
    $ms = ($timed | ForEach-Object { [int]$_[4] } | Measure-Object -Average).Average
    $tk = ($timed | ForEach-Object { [int]$_[5] } | Measure-Object -Average).Average
    'Average judge time {0:0} ms, {1:0} tokens' -f $ms, $tk
  }
  exit 0
}

if ($MODE -eq 'off') { exit 0 }
$by = '-'
function Log($cur, $verdict, $sure, $ms, $tokens, $action) {
  $row = @((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $cur, $verdict, $sure, $ms, $tokens, $action, $by) -join "`t"
  try { [IO.File]::AppendAllText($LOG, "$row`n", $Utf8) } catch {}
}
function Say($obj) {
  $bytes = $Utf8.GetBytes(($obj | ConvertTo-Json -Compress) + "`n")
  $out = [Console]::OpenStandardOutput(); $out.Write($bytes, 0, $bytes.Length); $out.Flush()
}
function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
# Reads a file Codex may still be writing.
function ReadShared($path) {
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
  try { (New-Object IO.StreamReader($fs, $Utf8)).ReadToEnd() } finally { $fs.Dispose() }
}

# The payload arrives as UTF-8 whatever the console code page is.
$payloadText = (New-Object IO.StreamReader([Console]::OpenStandardInput(), $Utf8)).ReadToEnd()
try { $payload = $payloadText | ConvertFrom-Json } catch { exit 0 }
$prompt = [string]$payload.prompt
$transcript = [string]$payload.transcript_path
if (-not $prompt.Trim()) { exit 0 }

# The effort in use: the last one the session recorded, else config.toml, else Codex's default.
$current = ''; $desktop = $false
if ($transcript -and (Test-Path -LiteralPath $transcript)) {
  try {
    $t = ReadShared $transcript
    $m = [regex]::Matches($t, '"reasoning_effort"\s*:\s*"([a-z]+)"')
    if ($m.Count) { $current = $m[$m.Count - 1].Groups[1].Value }
    $desktop = $t.Substring(0, [Math]::Min(4000, $t.Length)) -match '"originator"\s*:\s*"Codex Desktop"'
  } catch {}
}
if (-not $current) {
  $cfg = Join-Path $CodexHome 'config.toml'
  if (Test-Path -LiteralPath $cfg) {
    $m = [regex]::Matches([IO.File]::ReadAllText($cfg, $Utf8), '(?m)^\s*model_reasoning_effort\s*=\s*"([a-z]+)"')
    if ($m.Count) { $current = $m[$m.Count - 1].Groups[1].Value }
  }
}
if (-not $current) { $current = 'medium' }
# An effort this script does not know (a new level, say) cannot be compared: stay out of the way.
if ((Idx $current) -lt 0) { Log $current '-' '-' 0 0 'unknown-effort'; exit 0 }

# "ok", "go", "继续" between two steps keep the effort the work is already on: no judge.
if ($prompt.Length -le 24 -and $prompt -match '^\s*(ok(ay)?|y(es)?|yep|sure|go( ahead)?|continue|do it|proceed|thanks?|lgtm|好的?|行|可以|继续|是的?|对|嗯|开始吧?|确认|没问题)\s*[.!。！~]*\s*$') {
  Log $current '-' '-' 0 0 'follow-up'; exit 0
}

# The same prompt sent again (after a block, say) reuses its verdict instead of asking again.
$md5 = [Security.Cryptography.MD5]::Create()
$key = (-join ($md5.ComputeHash($Utf8.GetBytes($prompt)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
# A prompt this hook held back, sent again: the person has seen the advice, so it goes through.
$held = Join-Path $DATA 'held'
if (Test-Path -LiteralPath $held) {
  $h = ([IO.File]::ReadAllText($held)).Trim() -split '\s+'
  if ($h[0] -eq $key -and ((Now) - [long]$h[1]) -lt 900) {
    Remove-Item -LiteralPath $held -Force
    Log $current '-' '-' 0 0 'resent'; exit 0
  }
}

$effort = ''; $sure = 0.5; $why = ''; $ms = 0; $tokens = 0
$last = Join-Path $DATA 'last'
$cached = $false
if (Test-Path -LiteralPath $last) {
  $c = ([IO.File]::ReadAllText($last)).Trim() -split '\s+'
  if ($c.Count -ge 4 -and $c[0] -eq $key -and ((Now) - [long]$c[1]) -lt 900) {
    $cached = $true; $effort = $c[2]; $sure = $c[3]
    try { $why = [IO.File]::ReadAllText((Join-Path $DATA 'last.why'), $Utf8) } catch {}
  }
}

if (-not $cached) {
  $p = if ($prompt.Length -gt 6000) { $prompt.Substring(0, 6000) } else { $prompt }
  # Never cut a surrogate pair in half.
  if ($p.Length -and [char]::IsHighSurrogate($p[$p.Length - 1])) { $p = $p.Substring(0, $p.Length - 1) }

  $INSTRUCTIONS = 'You decide how much reasoning effort a coding agent should spend on the user message you are given. Never use tools. Answer only with the JSON the schema asks for. Levels: low = quick questions, explanations, small mechanical edits such as a rename, a typo or a config value, running one command. medium = ordinary feature work or a bug fix in code that is easy to locate, moderate multi-file edits, tests for clear behaviour. high = debugging unclear failures, concurrency, performance or security problems, design decisions, refactors across many files, anything where a wrong answer is costly. xhigh = long autonomous multi-step tasks, deep investigations, hard algorithmic or architectural problems. sure is your confidence from 0 to 1. why is one short reason, under 20 words, in the language of the user message.'
  $SCHEMA = [ordered]@{
    type = 'object'; additionalProperties = $false; required = @('effort', 'sure', 'why')
    properties = [ordered]@{
      effort = [ordered]@{ type = 'string'; enum = @('low', 'medium', 'high', 'xhigh') }
      sure = @{ type = 'number' }
      why = @{ type = 'string' }
    }
  }
  $ASK = "The agent is on reasoning effort $current. The user message:`n`n$p"
  $script:failed = ''

  # Finds the codex executable: the setting, then PATH, then the npm package, then Codex Desktop's own.
  function FindCodex {
    if ($CODEX) { return $CODEX }
    $cmd = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $npm = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
    if (Test-Path -LiteralPath $npm) { return $npm }
    try {
      $pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop | Select-Object -First 1
      $exe = Join-Path $pkg.InstallLocation 'app\resources\codex.exe'
      if (Test-Path -LiteralPath $exe) { return $exe }
    } catch {}
    return $null
  }

  # Each judge returns the verdict text (JSON) and sets $script:tokens, or returns $null and sets
  # $script:failed to the step that went wrong.
  function JudgeCodex {
    $exe = FindCodex
    if (-not $exe) { $script:failed = 'no-codex'; return $null }
    $off = 'apps browser_use browser_use_external computer_use code_mode_host goals hooks image_generation multi_agent plugins remote_plugin shell_snapshot shell_tool skill_search sleep_tool tool_suggest unified_exec view_image web_search workspace_dependencies worktrees'
    # notify = [] keeps a notify program from config.toml from firing on the judge's turn (it would see
    # the prompt, and a long-lived one would hold this hook's output open).
    $argline = 'app-server -c notify=[]' + (-join ($off -split ' ' | ForEach-Object { " --disable $_" }))
    # An empty working directory keeps project files such as AGENTS.md out of the judge's context.
    $cwd = Join-Path $DATA 'judge-cwd'; [void](New-Item -ItemType Directory -Force -Path $cwd)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = $argline; $psi.WorkingDirectory = $cwd
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.EnvironmentVariables['EFFORTLESS_JUDGE'] = '1'
    $deadline = [DateTime]::UtcNow.AddSeconds($BUDGET)
    $proc = [Diagnostics.Process]::Start($psi)
    # Drained so a chatty stderr cannot fill its pipe and stall the server.
    $proc.BeginErrorReadLine()
    try {
      $stdin = $proc.StandardInput.BaseStream
      function Send($obj) {
        $b = $Utf8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 20) + "`n"); $stdin.Write($b, 0, $b.Length); $stdin.Flush()
      }
      $script:pending = $null
      # The first line containing $needle that arrives before the deadline.
      function Await($needle) {
        while ($true) {
          $left = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
          if ($left -le 0) { return $null }
          if (-not $script:pending) { $script:pending = $proc.StandardOutput.ReadLineAsync() }
          if (-not $script:pending.Wait([int]$left)) { return $null }
          $line = $script:pending.Result; $script:pending = $null
          if ($null -eq $line) { return $null }
          if ($line.Contains($needle)) { return $line }
        }
      }
      Send ([ordered]@{ id = 1; method = 'initialize'; params = [ordered]@{ clientInfo = [ordered]@{ name = 'codex-effortless'; title = $null; version = '0.3.0' }; capabilities = $null } })
      if (-not (Await '"id":1')) { $script:failed = 'init'; return $null }
      Send @{ method = 'initialized' }
      Send ([ordered]@{ id = 2; method = 'thread/start'; params = [ordered]@{ model = $MODEL; ephemeral = $true; sandbox = 'read-only'; approvalPolicy = 'never'; cwd = $cwd; baseInstructions = $INSTRUCTIONS } })
      $r = Await '"id":2'
      if (-not $r) { $script:failed = 'thread'; return $null }
      $tid = ($r | ConvertFrom-Json).result.thread.id
      if (-not $tid) { $script:failed = 'thread'; return $null }
      Send ([ordered]@{ id = 3; method = 'turn/start'; params = [ordered]@{ threadId = $tid; effort = 'none'; outputSchema = $SCHEMA; input = @([ordered]@{ type = 'text'; text = "[effortless-judge] $ASK" }) } })
      # Wait for the finished answer; a turn that ends without one (an unknown model, an error) fails at once.
      $text = $null
      while ($m = Await '"method":"') {
        $j = $m | ConvertFrom-Json
        if ($j.method -eq 'item/completed' -and $j.params.item.type -eq 'agentMessage') { $text = $j.params.item.text; break }
        if ($j.method -eq 'turn/completed' -or $j.method -eq 'error') { break }
      }
      if (-not $text) { $script:failed = 'turn'; return $null }
      $u = Await 'thread/tokenUsage/updated'
      if ($u) { try { $script:tokens = [int](($u | ConvertFrom-Json).params.tokenUsage.total.totalTokens) } catch {} }
      return $text
    } finally {
      # The whole tree: anything the server started inherits this hook's handles and would keep Codex waiting.
      try { if (-not $proc.HasExited) { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } } catch {}
      try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
    }
  }

  # Any OpenAI-compatible endpoint: OpenRouter, OpenAI, a relay. Chat Completions or the Responses API.
  function JudgeApi {
    $url = $API_URL.TrimEnd('/'); $style = $API_STYLE
    if ($url -match '/chat/completions$') { $style = 'chat' }
    elseif ($url -match '/responses$') { $style = 'responses' }
    elseif ($style -eq 'responses') { $url += '/responses' }
    else { $url += '/chat/completions' }
    $system = "$INSTRUCTIONS Reply with a JSON object with the keys effort, sure and why."
    if ($style -eq 'responses') {
      $body = [ordered]@{ model = $API_MODEL; max_output_tokens = 400; store = $false; instructions = $system; input = $ASK }
      if ($API_FORMAT -eq 'object') { $body.text = @{ format = @{ type = 'json_object' } } }
      elseif ($API_FORMAT -ne 'none') { $body.text = @{ format = [ordered]@{ type = 'json_schema'; name = 'verdict'; strict = $true; schema = $SCHEMA } } }
      if ($API_REASONING) { $body.reasoning = @{ effort = $API_REASONING } }
    } else {
      $body = [ordered]@{ model = $API_MODEL; max_tokens = 400; messages = @(@{ role = 'system'; content = $system }, @{ role = 'user'; content = $ASK }) }
      if ($API_FORMAT -eq 'object') { $body.response_format = @{ type = 'json_object' } }
      elseif ($API_FORMAT -ne 'none') { $body.response_format = [ordered]@{ type = 'json_schema'; json_schema = [ordered]@{ name = 'verdict'; strict = $true; schema = $SCHEMA } } }
      if ($API_REASONING) { $body.reasoning_effort = $API_REASONING }
    }
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($BUDGET)
    try {
      $req = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Post, $url)
      [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $API_KEY")
      [void]$req.Headers.TryAddWithoutValidation('X-Title', 'codex-effortless')
      $req.Content = New-Object Net.Http.StringContent(($body | ConvertTo-Json -Compress -Depth 20), $Utf8, 'application/json')
      try { $res = $client.SendAsync($req).GetAwaiter().GetResult() } catch { $script:failed = 'http-000'; return $null }
      $raw = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      if ([int]$res.StatusCode -ne 200) { $script:failed = "http-$([int]$res.StatusCode)"; return $null }
    } finally { $client.Dispose() }
    try { $j = $raw | ConvertFrom-Json } catch { $script:failed = 'reply'; return $null }
    if ($j.usage.total_tokens) { $script:tokens = [int]$j.usage.total_tokens }
    if ($style -eq 'responses') {
      if ($j.output_text) { return [string]$j.output_text }
      return (-join @($j.output | ForEach-Object { $_.content } | Where-Object { $_.type -eq 'output_text' } | ForEach-Object { $_.text }))
    }
    return [string]$j.choices[0].message.content
  }

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $script:tokens = 0; $by = 'codex'; $verdictText = $null
  try {
    if ($API_URL -and $API_KEY) {
      $by = 'api'
      $verdictText = JudgeApi
      if (-not $verdictText) {
        Log $current '-' '-' $sw.ElapsedMilliseconds 0 "fail:api:$script:failed"
        if ($FALLBACK -ne 'codex') { exit 0 }
        $by = 'codex'; $script:failed = ''
      }
    }
    if ($by -eq 'codex') {
      $verdictText = JudgeCodex
      if (-not $verdictText) { Log $current '-' '-' $sw.ElapsedMilliseconds 0 "fail:codex:$script:failed"; exit 0 }
    }
  } catch {
    Log $current '-' '-' $sw.ElapsedMilliseconds 0 "fail:${by}:error"; exit 0
  }
  $ms = $sw.ElapsedMilliseconds; $tokens = $script:tokens

  try { $v = [string]$verdictText -replace '(?s)^\s*```(json)?\s*|\s*```\s*$', '' | ConvertFrom-Json } catch { $v = $null }
  $effort = [string]$v.effort
  if (-not $v -or (Idx $effort) -lt 0) { Log $current '-' '-' $ms $tokens "fail:${by}:verdict"; exit 0 }
  $sure = if ($null -ne $v.sure) { [double]$v.sure } else { 0.5 }
  $why = ([string]$v.why -replace '["\\]', '') -replace '[.。!！ ]+$', ''
  [IO.File]::WriteAllText($last, "$key $(Now) $effort $([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $sure))")
  [IO.File]::WriteAllText((Join-Path $DATA 'last.why'), $why, $Utf8)
}
$sure = [double]::Parse([string]$sure, [Globalization.CultureInfo]::InvariantCulture)

# Close calls lean the way the slider says; sure calls stay. Then the floor and ceiling.
$i = Idx $effort
if ($BIAS -ne 0) {
  $limit = if ([Math]::Abs($BIAS) -eq 1) { 0.65 } else { 0.85 }
  if ($sure -lt $limit) { $i = [Math]::Min([Math]::Max($i + [Math]::Sign($BIAS), 2), $LEVELS.Count - 1) }
}
$lo = Idx $MIN; $hi = Idx $MAX
if ($lo -lt 0) { $lo = Idx 'medium' }; if ($hi -lt 0) { $hi = Idx 'xhigh' }; if ($hi -lt $lo) { $hi = $lo }
$i = [Math]::Min([Math]::Max($i, $lo), $hi)
$picked = $LEVELS[$i]
$sureText = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $sure)

$gap = $i - (Idx $current)
if ($gap -eq 0) { Log $current $picked $sureText $ms $tokens 'same'; exit 0 }

# Codex Desktop has no effort shortcut keys: there it is the effort menu by the prompt box.
if ($desktop) { $how = "在输入框旁的推理档位菜单切到 $picked" }
elseif ($gap -gt 0) { $how = "按 Alt+. 升 $gap 档" }
else { $how = "按 Alt+, 降 $(-$gap) 档" }
$text = "effortless: 建议 $picked（当前 $current）— $why"
if ($MODE -eq 'block' -and $gap -ge $BLOCK_GAP) {
  Log $current $picked $sureText $ms $tokens 'block'
  [IO.File]::WriteAllText($held, "$key $(Now)")
  Say ([ordered]@{ decision = 'block'; reason = "$text。$how 后直接回车重发（重发会直接放行）。" })
} else {
  Log $current $picked $sureText $ms $tokens 'warn'
  Say @{ systemMessage = "$text（$how，对下一条消息生效）" }
}
