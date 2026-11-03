#!/usr/bin/env node
// Dossier diff helper: generate valid @pierre/diffs blocks and check a report.html.
//
//   report-diffs.mjs diffs [--repo <dir>] [--base <ref>]   HTML fragment on stdout
//   report-diffs.mjs check [--prose-only] <report.html>    exit 1 when a diff would render blank,
//                                                          the page would overflow, or the prose
//                                                          carries an unslop tell
//
// @pierre/diffs FileDiff takes { oldFile: {name, contents}, newFile: {name, contents} }.
// A `patch:` string is silently ignored and leaves the container empty, which is the
// failure this helper exists to prevent. The layout pass reads the page's own rules (see
// `layoutHits`) and reports the line of each element or rule that lets text out of its box.
// The prose pass is the mechanical slice of the `unslop` skill: code, diff output,
// script/style bodies and attributes are ignored, and `<!-- unslop:ignore -->` on a line
// keeps a word that is genuinely wanted.
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

// The mechanical slice of the `unslop` skill: short and always right, so the check never cries
// wolf over style. `<!-- unslop:ignore -->` on a line is the single escape.
const PROSE_RULES = [
  { id: "em dash", re: /\u2014|&mdash;|&#8212;|&#x2014;/i, hint: "use a period, comma or parentheses" },
  { id: '"testament to"', re: /\btestament to\b/i, hint: "state what happened" },
  { id: '"it\'s not just"', re: /\b(?:it|this|that)(?:(?:'|\u2019)s|\s+is)\s+not just\b/i, hint: "state the point directly" },
  { id: '"delve"', re: /\bdelv(?:e|es|ed|ing)\b/i, hint: "use a plainer verb" },
  { id: '"seamless"', re: /\bseamless(?:ly)?\b/i, hint: "say what it does" },
  { id: '"in order to"', re: /\bin order to\b/i, hint: 'use "to"' },
  { id: '"let me know"', re: /\blet me know\b/i, hint: "drop the chatbot sign-off" },
  { id: '"I hope this helps"', re: /\bI hope this helps\b/i, hint: "drop the chatbot sign-off" },
];

// Elements whose bodies are never prose, and the escape that keeps a wanted word on a line.
const RAW_BLOCKS = ["code", "pre", "textarea", "style", "script"];
const PROSE_ESCAPE = /unslop:ignore/;

const blankLineOut = (s) => s.replace(/[^\n]/g, " ");

// A tag, including one whose quoted attribute value holds `>`; `[^>"']*` crosses newlines,
// so a tag wrapped over several lines is masked whole.
const TAG_BODY = `[^>"']*(?:(?:"[^"]*"|'[^']*')[^>"']*)*`;

// Blank every non-prose region while keeping its newlines, so reported line numbers match the file.
function maskNonProse(html) {
  let s = html;
  // Inner blocks first, a few passes deep, so `<pre><code>` and `<code><pre>` both go blank.
  for (let pass = 0; pass < 4; pass++) {
    let changed = false;
    for (const tag of RAW_BLOCKS) {
      s = s.replace(new RegExp(`<${tag}\\b[^>]*>[\\s\\S]*?</${tag}\\s*>`, "gi"), (m) => {
        changed = true;
        return blankLineOut(m);
      });
    }
    if (!changed) break;
  }
  return s
    .replace(/<!--[\s\S]*?-->/g, blankLineOut)
    .replace(new RegExp(`<${TAG_BODY}>`, "g"), blankLineOut);
}

// One entry per rule matched on a prose line: { line, rule, hint, text }.
function proseHits(html) {
  const rawLines = html.split("\n");
  const ignored = new Set();
  rawLines.forEach((line, i) => {
    if (PROSE_ESCAPE.test(line)) ignored.add(i + 1);
  });

  const hits = [];
  maskNonProse(html)
    .split("\n")
    .forEach((line, i) => {
      const n = i + 1;
      if (ignored.has(n)) return;
      const text = line.replace(/\s+/g, " ").trim();
      if (!text) return;
      const shown = rawLines[i].trim().replace(/\s+/g, " ");
      for (const rule of PROSE_RULES) {
        if (!rule.re.test(text)) continue;
        hits.push({ line: n, rule: rule.id, hint: rule.hint, text: shown.length > 160 ? `${shown.slice(0, 157)}...` : shown });
      }
    });
  return hits;
}

// --- Layout pass -------------------------------------------------------------------------
// Dossier pages are hand-authored HTML, and the two shapes that overflow are always the same: a
// wide table or a `pre` line that cannot break, inside a grid or flex child that refuses to shrink,
// or a ref to an absolute path or one that climbs out of the page's folder. The pass reads the
// page's `<style>` rules and inline styles, then reports `<file>:<line>:` for each mechanical cause.
// It judges the rules as written, not a rendered layout: a page that solves a shape another way
// (an inline style, a class rule, minmax(0, ...) tracks) passes, and a verdict names the element or
// rule an author can go fix.

const lineAt = (html, index) => {
  let line = 1;
  for (let i = 0; i < index && i < html.length; i++) if (html[i] === "\n") line++;
  return line;
};

const parseDecls = (text) => {
  const decls = {};
  for (const part of text.split(";")) {
    const colon = part.indexOf(":");
    if (colon < 0) continue;
    decls[part.slice(0, colon).trim().toLowerCase()] = part.slice(colon + 1).trim().toLowerCase();
  }
  return decls;
};

// Every `selector { declarations }` rule in every `<style>` block, with the line it starts on.
// CSS comments are blanked first, so their `{` and `}` cannot split a rule. A rule nested in an
// `@media` block still matches; the `@media` header itself is skipped.
function layoutRules(html) {
  const rules = [];
  for (const block of html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi)) {
    const bodyStart = block.index + block[0].indexOf(">") + 1;
    const css = block[1].replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
    for (const rule of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const selector = rule[1].trim();
      if (!selector || selector.startsWith("@")) continue;
      const lead = rule[1].length - rule[1].trimStart().length;
      rules.push({
        selectors: selector.split(",").map((s) => s.trim()),
        decls: parseDecls(rule[2]),
        line: lineAt(html, bodyStart + rule.index + lead),
      });
    }
  }
  return rules;
}

// The element a selector applies to: its last compound (`td:first-child` and `.cards > .card` are
// `td` and `.card`). Pseudo-classes and attribute selectors are dropped.
const selectorTarget = (selector) =>
  (selector.trim().split(/[\s>+~]+/).filter(Boolean).pop() ?? "")
    .replace(/::?[a-zA-Z-]+(?:\([^)]*\))?/g, "")
    .replace(/\[[^\]]*\]/g, "");

const matchesTarget = (target, el) => {
  if (target === "*") return true;
  if (!target) return false;
  const m = target.match(/^([a-zA-Z][\w-]*)?((?:[.#][\w-]+)*)$/);
  if (!m) return false;
  const [, tag, rest] = m;
  if (tag && tag.toLowerCase() !== el.tag) return false;
  const wantId = (rest.match(/#([\w-]+)/) ?? [])[1];
  if (wantId && wantId !== el.id) return false;
  return [...rest.matchAll(/\.([\w-]+)/g)].every(([, c]) => el.classes.includes(c));
};

const elementStyle = (attrs) => parseDecls((attrs.match(/\bstyle\s*=\s*"([^"]*)"/i) ?? [])[1] ?? "");

// Declarations that apply to an element through matching rules, then its inline style. `cellTags`
// lets a table inherit what its own cells set (`td { overflow-wrap: anywhere }`).
function layoutProps(el, rules, cellTags = []) {
  const decls = {};
  for (const rule of rules) {
    const hit = rule.selectors.some((selector) => {
      const target = selectorTarget(selector);
      return matchesTarget(target, el) || cellTags.some((tag) => matchesTarget(target, { ...el, tag }));
    });
    if (hit) Object.assign(decls, rule.decls);
  }
  return Object.assign(decls, elementStyle(el.attrs));
}

const wrapsText = (decls) =>
  /^(?:anywhere|break-word|break-all)$/.test(decls["overflow-wrap"] ?? "") ||
  /^(?:break-all|break-word)$/.test(decls["word-break"] ?? "");

const wrapsPre = (decls) =>
  /^(?:pre-wrap|pre-line|break-spaces)$/.test(decls["white-space"] ?? "") ||
  /^(?:auto|scroll)$/.test(decls["overflow-x"] ?? "");

const tagsOf = (html, tag) =>
  [...html.matchAll(new RegExp(`<${tag}\\b([^>]*)>`, "gi"))].map((m) => ({
    tag,
    attrs: m[1],
    classes: ((m[1].match(/\bclass\s*=\s*"([^"]*)"/i) ?? [])[1] ?? "").split(/\s+/).filter(Boolean),
    id: (m[1].match(/\bid\s*=\s*"([^"]*)"/i) ?? [])[1] ?? "",
    index: m.index,
    line: lineAt(html, m.index),
  }));

const isLocalRef = (value) =>
  Boolean(value) && !value.startsWith("#") && !value.startsWith("//") && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(value);

// One hit per mechanical cause. Only a full document is judged: a fragment has no viewport and no
// page layout of its own, and a Markdown file has no HTML at all.
function layoutHits(html) {
  if (!/<html[\s>]/i.test(html)) return [];
  const rules = layoutRules(html);
  const hits = [];
  const preRanges = [...html.matchAll(/<pre\b[^>]*>[\s\S]*?<\/pre\s*>/gi)].map((m) => [m.index, m.index + m[0].length]);

  for (const pre of tagsOf(html, "pre")) {
    if (!wrapsPre(layoutProps(pre, rules))) {
      hits.push({ line: pre.line, msg: "<pre> has no wrap rule; add white-space: pre-wrap and overflow-wrap: anywhere (or overflow-x: auto)" });
    }
  }

  // Inline code is everywhere in a dossier, so a missing rule is one page-level hit, not one per path.
  const bareCode = tagsOf(html, "code").find((code) => {
    const inPre = preRanges.some(([start, end]) => code.index > start && code.index < end);
    return !inPre && !wrapsText(layoutProps(code, rules));
  });
  if (bareCode) hits.push({ line: bareCode.line, msg: "<code> has no wrap rule; add overflow-wrap: anywhere to code" });

  for (const table of tagsOf(html, "table")) {
    const decls = layoutProps(table, rules, ["td", "th", "tr"]);
    if (!wrapsText(decls) && !/^fixed$/.test(decls["table-layout"] ?? "") && decls["max-width"] === undefined) {
      hits.push({ line: table.line, msg: "<table> has no wrap rule; set overflow-wrap: anywhere on its cells or table-layout: fixed" });
    }
  }

  const layoutRule = rules.find((rule) => /^(?:inline-)?(?:grid|flex)$/.test(rule.decls.display ?? ""));
  if (layoutRule) {
    const inline = [...html.matchAll(/\bstyle\s*=\s*"([^"]*)"/gi)].map((m) => parseDecls(m[1]));
    const guarded = [...rules.map((rule) => rule.decls), ...inline].some((decls) =>
      Object.entries(decls).some(
        ([prop, value]) => (prop === "min-width" && /^0(?:px|rem|em|%)?$/.test(value)) || value.includes("minmax(0,"),
      ),
    );
    if (!guarded) {
      hits.push({ line: layoutRule.line, msg: "grid/flex layout has no shrink guard; add min-width: 0 to the children or minmax(0, 1fr) tracks" });
    }
  }

  const refs = [
    ...[...html.matchAll(/\b(?:src|href)\s*=\s*(?:"([^"]*)"|'([^']*)')/gi)].map((m) => ({ value: m[1] ?? m[2], line: lineAt(html, m.index) })),
    ...[...html.matchAll(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi)].map((m) => ({ value: m[2].trim(), line: lineAt(html, m.index) })),
  ];
  for (const { value, line } of refs) {
    if (!isLocalRef(value)) continue;
    if (value.startsWith("/") || value.startsWith("~") || /^[A-Za-z]:[\\/]/.test(value)) {
      hits.push({ line, msg: `absolute asset path: ${value} (use a path relative to the page)` });
    } else if (value.split(/[\\/]/).includes("..")) {
      hits.push({ line, msg: `asset path climbs out of the page folder: ${value}` });
    }
  }

  return hits;
}

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

function check(file, { proseOnly = false } = {}) {
  if (!file || !existsSync(file)) die(`report not found: ${file ?? "(none)"}`);
  const html = readFileSync(file, "utf8");
  const errors = [];

  if (!proseOnly) {
    // Judge the page's script code only: prose, embedded JSON data and fallback <pre> blocks may say anything.
    const code = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)]
      .filter(([, attrs]) => !/application\/json/.test(attrs))
      .map(([, , body]) => body)
      .join("\n");

    if (!/\bFileDiff\b/.test(code)) errors.push("no @pierre/diffs FileDiff call found (Section 3 would be empty)");
    if (/\bpatch\s*:/.test(code))
      errors.push("`patch:` is not a FileDiff option and renders nothing; pass oldFile/newFile ({ name, contents })");
    if (/\bFileDiff\b/.test(code) && !(/\boldFile\b/.test(code) && /\bnewFile\b/.test(code)))
      errors.push("FileDiff is used without oldFile and newFile");

    const empty = html.match(/<div[^>]*class="(?:[^"]*\s)?kp-diff(?:\s[^"]*)?"[^>]*>\s*<\/div>/g);
    if (empty) errors.push(`${empty.length} diff container(s) are empty`);
  }

  if (!proseOnly) {
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
  }

  for (const h of proseHits(html)) errors.push(`${file}:${h.line}: ${h.rule} (${h.hint}): ${h.text}`);

  // Only a rendered page has a layout to judge: a `*.html` file with an `<html>` element. A
  // Markdown note that mentions `<html>` in prose is not one, and neither is a diff fragment.
  const isPage = /\.(?:html?|xhtml)$/i.test(file) && /<html[\s>]/i.test(html);
  if (isPage) for (const hit of layoutHits(html)) errors.push(`${file}:${hit.line}: ${hit.msg}`);

  if (errors.length) {
    for (const e of errors) process.stderr.write(`FAILED: ${e}\n`);
    process.exit(1);
  }
  process.stdout.write(proseOnly ? `OK: ${file} has clean prose\n` : `OK: ${file} has renderable diffs and clean prose\n`);
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
  let proseOnly = false;
  let file;
  for (const a of args) {
    if (a === "--prose-only") proseOnly = true;
    else if (a.startsWith("-")) die(`unknown option '${a}'`);
    else if (file) die(`unexpected argument '${a}'`);
    else file = a;
  }
  check(file, { proseOnly });
} else {
  die("usage: kingpin report diffs [--repo <dir>] [--base <ref>] | kingpin report check [--prose-only] <report.html>");
}
