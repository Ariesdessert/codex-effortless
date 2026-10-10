# codex-effortless

A Codex take on [effortless](https://github.com/HeyCubit/effortless): before each prompt runs,
GPT-5.6 Luna judges how much reasoning effort it needs, and Codex tells you when that differs from
the effort you are on.

**It suggests; it does not switch.** Codex hooks can add context or block a prompt, but cannot set
the effort of a turn ([openai/codex#40599](https://github.com/openai/codex/issues/40599)). You
switch with `Alt+.` (up) and `Alt+,` (down).

## Install

```bash
bash install.sh
```

Then start `codex`, run `/hooks`, and trust the effortless hook. Remove it with
`bash install.sh --uninstall` (`--purge` also deletes settings and the log).

Needs `codex`, `bash`, and `grep -P` (and `curl` for the API judge). No API key needed: by default the
judge runs on your Codex login.

## What you see

| Situation | What happens |
|---|---|
| Luna agrees with the current effort | Nothing |
| Luna disagrees (warn mode) | A warning: `effortless: 建议 high（当前 medium）— reason (Alt+. 升 1 档…)`. The prompt still runs at the current effort; the switch applies to your next message. |
| Luna wants a higher effort (block mode) | The prompt is held back. Raise the effort and send it again; the same prompt is not judged again for 15 minutes. |
| A follow-up such as `ok`, `go`, `继续` | No judge; the effort stays |
| The judge fails or takes too long | The prompt goes through untouched |

## Settings

`~/.codex/effortless/effortless.conf` (environment variables of the same name override it):

| Setting | Default | Meaning |
|---|---|---|
| `EFFORTLESS_MODE` | `warn` | `warn`, `block`, or `off` |
| `EFFORTLESS_BLOCK_GAP` | `1` | In block mode, how many levels higher the verdict must be to hold the prompt |
| `EFFORTLESS_MODEL` | `gpt-5.6-luna` | The judge model |
| `EFFORTLESS_MIN` / `EFFORTLESS_MAX` | `medium` / `xhigh` | Suggestions stay between these |
| `EFFORTLESS_BIAS` | `0` | `-2` to `2`: tips the judge's close calls cheaper or smarter; sure calls stay |
| `EFFORTLESS_TIMEOUT` | `20` | Seconds before the prompt goes through without a verdict |

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

The key is passed to curl on stdin, so it does not show in the process list. `judge.sh --stats`
shows which judge answered (`api` or `codex`), and failures are logged as `fail:api:http-401` and so on.

## How it works

- `judge.sh` is a `UserPromptSubmit` hook. It starts a short-lived `codex app-server` over stdio
  with hooks, tools, plugins and apps disabled, opens an ephemeral thread on Luna with a small
  system prompt, and asks for `{effort, sure, why}` under a JSON schema, at Luna's lowest effort.
- The current effort is read from the session's transcript (the last `reasoning_effort` it
  recorded), falling back to `model_reasoning_effort` in `~/.codex/config.toml`.
- With an API URL and key, the same request goes to the endpoint instead: system prompt as `instructions`
  (Responses) or a system message (Chat), the verdict under the same JSON schema.
- Each verdict is logged locally to `~/.codex/effortless/data/verdicts.tsv`: time, current effort,
  verdict, confidence, judge time, tokens, action, and which judge answered. Prompt text is not logged.
- `judge.sh --stats` summarises that log.

## Cost and limits

- About **6 seconds** per judged prompt (measured 5.7 to 7.2 s), almost all of it Luna's response
  time through the Codex backend. Starting the server and the thread takes about 0.2 s.
- About **5,700 tokens** per judgement, counted against your Codex plan.
- The judge sees the prompt alone (first 6,000 characters), not the conversation, so it can
  misjudge short messages that only make sense in context.
- The current effort comes from the transcript. The transcript is not a stable Codex interface, and
  an effort you just changed may not show there until the next turn starts.
- The `Alt+.` / `Alt+,` step count assumes the model offers every level from low to xhigh.

## License

MIT. Inspired by [effortless](https://github.com/HeyCubit/effortless) (MIT) for Claude Code; no code is shared.
