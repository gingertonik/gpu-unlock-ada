#!/usr/bin/env bash
# prefill-bench.sh — full prefill speed sweep: 2K 16K 32K 64K 128K
#
# Target (current endpoint): http://127.0.0.1:8081/v1  (Strata on Cruachan)
# Method: one request per depth, max_tokens=1, unique seeded prompt per
# depth (keeps the prefix cache cold), streaming.
#   TTFT            = request sent -> first streamed data line (= prefill)
#   prefill tok/s   = actual prompt_tokens (server usage) / TTFT
#
# Usage:
#   ./prefill-bench.sh                  # full sweep against the endpoint below
#   ./prefill-bench.sh 2048 16384       # only these depths
#   ./prefill-bench.sh http://host:port/v1 2048   # different endpoint
set -u

ENDPOINT="http://127.0.0.1:8081/v1"
API_KEY=""   # Strata presets run keyless; header stays valid with empty bearer
DEFAULT_MODEL="swift-1.5-iq3_s"
CURL_TIMEOUT=1800
SETTLE=3   # seconds between depths

# ---------------- args ----------------
ARGS=("$@")
DEPTHS=(2048 16384 32768 65536 131072)
if [ ${#ARGS[@]} -gt 0 ]; then
  if [[ ${ARGS[0]} == http* ]]; then
    ENDPOINT=${ARGS[0]}
    [ ${#ARGS[@]} -gt 1 ] && DEPTHS=("${ARGS[@]:1}")
  else
    DEPTHS=("${ARGS[@]}")
  fi
fi
# normalize 16k/16K -> 16384, validate numeric (must write back via index)
for i in "${!DEPTHS[@]}"; do
  d=${DEPTHS[$i]}
  if [[ $d == *[kK] ]]; then d=$(( ${d%[kK]} * 1024 )); fi
  if ! [[ $d =~ ^[0-9]+$ ]]; then
    echo "bad depth: $d (use e.g. 2048 or 16k)" >&2
    exit 1
  fi
  DEPTHS[$i]=$d
done

# ---------------- helpers ----------------
label() { echo "$(( $1 / 1024 ))K"; }

# ~3.0 chars per token for this model's English
make_prompt() { # $1 = nominal token count
  local tokens=$1
  local chars=$(( tokens * 30 / 10 ))
  awk -v n="$chars" -v s="benchdepth${tokens}-pid$$-rand${RANDOM}${RANDOM}" 'BEGIN {
    base = "Seed " s ". The quick brown fox jumps over the lazy dog while the gray river runs slow under the old mill near the quiet town. ";
    out = "";
    while (length(out) < n) out = out base;
    printf "%s", substr(out, 1, n);
  }'
}

# ---------------- preflight ----------------
MODELS_JSON=$(curl -s -m 15 -H "Authorization: Bearer $API_KEY" "$ENDPOINT/models") || MODELS_JSON=""
MODEL=$(grep -o '"id":"[^"]*"' <<<"$MODELS_JSON" | head -1 | cut -d'"' -f4)
[ -z "$MODEL" ] && MODEL="$DEFAULT_MODEL"

echo "PREFILL BENCH"
echo "endpoint : $ENDPOINT"
echo "model    : $MODEL"
echo "time     : $(date -u '+%Y-%m-%d %H:%M UTC')"
echo ""
printf ' target    actual   prefill (s)   prefill (tok/s)\n'
printf ' ------   ------   -----------   ---------------\n'
printf ' (starred rate = engine prompt_ms over full prompt; prefill(s) column is\n'
printf '  client TTFT and runs low on Strata, which streams tokens mid-prefill)\n'

RESULTS=()

for d in "${DEPTHS[@]}"; do
  text=$(make_prompt "$d")
  bodyfile=$(mktemp)
  trap 'rm -f "$bodyfile"' EXIT
  printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":1,"temperature":0,"stream":true,"stream_options":{"include_usage":true}}' "$MODEL" "$text" > "$bodyfile"

  ttft="" ptt="" first=0
  cached="" eng_ms="" eng_n=""
  start=$(date +%s.%N)
  while IFS= read -r line; do
    if [ "$first" -eq 0 ] && [[ $line == data:* ]] && [[ $line != data:\ [DONE]* ]] \
        && grep -qE '"(reasoning_)?content": "[^\\]' <<<"$line"; then
      # first non-empty delta (content or reasoning); init chunks carry content:""
      now=$(date +%s.%N)
      ttft=$(awk -v a="$start" -v b="$now" 'BEGIN{printf "%.3f", b-a}')
      first=1
    fi
    if [[ $line == data:* && $line == *usage* ]]; then
      ptt=$(grep -o '"prompt_tokens"[[:space:]]*:[[:space:]]*[0-9]*' <<<"$line" | head -1 | grep -o '[0-9]*$')
      cached=$(grep -o '"cached_tokens"[[:space:]]*:[[:space:]]*[0-9]*' <<<"$line" | head -1 | grep -o '[0-9]*$')
      eng_ms=$(grep -o '"prompt_ms"[[:space:]]*:[[:space:]]*[0-9.]*' <<<"$line" | head -1 | grep -o '[0-9.]*$')
      eng_n=$(grep -o '"prompt_n"[[:space:]]*:[[:space:]]*[0-9]*' <<<"$line" | head -1 | grep -o '[0-9]*$')
    fi
  done < <(curl -sN --no-buffer -m "$CURL_TIMEOUT" \
      -H "Authorization: Bearer $API_KEY" \
      -H 'Content-Type: application/json' \
      --data-binary @"$bodyfile" "$ENDPOINT/chat/completions")

  if [ "$first" -eq 0 ] || [ -z "$ttft" ]; then
    actual="-" rps="ERR"
    printf ' %6s   %6s   %11s   %13s\n' "$(label "$d")" "$actual" "-" "no response"
    RESULTS+=("$(label "$d")|-|-|ERR")
  else
    # fall back to estimate if the server did not report usage
    if [ -z "$ptt" ]; then
      ptt=$(( ${#text} * 10 / 30 ))
      ptt="${ptt}~"
    fi
    # rate from engine timings when present (client TTFT on Strata is not reliable)
    if [ -n "$eng_ms" ] && [ -n "$eng_n" ] && [ -n "$ptt" ]; then
      rps=$(awk -v p="$ptt" -v ms="$eng_ms" 'BEGIN{printf "%.0f", (ms>0)? p*1000/ms : 0}')"*"
    else
      rps=$(awk -v t="$ttft" -v p="${ptt%~}" 'BEGIN{printf "%.0f", (t>0)? p/t : 0}')
    fi
    printf ' %6s   %6s   %11s   %13s\n' "$(label "$d")" "$ptt" "$ttft" "$rps"
    if [ -n "$eng_ms" ] && [ -n "$eng_n" ]; then
      printf '           engine: cache %s, cold-read %s tok in %s ms (%.0f tok/s)\n' \
        "${cached:-?}" "$eng_n" "$eng_ms" "$(awk -v n="$eng_n" -v ms="$eng_ms" 'BEGIN{printf "%.0f", (ms>0)? n*1000/ms : 0}')"
    fi
    RESULTS+=("$(label "$d")|$ptt|$ttft|$rps")
  fi
  [ "$d" != "${DEPTHS[${#DEPTHS[@]}-1]}" ] && sleep "$SETTLE"
done

echo ""
echo "done: ${#DEPTHS[@]} depths, $(date -u '+%Y-%m-%d %H:%M UTC')"
