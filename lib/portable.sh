# shellcheck shell=bash
# Portable readers for the clock and a file's modification time. Source it; it
# only defines functions (no `set` options, no output beyond what each states).
#
#   # shellcheck source=../lib/portable.sh
#   . "$KP_ROOT/lib/portable.sh"
#
# macOS ships BSD `stat` and `date`, CI and most hosts run GNU coreutils. Each
# function tries the GNU form first and then the BSD form, the shape
# lib/supervisor.sh already uses for the supervisor's start time. A failure is
# never turned into `0` or an empty string: the function returns 1 and prints
# nothing, so its caller reports the failure instead of reading a bogus age.

# kp_mtime <path>
# Prints <path>'s modification time as epoch seconds. Exit 1 and no output when
# neither `stat` form works (a missing file, or a stat that refuses both).
kp_mtime() {
  local path=${1:?} mtime
  [ -e "$path" ] || return 1
  mtime=$(stat -c %Y "$path" 2>/dev/null || true)
  [ -n "$mtime" ] || mtime=$(stat -f %m "$path" 2>/dev/null || true)
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$mtime"
}

# kp_now_iso
# Prints the current time in the ISO 8601 shape both platforms write
# (`date +%Y-%m-%dT%H:%M:%S%z`; GNU's `date -Iseconds` is not portable). Exit 1
# and no output when the clock cannot be read, so a caller under `set -e` stops
# instead of writing an empty timestamp.
kp_now_iso() {
  local now
  now=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || true)
  case "$now" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$now"
}

# kp_epoch_from_iso <iso>
# Prints <iso> as epoch seconds. <iso> is the value kp_now_iso writes; a value
# an older build wrote with `date -Iseconds` (`+HH:MM` instead of `+HHMM`) is
# accepted too. Exit 1 and no output when the shape is wrong, a date field is
# out of range, or neither `date` form parses it, so a caller never reads an
# unparseable value as "now" (which is what BSD `date -j -f` degrades to).
kp_epoch_from_iso() {
  local iso=${1:-} epoch bsd month day hour minute second
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ;;
    *) return 1 ;;
  esac
  # BSD strptime wants the offset without its colon: +02:00 -> +0200.
  bsd=$iso
  case "$bsd" in
    *[+-][0-9][0-9]:[0-9][0-9]) bsd="${bsd%:*}" && bsd="$bsd${iso##*:}" ;;
  esac
  epoch=$(date -d "$iso" +%s 2>/dev/null || true)
  case "$epoch" in ''|*[!0-9]*) epoch='' ;; esac
  if [ -z "$epoch" ]; then
    # BSD `date -j -f` keeps the current value for a field it cannot parse (a
    # month of 13 reads as "now") instead of failing. Check the field ranges
    # before trusting it. Re-formatting the epoch instead would compare the
    # reader's local offset with the value's own and reject a valid instant.
    case "$bsd" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9][0-9][0-9]) ;;
      *) return 1 ;;
    esac
    month=${bsd:5:2} day=${bsd:8:2} hour=${bsd:11:2} minute=${bsd:14:2} second=${bsd:17:2}
    case "$month" in 01|02|03|04|05|06|07|08|09|10|11|12) ;; *) return 1 ;; esac
    case "$day" in 0[1-9]|[12][0-9]|3[01]) ;; *) return 1 ;; esac
    case "$hour" in 0[0-9]|1[0-9]|2[0-3]) ;; *) return 1 ;; esac
    case "$minute" in 0[0-9]|[1-5][0-9]) ;; *) return 1 ;; esac
    case "$second" in 0[0-9]|[1-5][0-9]) ;; *) return 1 ;; esac
    epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$bsd" +%s 2>/dev/null || true)
    case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  fi
  printf '%s\n' "$epoch"
}
