#!/usr/bin/env bash
# codex-effortless: a Codex UserPromptSubmit hook. GPT-5.6 Luna judges how much reasoning effort the
# prompt needs; when that differs from the effort Codex is on, the hook says so (or, in block mode,
# holds the prompt back so you can raise the effort first). It never changes the effort itself:
# Codex hooks cannot (openai/codex#40599).
#
# By default the judge runs on your own Codex login through a short-lived `codex app-server` over stdio,
# so no API key is needed. With EFFORTLESS_API_URL and a key it asks an OpenAI-compatible endpoint
# (OpenRouter, OpenAI, a relay) instead, falling back to Codex if that fails. Any failure of both lets
# the prompt through untouched.
#
#   judge.sh            run as the hook (reads the hook payload on stdin)
#   judge.sh --stats    summarise the local verdict log
set -u

# The judge's own app-server has hooks disabled; this guards anything else that might call us back.
[ -n "${EFFORTLESS_JUDGE:-}" ] && exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE/effortless.conf" ] && . "$HERE/effortless.conf"
MODE=${EFFORTLESS_MODE:-warn}
MODEL=${EFFORTLESS_MODEL:-gpt-5.6-luna}
MIN=${EFFORTLESS_MIN:-medium}
MAX=${EFFORTLESS_MAX:-xhigh}
BIAS=${EFFORTLESS_BIAS:-0}
BLOCK_GAP=${EFFORTLESS_BLOCK_GAP:-1}
BUDGET=${EFFORTLESS_TIMEOUT:-20}
# Optional OpenAI-compatible judge (OpenRouter, OpenAI, a relay). Without a URL and key, Codex judges.
API_URL=${EFFORTLESS_API_URL:-}
API_KEY=${EFFORTLESS_API_KEY:-}
[ -z "$API_KEY" ] && [ -n "${EFFORTLESS_API_KEY_ENV:-}" ] && API_KEY=${!EFFORTLESS_API_KEY_ENV:-}
API_MODEL=${EFFORTLESS_API_MODEL:-openai/gpt-5.6-luna}
API_STYLE=${EFFORTLESS_API_STYLE:-chat}
API_FORMAT=${EFFORTLESS_API_FORMAT:-schema}
API_REASONING=${EFFORTLESS_API_REASONING:-}
FALLBACK=${EFFORTLESS_FALLBACK:-codex}
DATA=${EFFORTLESS_DATA:-${PLUGIN_DATA:-$HOME/.codex/effortless/data}}
mkdir -p "$DATA" 2>/dev/null
LOG="$DATA/verdicts.tsv"

LEVELS=(none minimal low medium high xhigh)
idx() { local i; for i in "${!LEVELS[@]}"; do [ "${LEVELS[$i]}" = "$1" ] && { echo "$i"; return; }; done; echo -1; }

if [ "${1:-}" = "--stats" ]; then
  [ -s "$LOG" ] || { echo "No verdicts yet ($LOG)."; exit 0; }
  echo "Verdicts: $(wc -l < "$LOG")"
  echo "By verdict:"; cut -f3 "$LOG" | sort | uniq -c | sort -rn
  echo "Actions:";    cut -f7 "$LOG" | sort | uniq -c | sort -rn
  echo "Judges:";     cut -f8 "$LOG" | grep -v "^-*$" | sort | uniq -c | sort -rn
  awk -F'\t' '$5>0{n++; ms+=$5; tk+=$6} END{if(n) printf "Average judge time %d ms, %d tokens\n", ms/n, tk/n}' "$LOG"
  exit 0
fi

[ "$MODE" = off ] && exit 0
log() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$4" "$5" "$6" "${by:--}" >> "$LOG" 2>/dev/null; }

payload=$(cat)
# Kept JSON-escaped on purpose: it is spliced straight into the judge's JSON request.
prompt=$(grep -oP '"prompt"\s*:\s*"\K(?:[^"\\]|\\.)*' <<<"$payload" | head -1)
transcript=$(grep -oP '"transcript_path"\s*:\s*"\K(?:[^"\\]|\\.)*' <<<"$payload" | head -1)
[ -z "$prompt" ] && exit 0

# The effort in use: the last one the session recorded, else config.toml, else Codex's default.
current=""
[ -n "$transcript" ] && [ -f "$transcript" ] && current=$(grep -oP '"reasoning_effort"\s*:\s*"\K[a-z]+' "$transcript" | tail -1)
[ -z "$current" ] && current=$(grep -oP '^\s*model_reasoning_effort\s*=\s*"\K[a-z]+' "$HOME/.codex/config.toml" 2>/dev/null | tail -1)
current=${current:-medium}

# "ok", "go", "继续" between two steps keep the effort the work is already on: no judge.
if [ "${#prompt}" -le 24 ] && grep -qiP '^\s*(ok(ay)?|y(es)?|yep|sure|go( ahead)?|continue|do it|proceed|thanks?|lgtm|好的?|行|可以|继续|是的?|对|嗯|开始吧?|确认|没问题)\s*[.!。！~]*\s*$' <<<"$prompt"; then
  log "$current" "-" "-" 0 0 "follow-up"
  exit 0
fi

# The same prompt sent again (after a block, say) reuses its verdict instead of asking again.
key=$(printf '%s' "$prompt" | md5sum | cut -c1-16)
# A prompt this hook held back, sent again: the person has seen the advice, so it goes through. Codex
# writes an effort changed with Alt+. / Alt+, to the transcript only once the next turn starts, so the
# effort read above may still be the old one and would hold the prompt back again.
if [ -f "$DATA/held" ] && read -r hkey hts < "$DATA/held" && [ "$hkey" = "$key" ] && [ $(( $(date +%s) - hts )) -lt 900 ]; then
  rm -f "$DATA/held"
  log "$current" "-" "-" 0 0 "resent"
  exit 0
fi

cached=""
[ -f "$DATA/last" ] && read -r ckey cts ceffort csure < "$DATA/last" && [ "$ckey" = "$key" ] && [ $(( $(date +%s) - cts )) -lt 900 ] && cached=1

if [ -n "$cached" ]; then
  effort=$ceffort; sure=$csure; why=$(cat "$DATA/last.why" 2>/dev/null); ms=0; tokens=0
else
  # Cut long prompts without ending inside an escape sequence.
  p=${prompt:0:6000}
  p=$(sed -E 's/\\u[0-9a-fA-F]{0,3}$//' <<<"$p")
  [[ $p =~ (\\+)$ ]] && (( ${#BASH_REMATCH[1]} % 2 == 1 )) && p=${p%\\}

  INSTRUCTIONS='You decide how much reasoning effort a coding agent should spend on the user message you are given. Never use tools. Answer only with the JSON the schema asks for. Levels: low = quick questions, explanations, small mechanical edits such as a rename, a typo or a config value, running one command. medium = ordinary feature work or a bug fix in code that is easy to locate, moderate multi-file edits, tests for clear behaviour. high = debugging unclear failures, concurrency, performance or security problems, design decisions, refactors across many files, anything where a wrong answer is costly. xhigh = long autonomous multi-step tasks, deep investigations, hard algorithmic or architectural problems. sure is your confidence from 0 to 1. why is one short reason, under 20 words, in the language of the user message.'
  SCHEMA='{"type":"object","additionalProperties":false,"required":["effort","sure","why"],"properties":{"effort":{"type":"string","enum":["low","medium","high","xhigh"]},"sure":{"type":"number"},"why":{"type":"string"}}}'
  ASK="The agent is on reasoning effort ${current}. The user message:\\n\\n${p}"

  # Each judge sets msg (text holding the verdict JSON, still escaped) and tokens, or returns 1 and
  # sets failed to the step that went wrong.
  judge_codex() {
    local OFF=() f cwd r tid m usage
    for f in apps browser_use browser_use_external computer_use code_mode_host goals hooks image_generation multi_agent plugins remote_plugin shell_snapshot shell_tool skill_search sleep_tool tool_suggest unified_exec view_image web_search workspace_dependencies worktrees; do
      OFF+=(--disable "$f")
    done
    # An empty working directory keeps project files such as AGENTS.md out of the judge's context.
    cwd="$DATA/judge-cwd"; mkdir -p "$cwd"
    deadline=$(( SECONDS + BUDGET ))
    coproc SRV { cd "$cwd" && EFFORTLESS_JUDGE=1 exec codex app-server "${OFF[@]}" 2>/dev/null; }
    trap 'kill "$SRV_PID" 2>/dev/null' EXIT
    send() { printf '%s\n' "$1" >&"${SRV[1]}"; }
    # Prints the first line containing $1 that arrives before the deadline.
    await() {
      local line left
      while left=$(( deadline - SECONDS )); [ "$left" -gt 0 ]; do
        IFS= read -r -t "$left" line <&"${SRV[0]}" || return 1
        [[ $line == *"$1"* ]] && { printf '%s' "$line"; return 0; }
      done
      return 1
    }
    send '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-effortless","title":null,"version":"0.2.0"},"capabilities":null}}'
    await '"id":1' >/dev/null || { failed=init; return 1; }
    send '{"method":"initialized"}'
    send '{"id":2,"method":"thread/start","params":{"model":"'"$MODEL"'","ephemeral":true,"sandbox":"read-only","approvalPolicy":"never","cwd":"'"$cwd"'","baseInstructions":"'"$INSTRUCTIONS"'"}}'
    r=$(await '"id":2') || { failed=thread; return 1; }
    tid=$(grep -oP '"thread"\s*:\s*\{\s*"id"\s*:\s*"\K[^"]+' <<<"$r")
    [ -n "$tid" ] || { failed=thread; return 1; }
    send '{"id":3,"method":"turn/start","params":{"threadId":"'"$tid"'","effort":"none","outputSchema":'"$SCHEMA"',"input":[{"type":"text","text":"[effortless-judge] '"$ASK"'"}]}}'
    # Wait for the finished answer; a turn that ends without one (an unknown model, an error) fails at once.
    msg=""
    while m=$(await '"method":"'); do
      case $m in
        *item/completed*'"type":"agentMessage"'*) msg=$m; break ;;
        *'"method":"turn/completed"'*|*'"method":"error"'*) break ;;
      esac
    done
    [ -n "$msg" ] || { failed=turn; return 1; }
    usage=$(await 'thread/tokenUsage/updated')
    tokens=$(grep -oP '"total"\s*:\s*\{\s*"totalTokens"\s*:\s*\K[0-9]+' <<<"$usage" | head -1)
    kill "$SRV_PID" 2>/dev/null
  }

  # Any OpenAI-compatible endpoint: OpenRouter, OpenAI, a relay. Chat Completions or the Responses API.
  judge_api() {
    local url=${API_URL%/} style=$API_STYLE format reasoning body out code
    case $url in
      */chat/completions) style=chat ;;
      */responses) style=responses ;;
      *) if [ "$style" = responses ]; then url="$url/responses"; else url="$url/chat/completions"; fi ;;
    esac
    local system="$INSTRUCTIONS Reply with a JSON object with the keys effort, sure and why."
    if [ "$style" = responses ]; then
      case $API_FORMAT in
        object) format=',"text":{"format":{"type":"json_object"}}' ;;
        none)   format='' ;;
        *)      format=',"text":{"format":{"type":"json_schema","name":"verdict","strict":true,"schema":'"$SCHEMA"'}}' ;;
      esac
      reasoning=""; [ -n "$API_REASONING" ] && reasoning=',"reasoning":{"effort":"'"$API_REASONING"'"}'
      body='{"model":"'"$API_MODEL"'","max_output_tokens":400,"store":false,"instructions":"'"$system"'","input":"'"$ASK"'"'"$format$reasoning"'}'
    else
      case $API_FORMAT in
        object) format=',"response_format":{"type":"json_object"}' ;;
        none)   format='' ;;
        *)      format=',"response_format":{"type":"json_schema","json_schema":{"name":"verdict","strict":true,"schema":'"$SCHEMA"'}}' ;;
      esac
      reasoning=""; [ -n "$API_REASONING" ] && reasoning=',"reasoning_effort":"'"$API_REASONING"'"'
      body='{"model":"'"$API_MODEL"'","max_tokens":400,"messages":[{"role":"system","content":"'"$system"'"},{"role":"user","content":"'"$ASK"'"}]'"$format$reasoning"'}'
    fi
    out=$(mktemp)
    # The key goes in through a config on stdin, so it never shows in the process list.
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$API_KEY" | curl -sS -m "$BUDGET" -o "$out" -w '%{http_code}' -K - \
      -H 'Content-Type: application/json' -H 'X-Title: codex-effortless' --data-binary "$body" "$url" 2>/dev/null)
    msg=$(cat "$out"); rm -f "$out"
    [ "$code" = 200 ] || { failed="http-${code:-000}"; return 1; }
    # The verdict is the output text: JSON inside a JSON string, so escaped like the Codex answer.
    tokens=$(grep -oP '"total_tokens"\s*:\s*\K[0-9]+' <<<"$msg" | head -1)
  }

  started=$(date +%s%N)
  failed=""; tokens=0; by=codex
  if [ -n "$API_URL" ] && [ -n "$API_KEY" ]; then
    by=api
    if ! judge_api; then
      log "$current" "-" "-" "$(( ($(date +%s%N) - started) / 1000000 ))" 0 "fail:api:$failed"
      [ "$FALLBACK" = codex ] || exit 0
      by=codex; failed=""
    fi
  fi
  if [ "$by" = codex ] && ! judge_codex; then
    log "$current" "-" "-" "$(( ($(date +%s%N) - started) / 1000000 ))" 0 "fail:codex:$failed"
    exit 0
  fi
  ms=$(( ($(date +%s%N) - started) / 1000000 ))
  tokens=${tokens:-0}

  # The verdict JSON sits escaped inside the answer's text field.
  effort=$(grep -oP '\\"effort\\"\s*:\s*\\"\K[a-z]+' <<<"$msg" | head -1)
  sure=$(grep -oP '\\"sure\\"\s*:\s*\K[0-9.]+' <<<"$msg" | head -1)
  why=$(grep -oP '\\"why\\"\s*:\s*\\"\K.*?(?=\\")' <<<"$msg" | head -1)
  why=${why//\\/}; why=${why//\"/}; why=$(sed -E 's/[.。!！ ]+$//' <<<"$why")
  if [ "$(idx "$effort")" -lt 0 ]; then log "$current" "-" "-" "$ms" "$tokens" "fail:$by:verdict"; exit 0; fi
  sure=${sure:-0.5}
  echo "$key $(date +%s) $effort $sure" > "$DATA/last"; printf '%s' "$why" > "$DATA/last.why"
fi

# Close calls lean the way the slider says; sure calls stay. Then the floor and ceiling.
picked=$effort
if [ "$BIAS" != 0 ]; then
  abs=${BIAS#-}; limit=$([ "$abs" = 1 ] && echo 0.65 || echo 0.85)
  if awk -v s="$sure" -v l="$limit" 'BEGIN{exit !(s < l)}'; then
    step=$([ "${BIAS:0:1}" = - ] && echo -1 || echo 1)
    i=$(( $(idx "$picked") + step )); [ "$i" -lt 2 ] && i=2; [ "$i" -gt 5 ] && i=5
    picked=${LEVELS[$i]}
  fi
fi
lo=$(idx "$MIN"); hi=$(idx "$MAX"); [ "$hi" -lt "$lo" ] && hi=$lo
i=$(idx "$picked"); [ "$i" -lt "$lo" ] && i=$lo; [ "$i" -gt "$hi" ] && i=$hi
picked=${LEVELS[$i]}

ci=$(idx "$current"); gap=$(( i - ci ))
if [ "$gap" -eq 0 ]; then
  log "$current" "$picked" "$sure" "$ms" "$tokens" "same"
  exit 0
fi

if [ "$gap" -gt 0 ]; then how="Alt+. 升 ${gap} 档"; else how="Alt+, 降 ${gap#-} 档"; fi
text="effortless: 建议 ${picked}（当前 ${current}）— ${why}"
if [ "$MODE" = block ] && [ "$gap" -ge "$BLOCK_GAP" ]; then
  log "$current" "$picked" "$sure" "$ms" "$tokens" "block"
  echo "$key $(date +%s)" > "$DATA/held"
  printf '{"decision":"block","reason":"%s。按 %s 后直接回车重发（原文还在输入框里，重发会直接放行）。"}\n' "$text" "$how"
else
  log "$current" "$picked" "$sure" "$ms" "$tokens" "warn"
  printf '{"systemMessage":"%s（%s，对下一条消息生效）"}\n' "$text" "$how"
fi
