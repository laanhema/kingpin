// Decide whether a file found at one of Kingpin's harness paths was written by Kingpin
// itself, so that `kingpin-spawn` may delete an earlier task's leftover from a reused pool
// slot (issue #127). Only a shape Kingpin itself writes proves ownership: a worktree is a
// checkout of the user's repository, the delete is not reversible, and a file whose content
// does not match is someone else's, so the spawn leaves it and names it.
//
// Usage: node leftover.mjs <worktree> <relative-path> <kingpin-home>
//   exit 0  the content is a shape Kingpin writes at that path
//   exit 1  it is not, or cannot be read: the caller must not delete it
// Prints nothing.
import fs from "node:fs";
import path from "node:path";

const [worktree, rel, kingpinHome] = process.argv.slice(2);

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

// The agy Stop hook: `bin/kingpin-spawn` writes an object whose only top-level key is
// `kingpin`. A hooks file with any other key is the project's or the user's.
function isKingpinHooks(file) {
  const config = readJson(file);
  return isObject(config) && Object.keys(config).length === 1 && config.kingpin !== undefined;
}

// The agy rules file: `bin/kingpin-spawn` writes agy's trigger frontmatter and then the
// worker preamble, whose first heading is "# Kingpin worker". agy skips a rules file
// without the frontmatter without a word, so the header and that heading together are
// the shape Kingpin generates.
const AGY_RULES_HEADER =
  "---\ntrigger: always_on\ndescription: Kingpin worker preamble\n---\n\n# Kingpin worker\n";

function isAgyRules(file) {
  return fs.readFileSync(file, "utf8").startsWith(AGY_RULES_HEADER);
}

// The OpenCode plugin pair (issue #127): a package file that is exactly the one-line
// object `bin/kingpin-spawn` writes, and the Stop plugin, matched on the lines that make
// it Kingpin's rather than on every byte so a version that changes the event handling
// still proves an older task's copy. Both live under `.opencode/plugins/`, a path a
// project can use itself, so neither predicate may accept a plugin Kingpin did not write.
function isOpencodePluginPackage(file) {
  return fs.readFileSync(file, "utf8").trim() === '{ "private": true, "type": "module" }';
}

const OC_STOP_PLUGIN_MARKERS = [
  'import { execFileSync } from "node:child_process";',
  'path.join(root, "bin", "kingpin-stop")',
  "export const KingpinStop = async () => {",
  'id: "kingpin.stop",',
];

function isOpencodeStopPlugin(file) {
  const text = fs.readFileSync(file, "utf8");
  return OC_STOP_PLUGIN_MARKERS.every((marker) => text.includes(marker));
}

// The OpenCode wiring before #96 wrote `{ "permission": ..., "instructions": [<task>/
// preamble.md] }`. OpenCode V2 ignores the path, so an older task's leftovers can still
// sit there. Every instruction must point into Kingpin's own home: a config pointing
// anywhere else is not the file Kingpin wrote.
function isOldOpencodeConfig(file, home) {
  const config = readJson(file);
  if (!isObject(config)) return false;
  if (Object.keys(config).some((key) => key !== "permission" && key !== "instructions")) return false;
  if (!Array.isArray(config.instructions) || config.instructions.length === 0) return false;
  const root = home.endsWith(path.sep) ? home : home + path.sep;
  return config.instructions.every((entry) => typeof entry === "string" && entry.startsWith(root));
}

function provesKingpin(file) {
  switch (rel) {
    case ".agents/hooks.json":
      return isKingpinHooks(file);
    case ".agents/rules/kingpin.md":
      return isAgyRules(file);
    case ".opencode/config.json":
      return isOldOpencodeConfig(file, kingpinHome);
    case ".opencode/plugins/package.json":
      return isOpencodePluginPackage(file);
    case ".opencode/plugins/kingpin-stop.js":
      return isOpencodeStopPlugin(file);
    default:
      // `.opencode/opencode.json` is the project's own config as much as Kingpin's: the
      // spawn merges into it, so a leftover copy cannot be told from a file a person
      // wrote, and `false` leaves it in place.
      return false;
  }
}

if (!worktree || !rel || !kingpinHome) process.exit(1);
let proven = false;
try {
  proven = fs.lstatSync(path.join(worktree, rel)).isFile() && provesKingpin(path.join(worktree, rel));
} catch {
  proven = false;
}
process.exit(proven ? 0 : 1);
