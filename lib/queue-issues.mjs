// Read the issue JSON `gh` prints for the issue-queue runner (bin/kingpin-queue).
// Usage: gh issue list --json number,labels | node queue-issues.mjs unclaimed
//        gh issue view <n> --json state,labels | node queue-issues.mjs state
// `unclaimed` reads a list and prints, sorted numerically and one per line, the number of
// every issue that does not carry the claim label. `state` reads one issue and prints
// CLAIMED for an open issue that carries the label, and gh's own state (OPEN, CLOSED, ...)
// otherwise. The claim label is what a worker that files its own issue puts on it in the
// create call, so the runner never spawns a second worker for it (issue #257). Invalid
// input exits 1 with a message on stderr, and an unknown mode exits 2.
import { readFileSync } from "node:fs";

const CLAIM_LABEL = "kingpin:claimed";

const mode = process.argv[2];
if (mode !== "unclaimed" && mode !== "state") {
  console.error("queue-issues: usage: node queue-issues.mjs unclaimed|state < gh-json");
  process.exit(2);
}

let doc;
try {
  doc = JSON.parse(readFileSync(0, "utf8"));
} catch (err) {
  console.error(`queue-issues: not valid JSON: ${err.message}`);
  process.exit(1);
}

const claimed = (issue) =>
  Array.isArray(issue.labels) &&
  issue.labels.some((label) => label && typeof label === "object" && label.name === CLAIM_LABEL);

if (mode === "unclaimed") {
  if (!Array.isArray(doc)) {
    console.error("queue-issues: unclaimed needs a list of issues");
    process.exit(1);
  }
  const numbers = doc
    .filter((issue) => issue && typeof issue === "object" && Number.isInteger(issue.number) && issue.number > 0)
    .filter((issue) => !claimed(issue))
    .map((issue) => issue.number)
    .sort((a, b) => a - b);
  if (numbers.length > 0) process.stdout.write(`${numbers.join("\n")}\n`);
} else {
  if (!doc || typeof doc !== "object" || Array.isArray(doc) || typeof doc.state !== "string") {
    console.error("queue-issues: state needs one issue with a string state");
    process.exit(1);
  }
  const state = doc.state.toUpperCase();
  process.stdout.write(`${state === "OPEN" && claimed(doc) ? "CLAIMED" : state}\n`);
}
