---
name: effortless
description: codex-effortless commands. Use when the user types $effortless (stats, debug, auto, save, settings, handoff, handoff full, resume, bench, update, desktop) or asks about effortless, its Auto effort, its alerts or a handoff to a fresh chat.
metadata:
  short-description: Auto effort, stats, save mode, settings and handoffs
---

# effortless

codex-effortless picks the reasoning effort for every prompt, and warns when a chat goes cold, gets swamped or a usage
limit runs hot. This skill runs its commands. The program is:

```
{{EFFORTLESS}}
```

Run it with the shell tool, show the user its output as it is (it is already in their language), and add nothing
unless they ask. Do not read or print the user's keys or `effortless.conf` lines ending in `KEY`.

## Commands

What follows `$effortless` picks the command. With nothing after it, run `debug` and list the commands below in one
short line each.

| The user types | Run |
|---|---|
| `$effortless stats` | `stats`: what this chat cost per effort, and what the judge took |
| `$effortless debug` | `debug`: settings, judge, Auto, the last chat as effortless sees it, the last verdicts |
| `$effortless auto` / `auto on` / `auto off` | `auto`, `auto on` or `auto off` |
| `$effortless save` / `save on` / `save off` | `save` ...: save mode keeps Auto at medium or below until the usage limit resets |
| `$effortless settings` | `config`, then offer to change any of them |
| `$effortless set KEY VALUE` | `config set EFFORTLESS_KEY VALUE` (add the `EFFORTLESS_` prefix if missing) |
| `$effortless test [prompt]` | `test [prompt]`: asks the judge once |
| `$effortless bench` | `bench`: scores the judge on labelled prompts (a few minutes; say so first) |
| `$effortless update` | `update` |
| `$effortless desktop on` / `off` | `desktop on` or `desktop off` (Windows only): Auto in Codex Desktop |
| `$effortless resume` | `resume`, then follow the handoff it prints as if the user had sent it. If it says the handoff is still being written, wait about 15 seconds and run it again |
| `$effortless handoff` | the quick handoff below |
| `$effortless handoff full` | the full handoff below |

The settings `config` shows are explained in `effortless.conf` next to the program. To change one, run
`config set`; never edit the file by hand.

## Handoff

A handoff carries this work into a fresh chat: write it, save it, and the user opens a new chat that picks it up.

**Quick** (`$effortless handoff`). Do not use tools to look anything up; write from what this chat already shows:

Start with the project, its folder and the branch. Then:
- Goal: one or two lines.
- Done: what changed, with file paths, and how each change was checked. Never present something planned, skipped or untested as done.
- Not done: what is half done, and the concrete blocker (a failed check, a missing approval, an open question).
- Git: local changes, local commits, pushed commits and open PRs, as last seen in this chat. You cannot check now, so say "as of last check".
- Next steps in priority order. Make the first one runnable: a file path, a command or a specific decision. Mark every step that needs the user with "needs user".
- To resume: the start command, the preview URL, and the limits on what is allowed (what needs the user's approval, test vs production).
- Do not redo: decisions made and why, approaches that failed.

Give only the final state of anything that changed during the chat. Point to specs, plans and files instead of
copying them. Leave out what is finished and no longer matters. Never include secrets, environment values or raw
logs. Write in the language the user writes in. Short bullets, at most about 40 lines.

**Full** (`$effortless handoff full`). If `config` shows `EFFORTLESS_HANDOFF_SKILL` set, run that skill instead of
the steps below and save the handoff it writes. Otherwise, using tools as needed:

1. Check the real state: git status, the last few commits, whether the branch is pushed, open PRs if gh is set up.
2. Rewrite HANDOFF.md in the project root from scratch (keep it under 80 lines): branch and open PRs, what is half done,
   next steps with the first one runnable, what only the user can do, and pointers to specs, plans and files.
   Never put secrets or environment values in it.
3. Write the handoff itself in the same shape as the quick one.

Then, for either kind, save the handoff text with one command, exactly like this (the text between the markers is
the handoff):

```
{{SAVE_EXAMPLE}}
```

and tell the user what its output says to do next (usually: open a new chat, then send `$effortless resume`).
Show the handoff in your reply too.
