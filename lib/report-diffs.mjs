#!/usr/bin/env node
// Dossier diff helper: generate valid @pierre/diffs blocks and check a report.html.
//
//   report-diffs.mjs diffs [--repo <dir>] [--base <ref>]   HTML fragment on stdout
//   report-diffs.mjs check <report.html>                   exit 1 when a diff would render blank
//
// @pierre/diffs FileDiff takes { oldFile: {name, contents}, newFile: {name, contents} }.
// A `patch:` string is silently ignored and leaves the container empty, which is the
// failure this helper exists to prevent.
import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const PIERRE = "https://esm.sh/@pierre/diffs@1.2.10?bundle";

const die = (msg, code = 2) => {
  process.stderr.write(`kingpin-report: ${msg}\n`);
  process.exit(code);
};

const esc = (s) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function git(repo, args, { allowFail = false, buffer = false } = {}) {
  try {
    return execFileSync("git", ["-C", repo, ...args], {
      encoding: buffer ? "buffer" : "utf8",
      maxBuffer: 256 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (e) {
    // `git diff --no-index` exits 1 when the files differ; its stdout is the diff.
    if (allowFail) return e.stdout ?? (buffer ? Buffer.alloc(0) : "");
    throw new Error(`git ${args.join(" ")}: ${e.stderr?.toString().trim() || e.message}`);
  }
}

function defaultBase(repo) {
  for (const ref of ["origin/HEAD", "origin/main", "main", "origin/master", "master"]) {
    try {
      git(repo, ["rev-parse", "--verify", "--quiet", ref]);
      return ref;
    } catch {}
  }
  return null;
}

const isBinary = (buf) => buf.subarray(0, 8000).includes(0);

function collect(repo, base) {
  const baseRef = base ?? defaultBase(repo);
  if (!baseRef) die("cannot find a base branch; pass --base <ref>");
  const mb = git(repo, ["merge-base", baseRef, "HEAD"]).trim();

  const entries = []; // { status, oldPath, newPath, untracked }
  const names = git(repo, ["diff", "--name-status", "-M", "-z", mb]).split("\0").filter(Boolean);
  for (let i = 0; i < names.length; ) {
    const status = names[i++];
    if (status[0] === "R" || status[0] === "C") {
      entries.push({ status: status[0], oldPath: names[i++], newPath: names[i++] });
    } else {
      const p = names[i++];
      entries.push({ status: status[0], oldPath: status[0] === "A" ? null : p, newPath: status[0] === "D" ? null : p });
    }
  }
  const seen = new Set(entries.map((e) => e.newPath ?? e.oldPath));
  const untracked = git(repo, ["ls-files", "--others", "--exclude-standard", "-z"]).split("\0").filter(Boolean);
  for (const p of untracked) {
    if (!seen.has(p)) entries.push({ status: "A", oldPath: null, newPath: p, untracked: true });
  }

  return entries.map((e) => {
    const name = e.newPath ?? e.oldPath;
    const oldBuf = e.oldPath ? git(repo, ["show", `${mb}:${e.oldPath}`], { buffer: true, allowFail: true }) : Buffer.alloc(0);
    const newBuf = e.newPath && existsSync(join(repo, e.newPath)) ? readFileSync(join(repo, e.newPath)) : Buffer.alloc(0);
    if (isBinary(oldBuf) || isBinary(newBuf)) {
      return { name, oldName: e.oldPath ?? name, status: e.status, binary: true, oldContents: "", newContents: "", text: "Binary file not shown." };
    }
    let text;
    if (e.untracked) {
      text = git(repo, ["diff", "--no-index", "--no-color", "--", "/dev/null", e.newPath], { allowFail: true });
    } else {
      const paths = e.oldPath && e.newPath && e.oldPath !== e.newPath ? [e.oldPath, e.newPath] : [name];
      text = git(repo, ["diff", "-M", "--no-color", mb, "--", ...paths], { allowFail: true });
    }
    return {
      name,
      oldName: e.oldPath ?? name,
      status: e.status,
      binary: false,
      oldContents: oldBuf.toString("utf8"),
      newContents: newBuf.toString("utf8"),
      text,
    };
  });
}

const STATUS = { A: "added", M: "modified", D: "deleted", R: "renamed", C: "copied", T: "type changed" };

function render(files) {
  // JSON inside <script>: keep "<" from ever closing the tag or opening a comment.
  const data = JSON.stringify(
    files.map(({ name, oldName, oldContents, newContents, binary }) => ({ name, oldName, oldContents, newContents, binary })),
  ).replace(/</g, "\\u003c");
  const blocks = files
    .map(
      (f, i) => `  <div class="kp-diff-file">
    <h3 class="kp-diff-title"><code>${esc(f.name)}</code> <small>${STATUS[f.status] ?? f.status}${f.oldName !== f.name ? ` from ${esc(f.oldName)}` : ""}</small></h3>
    <div class="kp-diff" data-index="${i}"><pre class="kp-fallback">${esc(f.text.trim() || "(no textual changes)")}</pre></div>
  </div>`,
    )
    .join("\n");
  return `<section id="kp-diffs">
${blocks}
  <script type="application/json" id="kp-diff-data">${data}</script>
  <script type="module">
    import { FileDiff } from "${PIERRE}";
    const files = JSON.parse(document.getElementById("kp-diff-data").textContent);
    const options = { theme: { light: "github-light", dark: "github-dark" }, themeType: "dark", overflow: "wrap", diffStyle: "split" };
    files.forEach((f, i) => {
      const box = document.querySelector('.kp-diff[data-index="' + i + '"]');
      const fallback = box.querySelector(".kp-fallback");
      if (f.binary) return;
      const host = document.createElement("div");
      box.appendChild(host);
      const settle = () => { if (host.childElementCount > 0) fallback.hidden = true; return host.childElementCount > 0; };
      try {
        // FileDiff needs oldFile/newFile objects. A raw patch string is not an option and renders nothing.
        new FileDiff(options).render({
          containerWrapper: host,
          oldFile: { name: f.oldName, contents: f.oldContents },
          newFile: { name: f.name, contents: f.newContents },
        });
        if (!settle()) setTimeout(settle, 1500);
      } catch (err) {
        console.error("kp-diff: render failed for " + f.name, err);
      }
    });
  </script>
</section>
`;
}

function check(file) {
  if (!file || !existsSync(file)) die(`report not found: ${file ?? "(none)"}`);
  const html = readFileSync(file, "utf8");
  // Judge the page's script code only: prose, embedded JSON data and fallback <pre> blocks may say anything.
  const code = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)]
    .filter(([, attrs]) => !/application\/json/.test(attrs))
    .map(([, , body]) => body)
    .join("\n");
  const errors = [];

  if (!/\bFileDiff\b/.test(code)) errors.push("no @pierre/diffs FileDiff call found (Section 3 would be empty)");
  if (/\bpatch\s*:/.test(code))
    errors.push("`patch:` is not a FileDiff option and renders nothing; pass oldFile/newFile ({ name, contents })");
  if (/\bFileDiff\b/.test(code) && !(/\boldFile\b/.test(code) && /\bnewFile\b/.test(code)))
    errors.push("FileDiff is used without oldFile and newFile");

  const empty = html.match(/<div[^>]*class="(?:[^"]*\s)?kp-diff(?:\s[^"]*)?"[^>]*>\s*<\/div>/g);
  if (empty) errors.push(`${empty.length} diff container(s) are empty`);

  const m = html.match(/<script type="application\/json" id="kp-diff-data">([\s\S]*?)<\/script>/);
  if (m) {
    try {
      const data = JSON.parse(m[1]);
      const boxes = (html.match(/class="kp-diff"/g) ?? []).length;
      if (!Array.isArray(data) || data.length === 0) errors.push("kp-diff-data holds no files");
      else {
        if (data.length !== boxes) errors.push(`kp-diff-data has ${data.length} files but the page has ${boxes} diff containers`);
        for (const f of data)
          if (typeof f.name !== "string" || typeof f.oldContents !== "string" || typeof f.newContents !== "string")
            errors.push(`kp-diff-data entry ${JSON.stringify(f.name)} lacks name/oldContents/newContents strings`);
      }
    } catch (e) {
      errors.push(`kp-diff-data is not valid JSON: ${e.message}`);
    }
  }

  if (errors.length) {
    for (const e of errors) process.stderr.write(`FAILED: ${e}\n`);
    process.exit(1);
  }
  process.stdout.write(`OK: ${file} has renderable diffs\n`);
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === "diffs") {
  let repo = process.cwd();
  let base;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--repo") repo = args[++i] ?? die("--repo needs a value");
    else if (args[i] === "--base") base = args[++i] ?? die("--base needs a value");
    else die(`unknown argument '${args[i]}'`);
  }
  try {
    const files = collect(repo, base);
    if (files.length === 0) die("no changed files against the base", 1);
    process.stdout.write(render(files));
  } catch (e) {
    die(e.message, 1);
  }
} else if (cmd === "check") {
  check(args[0]);
} else {
  die("usage: kingpin report diffs [--repo <dir>] [--base <ref>] | kingpin report check <report.html>");
}
