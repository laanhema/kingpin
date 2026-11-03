# Noir dossier: the Lavish template

Saved from the ranks proposal the boss liked (2026-11-03). Copy this folder, rename the html,
swap the content, keep the chrome.

```
noir-dossier/
  template.html   the page, with exhibits A–F and working input forms
  kingpin.jpg     the banner, copied from the kingpin repo's assets/kingpin.jpg
  DESIGN.md       these notes, beside the file they describe
```

The tracked copy is `assets/lavish/noir-dossier/` in the Kingpin repo, and it is the one to copy.
`tests/test-noir-template.sh` fails when one of the three files is missing, when `template.html`
reaches a file by an absolute path or through `..`, when a diff block loses its static fallback, or
when the page stops passing `bin/kingpin-report check` (`DESIGN.md` takes `--prose-only`).

## When to use it

Handover artifacts for the boss: proposals, plans, comparisons, review summaries, anything that
would otherwise be a wall of chat. Not for worker review dossiers: those come from
`worker/preamble.md` and `bin/kingpin-report diffs`, which own their own layout.

## Rules that make it work

- **Paper on ink.** Page is deep ink (`--ink: #12100c`), panels are parchment (`--paper: #efe6d2`)
  with a thin inner rule. Never flip it: the contrast between the dark room and the paper is the look.
- **Type is the costume.** `Playfair Display` 900 for display headings, `Special Elite` for labels,
  exhibit names, code and the stamp, `Source Serif 4` for body. Do not swap in a UI sans.
- **One accent.** Blood red (`--blood: #7d2020`) for emphasis and the stamp; gold (`--gold: #a8863a`)
  only for the kicker. No third accent.
- **Exhibits.** Each section opens with `EXHIBIT X · WHAT IT IS` in typewriter caps, then a
  sentence-case `h2`, then the content. It gives the page a spine and lets the boss cite sections.
- **Banner.** The repo image across the top with the rotated outline stamp (`DRAFT · NOT FILED`).
  Change the stamp text per artifact; keep it rotated and outlined, never filled.
- **Diagrams are inline SVG**, hand-authored, one concept per figure, `<title>` on every group so
  reviewers can annotate precisely. No Mermaid, no div-and-arrow boxes.
- **Code goes through `@pierre/diffs`.** Light theme pair (`github-light` on `themeType: "light"`)
  so it sits on the parchment without fighting it. Every `.diff-surface` keeps a static
  `<pre class="diff-fallback">` copy of its diff: the script hides it once the renderer fills the
  surface, and a reader with no CDN sees the change instead of an empty strip. Change both together.
- **Decisions are forms** at the bottom, one form per question, `data-lavish-question`, a Queue
  answer button per form, `data-lavish-annotate="off"` on `<html>`.
- **Prose passes the unslop pass** before it is served: state the point, cut the puffery, no em dash
  carpet-bombing, no rule-of-three reflex.

## Filling it in

1. Copy the folder to the session's `.lavish/` or a scratch dir with the image beside the html.
2. Change the `<title>` and the hero kicker first: a copy inherits the previous artifact's title
   until someone notices. Then replace the hero copy, the exhibits, and the SVG with this
   artifact's content. Delete exhibits you do not need; keep the order and the labels.
3. Keep the two form handlers if you are asking questions; delete both forms and the script block if
   you are not.
4. Check it at 1180 wide and at 480 wide; nothing may scroll sideways.
5. `lavish-axi <file>`, then poll with a one-line agent reply.
