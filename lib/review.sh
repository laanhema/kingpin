# shellcheck shell=bash
# The review-report reader: what the landing gate can derive from the report a
# `ready:` line names.
#
# Source it; it only defines functions (no `set` options, no output beyond what
# each states).
#
#   # shellcheck source=../lib/review.sh
#   . "$KP_BIN/../lib/review.sh"
#
# A review report is the markdown page the review skill writes: an
# `## Issues Found` block whose findings sit under the severity headings
# `### Critical`, `### High Priority`, `### Medium Priority` and
# `### Suggestions (Low)`. `bin/kingpin-land` is the caller: it asks this reader
# whether a findings verdict has anything that must block the merge, so an
# `APPROVE WITH NITS` whose open findings are all Low can land without a
# fix-pass agent session.
#
# The class comes from the section a finding sits in, never from the id letter:
# a report that quotes `**L3**` under `## What's Good`, or in a Fix Verification
# table row, is not naming an open finding. Everything here fails closed: a
# report that is missing, empty, has no `## Issues Found` block, carries no
# recognized severity heading, or carries a `###` heading inside that block which
# this reader does not know exits 1, and `bin/kingpin-land` then runs the fix
# pass rather than landing on a page it could not read. The unknown heading is
# the one a misspelling hides behind: `### High` instead of `### High Priority`
# would otherwise read as a section with nothing to block.

# _kp_review_scan <report-file>
# One line per open finding: `blocking<TAB><bullet>` or `followup<TAB><bullet>`.
# Reads only the `## Issues Found` block (entering on `## Issues Found`, leaving
# on the next `## ` heading), and classifies each finding by the `###` heading
# above it: Critical, High Priority and Medium Priority block, Suggestions (Low)
# is follow-up. A `###` heading inside the block that is none of those four could
# be a misspelled severity with a blocking finding under it, so it makes the
# whole scan unreadable instead of merely unclassified: nothing under it is
# reported, and the reader exits 1. A finding is a list item whose first bold
# token is an id (`- **M1** ...`). A trailing CR is stripped. Exits 1 when the
# file is absent or unreadable, when there is no Issues Found block, when no
# recognized severity heading was seen, or when the block holds a `###` heading
# this reader does not know; exits 0 otherwise, including a block whose sections
# all say `None`.
_kp_review_scan() {
  local report=${1:-}
  [ -n "$report" ] && [ -f "$report" ] && [ -r "$report" ] || return 1
  awk '
    { sub(/\r$/, "") }

    /^## Issues Found[[:space:]]*$/ {
      found = 1
      in_block = 1
      next
    }

    in_block && /^## / {
      in_block = 0
      class = ""
      next
    }

    in_block && /^### / {
      if ($0 ~ /^###[[:space:]]+Critical[[:space:]]*$/ \
          || $0 ~ /^###[[:space:]]+High Priority[[:space:]]*$/ \
          || $0 ~ /^###[[:space:]]+Medium Priority[[:space:]]*$/) {
        class = "blocking"
        seen = 1
      } else if ($0 ~ /^###[[:space:]]+Suggestions \(Low\)[[:space:]]*$/) {
        class = "followup"
        seen = 1
      } else {
        # A heading this reader does not know could be a misspelled severity
        # with a blocking finding under it, so the block is unreadable rather
        # than empty: report nothing from it and fail the whole scan.
        class = ""
        unknown = 1
      }
      next
    }

    in_block && class != "" && /^[[:space:]]*[-*+][[:space:]]+\*\*[CHML][0-9]+\*\*/ {
      printf "%s\t%s\n", class, $0
    }

    END {
      # A block whose headings this reader does not know proves nothing about
      # what blocks, so it is not an answer.
      exit !(found && seen && !unknown)
    }
  ' "$report"
}

# kp_review_blocking_count <report-file>
# How many open findings block the merge (Critical, High and Medium). Always
# prints a number on success, never a blank line; exits 1 when the scan cannot
# derive, so a caller can tell "zero blocking" from "no answer".
kp_review_blocking_count() {
  local report=${1:-} found
  found=$(_kp_review_scan "$report") || return 1
  printf '%s\n' "$found" | awk 'index($0, "blocking\t") == 1 { n++ } END { print n + 0 }'
}

# kp_review_followups <report-file>
# The follow-up (Low) finding bullet lines, verbatim, one per line. Prints nothing
# when there are none, and exits 1 when the scan cannot derive.
kp_review_followups() {
  local report=${1:-} found
  found=$(_kp_review_scan "$report") || return 1
  printf '%s\n' "$found" | awk 'index($0, "followup\t") == 1 { print substr($0, 10) }'
}
