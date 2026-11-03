// Mark one directory as trusted in Claude Code's config, so a worker launched
// there starts on its task instead of stopping at the folder-trust dialog.
// Usage: node claude-trust.mjs <directory>
// Writes a temp file and renames it over the config, and refuses when the
// config changed in between, so a concurrent Claude Code write is not lost.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import os from "node:os";

const target = fs.realpathSync(process.argv[2] ?? "");
const store = path.join(process.env.CLAUDE_CONFIG_DIR ?? os.homedir(), ".claude.json");
const hash = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

// A host where claude has never run has no store yet. Create the empty one here
// instead of dying on the read below, so the first launch on a fresh install
// records trust and starts on its task.
if (!fs.existsSync(store)) {
  fs.mkdirSync(path.dirname(store), { recursive: true });
  try {
    fs.writeFileSync(store, '{"projects":{}}\n', { mode: 0o600, flag: "wx" });
  } catch (err) {
    // Another writer created it between the check and the write; use theirs.
    if (err.code !== "EEXIST") throw err;
  }
}

for (let attempt = 0; attempt < 3; attempt += 1) {
  const raw = fs.readFileSync(store);
  const before = hash(raw);
  const root = JSON.parse(raw.toString("utf8"));
  root.projects ??= {};
  root.projects[target] ??= {};
  if (root.projects[target].hasTrustDialogAccepted === true) {
    console.log(`already trusted: ${target}`);
    process.exit(0);
  }
  root.projects[target].hasTrustDialogAccepted = true;
  const tmp = path.join(path.dirname(store), `.claude.json.kingpin.${process.pid}.${crypto.randomBytes(6).toString("hex")}`);
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  if (hash(fs.readFileSync(store)) !== before) {
    fs.rmSync(tmp, { force: true });
    continue;
  }
  fs.renameSync(tmp, store);
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  if (back.projects?.[target]?.hasTrustDialogAccepted === true) {
    console.log(`trusted: ${target}`);
    process.exit(0);
  }
}
console.error(`claude-trust: ${store} kept changing; trust for ${target} was not recorded`);
process.exit(1);
