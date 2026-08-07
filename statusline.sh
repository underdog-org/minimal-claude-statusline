#!/usr/bin/env bash
#
# Claude Code minimal statusline — pure shell + jq
#
# Three lines:
#   1) <model> │ <effort> │ <ctx%> │ <branch>
#   2) 5h  ●●○○○○○○○○  22%   2026-07-22 20:00
#   3) 7d  ●●○○○○○○○○  16%   2026-07-24 14:00
#
# Design:
#   - Reads stdin once, single guarded jq pass (`?`/`//`) -> fast, never blanks.
#   - Fields split on ASCII US (0x1f), a non-whitespace IFS, so empty windows
#     never collapse and shift later columns.
#   - Rate-limit values are merged against a shared cache at
#     ~/.claude/statusline-cache.json (single, fixed-size, atomically
#     overwritten).  A session only sees new numbers when *it* calls the API,
#     so parallel sessions otherwise drift; usage is monotonic within a window,
#     so "later window wins, then larger number wins" makes them converge — and
#     fills the startup window instead of showing n/a.
#   - Color has a job: icons are blue (structure you can find at a glance), text
#     is plain foreground, reset timestamps are the only grayed-out thing, and
#     the threshold colors (green/yellow/red) are reserved for usage numbers.
#     Model identity is orange so line 1 has one clear anchor.
#   - Responsive to COLUMNS: wide / medium / narrow tiers drop segments cleanly.
#   - Needs a truecolor terminal + a Nerd Font (icons are in the constants block).
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
GH_BLUE=$'\033[38;2;88;166;255m'    # #58a6ff  — all structural icons
GH_ORANGE=$'\033[38;2;255;166;87m'  # #ffa657  — model identity
GH_GRAY=$'\033[38;2;139;148;158m'   # #8b949e  — reset timestamps only

# ---- glyphs (Nerd Font — swap freely) -------------------------------------
G_MODEL=''      # nf-fa-robot        U+F544
G_EFFORT='󰓅'     # nf-md-speedometer  U+F04C5
G_CTX='󰍛'        # nf-md-memory       U+F035B
G_BRANCH=''     # powerline branch   U+E0A0
G_5H=''         # nf-fa-clock        U+F017  (5-hour window)
G_7D=''         # nf-fa-calendar     U+F073  (weekly window)
DIVIDER=''      # powerline soft div U+E0B1

# Every line leads with exactly one glyph + one space, so the content after it
# lines up across all three rows (Model aligns with the token labels).

FILLED='●'
EMPTY='○'
BAR_LEN=10

LOW=30   # < LOW  -> green
HIGH=70  # < HIGH -> yellow ; >= HIGH -> red

CACHE="${HOME}/.claude/statusline-cache.json"

# ---- read + parse (single guarded jq pass) --------------------------------
input=$(cat)

parsed=$(
  printf '%s' "$input" | jq -r '
    [ (.model.display_name? // "?"),
      # effort may be a string OR an object {"level": "..."} — accept both.
      ((.effort.level?) // (.effort | strings) // "-"),
      (.context_window.used_percentage? // ""),   # "" => still warming up
      (.rate_limits.five_hour.used_percentage? // ""),
      (.rate_limits.five_hour.resets_at? // ""),
      (.rate_limits.seven_day.used_percentage? // ""),
      (.rate_limits.seven_day.resets_at? // ""),
      (.workspace.current_dir? // .cwd? // "")
    ] | map(tostring) | join("")
  ' 2>/dev/null
)

IFS=$'\037' read -r model effort ctx r5_pct r5_reset r7_pct r7_reset cwd <<< "$parsed"
model=${model:-?}; effort=${effort:--}

# ---- rate-limit cache: merge live values with the shared cache ------------
# Each session only learns new rate-limit numbers when *it* talks to the API,
# so an idle session keeps showing whatever it last saw and parallel sessions
# drift apart (88% / 90% / 91%).  Usage inside a window is monotonic — it only
# rises until resets_at — so merging against a shared cache is unambiguous:
# a later window wins, and within one window the larger number wins.
cache_json='{}'
if [[ -f "$CACHE" ]]; then
  c=$(<"$CACHE") && jq -e . >/dev/null 2>&1 <<< "$c" && cache_json=$c
fi

merged=$(
  jq -rn --argjson c "$cache_json" \
    --arg lp5 "$r5_pct" --arg lr5 "$r5_reset" \
    --arg lp7 "$r7_pct" --arg lr7 "$r7_reset" '
      def num: tostring | tonumber? // 0;
      def pick(lp; lr; cp; cr):
        if   (lp // "") == ""     then [cp // "", cr // ""]
        elif (cp // "") == ""     then [lp, lr]
        elif (cr|num) > (lr|num)  then [cp, cr]        # cache is a newer window
        elif (cr|num) < (lr|num)  then [lp, lr]        # live is a newer window
        elif (cp|num) > (lp|num)  then [cp, cr]        # same window, cache saw more
        else [lp, lr] end;
      pick($lp5; $lr5; $c.r5_pct; $c.r5_reset)
      + pick($lp7; $lr7; $c.r7_pct; $c.r7_reset)
      | map(tostring) | join("")
    ' 2>/dev/null
)
[[ -n "$merged" ]] &&
  IFS=$'\037' read -r r5_pct r5_reset r7_pct r7_reset <<< "$merged"

# persist the merged view so every session converges on the same numbers
if [[ -n "$r5_pct" || -n "$r7_pct" ]]; then
  tmp=$(mktemp "${CACHE}.XXXXXX" 2>/dev/null) && {
    printf '{"r5_pct":"%s","r5_reset":"%s","r7_pct":"%s","r7_reset":"%s"}\n' \
      "$r5_pct" "$r5_reset" "$r7_pct" "$r7_reset" > "$tmp" && mv "$tmp" "$CACHE" \
      || rm -f "$tmp"
  }
fi

# ---- responsive tier -------------------------------------------------------
cols=${COLUMNS:-80}
if   (( cols >= 72 )); then tier=full
elif (( cols >= 48 )); then tier=medium
else                        tier=narrow
fi

# ---- pure helpers ----------------------------------------------------------
rnd() { printf '%.0f' "${1:-0}"; }

pct_color() {
  local p=$1
  if   (( p < LOW  )); then printf '%s' "$GH_GREEN"
  elif (( p < HIGH )); then printf '%s' "$GH_YELLOW"
  else                       printf '%s' "$GH_RED"
  fi
}

bar() {
  local p=$1 filled i out=''
  filled=$(( (p + 5) / 10 ))
  (( filled > BAR_LEN )) && filled=$BAR_LEN
  (( filled < 0 ))       && filled=0
  for (( i = 0; i < BAR_LEN; i++ )); do
    if (( i < filled )); then out+=$FILLED; else out+=$EMPTY; fi
  done
  printf '%s' "$out"
}

fmt_date() {                          # $1 epoch  $2 strftime-format
  local e=$1 f=$2
  [[ -z "$e" ]] && { printf '??'; return; }
  date -r "$e" +"$f" 2>/dev/null || date -d "@$e" +"$f" 2>/dev/null || printf '??'
}

join_sep() {                          # join non-empty args with dim divider
  local out='' s
  for s in "$@"; do
    [[ -z "$s" ]] && continue
    if [[ -z "$out" ]]; then out=$s; else out="$out ${DIM}${DIVIDER}${RESET} $s"; fi
  done
  printf '%s' "$out"
}

token_line() {                        # $1 icon  $2 label  $3 pct  $4 reset
  local icon=$1 label=$2 pct=$3 reset=$4 ip col fmt datestr
  if [[ -z "$pct" ]]; then
    printf '%s%s%s %-2s  %sn/a%s' \
      "$GH_BLUE" "$icon" "$RESET" "$label" "$GH_GRAY" "$RESET"
    return
  fi
  ip=$(rnd "$pct"); col=$(pct_color "$ip")
  printf '%s%s%s %-2s  %s%s%s  %s%3d%%%s' \
    "$GH_BLUE" "$icon" "$RESET" "$label" \
    "$col" "$(bar "$ip")" "$RESET" \
    "$col" "$ip" "$RESET"
  if [[ "$tier" != narrow ]]; then
    case "$tier" in full) fmt='%Y-%m-%d %H:%M' ;; *) fmt='%m-%d %H:%M' ;; esac
    datestr=$(fmt_date "$reset" "$fmt")
    printf '   %s%s%s' "$GH_GRAY" "$datestr" "$RESET"
  fi
}

# ---- model: name by tier, one identity color across all families ----------
case "$tier" in
  full)   name=$model ;;
  medium) name=${model% (*} ;;   # strip trailing " (1M context)"
  narrow) name=${model%% *} ;;   # first word only
esac
model_seg="${GH_ORANGE}${G_MODEL}${RESET} ${BOLD}${GH_ORANGE}${name}${RESET}"

# ---- effort: plain foreground unless expensive ------------------------------
case "$effort" in
  high)  ecolor=$GH_RED ;;
  xhigh) ecolor=$GH_PURPLE ;;
  max)   ecolor=$BOLD$GH_RED ;;
  *)     ecolor='' ;;             # low / medium / unknown -> plain, still legible
esac
effort_seg="${GH_BLUE}${G_EFFORT}${RESET} ${ecolor}${effort}${RESET}"

# ---- context: threshold color, or a warming skeleton -----------------------
if [[ -z "$ctx" ]]; then
  ctx_seg="${GH_BLUE}${G_CTX}${RESET} ${GH_GRAY}⋯${RESET}"
else
  ci=$(rnd "$ctx")
  ctx_seg="${GH_BLUE}${G_CTX}${RESET} $(pct_color "$ci")${ci}%${RESET}"
fi

# ---- branch: blue glyph + plain name, wide/medium only, inside a repo ------
branch_seg=''
if [[ "$tier" != narrow && -n "$cwd" ]]; then
  branch=$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null \
    || git -C "$cwd" rev-parse --short HEAD 2>/dev/null || true)
  [[ -n "$branch" ]] && branch_seg="${GH_BLUE}${G_BRANCH}${RESET} ${branch}"
fi

# ---- render ----------------------------------------------------------------
join_sep "$model_seg" "$effort_seg" "$ctx_seg" "$branch_seg"; printf '\n'
token_line "$G_5H" '5h' "$r5_pct" "$r5_reset"; printf '\n'
token_line "$G_7D" '7d' "$r7_pct" "$r7_reset"; printf '\n'
