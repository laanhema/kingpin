# Implementation report: issue #11

**Status**: COMPLETE

Files: `bin/kingpin-done`, `tests/test-automation.sh` (uncommitted on `kingpin/kingpin-11`).

Validation: `tests/test-automation.sh`, `test-acceptance.sh`, `test-harnesses.sh`, `test-report.sh`, `test-worker-settings.sh` all PASS. `bash -n bin/kingpin-done` PASS. shellcheck not installed (N/A). Test 16 was run against the old `kingpin-done`: the switched-branch and remote-deletion assertions FAIL there, PASS with the change.

Deviations: none. `--force` deletes the local branches but not the remote branch, since the merge check is skipped and nothing is verified.
