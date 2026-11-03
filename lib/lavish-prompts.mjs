// Decode one `lavish-axi poll` response from stdin and classify its prompts.
// Usage: lavish-axi poll <report.html> | node lavish-prompts.mjs <task-id>
//
// Prints `status<TAB><status>` (feedback, ended, browser_disconnected, waiting,
// ...), then one line per prompt: `<kind><TAB><base64 text>`. kind is `approve`
// only when the whole prompt is an approval command; anything else, including
// every Request Changes and "do not approve yet", is `feedback`.
// Needs LAVISH_AXI_BIN (path of lavish-axi) to find the response decoder that
// ships with it; without the decoder it scans the text instead.
import fs from "node:fs";
import path from "node:path";

const taskId = process.argv[2] ?? "";

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export function classify(text, id) {
  const t = text.trim().replace(/^["'`]+|["'`]+$/g, "").trim();
  if (/^request[\s-]*changes\b/i.test(t)) return "feedback";
  const idPart = id ? `(?:\\s+${escapeRe(id)})?` : "";
  const approve = new RegExp(
    `^(?:kingpin\\s+land${idPart}|land\\s+${id ? escapeRe(id) : "\\S+"}|approve(?:\\s*(?:&|and)\\s*land)?${idPart})\\s*$`,
    "i",
  );
  return approve.test(t) ? "approve" : "feedback";
}

function unquote(s) {
  s = s.trim();
  if (s.startsWith('"')) {
    try {
      return JSON.parse(s);
    } catch {
      return s.slice(1, -1);
    }
  }
  return s;
}

async function loadDecoder() {
  const bin = process.env.LAVISH_AXI_BIN;
  if (!bin) return null;
  let real = bin;
  try {
    real = fs.realpathSync(bin);
  } catch {}
  const pkg = path.join(path.dirname(real), "..", "node_modules");
  for (const file of [
    path.join(pkg, "@toon-format", "toon", "dist", "index.mjs"),
    path.join(pkg, "axi-sdk-js", "node_modules", "@toon-format", "toon", "dist", "index.mjs"),
  ]) {
    if (!fs.existsSync(file)) continue;
    try {
      const mod = await import(file);
      if (typeof mod.decode === "function") return mod.decode;
    } catch {}
  }
  return null;
}

// Fallback when the decoder is missing: scan the `prompts` section.
function scan(text) {
  const lines = text.split("\n");
  const out = { status: "", prompts: [] };
  const st = lines.find((l) => /^\s+status:\s*\S/.test(l));
  if (st) out.status = unquote(st.replace(/^\s+status:\s*/, ""));
  if (lines.some((l) => /^\s+session_ended:\s*true\b/.test(l))) out.session_ended = true;
  const start = lines.findIndex((l) => /^prompts(\[\d+\])?(\{[^}]*\})?:/.test(l));
  if (start < 0) return out;
  const header = lines[start].match(/\{([^}]*)\}/);
  const fields = header ? header[1].split(",").map((f) => f.trim()) : null;
  const col = fields ? Math.max(0, fields.indexOf("prompt")) : 0;

  // The section body is everything after the header that is indented or blank.
  const body = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    if (lines[i].length && !/^\s/.test(lines[i])) break;
    body.push(lines[i]);
  }

  // Expanded form: a `- uid: "1"` line opens an item, and the `key: value`
  // lines one indent deeper are its fields. A nested block such as `target:`
  // puts its own keys deeper still, so they stay inside the item they belong
  // to instead of opening a prompt of their own.
  const opener = body.find((l) => /^\s*- \S/.test(l));
  if (opener) {
    const base = opener.match(/^\s*/)[0].length;
    const deeper = body.find((l) => l.match(/^\s*/)[0].length > base);
    const fieldAt = deeper ? deeper.match(/^\s*/)[0].length : base + 2;
    const itemRe = new RegExp(`^\\s{${base}}- (.*)$`);
    const fieldRe = new RegExp(`^\\s{${fieldAt}}([A-Za-z_][\\w-]*):\\s*(.*)$`);
    let cur = null;
    // Only an item that carries a `prompt` is the reviewer's message. An item
    // with `text:` and no `prompt:` is element text, and emitting it would set
    // parsed > 0 in the listener, so the response would never be parked and the
    // reviewer would never learn their message was not understood.
    const flush = () => {
      if (cur && cur.prompt !== undefined) out.prompts.push(cur);
    };
    for (const l of body) {
      const item = l.match(itemRe);
      if (item) {
        flush();
        cur = {};
        const first = item[1].match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
        if (first) cur[first[1]] = unquote(first[2]);
        continue;
      }
      const field = cur && l.match(fieldRe);
      if (field) cur[field[1]] = unquote(field[2]);
    }
    flush();
    return out;
  }

  // Compact form: the header names the columns, and each row is one prompt.
  if (!fields) return out;
  for (const l of body) {
    if (!/^\s{2}\S/.test(l)) continue;
    const cells = l.trim().split(/,(?=(?:[^"]*"[^"]*")*[^"]*$)/);
    out.prompts.push({ prompt: unquote(cells[col] ?? "") });
  }
  return out;
}

const raw = fs.readFileSync(0, "utf8");
let data = null;
const decode = await loadDecoder();
if (decode) {
  try {
    data = decode(raw);
  } catch {}
}
if (!data || typeof data !== "object") data = scan(raw);

const ended = data.session?.session_ended === true || data.session_ended === true;
console.log(`status\t${ended ? "ended" : String(data.session?.status ?? data.status ?? "")}`);
for (const p of Array.isArray(data.prompts) ? data.prompts : []) {
  const text = typeof p === "string" ? p : String(p?.prompt ?? p?.text ?? "");
  if (!text.trim()) continue;
  console.log(`${classify(text, taskId)}\t${Buffer.from(text, "utf8").toString("base64")}`);
}
