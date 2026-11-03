// PreToolUse hook behind `kingpin-guard hook <orchestrator|worker>`.
// Reads the hook input (JSON) on stdin and answers through its exit status:
//   exit 0, no output   no opinion; the normal permission flow decides
//   exit 0, JSON output allow the tool call (a worker editing inside its sandbox)
//   exit 2, stderr text deny the tool call; Claude Code shows the text to the model
//
// orchestrator  The orchestrator session must not edit code. Denies Edit, Write,
//               NotebookEdit and Agent when the session runs in the main checkout, and when
//               that working directory cannot be resolved to a git worktree (fail closed).
//               Claude Code also loads the main checkout's
//               .claude/settings.local.json for its linked worktrees, so a plain deny
//               rule there would strip the same tools from every worker; this hook
//               sees the working directory and lets a worktree session through.
// worker        Edit, Write and NotebookEdit are allowed inside the worker's own
//               worktree and task folder ($KINGPIN_TASK_DIR) and denied anywhere else.
//               The worktree is pinned by $KINGPIN_WORKTREE, or by WORKTREE= in the
//               task's task.env for a worker spawned before that variable existed. It
//               is never taken from the session's working directory: a worker that
//               cd's to the main checkout must not gain write access to it, and a
//               worker that cd's to its task folder must keep its worktree.
// Both modes fail closed on a payload that cannot be read. Worker mode also denies a
// guarded tool call with no target path, and a worker whose worktree cannot be resolved.
// Orchestrator mode decides on the session's checkout, not the target, so a guarded call
// with no path (Agent never carries one) is allowed from a linked worktree, where Claude
// Code loads this hook for the worker too.
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

// The git dir and common dir of the repository at cwd, in one call, both as absolute
// canonical paths. Both empty when git cannot answer, which the callers treat as an
// unknown (and deny). git prints these relative to cwd (its absolute path for a linked
// worktree's git dir, and a symlinked cwd can mix the two forms), so they are resolved
// against cwd and symlink-canonicalized before any comparison: a main checkout must
// compare equal from its root and from any subdirectory of it, and for a linked worktree
// the first is `<main>/.git/worktrees/<name>` and the second `<main>/.git`. Deliberately
// no `--path-format=absolute`, which does this resolving but is rejected by git 2.30
// (issue #86).
function gitDirs(cwd) {
  const [rawGitDir = "", rawCommonDir = ""] = git(cwd, "rev-parse", "--git-dir", "--git-common-dir").split("\n");
  const absolute = (p) => (p ? realish(path.resolve(cwd, p)) : "");
  return { gitDir: absolute(rawGitDir), commonDir: absolute(rawCommonDir) };
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

// The value of the last KEY= line in an env file, the same "last assignment wins" as
// lib/status.sh kp_env_get. The file is never executed.
function envFileValue(file, key) {
  let text = "";
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
  let value = "";
  for (const line of text.split("\n")) {
    if (line.startsWith(`${key}=`)) value = line.slice(key.length + 1);
  }
  return value;
}

// The worker's allowed roots: its own leased worktree and its task folder. The
// worktree comes from the environment the launch script set, or from the task's
// task.env (which the worker itself can write, so it is only trusted after the
// linked-worktree check below). Returns null when no sandbox can be established.
function workerRoots() {
  const taskDir = process.env.KINGPIN_TASK_DIR || "";
  const worktree = process.env.KINGPIN_WORKTREE
    || (taskDir ? envFileValue(path.join(taskDir, "task.env"), "WORKTREE") : "");
  if (!worktree) return null;
  const root = realish(worktree);
  const { gitDir, commonDir } = gitDirs(root);
  // A main checkout has one directory for both; a worker always has a linked worktree.
  if (!gitDir || !commonDir || gitDir === commonDir) return null;
  return [root, taskDir ? realish(taskDir) : ""].filter(Boolean);
}

const mode = process.argv[2];
if (mode !== "orchestrator" && mode !== "worker") {
  process.stderr.write("usage: guard-hook.mjs <orchestrator|worker>\n");
  process.exit(1);
}

let input;
try {
  input = JSON.parse(fs.readFileSync(0, "utf8"));
} catch {
  deny("kingpin guard: the hook payload could not be read, so the edit is denied (fail closed).");
}
if (input === null || typeof input !== "object" || Array.isArray(input)) {
  deny("kingpin guard: the hook payload is not a JSON object, so the edit is denied (fail closed).");
}
const tool = typeof input.tool_name === "string" ? input.tool_name : "";
const cwd = typeof input.cwd === "string" && input.cwd !== "" ? input.cwd : process.cwd();

if (mode === "orchestrator") {
  if (!ORCHESTRATOR_DENIED.has(tool)) process.exit(0);
  const { gitDir, commonDir } = gitDirs(cwd);
  if (!gitDir || !commonDir) {
    deny(`${tool} denied: cannot tell whether ${cwd} is the Kingpin main checkout, so the edit is denied (fail closed). Run it from the Kingpin checkout, or spawn a worker (bin/kingpin spawn) for code changes.`);
  }
  if (gitDir !== commonDir) process.exit(0); // a worker worktree
  deny(`${tool} is denied in the Kingpin orchestrator session. Spawn a worker (bin/kingpin spawn) for code changes.`);
} else {
  if (!WORKER_GUARDED.has(tool)) process.exit(0);
  const target = input.tool_input?.file_path ?? input.tool_input?.notebook_path;
  if (typeof target !== "string" || target === "") {
    deny(`${tool} denied: the hook payload names no file path, so the worker's sandbox cannot be checked (fail closed).`);
  }
  const roots = workerRoots();
  if (!roots) {
    deny(`${tool} denied: cannot tell which worktree this worker owns (KINGPIN_WORKTREE, or WORKTREE= in $KINGPIN_TASK_DIR/task.env, must name its leased worktree), so the edit is denied (fail closed).`);
  }
  const resolved = realish(path.resolve(cwd, target));
  if (roots.some((r) => inside(r, resolved))) allow(`${tool} inside the worker's worktree or task folder`);
  deny(`${tool} denied: ${target} is outside this worker's worktree (${roots.join(" and ")}). Workers edit only their own worktree and task folder.`);
}
