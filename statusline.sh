#!/usr/bin/env bash
#
# Claude Code minimal statusline — pure shell + jq
#
# Three lines:
#   1) Model | Effort | Context
#   2) 5hr  Token: ●●●○○○○○○○ NN% Reset until MM-DD HH:mm
#   3) Week Token: ●●●○○○○○○○ NN% Reset until MM-DD HH:mm
#
# Design notes:
#   - Reads stdin once, parses with a single jq call (@tsv) -> fast cold start.
#   - Writes no temp files and keeps no state -> no leak, no cache staleness.
#   - Handles null (context after /compact) and absent rate_limits (non Pro/Max).
#
set -uo pipefail

# ---- constants -------------------------------------------------------------
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
DIM=$'\033[2m'
RESET=$'\033[0m'

FILLED='●'
EMPTY='○'
BAR_LEN=10

LOW=30   # < LOW  -> green
HIGH=70  # < HIGH -> yellow ; >= HIGH -> red

# ---- read + parse (single jq pass) ----------------------------------------
input=$(cat)

parsed=$(
  printf '%s' "$input" | jq -r '
    [ (.model.display_name // "?"),
      ((if (.effort | type) == "object" then .effort.level else .effort end) // "-"),
      (.context_window.used_percentage // 0),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.rate_limits.seven_day.resets_at // "")
    ] | @tsv
  ' 2>/dev/null
)

IFS=$'\t' read -r model effort ctx r5_pct r5_reset r7_pct r7_reset <<< "$parsed"

# ---- pure helpers ----------------------------------------------------------
rnd() { printf '%.0f' "${1:-0}"; }   # float pct -> nearest int

color_for() {                         # $1 int pct -> ANSI color code
  local p=$1
  if   (( p < LOW  )); then printf '%s' "$GREEN"
  elif (( p < HIGH )); then printf '%s' "$YELLOW"
  else                       printf '%s' "$RED"
  fi
}

bar() {                               # $1 int pct -> 10-char circle bar
  local p=$1 filled i out=''
  filled=$(( (p + 5) / 10 ))          # round to nearest circle
  (( filled > BAR_LEN )) && filled=$BAR_LEN
  (( filled < 0 ))       && filled=0
  for (( i = 0; i < BAR_LEN; i++ )); do
    if (( i < filled )); then out+=$FILLED; else out+=$EMPTY; fi
  done
  printf '%s' "$out"
}

fmt_date() {                          # $1 epoch seconds -> MM-DD HH:mm
  local e=$1
  [[ -z "$e" ]] && { printf '??'; return; }
  date -r "$e" +'%m-%d %H:%M' 2>/dev/null \
    || date -d "@$e" +'%m-%d %H:%M' 2>/dev/null \
    || printf '??'
}

token_line() {                        # $1 label  $2 pct  $3 reset-epoch
  local label=$1 pct=$2 reset=$3 ip col
  if [[ -z "$pct" ]]; then
    printf '%s %sn/a%s' "$label" "$DIM" "$RESET"
    return
  fi
  ip=$(rnd "$pct")
  col=$(color_for "$ip")
  printf '%s %s%s%s %s%3d%%%s %sReset until %s%s' \
    "$label" \
    "$col" "$(bar "$ip")" "$RESET" \
    "$col" "$ip" "$RESET" \
    "$DIM" "$(fmt_date "$reset")" "$RESET"
}

# ---- render ----------------------------------------------------------------
ctx_i=$(rnd "$ctx")
ctx_col=$(color_for "$ctx_i")

# Line 1: Model | Effort | Context
printf '%s %s|%s %s %s|%s Ctx %s%d%%%s\n' \
  "$model" "$DIM" "$RESET" \
  "$effort" "$DIM" "$RESET" \
  "$ctx_col" "$ctx_i" "$RESET"

# Line 2: 5-hour token window
token_line '5hr  Token:' "$r5_pct" "$r5_reset"; printf '\n'

# Line 3: 7-day (weekly) token window
token_line 'Week Token:' "$r7_pct" "$r7_reset"; printf '\n'
