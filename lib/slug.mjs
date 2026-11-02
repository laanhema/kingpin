// Turn a title or request into a short slug for task IDs, branches and windows.
// Usage: node slug.mjs <text...>
// Prints up to 3 lowercase alphanumeric words joined by dashes (stop words
// dropped, at most 24 characters), or an empty line when the text has no
// usable word. Always exits 0.
const MAX_WORDS = 3;
const MAX_CHARS = 24;
const STOP_WORDS = new Set(
  "a an the of to for and or in on with from by is are be it its as at that this when how into via".split(" "),
);

const words = process.argv
  .slice(2)
  .join(" ")
  .normalize("NFKD")
  .replace(/\p{M}/gu, "")
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, " ")
  .split(" ")
  .filter(Boolean);

let slug = "";
let count = 0;
for (const word of words.filter((w) => !STOP_WORDS.has(w))) {
  if (count >= MAX_WORDS) break;
  const next = slug ? `${slug}-${word}` : word;
  if (next.length > MAX_CHARS) break;
  slug = next;
  count += 1;
}
if (!slug && words.length > 0) slug = (words.find((w) => !STOP_WORDS.has(w)) ?? words[0]).slice(0, MAX_CHARS);
console.log(slug);
