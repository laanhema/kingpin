# Kingpin dossier: the fleet's one Lavish template

Built from the case-file page the operator approved after a long review loop. The page it came
from carried one task's diffs, screenshots and prose; this folder is the same look with sample
content, and the source task's data is gone. Copy a page, swap the content, keep the chrome.

```
kingpin-dossier/
  template.html   a worker's report.html: hero, telegram, stat cards, what changed, acceptance, review, validation, diffs
  handover.html   a page handed over for a decision: proposal, comparison, plan or review summary, with decision forms
  hero.jpg        the banner, copied from the repo's assets/kingpin.jpg
  DESIGN.md       these rules, beside the files they describe
```

Every page the fleet hands over starts here. `template.html` is a worker's `report.html` and the
curator's report page. `handover.html` is anything the boss reads and answers: a proposal, a
comparison, a plan, a review summary. Both share one look, so a report and a proposal read the
same way.

The older folders stay shipped. `assets/lavish/worker-dossier/` holds the dark GitHub look and
stays for pages already made from it. `assets/lavish/noir-dossier/` holds the first parchment
experiment and stays for reference. New pages use this folder.

## Palette

Paper on ink. The page is deep ink with a faint grain, and every panel is a sheet of parchment.
Never flip it: the contrast between the dark room and the paper is the look.

| Token | Value | Job |
|---|---|---|
| `--ink` | `#12100c` | page background |
| `--ink-2` | `#1b1813` | the darkest panel edge |
| `--paper` | `#efe6d2` | panels, cards, the brief sheet |
| `--paper-2` | `#e7dcc4` | table heads and inset rows |
| `--code-tint` | `#ddcfab` | the chip behind inline code |
| `--ink-on-paper` | `#1b1712` | text on a sheet |
| `--sepia` | `#6f5a40` | labels, notes, muted text |
| `--blood` | `#7d2020` | emphasis, links, the stamp |
| `--gold` | `#a8863a` | the kicker and link hover |
| `--pass` | `#2d4a24` | pass and approve |
| `--warn` | `#6b4a10` | partial and medium |

The brief section is one sheet of `var(--paper)`. Inside it, the telegram strip is the lighter
`#f3ecd6` sheet, which is why the action bar reads as a separate slip of paper laid on the brief.
Keep both values as they are: the difference is what makes the strip read as a telegram.

## The nine decisions

1. **Paper on ink.** `body` is ink with a faint grain, and every panel is a parchment
   `.card-custom` with a 1px inner rule. The brief section is one sheet holding the telegram, the
   tape labels, the summary and the four stat cards.
2. **Hero.** A framed picture at the top, a sideways `NOIR EDITION · NOT FILED` stamp in its
   corner, a `CASE FILE · WORKER DOSSIER` kicker in Special Elite, the title in Playfair Display
   (uppercase, one word in `em` in blood red), and a standfirst in 16.5px serif. The picture is
   `hero.jpg`, shipped beside the page and referenced as `src="hero.jpg"`.
3. **Four faces, each with one job.**
   - Source Serif 4 carries all reading text: 17px/1.6 body, 12px notes, section headings at
     22px to 28px and weight 700 with 1.25rem under them, change headings at 17.5px and weight
     700 with 11px under them, and the `Problem:` and `Solution:` lead-ins at 15.5px and weight
     800.
   - Special Elite carries every label: the kicker, the tape labels (`.kp-label`, filled and
     dashed outline), the stamps (`.kp-stamp`, `.kp-stamp.lg`), card labels, table heads,
     `MODIFIED` badges, figure captions, the telegram title and the buttons.
   - Commit Mono carries inline code chips and commands, at `.85em` on the warm `#ddcfab` chip
     and with no fill on the dark code panel. It loads from `@fontsource/commit-mono` 400 and 700
     on jsDelivr. Courier Prime is the fallback only.
   - Playfair Display carries the hero title and nothing else.

   Every face loads from a `<link>` in `<head>`. Never an `@import`: an import placed after a
   rule is dropped by the browser, and the whole page falls back without a word.
4. **Labels are typewriter, and so are tables.** Card labels and table heads are the same 10.5px
   Special Elite with `.16em` tracking in sepia. The rule that closes a table is
   `1px solid rgba(111,90,64,.7)`, the sepia of the note under it, so the note and its closing
   line read as one aside.
5. **Buttons are stamped.** A double-rule outline in the pass green or the blood red, with a
   slight opposing tilt. Hover deepens the button's own ink (`rgba(45,74,36,.17)` for green,
   `rgba(125,32,32,.15)` for red), never a neutral grey.
6. **Code Changes is the one dark region.** No panel behind the section, so the ink shows between
   the file rows. Each diff is its own `#0d1117` block with a `#30363d` border, the file row in
   Special Elite at 15px in real case with an 11px outlined badge.
7. **Links carry the stamp red**, a hairline underline in the same colour, and gold on hover, at
   body weight.
8. **Headings sit under a 2px ink rule** in the brief, and clear their content below it.
9. **Decision controls keep their handlers.** Both pages keep `kpAction` and `kpRequestChanges`
   with the no-Lavish fallback, because `kingpin land` and the retire path depend on them.

## The retire hook

`lib/dossier-finish.mjs` hides every element that carries `data-kp-finished-hide` when it marks a
finished page. On `template.html` the hook sits on the telegram (which holds both action buttons) and
on the status stamp, so a retired worker dossier loses its decision chrome and keeps its result. The
helper also strips the handler from any button that calls `kpAction` or `kpRequestChanges`, so nothing
on that page can queue a prompt after the task is archived. Keep the hook when you copy
`template.html`. `handover.html` carries no hook, because a handover is not the page `kingpin done`
retires: its decision forms keep `kpAnswer` and the queue path that answers them.

## Diffs

`Code Changes` goes through `@pierre/diffs`. `FileDiff` takes `oldFile` and `newFile`, each
`{ name, contents }`. It has no `patch` option: `render({ containerWrapper, patch: diffString })`
returns without rendering and leaves the section blank. Build the section with
`bin/kingpin-report diffs`, which prints the whole block in the shape the page needs.

- `themeType: "dark"`, with the `github-light` and `github-dark` pair.
- `overflow: "wrap"`, so a long line wraps inside its block instead of scrolling sideways.
- `diffStyle` is `split` at 1000px and wider, and `unified` below it. The renderer repaints on the
  breakpoint through a `change` listener, because the choice is made once per paint.
- `diffIndicators` stays at its default `bars`.
- Every diff keeps its static `<pre class="kp-fallback">`, so the page still reads with no
  network. The renderer hides the fallback once it has painted.
- `kp-diff-data` holds one JSON entry per diff block, with `name`, `oldContents` and
  `newContents`. A block and its entry change together, or `kingpin-report check` fails.

The handover page has no diff section at all, so it passes
`bin/kingpin-report check --prose-only`, while `template.html` takes the full check with its diff
checks.

## Handover pages

`handover.html` has the same chrome, palette, hero, stat cards, tables and stamp vocabulary as
`template.html`, and adds these parts:

- **A telegram that asks.** The same parchment strip, with the round seal showing `?`, the title
  `Decision needed`, the question count as its command line, the two stamped buttons and a
  `Go to the decisions` link. The badge row starts with the page kind (`Proposal`) and a
  `Decision Needed` stamp.
- **Callouts.** `.callout` is a sepia left-bordered note for the point of a section,
  `.callout.rec` is green for a recommendation, and `.callout.warn` is amber for a risk that
  needs a decision. At most one per section.
- **Option cards and one comparison table.** Three cards side by side, exactly one marked
  `RECOMMENDED`, then one table with a stamp per cell. Do not repeat the same facts in both.
- **Decision forms.** One `<form data-lavish-question>` per question at the bottom, built from
  `.q-option` rows (a radio or a checkbox), an optional note and a `Queue answer` button. Radio
  questions use `name="choice"`; a tick list sets `data-kind="batch"` and uses `name="items"`.
  The shared `kpAnswer` script queues one prompt per form, and without Lavish it prints the answer
  to paste into chat.
- **Diagrams are inline SVG.** One concept per figure, drawn in the page palette, with a
  `<title>` on every group so the boss can annotate it. No Mermaid and no div-and-arrow boxes.

For a review summary, keep the hero, the telegram, What Is Wrong Today, the findings table and
one decision form. Drop How It Would Work, the options and the risks.

## Fit the box

A dossier is read in a browser, so it has to hold its box at two widths. Open it with
`<html lang="en" data-lavish-annotate="off">`: annotation starts off because the reader is
usually reading, and the Lavish toolbar still turns it on when a review wants comments.

The stylesheet carries the overflow rules `worker/preamble.md` requires: `min-width: 0` on
everything, wrap rules on `pre`, `code`, `table`, `th`, `td` and `img`, and a `table-layout:
fixed` table with a `<colgroup>` of percentage widths. Grid and flex children need
`min-width: 0` or `minmax(0, 1fr)` tracks, or a long path refuses to shrink and pushes the page
wider. Check the finished page at 1280 and at 1024 wide: at both,
`document.documentElement.scrollWidth === document.documentElement.clientWidth`, and no element
is wider than its container.

`bin/kingpin-report check` fails on the mechanical causes and names the line: a `pre` or inline
`code` with no wrap rule, an `img` with no `max-width`, a table whose cells have none, a grid or
flex layout with no shrink guard, an asset path that is absolute or climbs out with `..`, a
declaration at the top level of a `<style>` block, a dark `color-scheme` claim with no background
on `body`, `html` or `:root`, and an `<html>` element with no `data-lavish-annotate`. Fix the line
it names. `overflow: hidden`, a narrower font or a shortened value is not a fix.

## Using it

1. Copy `template.html` to the task folder as `report.html`, or `handover.html` into the
   artifact's `.lavish/` folder, and copy `hero.jpg` beside the copy: both pages load the hero by
   relative path, so a page copied alone ships a broken banner.
2. Change the `<title>` first: a copy keeps the last page's title until someone notices. Then
   replace every `REPLACE` comment and every sample value: task id, branch, counts, rows,
   findings, screenshots.
3. Replace the sample diff section with the output of `bin/kingpin-report diffs`, and keep
   `kp-diff-data` in step with it.
4. Run the `unslop` skill over the page, then `bin/kingpin-report check` for a page with diffs
   and `bin/kingpin-report check --prose-only` for one without.
5. Open it with `lavish-axi <file>`.

`tests/test-kingpin-dossier-template.sh` fails when the folder loses a file, when a page loses a
rule from the nine decisions, when a diff loses its static fallback, when a decision form loses
its handler or its no-Lavish message, when either page stops passing its check, when the prose
regresses, or when the preambles stop pointing at this folder.
