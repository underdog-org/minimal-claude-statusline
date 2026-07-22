#!/usr/bin/env bash
#
# Claude Code minimal statusline — pure shell + jq
#
# Four lines:
#   1) <emoji> Model | Effort | Context
#   2)  branch
#   3) 5hr  Token: ●●●○○○○○○○ NN% Reset until MM-DD HH:mm
#   4) Week Token: ●●●○○○○○○○ NN% Reset until MM-DD HH:mm
#
# Design notes:
#   - Reads stdin once, parses with a single jq call (@tsv) -> fast cold start.
#   - Every jq field is guarded (`?` / `//`) so one odd shape (e.g. effort as an
#     object) can never blank the whole line.
#   - Writes no temp files, keeps no state -> no leak, no stale cache.
#   - GitHub-flavored truecolor palette (needs a truecolor terminal: iTerm2, etc).
#   - Branch glyph  is the Powerlevel10k/Nerd-Font branch icon (U+E0A0).
#
set -uo pipefail

# ---- palette (GitHub truecolor) -------------------------------------------
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'
GH_GREEN=$'\033[38;2;63;185;80m'    # #3fb950
GH_YELLOW=$'\033[38;2;210;153;34m'  # #d29922
GH_RED=$'\033[38;2;248;81;73m'      # #f85149
GH_PURPLE=$'\033[38;2;188;140;255m' # #bc8cff
GH_GRAY=$'\033[38;2;139;148;158m'   # #8b949e

FILLED='●'
EMPTY='○'
BAR_LEN=10
BRANCH_GLYPH=$''

# Threshold
LOW=30   # < LOW  -> green
HIGH=70  # < HIGH -> yellow ; >= HIGH -> red

# ---- read + parse (single jq pass, every field guarded) -------------------
input=$(cat)

parsed=$(
  printf '%s' "$input" | jq -r '
    [ (.model.display_name? // "?"),
      # effort may be a string OR an object {"level": "..."} — accept both.
      ((.effort.level?) // (.effort | strings) // "-"),
      (.context_window.used_percentage? // 0),
      (.rate_limits.five_hour.used_percentage? // ""),
      (.rate_limits.five_hour.resets_at? // ""),
      (.rate_limits.seven_day.used_percentage? // ""),
      (.rate_limits.seven_day.resets_at? // ""),
      (.workspace.current_dir? // .cwd? // "")
    ] | map(tostring) | join("")
  ' 2>/dev/null
)

# Split on ASCII US (0x1f): a non-whitespace IFS preserves empty fields, so an
# absent rate_limits window can never shift later columns (e.g. cwd) leftward.
IFS=$'\037' read -r model effort ctx r5_pct r5_reset r7_pct r7_reset cwd <<< "$parsed"
# last-resort defaults if jq produced nothing at all
model=${model:-?}; effort=${effort:--}; ctx=${ctx:-0}

# ---- pure helpers ----------------------------------------------------------
rnd() { printf '%.0f' "${1:-0}"; }   # float pct -> nearest int

pct_color() {                         # $1 int pct -> threshold color
  local p=$1
  if   (( p < LOW  )); then printf '%s' "$GH_GREEN"
  elif (( p < HIGH )); then printf '%s' "$GH_YELLOW"
  else                       printf '%s' "$GH_RED"
  fi
}

bar() {                               # $1 int pct -> 10-char circle bar
  local p=$1 filled i out=''
  filled=$(( (p + 5) / 10 ))
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
  col=$(pct_color "$ip")
  printf '%s %s%s%s %s%3d%%%s %sReset until %s%s' \
    "$label" \
    "$col" "$(bar "$ip")" "$RESET" \
    "$col" "$ip" "$RESET" \
    "$DIM" "$(fmt_date "$reset")" "$RESET"
}

# ---- model: color + emoji by family ---------------------------------------
case "$model" in
  *Sonnet*) model_color=$GH_GREEN;  model_emoji='✨' ;;
  *Opus*)   model_color=$GH_YELLOW; model_emoji='🧠' ;;
  *Fable*)  model_color=$GH_RED;    model_emoji='📖' ;;
  *Haiku*)  model_color='';         model_emoji='🍃' ;;  # default color
  *)        model_color='';         model_emoji='🤖' ;;
esac

# ---- effort: color by level ------------------------------------------------
case "$effort" in
  low)    effort_color=$GH_GREEN ;;
  medium) effort_color=$GH_YELLOW ;;
  high)   effort_color=$GH_RED ;;
  xhigh)  effort_color=$GH_PURPLE ;;
  max)    effort_color=$BOLD$GH_RED ;;
  *)      effort_color=$GH_GRAY ;;
esac

# ---- render ----------------------------------------------------------------
ctx_i=$(rnd "$ctx")
ctx_col=$(pct_color "$ctx_i")

# Line 1: <emoji> Model | Effort | Context
printf '%s %s%s%s%s %s|%s %s%s%s %s|%s Ctx %s%d%%%s\n' \
  "$model_emoji" \
  "$BOLD" "$model_color" "$model" "$RESET" \
  "$DIM" "$RESET" \
  "$effort_color" "$effort" "$RESET" \
  "$DIM" "$RESET" \
  "$ctx_col" "$ctx_i" "$RESET"

# Line 2: branch (only inside a git repo)
if [[ -n "$cwd" ]]; then
  branch=$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null \
    || git -C "$cwd" rev-parse --short HEAD 2>/dev/null || true)
  [[ -n "$branch" ]] && printf '%s %s%s%s\n' "$BRANCH_GLYPH" "$GH_GRAY" "$branch" "$RESET"
fi

# Line 3: 5-hour token window
token_line '5hr  Token:' "$r5_pct" "$r5_reset"; printf '\n'

# Line 4: 7-day (weekly) token window
token_line 'Week Token:' "$r7_pct" "$r7_reset"; printf '\n'
