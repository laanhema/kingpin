#!/usr/bin/env node
// Mark an archived review dossier as finished, so a page left open in a browser no
// longer looks like a review waiting on someone.
//
//   dossier-finish.mjs <file> --state merged|failed|finished [--task <id>] [--pr <url>]
//
// The page gets one banner naming the merged PR (or saying how the task ended), styled
// with the dossier's own dark palette, inserted as the first element of <body>. Every
// button that calls kpAction( or kpRequestChanges( loses its handler and gains
// disabled/aria-disabled, every element the template marks `data-kp-finished-hide`
// (the action bar and the READY FOR REVIEW badge) is hidden, and both handlers are
// replaced with a no-op, so nothing on the page can queue a prompt. The rewrite happens
// once: the banner carries MARKER, and a page that already holds it is left exactly as
// it is.
//
// Prints `OK: <file> marked finished` on a rewrite and `OK: <file> already marked
// finished` when it found MARKER. Writes `dossier-finish: <reason>` to stderr and
// exits 1 when the page cannot be read or written, and 2 for a bad argument.
import { readFileSync, writeFileSync } from "node:fs";

const MARKER = "<!-- kingpin:finished -->";

const die = (msg, code = 2) => {
  process.stderr.write(`dossier-finish: ${msg}\n`);
  process.exit(code);
};

const esc = (s) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// A PR value becomes a link only when it is an ordinary http(s) URL. Anything else is
// shown as text, so a status line cannot put a script or a file: URL on the page.
const SAFE_URL = /^https?:\/\/[^\s"'<>]+$/;

const prLabel = (url) => {
  const m = /\/pull\/(\d+)\/?$/.exec(url);
  return m ? `PR #${m[1]}` : "the pull request";
};

const banner = ({ state, task, pr }) => {
  const name = task ? `<span class="kp-finished-name">${esc(task)}</span>: ` : "";
  let body;
  if (state === "merged") {
    body = pr && SAFE_URL.test(pr)
      ? `Merged in <a href="${esc(pr)}">${esc(prLabel(pr))}</a>. Nothing on this page can be sent.`
      : "Merged. Nothing on this page can be sent.";
  } else if (state === "failed") {
    body = "The task finished without a merge. Nothing on this page can be sent.";
  } else {
    // `finished` covers a record whose last line is neither merged: nor failed:, such
    // as the cleanup-refused: recovery, so it makes no claim about a merge either way.
    body = "The task finished. Nothing on this page can be sent.";
  }
  return `${MARKER}
<style>
  .kp-finished { margin: 0 0 1.5rem; padding: 1rem 1.25rem; border: 1px solid #3d444d; border-left: 4px solid #2ea043; border-radius: .5rem; background: #161b22; color: #e6edf3; }
  .kp-finished-title { margin: 0; font-size: 1rem; font-weight: 600; line-height: 1.4; overflow-wrap: anywhere; }
  .kp-finished-body { margin: .25rem 0 0; font-size: .875rem; line-height: 1.5; color: #9ca3af; overflow-wrap: anywhere; }
  .kp-finished-name { font-family: ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace; }
  .kp-finished a { color: #58a6ff; }
  [data-kp-finished-hide] { display: none !important; }
</style>
<div class="kp-finished" role="status" data-kingpin-finished="${esc(task || "finished")}">
  <p class="kp-finished-title">This task is finished.</p>
  <p class="kp-finished-body">${name}${body}</p>
</div>
`;
};

// The no-op handlers, in case a link or a later script still calls one of them. It is
// inserted before </body> so it runs after the page has defined the real handlers.
const STUB = `<script>
  /* kingpin:finished. An archived dossier cannot queue a prompt. */
  window.kpAction = function () {};
  window.kpRequestChanges = function () {};
</script>
`;

// The handler names a decision control uses. A button that carries none of them is the
// author's own control and is left alone.
const HANDLERS = /\bkp(?:Action|RequestChanges)\s*\(/;

// One start tag, with its attributes matched through quoted values. Returns the tag with
// the onclick attribute dropped and disabled/aria-disabled added, or null when the tag
// does not need to change.
const inertButton = (tag) => {
  const attr = /\sonclick\s*=\s*("[^"]*"|'[^']*')/i.exec(tag);
  if (!attr || !HANDLERS.test(attr[1].slice(1, -1))) return null;
  let out = tag.replace(attr[0], "");
  if (!/\sdisabled\b/i.test(out)) out = out.replace(/^<button\b/i, "<button disabled");
  if (!/\saria-disabled\b/i.test(out)) out = out.replace(/^<button\b/i, '<button aria-disabled="true"');
  if (!/\sclass\s*=\s*/i.test(out)) {
    out = out.replace(/^<button\b/i, '<button class="kp-inert"');
  } else if (!/\skp-inert\b/.test(out)) {
    out = out.replace(/(\sclass\s*=\s*)(["'])/i, "$1$2kp-inert ");
  }
  return out;
};

const neutralize = (html) =>
  html.replace(/<button\b[^>]*>/gi, (tag) => inertButton(tag) ?? tag);

// Where the banner goes: as the first element of <main>, so it holds the page's own
// content column, then of <body> on a page with no <main> tag, and at the very top of a
// page that has neither. A page with no </body> keeps the stub at the end of the file.
const insertBanner = (html, block) => {
  const host = /<main\b[^>]*>/i.exec(html) ?? /<body\b[^>]*>/i.exec(html);
  if (host) {
    const at = host.index + host[0].length;
    return `${html.slice(0, at)}\n${block}${html.slice(at)}`;
  }
  return `${block}\n${html}`;
};

const insertStub = (html) => {
  const end = /<\/body\s*>/i.exec(html);
  if (end) return `${html.slice(0, end.index)}${STUB}${html.slice(end.index)}`;
  return `${html}\n${STUB}`;
};

const usage = "dossier-finish.mjs <file> --state merged|failed|finished [--task <id>] [--pr <url>]";

const args = process.argv.slice(2);
let file = "";
let state = "";
let task = "";
let pr = "";
for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  switch (arg) {
    case "--state":
      state = args[i + 1] ?? "";
      i += 1;
      break;
    case "--task":
      task = args[i + 1] ?? "";
      i += 1;
      break;
    case "--pr":
      pr = args[i + 1] ?? "";
      i += 1;
      break;
    case "-h":
    case "--help":
      process.stdout.write(`usage: ${usage}\n`);
      process.exit(0);
      break;
    default:
      if (arg.startsWith("-")) die(`unknown argument ${arg}`, 2);
      if (file) die(`unexpected argument ${arg}`, 2);
      file = arg;
  }
}
if (!file) die(`usage: ${usage}`, 2);
if (state !== "merged" && state !== "failed" && state !== "finished") {
  die(`--state must be merged, failed or finished`, 2);
}

let html;
try {
  html = readFileSync(file, "utf8");
} catch (err) {
  die(`cannot read ${file}: ${err.message}`, 1);
}
if (html.includes(MARKER)) {
  process.stdout.write(`OK: ${file} already marked finished\n`);
  process.exit(0);
}

const block = banner({ state, task, pr });
let out = insertBanner(neutralize(html), block);
out = insertStub(out);
try {
  writeFileSync(file, out);
} catch (err) {
  die(`cannot write ${file}: ${err.message}`, 1);
}
process.stdout.write(`OK: ${file} marked finished\n`);
