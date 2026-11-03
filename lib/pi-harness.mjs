// Behaviour behind worker/pi/kingpin-harness.ts, the Pi extension a spawned worker
// loads with `-e` (bin/kingpin-spawn's pi arm). The entry file is three lines of
// TypeScript so Pi's jiti loader has something to load; everything testable lives
// here, as plain ESM with node: builtins only, so `node --check` and the unit suite
// (tests/test-pi-harness.sh) can exercise it with a fake Pi API and no binary.
//
// registerPiHarness(api, env) subscribes three handlers:
//
//   agent_settled      exec <KINGPIN_ROOT>/bin/kingpin-stop, the one Stop hook all
//                      four harnesses share (issue #102), when KINGPIN_TASK_DIR is
//                      set. `agent_settled` is Pi's final idle signal (docs,
//                      extensions.md: agent_end can still retry or compact). A
//                      missing root or a failing script writes one stderr line and
//                      never throws: a stop hook that traps the session is worse
//                      than a lost outcome line.
//   resources_discover return KINGPIN_SKILLS_DIR (default ~/.claude/skills) so the
//                      fleet's /skill:<name> commands resolve; kingpin-curate reads
//                      the same variable for the same directory.
//   project_trust      answer yes for the leased worktree only, comparing realpaths,
//                      and never `remember`: a Kingpin worktree may carry the
//                      project's own .pi/ or .agents/skills, and trusting it for one
//                      process is enough to start unattended. Outside the worktree
//                      the answer is "undecided", so a project's own prompt flow is
//                      left alone.
//
// Loading the module by hand subscribes the handlers and touches nothing: the event
// log and the stop call are both behind KINGPIN_TASK_DIR.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

function realOrNull(p) {
  try {
    return fs.realpathSync(p);
  } catch {
    return null;
  }
}

// True when <cwd> is <root> or sits under it, on resolved paths. Two unresolvable
// paths are never equal: a trust answer needs both sides to exist.
function within(cwd, root) {
  if (!cwd || !root) return false;
  const resolvedCwd = realOrNull(cwd);
  const resolvedRoot = realOrNull(root);
  if (!resolvedCwd || !resolvedRoot) return false;
  return resolvedCwd === resolvedRoot || resolvedCwd.startsWith(resolvedRoot + path.sep);
}

export function registerPiHarness(api, env = process.env) {
  const taskDir = env.KINGPIN_TASK_DIR || "";
  const root = env.KINGPIN_ROOT || "";
  const worktree = env.KINGPIN_WORKTREE || "";
  const skillsDir = env.KINGPIN_SKILLS_DIR || path.join(os.homedir(), ".claude", "skills");

  // Debugging breadcrumb only, never fleet state: the same log the Phase 0 spike used.
  const logEvent = (line) => {
    if (!taskDir) return;
    try {
      fs.mkdirSync(taskDir, { recursive: true });
      fs.appendFileSync(path.join(taskDir, "harness-events.log"), `${new Date().toISOString()} ${line}\n`);
    } catch {
      // A breadcrumb that cannot be written must not disturb the session.
    }
  };

  const recordStop = () => {
    if (!taskDir) return;
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

  api.on("agent_settled", async () => {
    logEvent("agent_settled");
    recordStop();
  });

  api.on("resources_discover", async () => {
    logEvent(`resources_discover ${skillsDir}`);
    return { skillPaths: [skillsDir] };
  });

  api.on("project_trust", async (event) => {
    const cwd = (event && event.cwd) || "";
    logEvent(`project_trust ${cwd}`);
    if (within(cwd, worktree)) return { trusted: "yes" };
    return { trusted: "undecided" };
  });
}

export default registerPiHarness;
