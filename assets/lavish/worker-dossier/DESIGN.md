# Worker dossier: the shared report template

Built from the dossiers picked as the clearest in the archive, by choosing the best version of each
section: the header and stat cards from the new template, What Changed and Why and Code Changes from
`kingpin-4`, and Review Verdict and Every Finding plus Validation from `kp-fix-laanhema-skills`. This
folder is that design with sample content. Copy `template.html`, swap the content, keep the chrome.

```
worker-dossier/
  template.html   a worker's report.html: action bar, stat cards, what changed, review, validation, diffs
  handover.html   a page handed to the boss: proposal, comparison, plan or review summary, with decision forms
  DESIGN.md       these notes, beside the files they describe
```

It has no local assets, so it is one file. A screenshot section is included as a comment; copy the
images beside the report and use relative `src` paths.

## When to use it

`template.html` is a worker's `report.html` at the end of a task. `handover.html` is every page you
hand the boss to read and decide on. Both share one look, so a report and a proposal read the same
way. `assets/lavish/noir-dossier/` is a different, parchment look that stays in the repo for later;
nothing uses it by default.

## Rules that make it work

- **Stack.** Tailwind v4 browser build and DaisyUI v5 from the pinned CDN versions in `<head>`,
  plus one small `<style>` block. Keep the versions pinned; an unpinned CDN changes every old report.
- **Dark theme, set twice.** `<html data-theme="dark">` selects DaisyUI's dark theme, so badge colours
  (the task id pill is `badge-primary`) are the same in every browser. `color-scheme: dark` in the
  stylesheet paints the page `#0d1117` with text `#e6edf3`. Panels are `#161b22` with a `#30363d`
  border. No light variant. Dropping `data-theme` changes the pill colour.
- **Two components.** `.card-custom` is every panel and stat card. `.diffbox` (also applied to each
  `.kp-diff`) is the bordered frame around a diff. The look comes from Tailwind utilities on these.
- **Narrow column.** `max-w-5xl`, sections stacked with `space-y-8`, title-case `h2` headings.
- **Colour means status.** Emerald for pass, approve, fixed and Low severity. Amber for partial, medium findings and
  uncommitted work. Red for fail and critical or high findings. Blue for links. Do not use these
  colours for decoration.
- **Badges carry state.** `badge-success`, `badge-warning`, `badge-error` for results and severities (green
  Low, amber Medium, red Critical and High), `badge-ghost` (no colour) for N/A and `none`, `badge-outline` for neutral facts like the branch, `badge-primary` for the
  task id. Table rows use `badge-xs`.
- **The first screen answers three things.** Where the work stands (action bar), what it did
  (`h1` and one-line summary) and whether it is safe (four stat cards: Review Verdict, Validation,
  Files Modified, Git State).
- **Section order is fixed.** Action bar and header, What Changed and Why, Review Verdict and Every
  Finding, Validation, Before and After (visual changes only), Code Changes. Drop a section when the
  task has nothing for it; do not reorder.
- **What Changed and Why is numbered.** One `h3` per area of change ("1. ..."), each with a Problem
  paragraph and a Solution paragraph, then the Acceptance Criteria Verification table (Criterion,
  Status, Verification Method).
- **Tables set their column widths.** The overflow block uses `table-layout: fixed`, which splits columns equally unless told otherwise, so each table starts with a `<colgroup>` of percentage widths (narrow Pass, ID and Severity columns, a wide Finding column). Keep it when you add or remove a column.
- **Rows line up on one baseline.** Cells use a `1.25rem` line box and pills are centred on it with a small top margin. Put mono text such as an ID in a `<span class="font-mono">` inside the cell, not on the `<td>`, so its font does not move the baseline.
- **Every finding is a table row.** Pass, ID, Severity, Finding, Outcome. The ID stays with a finding
  across re-reviews. A last row with ID `none` and outcome `APPROVE` closes a clean review.
- **Validation is a table too.** Check, Result, Detail, one row per check, then at most one `text-xs`
  line for anything the table does not say.
- **Code Changes follows `kingpin-4`.** An `h2` with `text-2xl`, then per file a row with the path on
  the left and a small outlined badge on the right, and the diff in a bordered frame. The CSS in
  `<style>` shapes the output of `kingpin-report diffs` into that look, so paste the helper's section
  as is.
- **Fit the box.** The `<style>` block carries the overflow rules `worker/preamble.md` requires:
  `min-width: 0` on everything, wrap rules on `pre`, `code`, `table`, `th`, `td` and `img`. Check at
  1280 and 1024 wide. A pill in a table cell wraps too: `td > .badge` gets `white-space: normal`,
  `max-width: 100%`, `height: auto` with `min-height: var(--size)` and `line-height: 1.4`, so a short
  badge keeps its 1rem height on the row baseline and a long label grows the pill instead of spilling
  past its border. Badges outside a cell are unchanged, because the selector names `td > .badge`.
- **Annotation starts off.** `data-lavish-annotate="off"` is the reading default the worker contract asks for, so a stray click leaves no annotation card. The Lavish toolbar still turns annotation on when the boss wants to comment. The two action buttons are native buttons, so they work either way.
- **Buttons degrade.** Approve & Land and Request Changes call `window.lavish.queuePrompt` and fall
  back to copying the text when the page is opened as a plain file.
- **A finished page drops the decision chrome.** The action bar and the READY FOR REVIEW badge carry
  `data-kp-finished-hide`; the finished banner's stylesheet hides every element with that hook. Leave
  the hook on them when you copy the template.

## Using it

1. Copy `template.html` to the task folder as `report.html`.
2. Replace each `REPLACE` comment and every sample value (task id, branch, counts, rows, findings).
3. Replace the sample diff section with the output of `bin/kingpin-report diffs`.
4. Run the `unslop` skill, then `bin/kingpin-report check report.html`.

The shipped `template.html` passes `bin/kingpin-report check`. `check` ignores comments, so the
how-to block at the top does not trip the prose pass.

## Handover pages

`handover.html` has the same stack, palette, header, stat cards, badges, tables and `Code Changes`
style as `template.html`, and adds four things:

- **A decision header.** The action bar says what is needed ("Decision needed: 2 questions at the
  bottom") with an amber `?` circle and a `Go to the decisions` link, instead of Approve & Land. The
  badge row starts with the page kind (`PROPOSAL`, `REVIEW SUMMARY`) and a `DECISION NEEDED` or
  `APPROVE` status.
- **Callouts.** `.callout` is a blue left-bordered note for the point of a section, `.callout.rec`
  is green for a recommendation, `.callout.warn` is amber for a risk that needs a decision. One per
  section at most.
- **Option cards and one comparison table.** Three cards side by side, exactly one marked
  `RECOMMENDED`, then one table with a pill per cell. Do not repeat the same facts in both.
- **Decision forms.** One `<form data-lavish-question>` per question at the bottom, built from
  `.q-option` choice rows (DaisyUI `radio` or `checkbox`), an optional note and a `Queue answer`
  button. Choice questions use `name="choice"`; a tick list sets `data-kind="batch"` and uses
  `name="items"`. The shared `kpAnswer` script queues one prompt per form through
  `window.lavish.queuePrompt`, and without Lavish it shows the answer to paste into chat. The
  page carries `data-lavish-annotate="off"`, as every decision page does.
- **Diagrams are inline SVG.** One concept per figure, drawn in the page palette, with a `<title>` on
  every group so the boss can annotate it. No Mermaid and no div-and-arrow boxes.

For a **review summary**, keep the header, What You Need to Know, the findings table, the checks table
and one decision form (for example Land it, Land it after I read the diff, Request changes). Drop How It
Would Work, the options, the risks and The Change.

A handover page goes through the `unslop` skill and `bin/kingpin-report check <file>` before it is served,
exactly like a worker dossier (`--prose-only` when the page has no diff section). Step 5 of the how-to
comment at the top of `handover.html` says so.
