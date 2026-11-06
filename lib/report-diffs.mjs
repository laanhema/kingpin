#!/usr/bin/env node
// Dossier diff helper: generate valid @pierre/diffs blocks and check a report.html.
//
//   report-diffs.mjs diffs [--repo <dir>] [--base <ref>]   HTML fragment on stdout
//   report-diffs.mjs check [--prose-only] <file>           exit 1 when a diff would render blank,
//                                                          the page would overflow, a full page
//                                                          opens in Lavish annotation mode, or the
//                                                          prose carries an unslop tell. A `.md` or
//                                                          `.markdown` file is masked as markdown.
//
// @pierre/diffs FileDiff takes { oldFile: {name, contents}, newFile: {name, contents} }.
// A `patch:` option is silently ignored and leaves the container empty, which is the failure this
// helper exists to prevent. Its option test masks script comments and string literals first, so a
// report that only mentions `patch:` in prose passes. The layout pass reads the page's own rules
// (see `layoutHits`) and reports the line of each element or rule that lets text out of its box.
// The prose pass is the mechanical slice of the `unslop` skill: code, diff output,
// script/style bodies and attributes are ignored in a page, fenced and indented code, inline code
// spans and HTML comments are ignored in markdown, and `<!-- unslop:ignore -->` on a line keeps a
// word that is genuinely wanted in both.
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

// --- Markdown masking ----------------------------------------------------------------------
// Markdown has no tags, so the regions that are not prose are fenced and indented code, inline
// code spans and HTML comments. The mask keeps every newline, as `maskNonProse` does, so a
// reported line is the file's own line.
const MARKDOWN_PATH = /\.(?:md|markdown)$/i;

// Blank every line of a fenced block. The opener's run length matters: a shorter run inside a
// longer fence is content, so a four-backtick fence holding a three-backtick fence stays masked
// to its real close. A closing run must be the same character, at least as long, and alone on
// its line, which is what CommonMark requires.
function maskFences(md) {
  const out = [];
  let fence = null; // { char, len }
  for (const line of md.split(/\r?\n/)) {
    if (fence) {
      const close = line.match(/^ {0,3}(`{3,}|~{3,})\s*$/);
      if (close && close[1][0] === fence.char && close[1].length >= fence.len) fence = null;
      out.push(blankLineOut(line));
      continue;
    }
    const open = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    // A backtick fence's info string may not hold a backtick; that line is prose, not an opener.
    if (open && !(open[1][0] === "`" && open[2].includes("`"))) {
      fence = { char: open[1][0], len: open[1].length };
      out.push(blankLineOut(line));
      continue;
    }
    out.push(line);
  }
  return out.join("\n");
}

// A list marker: the indent, the bullet or ordered number, and the gap that follows it. Its end is
// the content column, which is where the item's own prose starts.
const LIST_MARKER = /^[ \t]*(?:[-*+]|\d{1,9}[.)])(?:[ \t]+|$)/;

// The column a run of spaces and tabs reaches, with a tab advancing to the next multiple of four.
const columnOf = (text) => {
  let col = 0;
  for (const ch of text) col += ch === "\t" ? 4 - (col % 4) : 1;
  return col;
};

// Blank indented code blocks. CommonMark makes a four-space line code only when it opens a block:
// the block must start four columns past the content column of the list item that holds it, and a
// blank line (or the top of the document) must precede it, because an indented code block cannot
// interrupt a paragraph. A blanket "four spaces means code" rule swallows the prose of a nested
// list item or a list-item continuation paragraph, so it is tracked line by line instead.
function maskIndentedCode(md) {
  const out = [];
  const lists = []; // content column of each open list item, innermost last
  let inCode = false;
  let opensBlock = true; // the top of the document can open a code block, as can a blank line
  for (const line of md.split("\n")) {
    if (!line.trim()) {
      out.push(line);
      opensBlock = true;
      continue;
    }
    const indent = columnOf(line.match(/^[ \t]*/)[0]);
    while (lists.length && indent < lists[lists.length - 1]) lists.pop();
    const base = lists.length ? lists[lists.length - 1] : 0;
    if (inCode ? indent >= base + 4 : opensBlock && indent >= base + 4) {
      out.push(blankLineOut(line));
      inCode = true;
      opensBlock = false;
      continue;
    }
    inCode = false;
    const marker = line.match(LIST_MARKER);
    if (marker) lists.push(columnOf(line.slice(0, marker[0].length)));
    out.push(line);
    opensBlock = false;
  }
  return out.join("\n");
}

function maskMarkdown(md) {
  return maskIndentedCode(maskFences(md))
    .replace(/(`+)(?:(?!\n\s*\n)[\s\S])*?\1/g, blankLineOut) // inline code spans
    .replace(/<!--[\s\S]*?-->/g, blankLineOut); // HTML comments
}

// One entry per rule matched on a prose line: { line, rule, hint, text }. `format` selects the
// masking; the rule list and the escape are the same for both formats.
function proseHits(text, format = "html") {
  const rawLines = text.split("\n");
  const ignored = new Set();
  rawLines.forEach((line, i) => {
    if (PROSE_ESCAPE.test(line)) ignored.add(i + 1);
  });

  const hits = [];
  (format === "markdown" ? maskMarkdown(text) : maskNonProse(text))
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
    const prop = part.slice(0, colon).trim().toLowerCase();
    const value = part.slice(colon + 1).replace(/\s*!important\s*$/i, "").trim().toLowerCase();
    decls[prop] = value;
  }
  return decls;
};

// Split a selector list on commas at parenthesis and bracket depth zero, so `:where(p, td)` stays
// one selector and its arguments are not mistaken for siblings of the rule.
function splitSelectorList(text) {
  const parts = [];
  let depth = 0;
  let quote = null;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote) {
      if (ch === quote && text[i - 1] !== "\\") quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") quote = ch;
    else if (ch === "(" || ch === "[") depth++;
    else if (ch === ")" || ch === "]") depth = Math.max(0, depth - 1);
    else if (ch === "," && depth === 0) {
      parts.push(text.slice(start, i).trim());
      start = i + 1;
    }
  }
  parts.push(text.slice(start).trim());
  return parts.filter(Boolean);
}

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
        selectors: splitSelectorList(selector),
        decls: parseDecls(rule[2]),
        line: lineAt(html, bodyStart + rule.index + lead),
      });
    }
  }
  return rules;
}

// A compound selector reduced to the shape `matchesTarget` understands. Pseudo-classes and attribute
// selectors are dropped, as before; `:where()`/`:is()` are handled separately because their
// arguments are alternatives, not decoration.
const compoundBase = (compound) =>
  compound
    .replace(/::?[a-zA-Z-]+(?:\([^)]*\))?/g, "")
    .replace(/\[[^\]]*\]/g, "");

const FUNCTIONAL_ANY = /:(?:where|is)\(/i;

// Every `:where(...)`/`:is(...)` in a compound, removed from the base and returned with its argument
// selector list. Returns null when a functional pseudo is unbalanced, which makes the selector
// unresolvable. A compound with only a functional pseudo keeps `rest: ""`; its arguments decide.
function functionalArgs(compound) {
  const lists = [];
  let rest = compound;
  for (;;) {
    const m = FUNCTIONAL_ANY.exec(rest);
    if (!m) break;
    const open = m.index + m[0].length - 1;
    let depth = 0;
    let close = -1;
    for (let i = open; i < rest.length; i++) {
      if (rest[i] === "(") depth++;
      else if (rest[i] === ")") {
        depth--;
        if (depth === 0) {
          close = i;
          break;
        }
      }
    }
    if (close < 0) return null;
    lists.push(splitSelectorList(rest.slice(open + 1, close)));
    rest = rest.slice(0, m.index) + rest.slice(close + 1);
  }
  return { rest, lists };
}

// A selector as compounds, each with the combinator joining it to the one before it. A sibling
// combinator (`+`, `~`) needs sibling order the scan does not record, so such a selector is
// unresolvable and is ignored. So is an unbalanced selector.
function parseChain(selector) {
  const parts = [];
  let buf = "";
  let depth = 0;
  let quote = null;
  let combinator = null;
  const flush = () => {
    const compound = buf.trim();
    buf = "";
    if (!compound) return;
    parts.push({ compound, combinator });
    combinator = " ";
  };
  for (let i = 0; i < selector.length; i++) {
    const ch = selector[i];
    if (quote) {
      buf += ch;
      if (ch === quote && selector[i - 1] !== "\\") quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      buf += ch;
      continue;
    }
    if (ch === "(" || ch === "[") {
      depth++;
      buf += ch;
      continue;
    }
    if (ch === ")" || ch === "]") {
      depth = Math.max(0, depth - 1);
      buf += ch;
      continue;
    }
    if (depth > 0) {
      buf += ch;
      continue;
    }
    if (/\s/.test(ch)) {
      if (buf.trim()) flush();
      continue;
    }
    if (ch === ">") {
      if (buf.trim()) flush();
      combinator = ">";
      continue;
    }
    if (ch === "+" || ch === "~") return null;
    buf += ch;
  }
  if (buf.trim()) flush();
  return parts.length ? parts : null;
}

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

// A compound matches when its tag, id and classes match and every `:where()`/`:is()` alternative it
// carries matches too. A compound reduced to nothing (an attribute-only or pseudo-only selector)
// matches nothing, as before.
const matchesCompound = (compound, el) => {
  const parsed = functionalArgs(compound);
  if (!parsed) return false;
  for (const list of parsed.lists) {
    if (!list.some((selector) => matchesSelector(selector, el))) return false;
  }
  const base = compoundBase(parsed.rest);
  if (base === "") return parsed.lists.length > 0;
  return matchesTarget(base, el);
};

// Walk the chain right to left: `A B` needs an ancestor matching `A`, `A > B` the direct parent.
function matchesChain(chain, i, el) {
  if (!el || !matchesCompound(chain[i].compound, el)) return false;
  if (i === 0) return true;
  if (chain[i].combinator === ">") return matchesChain(chain, i - 1, el.parent);
  for (let ancestor = el.parent; ancestor; ancestor = ancestor.parent) {
    if (matchesChain(chain, i - 1, ancestor)) return true;
  }
  return false;
}

const matchesSelector = (selector, el) => {
  const chain = parseChain(selector.trim());
  return chain ? matchesChain(chain, chain.length - 1, el) : false;
};

// An attribute value in either quote style (`style="..."` or `style='...'`).
const attrValue = (attrs, name) => {
  const m = attrs.match(new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`, "i"));
  return m ? m[1] ?? m[2] : "";
};

const elementStyle = (attrs) => parseDecls(attrValue(attrs, "style"));

// CSS inherits these from ancestors, so `p { overflow-wrap: anywhere }` reaches the text inside a
// real `<p>` and nothing else. `table-layout` and `overflow-x` do not inherit, so they stay out of
// this set and must be declared on the element itself.
const INHERITED_PROPS = ["overflow-wrap", "word-break", "white-space"];

// Declarations an element inherits: a rule's inherited properties count only when the whole
// selector matches an actual ancestor from the scan, so `.panel p` reaches a `p` inside a panel and
// no other. `:root` is the `<html>` element, which is what the pseudo-class matches in a page.
function inheritedProps(el, rules) {
  const decls = {};
  for (const rule of rules) {
    const reaches = rule.selectors.some((selector) => {
      if (selector.trim() === ":root") return el.ancestors.some((ancestor) => ancestor.tag === "html");
      return el.ancestors.some((ancestor) => matchesSelector(selector, ancestor));
    });
    if (!reaches) continue;
    for (const prop of INHERITED_PROPS) if (rule.decls[prop] !== undefined) decls[prop] = rule.decls[prop];
  }
  return decls;
}

// Declarations that apply to an element: the inherited properties from a real ancestor, then
// matching rules, then its inline style. `cellTags` lets a table inherit what its own cells set
// (`td { overflow-wrap: anywhere }`); the fake cell sits inside the table so a scoped rule like
// `.panel td` is judged against the markup the table really lives in.
function layoutProps(el, rules, cellTags = []) {
  const decls = inheritedProps(el, rules);
  const cells = cellTags.map((tag) => ({ ...el, tag, parent: el, ancestors: [...el.ancestors, el] }));
  for (const rule of rules) {
    const hit = rule.selectors.some(
      (selector) => matchesSelector(selector, el) || cells.some((cell) => matchesSelector(selector, cell)),
    );
    if (hit) Object.assign(decls, rule.decls);
  }
  return Object.assign(decls, elementStyle(el.attrs));
}

const wrapsText = (decls) =>
  /^(?:anywhere|break-word|break-all)$/.test(decls["overflow-wrap"] ?? "") ||
  /^(?:break-all|break-word)$/.test(decls["word-break"] ?? "");

const containsCellText = (decls) =>
  wrapsText(decls) ||
  /^(?:auto|scroll)$/.test(decls["overflow-x"] ?? decls["overflow"] ?? "") ||
  /^ellipsis$/.test(decls["text-overflow"] ?? "");

const wrapsPre = (decls) =>
  /^(?:pre-wrap|pre-line|break-spaces)$/.test(decls["white-space"] ?? "") ||
  /^(?:auto|scroll)$/.test(decls["overflow-x"] ?? "") ||
  /^(?:auto|scroll)$/.test(decls["overflow"] ?? "");

// Every element in the scan with the elements enclosing it, from one pass with a tag stack. The
// ancestry is what inherited properties and child guards are judged against, so a rule reaches an
// element only through the markup that really contains it. Void and self-closing tags never open a
// level, a closing tag pops the matching level (and anything left open inside it), and a stray
// closing tag is ignored.
const VOID_TAGS = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]);

function scanElements(html) {
  const elements = [];
  const stack = [];
  for (const m of html.matchAll(new RegExp(`<(/?)([a-zA-Z][\\w-]*)\\b(${TAG_BODY})>`, "g"))) {
    const [, closing, name, attrs] = m;
    const tag = name.toLowerCase();
    if (closing) {
      const at = stack.map((el) => el.tag).lastIndexOf(tag);
      if (at >= 0) stack.length = at;
      continue;
    }
    const el = {
      tag,
      attrs,
      classes: attrValue(attrs, "class").split(/\s+/).filter(Boolean),
      id: attrValue(attrs, "id"),
      index: m.index,
      line: lineAt(html, m.index),
      parent: stack[stack.length - 1] ?? null,
      ancestors: [...stack],
    };
    elements.push(el);
    if (!VOID_TAGS.has(tag) && !attrs.trimEnd().endsWith("/")) stack.push(el);
  }
  return elements;
}

const isLocalRef = (value) =>
  Boolean(value) && !value.startsWith("#") && !value.startsWith("//") && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(value);

// A grid/flex layout is guarded per rule: its own tracks may carry `minmax(0, ...)`, or every real
// element child must be matched by a `min-width: 0` rule. `min-width: 0` on the container itself
// does not count, a rule elsewhere on the page does not count, and neither does a rule that reaches
// only some children: the one left unguarded is the one that overflows.
const LAYOUT_DISPLAY = /^(?:inline-)?(?:grid|flex)$/;
const ZERO_WIDTH = /^0(?:px|rem|em|%)?$/;
const MINMAX_ZERO = /minmax\(\s*0(?:px|rem|em|%)?\s*,/;
const TRACK_PROPS = ["grid-template-columns", "grid-template-rows", "grid-auto-columns", "grid-auto-rows"];

const tracksGuarded = (decls) => TRACK_PROPS.some((prop) => MINMAX_ZERO.test(decls[prop] ?? ""));

// The selectors of every `min-width: 0` rule, kept whole: `.grid-a .cell` guards only cells inside
// `.grid-a`, so the ancestor part matters as much as the last compound.
const zeroWidthGuards = (rules) =>
  rules.filter((rule) => ZERO_WIDTH.test(rule.decls["min-width"] ?? "")).flatMap((rule) => rule.selectors);

const childrenGuarded = (container, guards, elements) => {
  const children = elements.filter((el) => el.parent === container);
  return children.every((child) => guards.some((selector) => matchesSelector(selector, child)));
};

// A layout rule is judged against the elements its selectors actually match. A rule that matches no
// element has no rendered layout, and a container with no element children has nothing that can
// overflow, so both are skipped instead of failed.
const containersGuarded = (rule, guards, elements) => {
  const containers = elements.filter((el) => rule.selectors.some((selector) => matchesSelector(selector, el)));
  return containers.every((container) => childrenGuarded(container, guards, elements));
};

// One hit per mechanical cause. Only a full document is judged: a fragment has no viewport and no
// page layout of its own, and a Markdown file has no HTML at all.
function layoutHits(html) {
  if (!/<html[\s>]/i.test(html)) return [];
  // A comment or a script body is not rendered, so a `<pre>` or `display: grid` written there is
  // not an element. `<style>` stays: that is where the page's layout rules live.
  const scan = html
    .replace(/<!--[\s\S]*?-->/g, blankLineOut)
    .replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, blankLineOut);
  const rules = layoutRules(scan);
  const elements = scanElements(scan);
  const guards = zeroWidthGuards(rules);
  const tagsOf = (tag) => elements.filter((el) => el.tag === tag);
  const hits = [];
  const preRanges = [...scan.matchAll(/<pre\b[^>]*>[\s\S]*?<\/pre\s*>/gi)].map((m) => [m.index, m.index + m[0].length]);

  for (const pre of tagsOf("pre")) {
    if (!wrapsPre(layoutProps(pre, rules))) {
      hits.push({ line: pre.line, msg: "<pre> has no wrap rule; add white-space: pre-wrap and overflow-wrap: anywhere (or overflow-x: auto)" });
    }
  }

  // Inline code is everywhere in a dossier, so a missing rule is one page-level hit, not one per path.
  const bareCode = tagsOf("code").find((code) => {
    const inPre = preRanges.some(([start, end]) => code.index > start && code.index < end);
    return !inPre && !wrapsText(layoutProps(code, rules));
  });
  if (bareCode) hits.push({ line: bareCode.line, msg: "<code> has no wrap rule; add overflow-wrap: anywhere to code" });

  // An image with no `max-width` keeps its intrinsic width and pushes a screenshot grid sideways.
  for (const img of tagsOf("img")) {
    if (layoutProps(img, rules)["max-width"] === undefined) {
      hits.push({ line: img.line, msg: "<img> has no max-width rule; add img { max-width: 100%; height: auto; }" });
    }
  }

  for (const table of tagsOf("table")) {
    // A fixed layout alone lets a long token run into the next column; the cells need the wrap rule.
    if (!containsCellText(layoutProps(table, rules, ["td", "th"]))) {
      hits.push({ line: table.line, msg: "<table> has no wrap rule; set overflow-wrap: anywhere on its cells" });
    }
  }

  for (const rule of rules) {
    if (!LAYOUT_DISPLAY.test(rule.decls.display ?? "")) continue;
    if (tracksGuarded(rule.decls) || containersGuarded(rule, guards, elements)) continue;
    hits.push({ line: rule.line, msg: "grid/flex layout has no shrink guard; add min-width: 0 to the children or minmax(0, 1fr) tracks" });
  }

  // `display` declared only in an inline `style` attribute is a layout too.
  for (const el of elements) {
    const decls = elementStyle(el.attrs);
    if (!LAYOUT_DISPLAY.test(decls.display ?? "")) continue;
    if (tracksGuarded(decls) || childrenGuarded(el, guards, elements)) continue;
    hits.push({ line: el.line, msg: "grid/flex layout has no shrink guard; add min-width: 0 to the children or minmax(0, 1fr) tracks" });
  }

  const refs = [
    ...[...scan.matchAll(/\b(?:src|href)\s*=\s*(?:"([^"]*)"|'([^']*)')/gi)].map((m) => ({ value: m[1] ?? m[2], line: lineAt(scan, m.index) })),
    ...[...scan.matchAll(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi)].map((m) => ({ value: m[2].trim(), line: lineAt(scan, m.index) })),
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

// --- Stylesheet parse pass ---------------------------------------------------------------
// The layout pass above reads the sheet as text, so a page whose whole `body` rule was swallowed by
// the browser's error recovery still carries every string it looks for. This pass walks each
// `<style>` block by brace depth instead. At the top level of a block only at-statements
// (`@import …;`) and rule preludes are legal, so a `;`-terminated segment there is a declaration the
// browser threw away, and so is a prelude line that reads `prop: value` (a selector never carries
// whitespace after its colon). Each failure names the line the way the prose rule does.
const DECL_LINE = /^\s*[-\w]+\s*:\s+\S/;
const STYLE_BLOCK = /<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi;

// The walk below judges stylesheets, so it must not read a `<style>` sequence that the browser never
// parses as one: a block written inside an HTML comment, or the same text inside a script string.
// Both are blanked, keeping every newline so the offsets still map to the file's own lines. The
// opposite case is left alone: a `<!--` that opens inside a block is the CSS CDO token, which the CSS
// parser drops while the declarations around it stay live.
function styleScan(html) {
  const scan = html.replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, blankLineOut);
  const sheets = [...scan.matchAll(STYLE_BLOCK)].map((m) => [m.index, m.index + m[0].length]);
  const inSheet = (at) => sheets.some(([start, end]) => at >= start && at < end);
  return scan.replace(/<!--[\s\S]*?-->/g, (m, at) => (inSheet(at) ? m : blankLineOut(m)));
}

function styleParseHits(html) {
  const scan = styleScan(html);
  const rawLines = html.split("\n");
  const hits = [];
  const quote = (line) => {
    const text = line.trim().replace(/\s+/g, " ");
    return text.length > 160 ? `${text.slice(0, 157)}...` : text;
  };
  const report = (line) => {
    if (hits.some((hit) => hit.line === line)) return;
    hits.push({
      line,
      msg: `declaration outside any selector (the browser drops the rule that follows it): ${quote(rawLines[line - 1] ?? "")}`,
    });
  };

  for (const block of scan.matchAll(STYLE_BLOCK)) {
    const bodyStart = block.index + block[0].indexOf(">") + 1;
    // CSS comments blanked, newlines kept, so every offset still maps to the file's own line. The
    // same goes for a legacy `<!-- … -->` CDO/CDC wrapper, whose two tokens the CSS parser drops:
    // blanked in place, the declarations between them are read as usual.
    const css = block[1]
      .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "))
      .replace(/^\s*<!--/, blankLineOut)
      .replace(/-->\s*$/, blankLineOut);
    let depth = 0;
    let quoteChar = null;
    let start = 0;

    const checkStatement = (end) => {
      const text = css.slice(start, end);
      const trimmed = text.trim();
      if (!trimmed || trimmed.startsWith("@")) return;
      const lead = text.length - text.trimStart().length;
      report(lineAt(html, bodyStart + start + lead));
    };

    const checkPrelude = (end) => {
      const text = css.slice(start, end);
      if (!text.trim() || text.trimStart().startsWith("@")) return;
      let offset = 0;
      for (const line of text.split("\n")) {
        if (DECL_LINE.test(line)) {
          report(lineAt(html, bodyStart + start + offset));
          return;
        }
        offset += line.length + 1;
      }
    };

    for (let i = 0; i < css.length; i++) {
      const ch = css[i];
      if (quoteChar) {
        if (ch === quoteChar && css[i - 1] !== "\\") quoteChar = null;
        continue;
      }
      if (ch === '"' || ch === "'") {
        quoteChar = ch;
      } else if (ch === "{") {
        if (depth === 0) checkPrelude(i);
        depth++;
        start = i + 1;
      } else if (ch === "}") {
        depth = Math.max(0, depth - 1);
        start = i + 1;
      } else if (ch === ";" && depth === 0) {
        checkStatement(i);
        start = i + 1;
      }
    }
    if (depth === 0) checkStatement(css.length);
  }
  return hits;
}

// --- Palette pass ------------------------------------------------------------------------
// A page that claims `color-scheme: dark` and paints nothing still renders white: a transparent
// body on a default document is white, with black text. Once the parse pass has established what
// the sheet really holds, require a parsed background on `body`, `html` or `:root`. Presence is the
// contract, not luminance: hand-built noir pages paint gradients and CSS variables, and a
// value-level check would misread near-invisible white gradient stops and var() indirection. A
// selector counts when it targets the root syntactically (so a document that omits the `<body>` tag
// is still judged) or when it matches the page's real `<body>`/`<html>` element, and an inline
// style on either element counts too.
const BACKGROUND_PROPS = ["background", "background-color"];
const DARK_CLAIM = /\bdark\b/i;

function paletteHits(html) {
  const scan = html
    .replace(/<!--[\s\S]*?-->/g, blankLineOut)
    .replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, blankLineOut);
  const rules = layoutRules(scan);
  const claim = rules.find((rule) => DARK_CLAIM.test(rule.decls["color-scheme"] ?? ""));
  if (!claim) return [];

  const roots = scanElements(scan).filter((el) => el.tag === "body" || el.tag === "html");
  const hasBackground = (decls) => BACKGROUND_PROPS.some((prop) => decls[prop] !== undefined);
  const targetsRoot = (selector) => {
    const base = compoundBase(selector).trim();
    if (base === "body" || base === "html") return true;
    if (!base && /:root\b/.test(selector)) return true;
    return roots.some((el) => matchesSelector(selector, el));
  };
  const painted =
    roots.some((el) => hasBackground(elementStyle(el.attrs))) ||
    rules.some((rule) => hasBackground(rule.decls) && rule.selectors.some(targetsRoot));
  if (painted) return [];

  return [
    {
      line: claim.line,
      msg: "color-scheme: dark has no background rule on body, html or :root (a transparent body renders white)",
    },
  ];
}

// --- Annotation pass ---------------------------------------------------------------------
// Lavish opens a page in annotation mode unless the root element opts out, so a reader who only
// meant to read loses the page to a stray click. Dossiers therefore carry
// `data-lavish-annotate="off"` on `<html>`; the toolbar still turns annotation on for a review
// that wants comments. Presence is the contract, because the issue that asked for this rule makes
// only the missing attribute a failure: an explicit `"on"` is a deliberate choice for a page that
// means to be annotated, and Lavish reads an unknown value as on anyway. Only a real attribute on
// the root counts, so quoted values are blanked before the test: the name written inside another
// attribute's value, as a `title` explaining the rule does, is not an attribute and the page still
// opens in annotation mode. Comments and script bodies are blanked like the palette pass does, so
// a root element written in either is not a page.
const ANNOTATE_ATTR = /\bdata-lavish-annotate\s*=/i;
const QUOTED_VALUE = /"[^"]*"|'[^']*'/g;

function annotateHits(html) {
  const scan = html
    .replace(/<!--[\s\S]*?-->/g, blankLineOut)
    .replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, blankLineOut);
  const root = scanElements(scan).find((el) => el.tag === "html");
  if (!root || ANNOTATE_ATTR.test(root.attrs.replace(QUOTED_VALUE, '""'))) return [];
  return [
    {
      line: root.line,
      msg: 'no data-lavish-annotate="off" on <html> (the page opens in annotation mode; add data-lavish-annotate="off", or "on" to choose it)',
    },
  ];
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
    /* A split diff needs room for two columns. Below 1000px the same patch reads far
       better in one column, so the renderer follows the viewport. */
    const wide = window.matchMedia("(min-width: 1000px)");
    const options = () => ({
      theme: { light: "github-light", dark: "github-dark" },
      themeType: "dark", overflow: "wrap",
      diffStyle: wide.matches ? "split" : "unified",
    });
    const paint = () => {
      files.forEach((f, i) => {
        const box = document.querySelector('.kp-diff[data-index="' + i + '"]');
        if (!box || f.binary) return;
        const fallback = box.querySelector(".kp-fallback");
        box.querySelectorAll(":scope > div").forEach((old) => old.remove());
        const host = document.createElement("div");
        box.appendChild(host);
        const settle = () => { if (host.childElementCount > 0) fallback.hidden = true; return host.childElementCount > 0; };
        try {
          // FileDiff needs oldFile/newFile objects. A raw patch string is not an option and renders nothing.
          new FileDiff(options()).render({
            containerWrapper: host,
            oldFile: { name: f.oldName, contents: f.oldContents },
            newFile: { name: f.name, contents: f.newContents },
          });
          if (!settle()) setTimeout(settle, 1500);
        } catch (err) {
          console.error("kp-diff: render failed for " + f.name, err);
        }
      });
    };
    paint();
    wide.addEventListener("change", paint);
  </script>
</section>
`;
}

// --- Diff option check ---------------------------------------------------------------------
// The blank-diff check reads a dossier's script code, and a script may carry prose about the rule
// it obeys ("no `patch:` option, pass oldFile/newFile") in a comment or an error string. That
// prose is not the option, so the test runs on a masked copy: comments, string literals and regex
// literals are blanked in place, with every newline kept so a reported line still matches the
// file. A string in an object-key position is code, not prose, so a `patch` key keeps its text and
// still fails; every other key is blanked like any other string.
function maskJs(code) {
  // UTF-16 units, so every index below (which comes from `code`) addresses the same element.
  const out = code.split("");
  const blank = (from, to) => {
    for (let k = from; k < to && k < out.length; k++) if (out[k] !== "\n") out[k] = " ";
  };
  // The index of the nearest non-space character before `at` in the masked output (comments
  // already blanked), or after `at` in the source.
  const prevAt = (at) => {
    for (let k = at - 1; k >= 0; k--) if (!/\s/.test(out[k])) return k;
    return -1;
  };
  const nextAt = (at) => {
    for (let k = at; k < code.length; k++) if (!/\s/.test(code[k])) return k;
    return code.length;
  };
  // A `/` opens a regex literal in expression position and is division after a value. The previous
  // token decides: a value (identifier, number, `)`, `]`, a literal) means division, and an
  // operator, an opening bracket or a keyword like `return` means a regex.
  const REGEX_KEYWORD = /^(?:return|typeof|instanceof|in|of|new|delete|void|do|else|yield|await|throw|case)$/;
  const regexStart = (at) => {
    let k = at - 1;
    while (k >= 0 && /\s/.test(out[k])) k--;
    if (k < 0) return true;
    if (!/[)\]}'"`\w$]/.test(out[k])) return true;
    if (!/[A-Za-z_$]/.test(out[k])) return false;
    let s = k;
    while (s >= 0 && /[\w$]/.test(out[s])) s--;
    return REGEX_KEYWORD.test(out.slice(s + 1, k + 1).join(""));
  };
  // The end of a regex literal: escapes and `[...]` classes are skipped, flags are consumed, and an
  // unterminated regex stops at its line the way a stray quote does.
  const regexEnd = (at) => {
    let inClass = false;
    for (let k = at + 1; k < code.length; k++) {
      const c = code[k];
      if (c === "\\") {
        k++;
        continue;
      }
      if (c === "\n") return k;
      if (inClass) {
        if (c === "]") inClass = false;
        continue;
      }
      if (c === "[") inClass = true;
      else if (c === "/") {
        k++;
        while (k < code.length && /[a-z]/i.test(code[k])) k++;
        return k;
      }
    }
    return code.length;
  };
  // One quoted run: escapes are skipped, and an unterminated ' or " stops at its line, so a stray
  // quote can drop at most the rest of that line.
  const quotedEnd = (at) => {
    const quote = code[at];
    for (let k = at + 1; k < code.length; k++) {
      if (code[k] === "\\") {
        k++;
        continue;
      }
      if (code[k] === quote) return k + 1;
      if (code[k] === "\n" && quote !== "`") return k;
    }
    return code.length;
  };

  const interpolations = []; // brace depth at each open `${` of a template literal
  let mode = "code";
  let brace = 0;
  for (let i = 0; i < code.length; ) {
    const ch = code[i];
    if (mode === "template") {
      if (ch === "\\") {
        blank(i, i + 2);
        i += 2;
      } else if (ch === "`") {
        mode = "code";
        i++;
      } else if (ch === "$" && code[i + 1] === "{") {
        interpolations.push(brace);
        mode = "code";
        i += 2;
      } else {
        blank(i, i + 1);
        i++;
      }
      continue;
    }
    if (ch === "/" && code[i + 1] === "/") {
      const end = code.indexOf("\n", i);
      blank(i, end < 0 ? code.length : end);
      i = end < 0 ? code.length : end;
      continue;
    }
    if (ch === "/" && code[i + 1] === "*") {
      const close = code.indexOf("*/", i + 2);
      const end = close < 0 ? code.length : close + 2;
      blank(i, end);
      i = end;
      continue;
    }
    if (ch === "/" && regexStart(i)) {
      const end = regexEnd(i);
      blank(i, end);
      i = end;
      continue;
    }
    if (ch === '"' || ch === "'") {
      const end = quotedEnd(i);
      const terminated = code[end - 1] === ch;
      const open = prevAt(i);
      const close = nextAt(end);
      const plainKey = terminated && (out[open] === "{" || out[open] === ",") && code[close] === ":";
      const computedKey = terminated && out[open] === "[" && code[close] === "]" && code[nextAt(close + 1)] === ":";
      if ((plainKey || computedKey) && code.slice(i + 1, end - 1).trim() === "patch") {
        // Keep a `patch` key's own text so `"patch":` and `["patch"]:` read as `patch:` to the
        // option regex; every other key is not the option and is blanked whole.
        if (computedKey) {
          blank(open, i + 1);
          blank(end - 1, close + 1);
        } else {
          blank(i, i + 1);
          blank(end - 1, end);
        }
      } else {
        blank(i, end);
      }
      i = end;
      continue;
    }
    if (ch === "`") {
      mode = "template";
      i++;
      continue;
    }
    if (ch === "{") {
      brace++;
    } else if (ch === "}") {
      if (interpolations.length && brace === interpolations[interpolations.length - 1]) {
        interpolations.pop();
        mode = "template";
      } else {
        brace = Math.max(0, brace - 1);
      }
    }
    i++;
  }
  return out.join("");
}

function check(file, { proseOnly = false } = {}) {
  if (!file || !existsSync(file)) die(`report not found: ${file ?? "(none)"}`);
  const text = readFileSync(file, "utf8");
  const format = MARKDOWN_PATH.test(file) ? "markdown" : "html";
  // Markdown carries no diff section, so its diff checks are skipped the way `--prose-only` skips
  // them; the prose, layout and palette passes still run where they apply.
  const skipDiffs = proseOnly || format === "markdown";
  const errors = [];

  if (!skipDiffs) {
    // Judge the page's script code only: prose, embedded JSON data and fallback <pre> blocks may
    // say anything. The option test reads the masked copy, so a comment or a string that mentions
    // `patch:` is not mistaken for the option; the FileDiff/oldFile/newFile tests read the script
    // as written.
    const script = [...text.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)]
      .filter(([, attrs]) => !/application\/json/.test(attrs))
      .map(([, , body]) => body)
      .join("\n");
    const masked = maskJs(script);

    if (!/\bFileDiff\b/.test(script)) errors.push("no @pierre/diffs FileDiff call found (Section 3 would be empty)");
    if (/\bpatch\s*:/.test(masked))
      errors.push("`patch:` is not a FileDiff option and renders nothing; pass oldFile/newFile ({ name, contents })");
    if (/\bFileDiff\b/.test(script) && !(/\boldFile\b/.test(script) && /\bnewFile\b/.test(script)))
      errors.push("FileDiff is used without oldFile and newFile");

    const empty = text.match(/<div[^>]*class="(?:[^"]*\s)?kp-diff(?:\s[^"]*)?"[^>]*>\s*<\/div>/g);
    if (empty) errors.push(`${empty.length} diff container(s) are empty`);
  }

  if (!skipDiffs) {
    const m = text.match(/<script type="application\/json" id="kp-diff-data">([\s\S]*?)<\/script>/);
    if (m) {
      try {
        const data = JSON.parse(m[1]);
        const boxes = (text.match(/class="kp-diff"/g) ?? []).length;
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

  for (const h of proseHits(text, format)) errors.push(`${file}:${h.line}: ${h.rule} (${h.hint}): ${h.text}`);

  // Only a rendered page has a layout to judge: a `*.html` file with an `<html>` element. A
  // Markdown note that mentions `<html>` in prose is not one, and neither is a diff fragment.
  // The pass judges whether each rule is present, so a dossier finished before this rule existed
  // can fail it while measuring no overflow. That is intended, and not a bug to "fix" by
  // weakening the pass: criterion 5 of issue #108 was reworded to grandfather those pages, and the
  // owner's comment on that issue is the record. Every page in this repository keeps passing.
  const isPage = format === "html" && /\.(?:html?|xhtml)$/i.test(file) && /<html[\s>]/i.test(text);
  if (isPage) {
    for (const hit of styleParseHits(text)) errors.push(`${file}:${hit.line}: ${hit.msg}`);
    for (const hit of paletteHits(text)) errors.push(`${file}:${hit.line}: ${hit.msg}`);
    for (const hit of layoutHits(text)) errors.push(`${file}:${hit.line}: ${hit.msg}`);
    for (const hit of annotateHits(text)) errors.push(`${file}:${hit.line}: ${hit.msg}`);
  }

  if (errors.length) {
    for (const e of errors) process.stderr.write(`FAILED: ${e}\n`);
    process.exit(1);
  }
  process.stdout.write(skipDiffs ? `OK: ${file} has clean prose\n` : `OK: ${file} has renderable diffs and clean prose\n`);
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
  die("usage: kingpin report diffs [--repo <dir>] [--base <ref>] | kingpin report check [--prose-only] <file>");
}
