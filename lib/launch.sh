# shellcheck shell=bash
# The worker preamble and the per-harness `launch.sh` generator that `kingpin-spawn`
# and `kingpin-restore` share, so a fifth harness or a changed flag is written once and
# a restored worker cannot drift from a freshly spawned one. Source it; it defines the
# functions below and nothing else (no `set` options, no output beyond what each states,
# every function returns 0 unless stated).
#
#   # shellcheck source=../lib/launch.sh
#   . "$KP_ROOT/lib/launch.sh"
#
# The caller sets KP_ROOT (this checkout), KP_PI_PROVIDER and KP_PI_MODEL (empty when
# unset), and reads `<task-dir>/injected` after `kp_harness_launch_script` to learn the
# worktree paths that launch injected. The prompt is read from its file by the launch
# script itself, so a long request is never re-quoted onto a command line.
#
# It also reads the sessions a harness already has for a worktree
# (`kp_harness_sessions`), says whether one is live and how old it is, and builds the
# argv words that resume one, so `kingpin-restore` continues the conversation a task
# already had instead of starting a second one (issue #168).

# shellcheck source=status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/status.sh"
# shellcheck source=gitdir.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gitdir.sh"
# shellcheck source=portable.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable.sh"

# The window in which a reported session counts as live, in seconds. Chosen from the
# issue #168 timeline (the orphan session was updated seconds before the restore ran)
# and long enough to cover a worker that was idle awaiting input when its window died.
# Internal on purpose: it is not a KINGPIN_* variable, so the CLI reference stays as it
# is, and a suite steers it by writing fixture timestamps.
_kp_session_live_seconds=900

# The number of rows a harness's session listing is asked for. Far above a project's
# session count, because a task's own session may be older than the newest handful and
# a listing that stops early would read as "no session". A listing that reaches this
# length is reported as truncated rather than trusted as complete.
_kp_session_list_cap=1000

# kp_worker_preamble <task-dir> <worktree> <mode>
# Writes `<task-dir>/preamble.md` from worker/preamble.md with the task placeholders
# substituted. The harness is read from the task record, because the pi and codex
# preambles carry one extra sentence (neither was observed to have a subagent tool, so a
# delegating skill's steps run inline and /do must not stop to ask whether to continue).
kp_worker_preamble() {
  local task_dir=${1:?kp_worker_preamble needs a task dir} worktree=${2:?} mode=${3:?}
  task_dir=${task_dir%/}
  local id harness
  id=$(kp_env_get "$task_dir/task.env" TASK_ID)
  [ -n "$id" ] || id=$(basename "$task_dir")
  harness=$(kp_env_get "$task_dir/task.env" HARNESS)
  [ -n "$harness" ] || harness=claude
  sed -e "s|{{TASK_ID}}|$id|g" -e "s|{{TASK_DIR}}|$task_dir|g" -e "s|{{MODE}}|$mode|g" \
    -e "s|{{WORKTREE}}|$worktree|g" -e "s|{{KP_ROOT}}|${KP_ROOT:?}|g" \
    "${KP_ROOT:?}/worker/preamble.md" > "$task_dir/preamble.md" \
    || { echo "cannot write $task_dir/preamble.md" >&2; return 1; }
  case $harness in
    pi|codex)
      printf '%s\n' '' 'This harness has no subagent tool: run every step of the skill inline in this session, and continue rather than asking whether to continue without subagents.' >> "$task_dir/preamble.md" \
        || { echo "cannot write $task_dir/preamble.md" >&2; return 1; }
      ;;
  esac
  return 0
}

# kp_harness_command <harness>
# Prints the command a harness launches with: KINGPIN_CLAUDE, KINGPIN_AGY,
# KINGPIN_OPENCODE, KINGPIN_PI or KINGPIN_CODEX, each defaulting to the harness's own
# name. Exit 1 for an unknown harness, so a caller validates before it trusts the value.
kp_harness_command() {
  case "${1:-}" in
    claude) printf '%s\n' "${KINGPIN_CLAUDE:-claude}" ;;
    agy) printf '%s\n' "${KINGPIN_AGY:-agy}" ;;
    opencode) printf '%s\n' "${KINGPIN_OPENCODE:-opencode}" ;;
    pi) printf '%s\n' "${KINGPIN_PI:-pi}" ;;
    codex) printf '%s\n' "${KINGPIN_CODEX:-codex}" ;;
    *) return 1 ;;
  esac
}

# kp_harness_session_live <updated-epoch>
# Exit 0 when <updated-epoch> is a numeric timestamp inside the live window, 1 otherwise.
# A future timestamp counts as live: the clock pair cannot prove it dead.
kp_harness_session_live() {
  local updated=${1:-} now
  case "$updated" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  [ $((now - updated)) -le "$_kp_session_live_seconds" ]
}

# kp_harness_session_age <updated-epoch>
# Prints the age as `12s`, `4m`, `3h` or `6d`. Exit 1 and no output for a non-numeric
# value, so a caller reports the missing figure instead of printing a bogus age.
kp_harness_session_age() {
  local updated=${1:-} now age
  case "$updated" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  age=$((now - updated))
  [ "$age" -ge 0 ] || age=0
  if [ "$age" -lt 60 ]; then
    printf '%ss\n' "$age"
  elif [ "$age" -lt 3600 ]; then
    printf '%sm\n' "$((age / 60))"
  elif [ "$age" -lt 86400 ]; then
    printf '%sh\n' "$((age / 3600))"
  else
    printf '%sd\n' "$((age / 86400))"
  fi
}

# kp_harness_sessions <harness> <worktree>
# Prints one line per session the harness already has for <worktree>, newest first:
# `<id><TAB><updated-epoch-seconds><TAB><label>`, where the label is the session title
# capped at 60 characters with tabs and newlines collapsed (empty when the store has
# none). Exit 0 with no output when the harness reports no session, 3 with the rows it
# did report when the listing reached the cap (so older sessions may be missing), and
# exit 1 with no output when the harness cannot report sessions or the read failed, so
# a caller can tell "there is none" and "this list may be incomplete" from "I cannot
# know". OpenCode's listing is filtered on the session's recorded directory resolved
# through realpath, because one project id covers every worktree of a repository;
# claude's store is per directory already. agy and pi have no documented listing call,
# so they report nothing and say so by the exit status.
kp_harness_sessions() {
  local harness=${1:?kp_harness_sessions needs a harness}
  local worktree=${2:?kp_harness_sessions needs a worktree}
  local cmd raw base dir slug f updated seen rc=0
  case "$harness" in
    opencode)
      cmd=$(kp_harness_command opencode) || return 1
      raw=$(cd "$worktree" && "$cmd" session list --format json -n "$_kp_session_list_cap" 2>/dev/null) || return 1
      # shellcheck disable=SC2016 # single quotes are intentional: the program runs in node
      printf '%s\n' "$raw" | node -e '
        const fs = require("fs");
        const path = require("path");
        const chunks = [];
        process.stdin.on("data", (d) => chunks.push(d)).on("end", () => {
          let rows = null;
          try { rows = JSON.parse(chunks.join("")); } catch {}
          if (!Array.isArray(rows)) process.exit(1);
          const norm = (p) => {
            try { return fs.realpathSync(p); } catch { return path.resolve(p); }
          };
          const target = norm(process.argv[1]);
          const cap = Number(process.argv[2]);
          const out = [];
          for (const r of rows) {
            if (!r || typeof r.id !== "string" || typeof r.directory !== "string") continue;
            if (norm(r.directory) !== target) continue;
            const updated = Number(r.updated);
            if (!Number.isFinite(updated)) continue;
            const label = String(r.title === undefined || r.title === null ? "" : r.title)
              .replace(/[\t\r\n]+/g, " ").slice(0, 60);
            out.push([r.id, Math.floor(updated / 1000), label]);
          }
          out.sort((a, b) => b[1] - a[1]);
          for (const row of out) process.stdout.write(`${row[0]}\t${row[1]}\t${row[2]}\n`);
          if (Number.isFinite(cap) && rows.length >= cap) process.exitCode = 3;
        });
      ' "$worktree" "$_kp_session_list_cap" 2>/dev/null || rc=$?
      case $rc in
        0|3) return "$rc" ;;
        *) return 1 ;;
      esac
      ;;
    claude)
      # The transcript store is per working directory: <config>/projects/<slug>, where the
      # slug replaces every character outside [A-Za-z0-9-] with `-`. Try the worktree as
      # recorded, then its physical path, and list each store once. A missing directory is
      # "no sessions", not a failure.
      base=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
      seen=' '
      for dir in "$worktree" "$(cd "$worktree" && pwd -P)"; do
        slug=$(printf '%s' "$dir" | sed 's/[^A-Za-z0-9-]/-/g')
        case "$seen" in *" $slug "*) continue ;; esac
        seen="$seen$slug "
        [ -d "$base/$slug" ] || continue
        for f in "$base/$slug"/*.jsonl; do
          [ -f "$f" ] || continue
          updated=$(kp_mtime "$f") || continue
          printf '%s\t%s\t\n' "$(basename "$f" .jsonl)" "$updated"
        done
      done | LC_ALL=C sort -t "$(printf '\t')" -k2,2nr
      ;;
    *) return 1 ;;
  esac
}

# kp_harness_resume_args <harness> <session-id>
# Prints the argv words that resume one session, one per line, so the caller reads them
# into an array with the bash-3.2-safe `while IFS= read -r` shape. OpenCode resumes by
# id; claude's `--continue` is scoped to the current directory, so its detected id is used
# for the record only. Exit 1 for a harness with no resume support here (agy, pi).
kp_harness_resume_args() {
  local harness=${1:?kp_harness_resume_args needs a harness} session=${2:-}
  case "$harness" in
    opencode)
      [ -n "$session" ] || return 1
      printf '%s\n' --session "$session"
      ;;
    claude) printf '%s\n' --continue ;;
    *) return 1 ;;
  esac
}

# A TOML basic string for a path. `codex -c key=value` parses the value as TOML, so a
# KINGPIN_HOME holding a space or a quote still produces a value Codex reads whole.
toml_quote() {
  local v=${1:?}
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  printf '"%s"' "$v"
}

# True when this host carries a Codex hook set, which raises Codex's second review dialog
# ("Hooks need review") that `-a never` does not cover and no `-c` value suppresses
# (issue #106, Phase 0 check 7). A hook set is `features.hooks = true` in the config
# store, or a `hooks.json` beside it whose `hooks` object is not empty.
codex_hook_set() {
  local dir=${CODEX_HOME:-$HOME/.codex} cfg hooks
  cfg=$dir/config.toml
  if [ -f "$cfg" ] && awk '
    /^[[:space:]]*\[/ { inside = ($0 ~ /^[[:space:]]*\[features\][[:space:]]*$/) }
    inside && /^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$cfg"; then
    return 0
  fi
  hooks=$dir/hooks.json
  [ -f "$hooks" ] || return 1
  # shellcheck disable=SC2016 # single quotes are intentional: the program runs in node
  node -e '
    const fs = require("fs");
    let o = {};
    try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(1); }
    const h = o && typeof o === "object" ? o.hooks : undefined;
    process.exit(h && typeof h === "object" && !Array.isArray(h) && Object.keys(h).length > 0 ? 0 : 1);
  ' "$hooks" 2>/dev/null
}

# kp_harness_launch_script <task-dir> <worktree> <harness> <prompt-file> [resume-word ...]
# Writes `<task-dir>/launch.sh` for one harness, makes it executable, and records the
# worktree paths it injected in `<task-dir>/injected` (one per line, empty when none),
# so the caller never captures stdout and a failure keeps its exit status. The prompt
# is read at launch time from <prompt-file>. Any extra arguments are argv words placed
# before the harness's own flags (a resume's `--session <id>`, for example), so the
# prompt stays the last argument and the harness reads it as the initial turn of the
# session it resumed. With no extra word the generated file is byte-identical to a
# fresh launch's, which is what keeps spawn and the suites reading one shape. Returns 1
# with a stderr reason for the opencode tracked-config refusal, a node failure and a
# missing pi extension.
kp_harness_launch_script() {
  local task_dir=${1:?kp_harness_launch_script needs a task dir}
  local worktree=${2:?} harness=${3:?} prompt=${4:?}
  task_dir=${task_dir%/}
  shift 4
  local -a resume=("$@")
  local resume_words=''
  [ "${#resume[@]}" -eq 0 ] || resume_words=$(printf '%q ' "${resume[@]}")
  [ -f "$prompt" ] || { echo "prompt file is missing: $prompt" >&2; return 1; }
  local -a injected=() pi_args=()

  case "$harness" in
    claude)
      node "${KP_ROOT:?}/lib/claude-trust.mjs" "$worktree" >/dev/null \
        || { echo "cannot record the claude trust for $worktree" >&2; return 1; }
      cat > "$task_dir/launch.sh" <<EOF
#!/usr/bin/env bash
export KINGPIN_TASK_DIR='$task_dir'
export KINGPIN_WORKTREE='$worktree'
export KINGPIN_ROOT='${KP_ROOT:?}'
exec ${KINGPIN_CLAUDE:-claude} ${resume_words}--append-system-prompt-file '$task_dir/preamble.md' --settings '${KP_ROOT:?}/worker/hooks.json' "\$(cat '$prompt')"
EOF
      ;;
    agy)
      node "${KP_ROOT:?}/lib/agy-trust.mjs" "$worktree" >/dev/null \
        || { echo "cannot record the agy trust for $worktree" >&2; return 1; }
      mkdir -p "$worktree/.agents/rules" \
        || { echo "cannot create $worktree/.agents/rules" >&2; return 1; }
      # A rules file agy does not recognize is skipped without a word, so the preamble
      # carries the trigger frontmatter that makes agy load it (verified with agy 1.4.12).
      {
        printf -- '---\ntrigger: always_on\ndescription: Kingpin worker preamble\n---\n\n'
        cat "$task_dir/preamble.md"
      } > "$worktree/.agents/rules/kingpin.md" \
        || { echo "cannot write $worktree/.agents/rules/kingpin.md" >&2; return 1; }
      cat > "$worktree/.agents/hooks.json" << 'EOF_HOOKS'
{
  "kingpin": {
    "Stop": [
      {
        "type": "command",
        "command": "[ -n \"${KINGPIN_TASK_DIR:-}\" ] || exit 0; if [ -x \"${KINGPIN_ROOT:-/nonexistent}/bin/kingpin-stop\" ]; then \"$KINGPIN_ROOT/bin/kingpin-stop\" || true; else echo \"kingpin: stop hook unavailable (KINGPIN_ROOT unset or kingpin-stop missing); the worker's outcome is not recorded\" >&2; fi; exit 0",
        "timeout": 30
      }
    ]
  }
}
EOF_HOOKS
      injected+=('.agents/rules/kingpin.md' '.agents/hooks.json')
      cat > "$task_dir/launch.sh" <<EOF
#!/usr/bin/env bash
export KINGPIN_TASK_DIR='$task_dir'
export KINGPIN_ROOT='${KP_ROOT:?}'
exec ${KINGPIN_AGY:-agy} ${resume_words}--prompt-interactive "\$(cat '$prompt')" --dangerously-skip-permissions
EOF
      ;;
    opencode)
      mkdir -p "$worktree/.opencode/plugins" \
        || { echo "cannot create $worktree/.opencode/plugins" >&2; return 1; }
      # OpenCode V2 reads opencode.json(c) (or .opencode/opencode.json), not
      # .opencode/config.json, which it ignores without a word (verified with
      # opencode 2.2.5: the old file left the worker with no preamble at all).
      # That path is also a project's normal config, holding its own instructions and
      # permissions, so it is merged into, never truncated. A file the project tracks
      # cannot be hidden by .git/info/exclude: rewriting it would start the worker on a
      # dirty tree and a worker could commit the change, so the launch is refused.
      if git -C "$worktree" ls-files --error-unmatch .opencode/opencode.json >/dev/null 2>&1; then
        echo "refusing to launch: $worktree/.opencode/opencode.json is tracked by the project; Kingpin must add the preamble to its instructions, so untrack that file (add it to .gitignore) and launch again" >&2
        return 1
      fi
      # shellcheck disable=SC2016 # single quotes are intentional: the program runs in node
      node -e '
        const fs = require("fs");
        const [file, entry] = [process.argv[1], process.argv[2]];
        let cfg = {};
        if (fs.existsSync(file)) {
          try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); }
          catch (e) { console.error(`kingpin: ${file} is not valid JSON; fix it and launch again`); process.exit(1); }
        }
        if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) {
          console.error(`kingpin: ${file} must contain a JSON object`); process.exit(1);
        }
        if (cfg.instructions !== undefined && !Array.isArray(cfg.instructions)) {
          console.error(`kingpin: "instructions" in ${file} must be a JSON array`); process.exit(1);
        }
        cfg.$schema = cfg.$schema || "https://opencode.ai/config.json";
        cfg.instructions = (cfg.instructions || []).filter((e) => e !== entry).concat(entry);
        const tmp = `${file}.tmp.${process.pid}`;
        fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2) + "\n");
        fs.renameSync(tmp, file);
      ' "$worktree/.opencode/opencode.json" "$task_dir/preamble.md" \
        || { echo "cannot update $worktree/.opencode/opencode.json" >&2; return 1; }
      cat > "$worktree/.opencode/plugins/package.json" << 'EOF_OC_PKG'
{ "private": true, "type": "module" }
EOF_OC_PKG
      cat > "$worktree/.opencode/plugins/kingpin-stop.js" << 'EOF_OC_PLUG'
import { execFileSync } from "node:child_process";
import path from "node:path";

// The one Stop hook: bin/kingpin-stop records the turn end and appends the missing
// outcome (issue #102). A failed hook warns here and never blocks the stop.
const recordStop = () => {
  const taskDir = process.env.KINGPIN_TASK_DIR;
  if (!taskDir) return;
  const root = process.env.KINGPIN_ROOT;
  if (!root) {
    console.error("kingpin: stop hook unavailable (KINGPIN_ROOT unset); the worker's outcome is not recorded");
    return;
  }
  try {
    execFileSync(path.join(root, "bin", "kingpin-stop"), [], { stdio: ["ignore", "ignore", "inherit"] });
  } catch (err) {
    console.error(`kingpin: stop hook failed: ${err && err.message ? err.message : err}`);
  }
};

const setupEventSubscription = (ctx, handler) => {
  if (!ctx || !ctx.event || !ctx.event.subscribe) return false;
  const controller = new AbortController();
  void (async () => {
    try {
      const stream = await ctx.event.subscribe({ signal: controller.signal, onActivity() {} });
      for await (const event of stream) await handler(event);
    } catch {}
  })();
  return true;
};

const makeHandler = () => {
  return async (event) => {
    const type = event && (event.type || event.name) || "";
    if (
      type === "session.execution.succeeded" ||
      type === "session.execution.interrupted" ||
      type === "session.execution.failed" ||
      type === "session.idle"
    ) {
      recordStop();
    }
  };
};

export const KingpinStop = async () => {
  const handleEvent = makeHandler();
  return {
    event: async ({ event }) => handleEvent(event),
  };
};

export default {
  id: "kingpin.stop",
  server: KingpinStop,
  setup(ctx) {
    setupEventSubscription(ctx, makeHandler());
  },
};
EOF_OC_PLUG
      injected+=('.opencode/opencode.json' '.opencode/plugins/package.json' '.opencode/plugins/kingpin-stop.js')
      cat > "$task_dir/launch.sh" <<EOF
#!/usr/bin/env bash
export KINGPIN_TASK_DIR='$task_dir'
export KINGPIN_ROOT='${KP_ROOT:?}'
exec ${KINGPIN_OPENCODE:-opencode} ${resume_words}--standalone --auto --prompt "\$(cat '$prompt')"
EOF
      ;;
    pi)
      # Pi writes nothing into the worktree: the preamble arrives through
      # --append-system-prompt and the extension loads from this checkout by absolute
      # path, so there is no injected path and no task exclude file. The extension
      # records the turn end and answers the project-trust prompt for this worktree.
      [ -f "${KP_ROOT:?}/worker/pi/kingpin-harness.ts" ] \
        || { echo "missing harness extension: $KP_ROOT/worker/pi/kingpin-harness.ts" >&2; return 1; }
      pi_args=(--append-system-prompt "$task_dir/preamble.md" -e "$KP_ROOT/worker/pi/kingpin-harness.ts")
      # Each flag is passed only when its own project key is set: a vendor `/login`
      # host keeps Pi's default model, and an inconsistent pair fails in the pane
      # rather than at launch (no auth preflight here; `kingpin scope doctor` is that job).
      [ -z "${KP_PI_PROVIDER:-}" ] || pi_args+=(--provider "$KP_PI_PROVIDER")
      [ -z "${KP_PI_MODEL:-}" ] || pi_args+=(--model "$KP_PI_MODEL")
      # %q on every argv word keeps a path with spaces intact; the prompt is read from
      # its file at launch, so a long request is never re-quoted into the command line.
      {
        printf '#!/usr/bin/env bash\n'
        printf 'export KINGPIN_TASK_DIR=%q\n' "$task_dir"
        printf 'export KINGPIN_WORKTREE=%q\n' "$worktree"
        printf 'export KINGPIN_ROOT=%q\n' "$KP_ROOT"
        printf 'exec %s' "${KINGPIN_PI:-pi}"
        printf ' %q' ${resume[@]+"${resume[@]}"} "${pi_args[@]}"
        # shellcheck disable=SC2016 # the program text belongs to the generated launch script
        printf ' "$(cat %q)"\n' "$prompt"
      } > "$task_dir/launch.sh" \
        || { echo "cannot write $task_dir/launch.sh" >&2; return 1; }
      ;;
    codex)
      # Codex 0.166 has no slash command for the fleet's skills: `$<name>` expands only
      # when the skill is discovered under $CODEX_HOME/skills or <worktree>/.codex/skills
      # (issue #106, Phase 0 check 5), so each fleet skill is linked in by name. A worker
      # with no skills cannot do the fleet's job, so a missing skills directory is a
      # refusal, not a warning.
      local skills_root codex_cmd skill_md skill_dir skill_name link trust_out
      local git_dir common_dir
      local -a codex_skill_names=()
      skills_root=${KINGPIN_SKILLS_DIR:-$HOME/.claude/skills}
      [ -d "$skills_root" ] || {
        echo "refusing to launch a codex worker: $skills_root is missing (set KINGPIN_SKILLS_DIR); a codex worker gets /issue-flow, /do and /review from skills, and Codex 0.166 has no such slash command" >&2
        return 1
      }
      codex_cmd=$(kp_harness_command codex) || return 1
      git_dir=$(kp_git_dir "$worktree") || { echo "cannot read the git directory of $worktree" >&2; return 1; }
      common_dir=$(kp_git_common_dir "$worktree") || { echo "cannot read the common git directory of $worktree" >&2; return 1; }
      # Codex stops at a folder-trust dialog unless its own config.toml trusts the
      # directory, and a `-c` override does not suppress it (check 7). The entry is seeded
      # here and removed again by `kingpin done` or by the spawn's failure trap. What the
      # seed wrote is recorded in `codex-trust`, so the removal never deletes a section or
      # a key the user already had (issue #106 review, M2): `section` means this spawn
      # created the whole section, `key` means it added only the trust_level line to the
      # user's own section, and `replaced` also restores the line it overwrote.
      trust_out=$(node "${KP_ROOT:?}/lib/codex-trust.mjs" --previous-out "$task_dir/codex-trust-prev" "$worktree") || {
        echo "refusing to launch: cannot record Codex folder trust for $worktree" >&2
        return 1
      }
      case $trust_out in
        trusted:*) printf 'section\n' > "$task_dir/codex-trust" ;;
        trusted-key:*)
          if [ -s "$task_dir/codex-trust-prev" ]; then
            printf 'replaced\n' > "$task_dir/codex-trust"
          else
            printf 'key\n' > "$task_dir/codex-trust"
            rm -f "$task_dir/codex-trust-prev"
          fi
          printf 'codex: %s already carried a Codex project section; this spawn adds only the trust_level line, and only that line is removed again\n' \
            "$worktree" >&2
          ;;
        already-trusted:*)
          printf 'codex: Codex already trusts %s; the entry predates this task and is left in place\n' "$worktree" >&2
          ;;
        *) echo "refusing to launch: cannot record Codex folder trust for $worktree" >&2; return 1 ;;
      esac
      mkdir -p "$worktree/.codex/skills" \
        || { echo "cannot create $worktree/.codex/skills" >&2; return 1; }
      # One link per skill, so a project's own skill at the same name is left alone (and
      # named) instead of replaced, and a tracked path is refused instead of shadowed.
      # The names are checked in one pass and linked in a second: a refusal at any name
      # must not leave the links an earlier name already created in the pooled slot. A
      # second-pass failure (a failed `ln -s`) is covered too, because each link is
      # recorded in `<task-dir>/injected` before it is made, and the spawn's failure trap
      # removes exactly what that file names (issue #106 review, M4).
      for skill_md in "$skills_root"/*/SKILL.md; do
        [ -f "$skill_md" ] || continue
        skill_dir=$(dirname "$skill_md")
        skill_name=$(basename "$skill_dir")
        link=$worktree/.codex/skills/$skill_name
        if git -C "$worktree" ls-files --error-unmatch -- ".codex/skills/$skill_name" >/dev/null 2>&1; then
          echo "refusing to launch: $worktree/.codex/skills/$skill_name is tracked by the project; Kingpin must link its own skill there, so untrack that path (add it to .gitignore) and respawn" >&2
          return 1
        fi
        if [ -L "$link" ]; then
          # An earlier task's link into the skills checkout is Kingpin's to replace; a link
          # pointing anywhere else is not.
          case $(readlink "$link") in
            "$skills_root"/*) codex_skill_names+=("$skill_name") ;;
            *)
              printf 'codex: leaving %s in %s: it links somewhere other than %s, so it is not Kingpin'"'"'s to replace\n' \
                ".codex/skills/$skill_name" "$worktree" "$skills_root" >&2
              continue
              ;;
          esac
        elif [ -e "$link" ]; then
          printf 'codex: leaving %s in %s: the project already carries a skill there, so Kingpin does not replace it\n' \
            ".codex/skills/$skill_name" "$worktree" >&2
          continue
        else
          codex_skill_names+=("$skill_name")
        fi
      done
      for skill_name in "${codex_skill_names[@]+"${codex_skill_names[@]}"}"; do
        link=$worktree/.codex/skills/$skill_name
        # An earlier task's link into the skills checkout is Kingpin's to replace.
        [ ! -L "$link" ] || rm -f "$link"
        # Record the path before the link exists: cleanup removes only a path that is
        # there, so a recorded-but-uncreated one is harmless, while a created-but-
        # unrecorded one would outlive the task folder.
        injected+=(".codex/skills/$skill_name")
        printf '%s\n' "${injected[@]}" > "$task_dir/injected" \
          || { echo "cannot write $task_dir/injected" >&2; return 1; }
        ln -s "$skills_root/$skill_name" "$link" \
          || { echo "cannot link the $skill_name skill into $worktree/.codex/skills" >&2; return 1; }
      done
      # The turn end. Codex runs this on every completed turn, including its background
      # title-generation one; bin/kingpin-stop is idempotent per state, so that second
      # event rewrites `stopped` and appends no duplicate line. Codex appends its JSON
      # payload as argv, which is dropped: the wrapper exports what the hook needs instead
      # of trusting the environment Codex hands a notify program.
      {
        printf '#!/usr/bin/env bash\n'
        printf 'export KINGPIN_TASK_DIR=%q\n' "$task_dir"
        printf 'export KINGPIN_ROOT=%q\n' "${KP_ROOT:?}"
        printf 'exec %q\n' "${KP_ROOT}/bin/kingpin-stop"
      } > "$task_dir/notify.sh" \
        || { echo "cannot write $task_dir/notify.sh" >&2; return 1; }
      chmod +x "$task_dir/notify.sh" \
        || { echo "cannot make $task_dir/notify.sh executable" >&2; return 1; }
      {
        printf '#!/usr/bin/env bash\n'
        printf 'export KINGPIN_TASK_DIR=%q\n' "$task_dir"
        printf 'export KINGPIN_WORKTREE=%q\n' "$worktree"
        printf 'export KINGPIN_ROOT=%q\n' "${KP_ROOT:?}"
        # The sandbox denies /tmp, and every suite in this repository keeps its scratch
        # root in `mktemp -d`, which resolves through $TMPDIR (tests/lib.sh). The task
        # folder is already a writable root, so the worker's scratch space lives in it.
        printf 'export TMPDIR=%q\n' "$task_dir/tmp"
        printf 'mkdir -p -- %q\n' "$task_dir/tmp"
        printf 'exec %s' "$codex_cmd"
        # -C: the worktree is the working root. -a never: no per-command approval prompt.
        # -s workspace-write: the Linux sandbox is the containment mechanism (issue #106,
        # Decision 3); the task folder is one extra writable root, because status, stopped
        # and question.md live there. Every -c value is TOML.
        printf ' %q' -C "$worktree" -a never -s workspace-write
        # Codex asks a second, separate question when the host has a hook set that is new
        # or changed ("Hooks need review"), and `-a never` does not answer it (check 7).
        # The measured answer is this bypass, and it is passed only when there is a hook
        # set to review, so a host with none keeps Codex's protection (review, M3).
        if codex_hook_set; then printf ' %q' --dangerously-bypass-hook-trust; fi
        # The preamble arrives through model_instructions_file, so the tracked AGENTS.md is
        # never rewritten. Network stays on: the fleet's job is `gh` and `git push`
        # (Decision 5), while the filesystem stays confined. /tmp is denied and $TMPDIR is
        # left out of the sandbox's view because it already sits inside a writable root
        # (Decision 6).
        printf ' %q' -c "model_instructions_file=$(toml_quote "$task_dir/preamble.md")"
        printf ' %q' -c sandbox_workspace_write.exclude_slash_tmp=true
        printf ' %q' -c sandbox_workspace_write.exclude_tmpdir_env_var=true
        # A linked worktree keeps its index and refs in the git dirs, outside the worktree
        # root, and the sandbox mounts those read-only over a writable root that contains
        # them: without both roots a worker can edit files but never stage or commit
        # (issue #106 review, H1). The common dir is shared, so one worker can reach
        # another task's git state; docs/worker-permissions.md states that price.
        printf ' %q' -c "sandbox_workspace_write.writable_roots=[$(toml_quote "$task_dir"),$(toml_quote "$git_dir"),$(toml_quote "$common_dir")]"
        printf ' %q' -c sandbox_workspace_write.network_access=true
        printf ' %q' -c "notify=[$(toml_quote "$task_dir/notify.sh")]"
        # shellcheck disable=SC2016 # the program text belongs to the generated launch script
        printf ' "$(cat %q)"\n' "$prompt"
      } > "$task_dir/launch.sh" \
        || { echo "cannot write $task_dir/launch.sh" >&2; return 1; }
      ;;
    *)
      echo "unsupported harness: $harness (must be claude, agy, opencode, pi, or codex)" >&2
      return 1
      ;;
  esac

  if [ "${#injected[@]}" -gt 0 ]; then
    printf '%s\n' "${injected[@]}" > "$task_dir/injected" \
      || { echo "cannot write $task_dir/injected" >&2; return 1; }
  else
    # A harness that injects nothing (pi) records no file at all: the cleanup reads
    # its absence as "nothing to remove", and a suite asserts it is not there.
    rm -f "$task_dir/injected" || true
  fi
  chmod +x "$task_dir/launch.sh" \
    || { echo "cannot make $task_dir/launch.sh executable" >&2; return 1; }
  return 0
}
