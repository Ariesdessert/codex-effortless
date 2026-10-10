# codex-effortless

A Codex take on [effortless](https://github.com/HeyCubit/effortless): before each prompt runs,
GPT-5.6 Luna judges how much reasoning effort it needs, and Codex tells you when that differs from
the effort you are on.

**It suggests; it does not switch.** Codex hooks can add context or block a prompt, but cannot set
the effort of a turn ([openai/codex#40599](https://github.com/openai/codex/issues/40599)). You
switch with `Alt+.` (up) and `Alt+,` (down) in the CLI, or with the effort menu in Codex Desktop.

## Install

Codex on Windows and Codex inside WSL keep separate settings (`%USERPROFILE%\.codex` and `~/.codex`),
so install on each side you use. Both read the same `effortless.conf` format.

**WSL, Linux, macOS** (bash):

```bash
bash install.sh
```

Then start `codex`, run `/hooks`, and trust the effortless hook. Remove it with
`bash install.sh --uninstall` (`--purge` also deletes settings and the log). Needs `codex`, `bash`,
and `grep -P` (and `curl` for the API judge).

**Windows: the CLI in PowerShell or cmd, and Codex Desktop** (PowerShell 5.1 or 7, nothing to install):

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

Then trust the hook once: start the CLI (`codex.cmd` if your execution policy blocks `codex.ps1`) and
run `/hooks`. Codex Desktop reads the same `%USERPROFILE%\.codex`, so the hook runs there too. Remove it
with `install.ps1 -Uninstall` (`-Purge` also deletes settings and the log).

The hook runs `judge.ps1` with `-ExecutionPolicy Bypass`, so it works under an `AllSigned` or
`RemoteSigned` policy without changing that policy. The judge finds `codex.exe` on PATH, in the npm
package, or inside Codex Desktop; set `EFFORTLESS_CODEX` to point it elsewhere.

No API key needed on either side: by default the judge runs on your Codex login.
## What you see

| Situation | What happens |
|---|---|
| Luna agrees with the current effort | Nothing |
| Luna disagrees (warn mode) | A warning: `effortless: 建议 high（当前 medium）— reason（按 Alt+. 升 1 档…）`. In Codex Desktop it names the level to pick in the effort menu instead. The prompt still runs at the current effort; the switch applies to your next message. |
| Luna wants a higher effort (block mode) | The prompt is held back. Raise the effort and send it again; the same prompt is not judged again for 15 minutes. |
| A follow-up such as `ok`, `go`, `继续` | No judge; the effort stays |
| The judge fails or takes too long | The prompt goes through untouched |

## Settings

`~/.codex/effortless/effortless.conf`, on Windows `%USERPROFILE%\.codex\effortless\effortless.conf`
(environment variables of the same name override it):

| Setting | Default | Meaning |
|---|---|---|
| `EFFORTLESS_MODE` | `warn` | `warn`, `block`, or `off` |
| `EFFORTLESS_BLOCK_GAP` | `1` | In block mode, how many levels higher the verdict must be to hold the prompt |
| `EFFORTLESS_MODEL` | `gpt-5.6-luna` | The judge model |
| `EFFORTLESS_MIN` / `EFFORTLESS_MAX` | `medium` / `xhigh` | Suggestions stay between these (`low` … `xhigh`, `max`, `ultra`) |
| `EFFORTLESS_BIAS` | `0` | `-2` to `2`: tips the judge's close calls cheaper or smarter; sure calls stay |
| `EFFORTLESS_TIMEOUT` | `20` | Seconds before the prompt goes through without a verdict |
| `EFFORTLESS_CODEX` | empty | Windows only: the `codex.exe` the judge runs. Empty: found by itself |

## Judge through an API (OpenRouter, OpenAI, a relay)

By default Luna judges on your Codex login. To use any OpenAI-compatible `/chat/completions`
endpoint (Chat Completions or the Responses API) instead, set a URL and a key in
`~/.codex/effortless/effortless.conf`:

```bash
EFFORTLESS_API_URL=https://openrouter.ai/api/v1
EFFORTLESS_API_KEY_ENV=OPENROUTER_API_KEY     # read the key from this variable (start codex with it set)
# EFFORTLESS_API_KEY=sk-or-...                # or put the key here (the file is chmod 600)
EFFORTLESS_API_MODEL=openai/gpt-5.6-luna      # the model name that endpoint uses
```

| Setting | Default | Meaning |
|---|---|---|
| `EFFORTLESS_API_URL` | empty | Base URL; `/chat/completions` is added unless already there. Empty: judge on Codex |
| `EFFORTLESS_API_KEY` / `EFFORTLESS_API_KEY_ENV` | empty | The key, or the name of an environment variable holding it |
| `EFFORTLESS_API_MODEL` | `openai/gpt-5.6-luna` | `gpt-5.6-luna` on OpenAI itself |
| `EFFORTLESS_API_STYLE` | `chat` | `chat` posts to `/chat/completions`, `responses` to `/responses` (OpenAI Responses API, sent with `store: false`). A URL ending in either path picks the style itself |
| `EFFORTLESS_API_REASONING` | empty | Reasoning effort for the judge model (`none`, `low`, ...): `reasoning.effort` on Responses, `reasoning_effort` on Chat. Empty leaves it to the endpoint |
| `EFFORTLESS_API_FORMAT` | `schema` | `schema` (strict JSON schema), `object` (JSON mode, for endpoints that reject schemas), `none` |
| `EFFORTLESS_FALLBACK` | `codex` | When the API fails: `codex` judges on your login instead; `none` lets the prompt through |

On Windows, Codex Desktop started from the Start menu does not see a variable set in one terminal:
set it for your user with `setx OPENROUTER_API_KEY sk-or-...` (judge.ps1 reads user variables too).

The key is passed to curl on stdin (judge.ps1 sends it from memory), so it does not show in the
process list. `judge.sh --stats`
shows which judge answered (`api` or `codex`), and failures are logged as `fail:api:http-401` and so on.

## How it works

- `judge.sh` (`judge.ps1` on Windows) is a `UserPromptSubmit` hook. It starts a short-lived `codex app-server` over stdio
  with hooks, tools, plugins, apps and `notify` disabled, opens an ephemeral thread on Luna with a small
  system prompt, and asks for `{effort, sure, why}` under a JSON schema, at Luna's lowest effort.
- The current effort is read from the session's transcript (the last `reasoning_effort` it
  recorded), falling back to `model_reasoning_effort` in `~/.codex/config.toml`.
- With an API URL and key, the same request goes to the endpoint instead: system prompt as `instructions`
  (Responses) or a system message (Chat), the verdict under the same JSON schema.
- Each verdict is logged locally to `~/.codex/effortless/data/verdicts.tsv`: time, current effort,
  verdict, confidence, judge time, tokens, action, and which judge answered. Prompt text is not logged.
- `judge.sh --stats` (`judge.ps1 -Stats`) summarises that log.

## Cost and limits

- About **6 seconds** per judged prompt (measured 5.7 to 7.2 s), almost all of it Luna's response
  time through the Codex backend. Starting the server and the thread takes about 0.2 s. On Windows
  it is about **9 to 11 seconds**: starting PowerShell and the Windows server adds 1 to 3 s.
- About **5,700 tokens** per judgement (about 7,700 measured on Windows), counted against your Codex plan.
- The judge sees the prompt alone (first 6,000 characters), not the conversation, so it can
  misjudge short messages that only make sense in context.
- The current effort comes from the transcript. The transcript is not a stable Codex interface, and
  an effort you just changed may not show there until the next turn starts.
- The `Alt+.` / `Alt+,` step count assumes the model offers every level from low to the one you are on.
- An effort level the judge does not know (one Codex adds later) is left alone: the prompt goes through.

## License

MIT. Inspired by [effortless](https://github.com/HeyCubit/effortless) (MIT) for Claude Code; no code is shared.
