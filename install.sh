#!/usr/bin/env bash
# Installs codex-effortless as a user-level Codex hook:
#   ~/.codex/effortless/{judge.sh,effortless.conf}  and a UserPromptSubmit entry in ~/.codex/hooks.json
#   install.sh --uninstall   removes both (your effortless.conf and verdict log are kept unless --purge)
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.codex/effortless"
HOOKS="$HOME/.codex/hooks.json"
MARK='effortless/judge.sh'

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

if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "--purge" ]; then
  if [ -f "$HOOKS" ] && grep -q "$MARK" "$HOOKS"; then
    if [ "$(tr -d ' \n' < "$HOOKS")" = "$(printf '%s' "$ENTRY" | tr -d ' \n')" ]; then
      rm "$HOOKS"; echo "Removed $HOOKS"
    else
      echo "$HOOKS has other hooks too: remove the entry that runs $MARK by hand."
    fi
  fi
  rm -f "$DEST/judge.sh"
  [ "${1:-}" = "--purge" ] && rm -rf "$DEST"
  echo "codex-effortless uninstalled."
  exit 0
fi

command -v codex >/dev/null || { echo "codex is not on PATH."; exit 1; }
echo test | grep -qP 't' 2>/dev/null || { echo "grep -P (PCRE) is required."; exit 1; }

mkdir -p "$DEST"
install -m 755 "$HERE/judge.sh" "$DEST/judge.sh"
if [ -f "$DEST/effortless.conf" ]; then
  echo "Kept your existing $DEST/effortless.conf"
else
  install -m 600 "$HERE/effortless.conf" "$DEST/effortless.conf"
fi

if [ ! -f "$HOOKS" ]; then
  printf '%s\n' "$ENTRY" > "$HOOKS"
  echo "Wrote $HOOKS"
elif grep -q "$MARK" "$HOOKS"; then
  echo "$HOOKS already runs effortless."
else
  echo "$HOOKS already exists with other hooks. Add this UserPromptSubmit entry to it by hand:"
  printf '%s\n' "$ENTRY"
fi

cat <<'EOF'

Next:
  1. Start codex and run /hooks to review and trust the effortless hook (Codex skips untrusted hooks).
  2. Send a prompt: while "effortless: Luna 正在判断档位…" shows, Luna is judging (about 6 s).
  3. ~/.codex/effortless/judge.sh --stats shows what it has suggested so far.
EOF
