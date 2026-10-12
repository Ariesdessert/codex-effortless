#!/usr/bin/env bash
# Installs codex-effortless for Codex on Linux, macOS and WSL (Codex on Windows: install.ps1).
#
#   bash install.sh                 install, asking a few setup questions
#   bash install.sh --quiet         install with what is already set (updates use this)
#   bash install.sh --status-line   also show effort, context and limits in the Codex status line
#   bash install.sh --uninstall     remove it (your settings and log are kept)
#   bash install.sh --purge         remove it, settings and log too
#
# Puts effortless.pl, judge.sh and effortless.conf in ~/.codex/effortless, a UserPromptSubmit entry in
# ~/.codex/hooks.json, the $effortless skill in ~/.codex/skills, and the codex-auto command in ~/.local/bin.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
DEST="$CODEX_HOME/effortless"
HOOKS="$CODEX_HOME/hooks.json"
SKILL="$CODEX_HOME/skills/effortless"
BIN="$HOME/.local/bin"
MARK='effortless/judge.sh'
QUIET=; STATUS=; MODE=install
for a in "$@"; do
  case $a in
    --quiet) QUIET=1 ;;
    --status-line) STATUS=1 ;;
    --uninstall) MODE=uninstall ;;
    --purge) MODE=purge ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done
[ -t 0 ] || QUIET=1

ENTRY='{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.codex/effortless/judge.sh\"",
            "timeout": 30,
            "statusMessage": "effortless: Luna 正在判断档位…"
          }
        ]
      }
    ]
  }
}'

if [ "$MODE" != install ]; then
  if [ -f "$HOOKS" ] && grep -q "$MARK" "$HOOKS"; then
    if [ "$(tr -d ' \n' < "$HOOKS")" = "$(printf '%s' "$ENTRY" | tr -d ' \n')" ]; then
      rm "$HOOKS"; echo "Removed $HOOKS"
    else
      echo "$HOOKS has other hooks too: remove the entry that runs $MARK by hand."
    fi
  fi
  rm -rf "$SKILL"
  if grep -qs effortless "$BIN/codex-auto"; then rm -f "$BIN/codex-auto"; fi
  rm -f "$DEST/judge.sh" "$DEST/effortless.pl" "$DEST/source"
  rm -rf "$DEST/bench"
  [ "$MODE" = purge ] && rm -rf "$DEST"
  echo "codex-effortless uninstalled."
  exit 0
fi

# effortless.pl also finds codex where OpenAI's installer puts it when PATH does not have it.
command -v codex >/dev/null || [ -x "$HOME/.local/bin/codex" ] || [ -x "$CODEX_HOME/packages/standalone/current/bin/codex" ] ||
  { echo "This needs the Codex CLI. Install it with: curl -fsSL https://chatgpt.com/codex/install.sh | sh"; exit 1; }
perl -MJSON::PP -MDigest::SHA -e1 2>/dev/null || { echo "perl with JSON::PP and Digest::SHA is required (core modules)."; exit 1; }
command -v curl >/dev/null || echo "Note: curl is not installed; only needed for OpenRouter."

mkdir -p "$DEST/bench" "$SKILL"
install -m 755 "$HERE/effortless.pl" "$DEST/effortless.pl"
install -m 755 "$HERE/judge.sh" "$DEST/judge.sh"
install -m 644 "$HERE/bench/judge-cases.json" "$DEST/bench/judge-cases.json"
printf '%s\n' "$HERE" > "$DEST/source"

# Settings: a new install gets the template; an existing file keeps every value and gains the settings it lacks.
CONF="$DEST/effortless.conf"
if [ -f "$CONF" ]; then
  added=0
  while IFS= read -r line; do
    key=$(sed -nE 's/^(EFFORTLESS_[A-Z_]+)=.*/\1/p' <<<"$line")
    [ -n "$key" ] || continue
    grep -qE "^\s*$key=" "$CONF" && continue
    printf '%s\n' "$line" >> "$CONF"; added=$((added + 1))
  done < "$HERE/effortless.conf"
  echo "Kept your $CONF$([ $added -gt 0 ] && echo " (added $added new settings)")"
else
  install -m 600 "$HERE/effortless.conf" "$CONF"
fi

# The $effortless skill, with this machine's command in it.
EFF="perl \"$DEST/effortless.pl\""
SAVE="cat <<'EFFORTLESS_HANDOFF' | perl \"$DEST/effortless.pl\" handoff-save
(the handoff)
EFFORTLESS_HANDOFF"
perl -0pe 'BEGIN { ($e, $s) = (shift, shift) } s/\{\{EFFORTLESS\}\}/$e/g; s/\{\{SAVE_EXAMPLE\}\}/$s/g' "$EFF" "$SAVE" \
  < "$HERE/skills/effortless/SKILL.md" > "$SKILL/SKILL.md"

# codex-auto: the Codex CLI with Auto.
mkdir -p "$BIN"
cat > "$BIN/codex-auto" <<EOF
#!/usr/bin/env bash
# codex-effortless: the Codex CLI with Auto (every prompt runs at the effort the judge picks).
exec perl "$DEST/effortless.pl" codex "\$@"
EOF
chmod 755 "$BIN/codex-auto"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Note: $BIN is not on your PATH; add it to use codex-auto." ;; esac

if [ ! -f "$HOOKS" ]; then
  printf '%s\n' "$ENTRY" > "$HOOKS"; echo "Wrote $HOOKS"
elif grep -q "$MARK" "$HOOKS"; then
  echo "$HOOKS already runs effortless."
else
  echo "$HOOKS already exists with other hooks. Add this UserPromptSubmit entry to it by hand:"
  printf '%s\n' "$ENTRY"
fi

set_conf() { perl "$DEST/effortless.pl" config set "$1" "$2" >/dev/null; }
if [ -z "$QUIET" ]; then
  echo
  echo "Setup (Enter keeps the choice in brackets; change any of it later with \$effortless settings):"
  read -r -p "  Judge: 1 Luna on your Codex login, 2 add OpenRouter (OpenRouter key) [1] " j
  case ${j:-1} in
    2)
      read -r -s -p "  OpenRouter key (not shown; saved in $CONF, readable only by you): " k; echo
      [ -n "$k" ] && set_conf EFFORTLESS_OPENROUTER_KEY "$k" ;;
  esac
  read -r -p "  Lean: -2 cheapest … 0 balanced … 2 smartest [0] " b
  [ -n "$b" ] && set_conf EFFORTLESS_BIAS "$b"
  if [ -z "$STATUS" ] && ! grep -qE '^\s*status_line\s*=' "$CODEX_HOME/config.toml" 2>/dev/null; then
    read -r -p "  Show effort, context and limits in the Codex status line? [Y/n] " s
    case ${s:-y} in [yY]*) STATUS=1 ;; esac
  fi
fi

# The status line shows what the original's bar did: the effort in use, how full the context is, the limits.
if [ -n "$STATUS" ]; then
  CFG="$CODEX_HOME/config.toml"
  if grep -qE '^\s*status_line\s*=' "$CFG" 2>/dev/null; then
    echo "Your config.toml already sets status_line; left as it is."
  else
    touch "$CFG"; cp "$CFG" "$CFG.before-effortless"
    LINE='status_line = ["model-with-reasoning", "context-used", "five-hour-limit", "weekly-limit", "current-dir"]'
    if grep -qE '^\s*\[tui\]\s*$' "$CFG"; then
      perl -0pi -e 'BEGIN { $l = shift } s/^(\s*\[tui\]\s*\n)/$1$l\n/m' "$LINE" "$CFG"
    else
      printf '\n[tui]\n%s\n' "$LINE" >> "$CFG"
    fi
    echo "Status line set in $CFG (backup: config.toml.before-effortless)."
  fi
fi

cat <<EOF

Next:
  1. Start codex and run /hooks to review and trust the effortless hook, if you have not (Codex skips untrusted hooks).
  2. codex-auto starts Codex with Auto: every prompt runs at the effort the judge picks.
     Plain codex works too: then the hook says which effort to switch to.
  3. \$effortless in Codex: stats, settings, save mode, handoff and the rest.
EOF
