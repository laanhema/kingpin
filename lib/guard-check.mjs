// `kingpin-guard check` gets one node start for both files it reads: the guard settings
// file and the OpenCode config. The printed line is `<guard> <contract>` where guard is
// the exit-encoding the check case previously got from its own node call (0 active,
// 1 incomplete, 2 stale deny rules) and contract is the verdict its contract check
// previously got from a second node call (`missing` covers both a config file absent and
// a config that does not load the contract entry, `badjson` is a config Kingpin cannot
// parse, `none` is no contract to check). The shell maps the tokens to the same messages
// and exit codes the two calls produced.
import { readFileSync, existsSync } from "fs";

const [file, legacyJson, hookCmd, matcher, contractSrc, opencodeCfg, homeContract] =
  process.argv.slice(2);

let guard = 1;
try {
  const cfg = JSON.parse(readFileSync(file, "utf8"));
  const legacy = JSON.parse(legacyJson);
  const deny = cfg && cfg.permissions && cfg.permissions.deny;
  // Legacy deny rules leak into every worker worktree, so they fail the check.
  if (Array.isArray(deny) && legacy.some((t) => deny.includes(t))) {
    guard = 2;
  } else {
    const entries = (cfg && cfg.hooks && cfg.hooks.PreToolUse) || [];
    const ok = Array.isArray(entries) && entries.some((e) => e && e.matcher === matcher &&
      Array.isArray(e.hooks) && e.hooks.some((h) => h && h.type === "command" && h.command === hookCmd));
    guard = ok ? 0 : 1;
  }
} catch {
  guard = 1;
}

let contract = "none";
if (existsSync(contractSrc)) {
  if (!existsSync(opencodeCfg)) {
    contract = "missing";
  } else {
    let oc;
    try {
      oc = JSON.parse(readFileSync(opencodeCfg, "utf8"));
    } catch {
      contract = "badjson";
    }
    if (contract === "none") {
      contract = oc && Array.isArray(oc.instructions) && oc.instructions.includes(homeContract)
        ? "ok" : "missing";
    }
  }
}

console.log(`${guard} ${contract}`);
