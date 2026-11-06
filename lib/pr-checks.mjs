// Classify the check rollup of a pull request.
// Usage: gh pr view <url> --json statusCheckRollup | node pr-checks.mjs
// Reads {"statusCheckRollup": [...]} on stdin and prints one word, PASSED, FAILED or
// PENDING; for FAILED a second line holds the comma-joined names of the failing
// entries. A check run carries `status` and `conclusion`, a commit status carries
// `state`. An empty or missing rollup is PASSED: a repository with no checks has
// nothing red to report. Invalid input exits 1 with a message on stderr.
import { readFileSync } from "node:fs";

const FAILED_CONCLUSIONS = new Set([
  "FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE",
]);
const FAILED_STATES = new Set(["FAILURE", "ERROR"]);
const PENDING_STATES = new Set(["PENDING", "EXPECTED"]);

let doc;
try {
  doc = JSON.parse(readFileSync(0, "utf8"));
} catch (err) {
  console.error(`pr-checks: not valid JSON: ${err.message}`);
  process.exit(1);
}
const rollup = doc && typeof doc === "object" ? doc.statusCheckRollup : undefined;
if (rollup !== undefined && rollup !== null && !Array.isArray(rollup)) {
  console.error("pr-checks: statusCheckRollup is not a list");
  process.exit(1);
}

const upper = (v) => (typeof v === "string" ? v.toUpperCase() : "");
const failed = [];
let pending = false;
for (const entry of rollup ?? []) {
  if (!entry || typeof entry !== "object") continue;
  const conclusion = upper(entry.conclusion);
  const state = upper(entry.state);
  const status = upper(entry.status);
  if (FAILED_CONCLUSIONS.has(conclusion) || FAILED_STATES.has(state)) {
    failed.push(String(entry.name ?? entry.context ?? "unnamed").replace(/[\s,]+/g, " ").trim());
  } else if ((status !== "" && status !== "COMPLETED") || PENDING_STATES.has(state)) {
    pending = true;
  }
}

if (failed.length > 0) {
  console.log("FAILED");
  console.log(failed.join(","));
} else {
  console.log(pending ? "PENDING" : "PASSED");
}
