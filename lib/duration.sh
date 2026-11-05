# shellcheck shell=bash
# Shared duration parsing and formatting: one parser for every --since/--ttl flag and
# one formatter for every summary line. Source it; it only defines functions (no `set`
# options, no output beyond what each states, every function returns 0 unless stated).

# kp_parse_duration <spec>
# Prints <spec> in seconds. One or more <digits><unit> segments with unit s, m, h or d;
# each number is at most 9 digits and the total must be positive. Anything else (a bare
# number, an unknown unit, a trailing character, a zero total) fails with exit 1 and no
# output, so a caller reports the argument instead of reading a guessed value. A leading
# zero is decimal, not octal: 08h is eight hours.
kp_parse_duration() {
  local spec=${1:-} total=0 num unit
  [ -n "$spec" ] || return 1
  while [ -n "$spec" ]; do
    case "$spec" in [0-9]*) ;; *) return 1 ;; esac
    num=${spec%%[!0-9]*}
    spec=${spec#"$num"}
    [ "${#num}" -le 9 ] || return 1
    num=$((10#$num))
    case "$spec" in
      s*) unit=1 ;;
      m*) unit=60 ;;
      h*) unit=3600 ;;
      d*) unit=86400 ;;
      *) return 1 ;;
    esac
    spec=${spec#?}
    total=$((total + num * unit))
  done
  [ "$total" -gt 0 ] || return 1
  printf '%s\n' "$total"
}

# kp_format_duration <seconds>
# Prints a short form floored to the largest whole unit: `3h12m`, `48m`, `12s`, and `2h`
# when the minutes are zero. Bad input reads as `0s`, so a report never shows a blank.
kp_format_duration() {
  local s=${1:-0} h m
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if [ "$s" -lt 60 ]; then printf '%ds\n' "$s"; return 0; fi
  if [ "$s" -lt 3600 ]; then printf '%dm\n' $((s / 60)); return 0; fi
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$m" -eq 0 ]; then printf '%dh\n' "$h"; else printf '%dh%02dm\n' "$h" "$m"; fi
}
