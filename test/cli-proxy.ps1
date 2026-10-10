# Drives `effortless.exe codex --serve` the way the Codex TUI does (a WebSocket with a bearer token), on Windows,
# against the real codex.exe and judge:
#   0. a connection without the token is refused;
#   1. a simple prompt sent at high runs at what the judge picks (low); 2. a follow-up keeps it;
#   3. changing the effort by hand pauses Auto for the chat.
# Usage: powershell -ExecutionPolicy Bypass -File test\cli-proxy.ps1 -Exe path\to\effortless.exe -Data path\to\data
param([Parameter(Mandatory)] [string]$Exe, [Parameter(Mandatory)] [string]$Data)
$ErrorActionPreference = 'Stop'
$env:EFFORTLESS_DATA = $Data
$env:EFFORTLESS_MIN = 'low'; $env:EFFORTLESS_MODE = 'auto'   # the test expects low, whatever your own floor is
$psi = New-Object Diagnostics.ProcessStartInfo $Exe, 'codex --serve'
$psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
$srv = [Diagnostics.Process]::Start($psi)
$url, $token = $srv.StandardOutput.ReadLine() -split ' '
$bad = 0
function Check($cond, $what) { if ($cond) { "ok   $what" } else { "FAIL $what"; $script:bad++ } }
try {
  $anon = New-Object Net.WebSockets.ClientWebSocket
  $refused = $false
  try { $anon.ConnectAsync([Uri]$url, [Threading.CancellationToken]::None).Wait() } catch { $refused = $true }
  Check $refused 'a connection without the token is refused'

  $ws = New-Object Net.WebSockets.ClientWebSocket
  $ws.Options.SetRequestHeader('Authorization', "Bearer $token")
  $ws.ConnectAsync([Uri]$url, [Threading.CancellationToken]::None).Wait()
  $utf8 = New-Object Text.UTF8Encoding $false
  function Send($obj) {
    $b = $utf8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 20))
    $ws.SendAsync((New-Object ArraySegment[byte] (, $b)), 'Text', $true, [Threading.CancellationToken]::None).Wait()
  }
  $buf = New-Object byte[] 1048576
  function Next {
    $ms = New-Object IO.MemoryStream
    do {
      $r = $ws.ReceiveAsync((New-Object ArraySegment[byte] (, $buf)), [Threading.CancellationToken]::None).Result
      $ms.Write($buf, 0, $r.Count)
    } until ($r.EndOfMessage)
    $utf8.GetString($ms.ToArray()) | ConvertFrom-Json
  }
  function WaitFor([scriptblock]$pred) { while ($true) { $m = Next; if (& $pred $m) { return $m } } }
  Send @{ id = 1; method = 'initialize'; params = @{ clientInfo = @{ name = 'effortless-test'; title = $null; version = '0' }; capabilities = $null } }
  [void](WaitFor { param($m) $m.id -eq 1 })
  Send @{ method = 'initialized' }
  Send @{ id = 2; method = 'thread/start'; params = @{ sandbox = 'read-only'; approvalPolicy = 'never' } }
  $t = (WaitFor { param($m) $m.id -eq 2 }).result
  $tid = $t.thread.id
  "thread $tid, model $($t.model)"
  function Turn($id, $text, $effort) {
    Send @{ id = $id; method = 'turn/start'; params = @{ threadId = $tid; effort = $effort; input = @(@{ type = 'text'; text = $text }) } }
    [void](WaitFor { param($m) $m.method -eq 'turn/completed' })
    Get-Content -Raw -Encoding UTF8 (Join-Path $Data "routed\$tid") | ConvertFrom-Json
  }
  $r1 = Turn 3 'What does the -r flag of cp do? Answer in one short sentence, no tools.' 'high'
  Check ($r1.effort -eq 'low') "simple prompt sent at high runs at low (judge: $($r1.effort), $($r1.why))"
  $r2 = Turn 4 'ok' $r1.effort
  Check ($r2.action -eq 'follow-up') "follow-up keeps $($r2.effort) ($($r2.action))"
  $r3 = Turn 5 'Now say hi.' 'xhigh'
  Check ($r3.action -eq 'manual') "effort changed by hand pauses Auto ($($r3.action))"
  if ($t.thread.path -and (Test-Path -LiteralPath $t.thread.path)) {
    $efforts = (Select-String -LiteralPath $t.thread.path -Pattern '"type":"turn_context".*?"effort":"([a-z]+)"' -AllMatches | ForEach-Object { $_.Matches[0].Groups[1].Value }) -join ' '
    Check ($efforts -eq 'low low xhigh') "the session ran at: $efforts"
    Remove-Item -LiteralPath $t.thread.path   # a test thread, not yours
  }
} finally {
  & taskkill.exe /PID $srv.Id /T /F 2>&1 | Out-Null
}
exit $bad
