// Mark one directory as trusted in Antigravity CLI's config, so a worker launched
// there starts on its task instead of stopping at the folder-trust dialog.
// Usage: node agy-trust.mjs <directory>
// Writes a temp file and renames it over the config, and retries when the
// config changed in between, so a concurrent CLI write is not lost.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import os from "node:os";

const target = fs.realpathSync(process.argv[2] ?? "");
const logicalTarget = process.argv[2] ? path.resolve(process.argv[2]) : target;
const storeDir = process.env.GEMINI_CONFIG_DIR ?? path.join(os.homedir(), ".gemini", "antigravity-cli");
fs.mkdirSync(storeDir, { recursive: true });
const store = path.join(storeDir, "settings.json");
const hash = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

for (let attempt = 0; attempt < 3; attempt += 1) {
  let raw = Buffer.from("{}");
  if (fs.existsSync(store)) {
    raw = fs.readFileSync(store);
  }
  const before = hash(raw);
  let root = {};
  try {
    const text = raw.toString("utf8").trim();
    if (text) root = JSON.parse(text);
  } catch (err) {
    console.error(`agy-trust: malformed settings in ${store}: ${err.message}`);
    process.exit(1);
  }
  root.trustedWorkspaces ??= [];
  if (!Array.isArray(root.trustedWorkspaces)) root.trustedWorkspaces = [];

  const needed = [...new Set([target, logicalTarget])].filter((p) => !root.trustedWorkspaces.includes(p));
  if (needed.length === 0) {
    console.log(`already trusted: ${target}`);
    process.exit(0);
  }

  root.trustedWorkspaces.push(...needed);
  const tmp = path.join(storeDir, `.settings.json.kingpin.${process.pid}.${crypto.randomBytes(6).toString("hex")}`);
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });

  let currentHash = "absent";
  if (fs.existsSync(store)) {
    currentHash = hash(fs.readFileSync(store));
  }
  if (currentHash !== before) {
    fs.rmSync(tmp, { force: true });
    continue;
  }
  fs.renameSync(tmp, store);
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  if (Array.isArray(back.trustedWorkspaces) && back.trustedWorkspaces.includes(target)) {
    console.log(`trusted: ${target}`);
    process.exit(0);
  }
}
console.error(`agy-trust: ${store} kept changing; trust for ${target} was not recorded`);
process.exit(1);
