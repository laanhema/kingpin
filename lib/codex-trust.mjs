// Record (or drop) the trusted-project entry Codex CLI needs before it will start a
// session in a directory without stopping at its folder-trust dialog.
//
// Usage: node codex-trust.mjs [--remove | --remove-key | --restore-key <file>]
//                             [--previous-out <file>] <worktree>
//   add (default)  ensure `[projects."<realpath>"]` carries `trust_level = "trusted"`;
//                  every other line stays byte-identical. Prints `trusted: <path>` when
//                  it wrote the whole section, `trusted-key: <path>` when the section
//                  already existed and only the key line was added, or
//                  `already-trusted: <path>` when the entry was already there.
//   --remove       drop the whole section, for one the add step created. Prints
//                  `untrusted: <path>`, or `no-entry: <path>` when the header was gone.
//   --remove-key   drop only the `trust_level` line from a section that stays, for a key
//                  the add step wrote into the user's own section. Prints
//                  `untrusted-key: <path>`, or `no-entry: <path>` when the key was gone.
//   --restore-key  put back the line `--previous-out` recorded, for a `trust_level` value
//                  the add step overwrote. Prints `restored-key: <path>`, or `no-entry:`.
//   --previous-out write the line the add step overwrote to <file>, so the caller can
//                  restore it later; the file is left absent when nothing was overwritten.
//
// The store is `${CODEX_HOME:-$HOME/.codex}/config.toml`, the user's own file, and a
// spawn that seeded an entry removes it again at `kingpin done`, removing only what it
// wrote: a section or key the user already had is never deleted or narrowed.
//
// Why a config edit instead of a launch flag: a `-c` override does not suppress the
// folder-trust dialog (issue #106, Phase 0 check 7), so the entry has to be in the file
// Codex reads at startup. The write is a temp file in the same directory, renamed into
// place, retried when the sha256 of the file changed in between, so a Codex process
// writing its own config at the same moment is not lost.
//
// Exit 0 on success, 1 with one `codex-trust:` line on stderr on failure. Nothing else
// prints on stderr.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import os from "node:os";

const fail = (message) => {
  console.error(`codex-trust: ${message}`);
  process.exit(1);
};

const args = process.argv.slice(2);
let command = "add";
let previousOut = "";
let restoreFile = "";
let target = "";
for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (arg === "--remove" || arg === "--remove-key") {
    command = arg === "--remove" ? "section" : "key";
  } else if (arg === "--restore-key") {
    command = "restore";
    restoreFile = args[i + 1] || "";
    i += 1;
    if (!restoreFile) fail(`--restore-key needs the file --previous-out wrote`);
  } else if (arg === "--previous-out") {
    previousOut = args[i + 1] || "";
    i += 1;
    if (!previousOut) fail(`--previous-out needs a file`);
  } else if (!target) {
    target = arg;
  } else {
    fail(`unexpected argument: ${arg}`);
  }
}
if (!target) fail(`usage: node codex-trust.mjs [--remove | --remove-key | --restore-key <file>] [--previous-out <file>] <worktree>`);

let resolved;
try {
  resolved = fs.realpathSync(target);
} catch (err) {
  fail(`cannot resolve ${target}: ${err.message}`);
}

// The line a restored entry puts back, taken verbatim from the file --previous-out named.
let restoreLine = "";
if (command === "restore") {
  try {
    restoreLine = fs.readFileSync(restoreFile, "utf8").replace(/\n+$/, "");
  } catch (err) {
    fail(`cannot read ${restoreFile}: ${err.message}`);
  }
  if (!restoreLine) fail(`${restoreFile} is empty; there is no line to restore`);
}

const storeDir = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const store = path.join(storeDir, "config.toml");
const hash = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

// A TOML basic key: double quotes, with the two characters that need escaping.
const tomlKey = (value) => `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
const header = `[projects.${tomlKey(resolved)}]`;
const trustLine = 'trust_level = "trusted"';
const isHeading = (line) => line.trim().startsWith("[");

// The section's line range: its header index and the index of the next heading (or the
// end of the file). -1 when the file carries no such section.
function findSection(lines) {
  const start = lines.findIndex((line) => line.trim() === header);
  if (start < 0) return { start: -1, end: -1 };
  let end = start + 1;
  while (end < lines.length && !isHeading(lines[end])) end += 1;
  return { start, end };
}

// Every byte outside the section a caller edits, so a wrong edit is visible instead of
// silently dropping the user's other keys.
function withSection(text) {
  const lines = text === "" ? [] : text.split("\n");
  const { start, end } = findSection(lines);
  return { lines, start, end };
}

// The edited text for the add mode and what it wrote: `wrote` is "section" (the whole
// section is new) or "key" (only the trust_level line is new, in a section the user
// already had), plus the line it overwrote when the user's own trust_level carried
// another value. `next` is null when the file already says trusted.
function addEntry(text) {
  const { lines, start, end } = withSection(text);
  if (start < 0) {
    const body = text === "" ? "" : text.endsWith("\n") ? text : `${text}\n`;
    return { next: `${body}${body ? "\n" : ""}${header}\n${trustLine}\n`, wrote: "section", replaced: null };
  }
  const section = lines.slice(start + 1, end);
  if (section.some((line) => line.trim() === trustLine)) return { next: null, wrote: null, replaced: null };
  const at = section.findIndex((line) => /^[ \t]*trust_level[ \t]*=/.test(line));
  if (at >= 0) {
    const replaced = lines[start + 1 + at];
    lines[start + 1 + at] = trustLine;
    return { next: lines.join("\n"), wrote: "key", replaced };
  }
  lines.splice(start + 1, 0, trustLine);
  return { next: lines.join("\n"), wrote: "key", replaced: null };
}

// The edited text for the remove modes, or null when the file carries nothing to drop.
// `section` takes the whole section; `key` and `restore` touch only the trust_level line
// and leave every other key in it exactly as the user had it.
function removeEntry(text, which) {
  const { lines, start, end } = withSection(text);
  if (start < 0) return null;
  if (which === "section") {
    // A blank separator line this file's own writer put above the section goes with it, so
    // adding and removing an entry leaves the file as it was.
    const from = start > 0 && lines[start - 1].trim() === "" ? start - 1 : start;
    lines.splice(from, end - from);
  } else {
    const section = lines.slice(start + 1, end);
    const at = section.findIndex((line) => /^[ \t]*trust_level[ \t]*=/.test(line));
    if (at < 0) return null;
    if (which === "restore") {
      lines[start + 1 + at] = restoreLine;
    } else {
      lines.splice(start + 1 + at, 1);
    }
  }
  let joined = lines.join("\n");
  // The file's own trailing newline survives the removed block, so an add followed by a
  // remove leaves the file byte-identical.
  if (text.endsWith("\n") && joined !== "" && !joined.endsWith("\n")) joined += "\n";
  return joined;
}

const describe = (err) => (err && err.message ? err.message : String(err));

try {
  fs.mkdirSync(storeDir, { recursive: true });
} catch (err) {
  fail(`cannot create ${storeDir}: ${describe(err)}`);
}

let mode = 0;
try {
  mode = fs.statSync(store).mode & 0o777;
} catch {
  mode = 0o644;
}

for (let attempt = 0; attempt < 3; attempt += 1) {
  // A host that has never run Codex has no config.toml. "absent" is a state of its
  // own, so the retry guard compares like with like instead of treating the file's
  // arrival during this attempt as a concurrent write.
  const existed = fs.existsSync(store);
  const raw = existed ? fs.readFileSync(store) : Buffer.from("");
  const before = existed ? hash(raw) : "absent";
  const text = raw.toString("utf8");
  const edit = command === "add" ? addEntry(text) : { next: removeEntry(text, command), wrote: null, replaced: null };
  const next = edit.next;

  if (next === null) {
    const done = command === "add" ? "already-trusted" : "no-entry";
    // Nothing to record: no stale note may survive to restore a line that is still there.
    if (command === "add" && previousOut) {
      try { fs.rmSync(previousOut, { force: true }); } catch {}
    }
    console.log(`${done}: ${resolved}`);
    process.exit(0);
  }

  const tmp = path.join(storeDir, `.config.toml.kingpin.${process.pid}.${crypto.randomBytes(6).toString("hex")}`);
  try {
    fs.writeFileSync(tmp, next, { mode, flag: "wx" });
  } catch (err) {
    fail(`cannot write ${tmp}: ${describe(err)}`);
  }

  let currentHash = "absent";
  if (fs.existsSync(store)) currentHash = hash(fs.readFileSync(store));
  if (currentHash !== before) {
    fs.rmSync(tmp, { force: true });
    continue;
  }
  try {
    fs.renameSync(tmp, store);
  } catch (err) {
    fs.rmSync(tmp, { force: true });
    fail(`cannot replace ${store}: ${describe(err)}`);
  }

  // Remember the line the add step overwrote, so a later remove can put it back. A failed
  // write only costs that restore, and it must not undo the seed: the entry is in place.
  if (command === "add" && previousOut) {
    try {
      if (edit.replaced === null) fs.rmSync(previousOut, { force: true });
      else fs.writeFileSync(previousOut, `${edit.replaced}\n`);
    } catch {
      try { fs.rmSync(previousOut, { force: true }); } catch {}
    }
  }

  // Read the file back: the entry has to be there (add) or gone (a whole-section remove),
  // and every other line has to be what it was.
  const back = fs.readFileSync(store, "utf8");
  const present = findSection(back === "" ? [] : back.split("\n")).start >= 0;
  const ok = command === "add" ? present : command === "section" ? !present : present;
  if (ok) {
    const token = command === "add" ? (edit.wrote === "section" ? "trusted" : "trusted-key")
      : command === "section" ? "untrusted"
      : command === "restore" ? "restored-key" : "untrusted-key";
    console.log(`${token}: ${resolved}`);
    process.exit(0);
  }
  fail(`${store} did not keep the change for ${resolved}`);
}

fail(`${store} kept changing; the entry for ${resolved} was not recorded`);
