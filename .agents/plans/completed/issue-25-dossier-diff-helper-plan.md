# Plan: Standardize dossier diff generation (#25)

## Problem
Workers render dossier diffs with `new FileDiff(opts).render({ patch })`; `@pierre/diffs` needs `oldFile`/`newFile`, so Section 3 rendered blank.

## Approach (all three proposed solutions)
1. `worker/preamble.md`: add the verified `oldFile`/`newFile` snippet, a warning that `patch:` is invalid, and a pointer to the helper. `bin/kingpin-spawn` substitutes a new `{{KP_ROOT}}` so workers can call the helper by absolute path.
2. `lib/report-diffs.mjs` + `bin/kingpin-report` (+ `kingpin report` dispatch):
   - `diffs [--repo d] [--base ref]`: HTML fragment, one container per changed file. Each container holds a static unified-diff fallback, visible until Pierre has rendered. A JSON block carries name/oldName/oldContents/newContents; a module script renders FileDiff with oldFile/newFile.
   - `check <report.html>`: gate. Fails on `patch:`, FileDiff without oldFile/newFile, no FileDiff, empty containers, bad or mismatched JSON data.
3. Preamble tells workers to run `check` before appending `ready:`.

## Tasks
- [x] lib/report-diffs.mjs, bin/kingpin-report, dispatch and usage in bin/kingpin
- [x] preamble and `{{KP_ROOT}}` substitution in kingpin-spawn
- [x] tests/test-report.sh, README and README command table
- [x] Validate: run tests, render the generated fragment in Chrome and confirm non-empty diffs
