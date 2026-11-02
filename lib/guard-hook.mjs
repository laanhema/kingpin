// PreToolUse hook behind `kingpin-guard hook <orchestrator|worker>`.
// Reads the hook input (JSON) on stdin and answers through its exit status:
//   exit 0, no output   no opinion; the normal permission flow decides
//   exit 0, JSON output allow the tool call (a worker editing inside its sandbox)
//   exit 2, stderr text deny the tool call; Claude Code shows the text to the model
//
// orchestrator  The orchestrator session must not edit code. Denies Edit, Write,
//               NotebookEdit and Agent, but only when the session runs in the main
//               checkout. Claude Code also loads the main checkout's
//               .claude/settings.local.json for its linked worktrees, so a plain deny
//               rule there would strip the same tools from every worker; this hook
//               sees the working directory and lets a worktree session through.
// worker        Edit, Write and NotebookEdit are allowed inside the worker's own
//               worktree and task folder ($KINGPIN_TASK_DIR) and denied anywhere else.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const ORCHESTRATOR_DENIED = new Set(["Edit", "Write", "NotebookEdit", "Agent"]);
const WORKER_GUARDED = new Set(["Edit", "Write", "NotebookEdit"]);

function git(cwd, ...args) {
  try {
    return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return "";
  }
}

// Resolve symlinks of the nearest existing ancestor, so a link out of the
// worktree cannot smuggle a write past the prefix check.
function realish(p) {
  const tail = [];
  let cur = path.resolve(p);
  for (;;) {
    try {
      return path.join(fs.realpathSync(cur), ...tail.reverse());
    } catch {
      const up = path.dirname(cur);
      if (up === cur) return path.resolve(p);
      tail.push(path.basename(cur));
      cur = up;
    }
  }
}

const inside = (root, p) => p === root || p.startsWith(root.endsWith(path.sep) ? root : root + path.sep);

function deny(msg) {
  process.stderr.write(`${msg}\n`);
  process.exit(2);
}

function allow(reason) {
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: reason },
  })}\n`);
  process.exit(0);
}

const mode = process.argv[2];
let input = {};
try {
  input = JSON.parse(fs.readFileSync(0, "utf8"));
} catch {
  process.exit(0);
}
const tool = input.tool_name ?? "";
const cwd = input.cwd || process.cwd();

if (mode === "orchestrator") {
  if (!ORCHESTRATOR_DENIED.has(tool)) process.exit(0);
  const gitDir = git(cwd, "rev-parse", "--path-format=absolute", "--git-dir");
  const commonDir = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir");
  if (!gitDir || gitDir !== commonDir) process.exit(0); // a worker worktree, or not a repository
  deny(`${tool} is denied in the Kingpin orchestrator session. Spawn a worker (bin/kingpin spawn) for code changes.`);
} else if (mode === "worker") {
  if (!WORKER_GUARDED.has(tool)) process.exit(0);
  const target = input.tool_input?.file_path ?? input.tool_input?.notebook_path;
  if (typeof target !== "string" || target === "") process.exit(0);
  const top = git(cwd, "rev-parse", "--show-toplevel");
  const roots = [top, process.env.KINGPIN_TASK_DIR].filter(Boolean).map(realish);
  if (roots.length === 0) deny(`${tool} denied: cannot tell which worktree this worker owns.`);
  const resolved = realish(path.resolve(cwd, target));
  if (roots.some((r) => inside(r, resolved))) allow(`${tool} inside the worker's worktree or task folder`);
  deny(`${tool} denied: ${target} is outside this worker's worktree (${roots.join(" and ")}). Workers edit only their own worktree and task folder.`);
} else {
  process.stderr.write("usage: guard-hook.mjs <orchestrator|worker>\n");
  process.exit(1);
}
