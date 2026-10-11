# codex-effortless

[effortless](https://github.com/HeyCubit/effortless) for Codex: a small model reads each prompt and picks the reasoning
effort for it. Quick questions get low, hard jobs get high, and you stop touching the effort menu. Around that it
warns when a chat goes cold, gets swamped or a usage limit runs hot, says when a fresh chat would pay off, and hands
off to one.

It runs in the Codex CLI (Linux, macOS, WSL, Windows PowerShell or cmd) and in Codex Desktop on Windows.

## How Auto works in Codex

Codex hooks cannot set a turn's effort ([openai/codex#40599](https://github.com/openai/codex/issues/40599)), so Auto
sits in front of Codex's own app-server instead and writes the effort into each new prompt's `turn/start`. The turn
runs at that effort and the CLI's status line shows it.

| You start | What happens |
|---|---|
| `codex-auto` (any arguments `codex` takes) | **Auto**: the CLI connects to a private proxy (`--remote`), which sets each prompt's effort |
| Codex Desktop with Auto on (Windows, `effortless desktop on`) | **Auto**: Desktop starts its app-server through `effortless.exe` (`CODEX_CLI_PATH`), which sets each prompt's effort |
| plain `codex`, or Desktop with Auto off | **Hints**: a prompt that needs a higher effort is held back once, with the effort to switch to (`Alt+.` in the CLI, the effort menu in Desktop); the text stays in the box, so raise it and press Enter. A lower effort is only suggested |

Changing the effort yourself pauses Auto for that chat and says so: you always win. `$effortless auto` brings it back.

## Install

Codex on Windows and Codex inside WSL keep separate settings (`%USERPROFILE%\.codex` and `~/.codex`), so install on
each side you use. Both read the same `effortless.conf` format.

**Linux, macOS, WSL** (needs `codex`, `perl` with its core modules, and `curl` for Jev):

```bash
bash install.sh
```

**Windows: the CLI in PowerShell or cmd, and Codex Desktop** (nothing to install: it builds `effortless.exe` with the
C# compiler that comes with Windows):

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

A few setup questions follow (judge, lean, status line, and on Windows Auto in Desktop); `-Quiet` / `--quiet` skips
them. Then trust the hook once: start Codex (`codex.cmd` if your execution policy blocks `codex.ps1`), run `/hooks`,
and trust effortless. Desktop reads the same `%USERPROFILE%\.codex`, so it is trusted there too.

| Installed | Where |
|---|---|
| the program and `effortless.conf` | `~/.codex/effortless` (`effortless.pl`, `judge.sh`) or `%USERPROFILE%\.codex\effortless` (`effortless.exe`) |
| the hook | a `UserPromptSubmit` entry in `hooks.json` next to them |
| the `$effortless` skill | `~/.codex/skills/effortless` |
| `codex-auto` | `~/.local/bin`, or `%USERPROFILE%\.codex\effortless\bin\codex-auto.cmd` (put on your user PATH only with `-AddToPath`) |
| the status line (if you say yes) | `[tui] status_line` in `config.toml`, backed up first |

Remove it with `install.sh --uninstall` or `install.ps1 -Uninstall` (`--purge` / `-Purge` also delete settings and log).
On Windows, the hook runs `effortless.exe` directly, so an `AllSigned` or `RemoteSigned` execution policy does not get in
the way. Behaviour-based antivirus can still flag the installer, since it builds an exe and writes into your profile:
Kaspersky flagged it once as `PDM:Trojan.Win32.Generic` and rolled back the PATH change it made, so editing PATH is now
opt-in and the build runs from a local copy. Every
line it runs is in `install.ps1` and `windows\effortless.cs`; read them, and add an exclusion for
`%USERPROFILE%\.codex\effortless` only if you are satisfied.

## What you see

| Situation | What happens |
|---|---|
| Auto picks another effort | `effortless: 自动切到 high（原 medium）`, and the turn runs at high. The status line shows it too |
| The prompt names a level (`max effort`, `effort: low`, `xhigh`) | It runs at that level, past Min, Max and save mode, with no judge call. `don't use max effort` and `a medium sized image` name nothing |
| The same effort, or a follow-up such as `ok`, `go`, `继续` | Nothing. A short follow-up keeps the effort without asking the judge, unless the last reply ended on a question: then the answer goes to the judge, since "B" can start a big job |
| No Auto (plain `codex`), the judge wants more | The prompt is held back: `effortless: 建议 high（当前 medium）— reason。按 Alt+. 升 1 档后直接回车重发`. Sent again within 15 minutes, it goes through. `EFFORTLESS_MODE=warn` only says it instead |
| No Auto, the judge wants less | `effortless: 建议 low（当前 high）— reason（按 Alt+, 降 2 档，对下一条消息生效）` |
| The chat went cold (idle 30 minutes, context of 150k tokens or more) | The first prompt is held back once: it would reread the whole chat at full price. `/compact` or hand off first, or send it again to go ahead |
| `$effortless handoff` in a cold chat (idle 30 minutes) | Luna writes the handoff from the transcript in the background instead of the chat's model rereading it all at full price; `/new` and `$effortless resume` pick it up. Send it again to have the chat's model write it |
| The chat is swamped (context past 50%) | A warning naming `/compact` and `$effortless handoff`; again after 50k more tokens |
| A 5-hour or weekly limit passes 80% | A warning with the reset time and `$effortless save`: save mode keeps Auto at medium or below until the limit resets. Said once for that limit window, in any chat, and once more at 95% |
| A fresh chat would pay off | From 30% context, every second prompt, the judge also reads what the chat was for, the trail of topics and the last reply, and says so only for a clear reason (the task finished and the next one is different, the chat goes in circles…) |
| The judge fails or is slow | The prompt goes on at the effort it had; a judge that keeps failing is named once per session (`判断器没有及时回答…`, `Jev 拒绝了 key（401）…`) |
| A new version is out | Said once per session; `$effortless update` installs it |

The status line (`install.sh --status-line`, or yes to the question) shows the effort in use, how full the context is
and the 5-hour and weekly limits all the time, which is what the original's bar showed. `EFFORTLESS_BAR=always` also puts
a line like `effortless: high · ◔ 38% · 缓存约剩 24 分钟 · 5 小时 42%` on every prompt, for Codex Desktop.

## Commands

Type these in Codex (CLI or Desktop); the skill runs the program for you. The same commands work in a terminal:
`perl ~/.codex/effortless/effortless.pl stats`, or `effortless.exe stats` on Windows.

| Command | Does |
|---|---|
| `$effortless stats` | what this chat cost per effort, and what the judge took |
| `$effortless debug` | settings, judge, Auto, the last chat as effortless sees it, the last verdicts |
| `$effortless auto` / `auto on` / `auto off` | Auto on or off (and ends a pause from changing the effort by hand) |
| `$effortless save` | save mode on or off |
| `$effortless settings` / `set KEY VALUE` | shows or changes `effortless.conf` |
| `$effortless handoff` | the quick handoff: the model writes it from what the chat shows, effortless saves it; then `/new` and `$effortless resume`. In a cold chat Luna writes it from the transcript instead |
| `$effortless handoff full` | checks git, rewrites `HANDOFF.md`, then the same (or runs your own skill: `EFFORTLESS_HANDOFF_SKILL`) |
| `$effortless resume` | in a fresh chat: carries on from the saved handoff |
| `$effortless test [prompt]` | asks the judge once |
| `$effortless bench` | scores the judge on the labelled prompts in `bench/judge-cases.json` |
| `$effortless desktop on` / `off` | Auto in Codex Desktop (Windows) |
| `$effortless update` | pulls the repo you installed from and reinstalls |

`EFFORTLESS_HANDOFF_AFTER=copy` also puts the handoff on the clipboard; `confirm` makes the new chat say where things
stand and wait instead of carrying on.

## Settings

`effortless.conf` next to the program (environment variables of the same name win). Every setting is explained in the file.

| Setting | Default | Meaning |
|---|---|---|
| `EFFORTLESS_MODE` | `auto` | `auto` (`block` is the same), `warn` (only say, never switch or hold back, even through `codex-auto`), `off` |
| `EFFORTLESS_JUDGE` | `auto` | `auto`: Luna, and Jev first when a TypeSafe key is set. `luna`: never Jev. `jev`: the key may also come from `~/.config/jev/.env` |
| `EFFORTLESS_MODEL` | `gpt-5.6-luna` | the judge model on your Codex login |
| `EFFORTLESS_MIN` / `EFFORTLESS_MAX` | `medium` / `max` | Auto stays between these; efforts the model does not take are skipped to the nearest one it does |
| `EFFORTLESS_BIAS` | `0` | `-2` to `2`: tips the judge's close calls cheaper or smarter; sure calls stay |
| `EFFORTLESS_TIMEOUT` | `20` | seconds before the prompt goes on at the effort it had |
| `EFFORTLESS_COLD` / `_COLD_MINUTES` / `_COLD_TOKENS` | `block` / `30` / `150000` | the cold-chat check (`warn` or `off` instead of holding the prompt) |
| `EFFORTLESS_SWAMP_AT` | `50` | percent of the context window |
| `EFFORTLESS_HOT_AT` | `80` | percent of a usage limit (said once per limit window, again at 95%) |
| `EFFORTLESS_HANDOFF_FROM` / `_EVERY` | `30` / `2` | when the judge checks whether a fresh chat would pay off (`off`: never) |
| `EFFORTLESS_HIDE` | `reason` | parts to keep quiet: `reason` (the judge's reason on an Auto switch), and the alerts `swamp` (context), `hot` (running low), `cold` (cold cache) |
| `EFFORTLESS_BAR` | `changes` | `always`: a status line on every prompt |
| `EFFORTLESS_CODEX` | empty | the codex the judge and Auto run. Empty: found by itself (on Windows also inside Codex Desktop) |

Why 30 minutes for a cold cache: over this machine's Codex sessions, a prompt after up to about 20 minutes idle was
still read almost entirely from the cache; after 45 to 60 minutes it mostly was not.

## Judges: Luna and Jev

Luna judges on your Codex login: no key, and it goes the way your Codex goes (the same `CODEX_HOME` config and login).

**Jev** ([TypeSafe](https://typesafe.ai)) answers in well under a second with its confidence: set
`EFFORTLESS_TYPESAFE_KEY` (or `TYPESAFE_API_KEY`) and it judges first; when it is unsure (below even odds), fails or
takes over 3 seconds, Luna decides.

The key goes only to TypeSafe. On Linux it reaches curl on stdin and the request body is a private file, so neither
shows in the process list; on Windows it stays in memory.

## How well it judges

`$effortless bench` runs the original's labelled prompts through the same pipeline a real prompt takes (the 5 cases
about Claude models left out) and scores the answer against the efforts a careful person would accept. One run with
Luna, 2026-10-10:

| Judge | Right, all 70 | Right, 19 held out | Too low | Too high | Median time |
|---|---|---|---|---|---|
| Luna (Codex login) | 96% | 100% | 2 | 1 | 6.3 s |

The original measured Haiku at 92 to 93% and Jev at 99% on its 73 cases. The held-out cases were never tuned against;
70 cases is a small set and the judge is not fully deterministic, so runs differ by a few points.

## Cost and limits

- A judged prompt waits for the judge: about **6 to 7 seconds** with Luna on Linux and WSL, **8 to 9** on Windows, almost
  all of it Luna's answer; Jev is quicker. Follow-ups and named levels skip the judge. About 6,000 tokens a judgement
  on your Codex plan.
- Auto and the hook read the session's transcript (effort, context, limits, messages), which is not a stable Codex
  interface.
- In Auto, quitting the CLI prints Codex's own "To reconnect, run codex --remote …" line; the proxy is gone by then:
  `codex-auto resume <id>` picks the chat up.
- Auto in Codex Desktop rests on `CODEX_CLI_PATH`, which Desktop reads but does not document. With it set, Desktop runs
  its agent the way the CLI does: it does not use the app's own Windows sandbox service. `effortless desktop off` (and a
  Desktop restart) goes back.
- The original's bar, buttons, themes and animations have no counterpart: Codex has no way for a plugin to draw. The
  status line, the messages and `$effortless` carry the same information.
- Compaction runs on the chat's model: Codex has no setting for a cheaper compaction model. Moving simple prompts to a
  cheaper model is not offered either (the original keeps it off by default too).
- The original now runs a subagent at the effort Auto picked for its turn. Codex starts subagents inside the app-server,
  out of Auto's reach, so they keep the effort Codex gives them.

## Develop

```bash
perl test/auto-proxy.pl                                   # Auto on Linux/WSL, against the real codex and judge
perl test/desktop-shim.pl /mnt/c/.../effortless.exe       # Desktop's app-server path, from WSL
powershell -File test\cli-proxy.ps1 -Exe ...\effortless.exe -Data ...   # the CLI's WebSocket path on Windows
```

Each makes a few real model calls on your login and removes the test chat it made.

## License

MIT. Adapted from [effortless](https://github.com/HeyCubit/effortless) (MIT, Copyright (c) 2026 HeyCubit): the judge,
Jev and handoff prompts, the handoff format and `bench/judge-cases.json` come from it, rewritten for Codex.
