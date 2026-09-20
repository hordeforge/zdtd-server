---
name: zdtd operator console
description: Paper cockpit dashboard for the zdtd dedicated server
colors:
  paper: "#f7f5f0"
  paper-sunk: "#efece4"
  card: "#fffdf8"
  rule: "#e2ddd0"
  rule-strong: "#cfc8b6"
  control-line: "#5f686f"
  ink: "#1a1d21"
  ink-muted: "#4d545c"
  ink-faint: "#5f686f"
  signal: "#0f5c37"
  signal-ink: "#0c4a2d"
  signal-soft: "#dcefe1"
  warn-ink: "#6b4a00"
  warn-soft: "#f2dbaa"
  error: "#8a2318"
  error-ink: "#3d0d07"
  error-border: "#d59f96"
  error-soft: "#f5c9c2"
  terminal: "#101418"
  terminal-raised: "#1a2129"
  terminal-rule: "#2a333d"
  terminal-band-1: "#22303c"
  terminal-band-2: "#2c3f4e"
  terminal-text: "#d8e2dc"
  terminal-faint: "#7f8b94"
  terminal-key: "#ffd8a0"
  terminal-ok: "#5fd894"
  terminal-bad: "#ff7364"
  on-signal: "#ffffff"
  pill-ok-line: "#9cc6aa"
  pill-warn-line: "#cbab72"
  knob-shadow: "rgba(0,0,0,.25)"
typography:
  brand:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
    fontSize: "1.75rem"
    fontWeight: 700
    letterSpacing: "-0.02em"
  glance:
    fontSize: "1.7rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.02em"
  stat:
    fontSize: "1.25rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.01em"
  glance-compact:
    fontSize: "1.35rem"
    fontWeight: 700
    lineHeight: 1.2
  heading:
    fontSize: "1.05rem"
    fontWeight: 600
    letterSpacing: "-0.01em"
  field:
    fontSize: "1rem"
    fontWeight: 400
  body:
    fontSize: "0.95rem"
    fontWeight: 400
    lineHeight: 1.6
  body-tight:
    fontSize: "0.9rem"
    fontWeight: 400
    lineHeight: 1.6
  mono:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, Liberation Mono, monospace"
    fontSize: "0.88rem"
  meta:
    fontSize: "0.8rem"
    fontWeight: 400
  label:
    fontSize: "0.72rem"
    fontWeight: 600
    letterSpacing: "0.06em"
rounded:
  chip: "6px"
  tab: "8px"
  control: "9px"
  card: "10px"
  dot: "50%"
  pill: "999px"
spacing:
  cell: "0.9rem 1.1rem"
  card-pad: "1.1rem 1.25rem"
  stack: "1.25rem"
  page-pad: "1.5rem"
components:
  button-primary:
    backgroundColor: "{colors.signal}"
    textColor: "#ffffff"
    rounded: "{rounded.control}"
    padding: "0 1.25rem"
    height: "44px"
  button-secondary:
    backgroundColor: "{colors.card}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "0 1.1rem"
    height: "44px"
  tab-selected:
    backgroundColor: "{colors.signal-soft}"
    textColor: "{colors.signal-ink}"
    rounded: "{rounded.control}"
    padding: "0.45rem 0.7rem"
    height: "44px"
  pill-ok:
    backgroundColor: "{colors.signal-soft}"
    textColor: "{colors.signal-ink}"
    rounded: "{rounded.pill}"
    padding: "0.22rem 0.6rem"
  field:
    backgroundColor: "{colors.card}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "0.65rem 0.8rem"
    height: "44px"
  terminal:
    backgroundColor: "{colors.terminal}"
    textColor: "{colors.terminal-text}"
    rounded: "{rounded.card}"
    padding: "0.9rem 1rem"
---

# Design System: zdtd operator console

## Overview

**Creative North Star: "Paper Cockpit"**

The console is a printed spec sheet with one terminal pasted onto it. The
ground is warm paper, the cards are white, and a single green signal carries
"healthy, live, go". Everything the operator must trust is written down in
words next to its number: pills say `idle`, `ACTIVE`, `in world`, `set`, never
just a colour. The page refuses the dark-ops dashboard and it refuses burying
the health answer behind tabs; the whole-server reading is in the first
viewport, and the tabs only hold the long tail.

The one piece of darkness is the instrument panel: the tick chart and the
console log are the only black surfaces in the product, and they are black
because a terminal is. That split is the identity. A control room is a desk you
can read under a lamp; the screen inside the bezel is the machine.

The voice is dense and exact. Values are printed at the size a person reads a
gauge: large, tabular, monospaced where they are machine numbers, sans where
they are prose. Signals are never invented. When a reading is missing the page
says so rather than filling the space.

**Key Characteristics:**
- Warm paper ground, white cards, one green signal, no second accent.
- Exactly one dark surface family: the terminal, used only for the chart and the console log.
- State is a word in a pill; colour is confirmation, never the message.
- Gutters and hairlines instead of boxes and shadows: the layout is a ruled table.
- Numbers are monospaced and tabular; labels are small, uppercase, and letter-spaced.

## Colors

A warm neutral paper palette with one deep green signal and a dedicated terminal family for the instrument surfaces.

### Primary
- **Signal Green** (`#0f5c37`): the only accent. Primary buttons, the selected tab fill, the health lamp, the meter fill, and the "healthy" pill text. Used sparingly; when it appears it means "this is live and fine".
- **Signal Deep** (`#0c4a2d`): hover and border for signal-filled controls, and link text on paper.
- **Signal Wash** (`#dcefe1`): selected tab background and the `ok` pill fill.

### Neutral
- **Warm Paper** (`#f7f5f0`): the page ground.
- **Sunk Paper** (`#efece4`): table headers, deck heads, code chips, hover fills.
- **Card** (`#fffdf8`): every panel, control, and field background.
- **Rule** (`#e2ddd0`): hairline dividers and card borders.
- **Rule Strong** (`#cfc8b6`): heavier hairlines on pills and dense separators.
- **Control Line** (`#5f686f`): the only boundary colour on an interactive control. Anything a click target is drawn with uses this, so a control is never identified by a 1.6:1 hairline.
- **Ink** (`#1a1d21`), **Ink Muted** (`#4d545c`), **Ink Faint** (`#5f686f`): body, secondary, and metadata text.
- **Warning Ink** (`#6b4a00`) on **Warning Wash** (`#f2dbaa`): counters that have started to move.
- **Error Ink** (`#3d0d07`, 11.1:1) on **Error Wash** (`#f5c9c2`) for banners, and **Error** (`#8a2318`) for error text on paper.
- **Terminal** (`#101418`), **Terminal Raised** (`#1a2129`), **Terminal Rule** (`#2a333d`), **Terminal Band 1/2** (`#22303c`, `#2c3f4e`), **Terminal Text** (`#d8e2dc`), **Terminal Faint** (`#7f8b94`), **Terminal Key** (`#ffd8a0`), **Terminal OK** (`#5fd894`), **Terminal Bad** (`#ff7364`): the instrument family. The chart reads them at runtime, so they live in CSS and are re-read when forced-colors changes.

### Named Rules
**The One Terminal Rule.** Only the tick chart and the console log may be dark. A dark card anywhere else is a bug, not a variant.

**The Word Before Colour Rule.** A state is always written (`idle`, `ACTIVE`, `disabled`, `set`). Colour reinforces the word; it never replaces it.

**The 4.5 Floor Rule.** Every text pair in the shipped pages clears 4.5:1; body text on paper clears 7:1. A new pair below the floor is a defect, not a style choice.

## Typography

**Display Font:** system sans (`-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial`).
**Body Font:** the same system sans.
**Label/Mono Font:** system mono (`ui-monospace, SFMono-Regular, Menlo, Consolas, Liberation Mono`).

**Character:** the sans is paper and prose; the mono is the machine. The pairing does the work that colour does elsewhere: if it came off the wire, it is mono and tabular.

### Hierarchy
- **Brand** (700, 1.75rem, -0.02em): the sign-in wordmark. The only display-size type in the product.
- **Glance** (700, 1.7rem, 1.2, tabular): the four headline readings in the glance band; the largest type on the dashboard.
- **Glance compact** (700, 1.35rem): the same band below 30rem, where the cells stay two-per-row.
- **Stat** (700, 1.25rem, 1.2, tabular): the reading in every other stat cell.
- **Heading** (600, 1.05rem, -0.01em): section and card titles.
- **Field** (400, 1rem): control labels, inputs, and primary button text.
- **Body** (400, 0.95rem, 1.6) and **Body tight** (400, 0.9rem, 1.6): prose, table cells, deck subtitles, control text.
- **Mono** (0.88rem, tabular): tick counters, ports, coordinates, command output. Always paired with a sans label, never standing alone.
- **Meta** (400, 0.8rem): captions, hints, footers, table headers.
- **Label** (600, 0.72rem, 0.06em, uppercase): stat captions and stacked-table row labels.
- **Sign-in scale** (0.8rem / 1rem / 1.75rem): three steps only, so the login card reads as one calm column.

### Named Rules
**The Mono Means Machine Rule.** A number read from the server is monospaced and tabular. A sentence about it is sans.

**The One Reading Size Rule.** Each band has one dominant size. Two adjacent sizes that differ by less than 1.25x are the same size, and one of them should go.

## Layout

One column, `max-width: 1080px`, centred, with a sticky header and a sticky tab strip. Below the tabs the page is a vertical stack of white cards separated by `1.25rem`: the glance band, the tick tape (terminal chart plus job file), then the active panel. Gutters are ruled cells, not floating boxes: stat grids are `auto-fit` columns separated by 1px hairlines, so a row of readings reads as one table.

The glance band is four `minmax(150px, 1fr)` cells: server tick, players in world, tick p99 against the 50 ms budget with a meter, and blood-moon state. It is always present, in every tab, because the health answer must not be buried. Long panels (players, modules) scroll inside their own card rather than lengthening the page.

Breakpoints: at `55rem` the header unwraps and the tab strip becomes a horizontally scrolling rail with a mask fade at the right edge and scroll snapping, so the tabs past the fold are visibly reachable. At `30rem` the glance band keeps two columns (never one) and the type in it steps down, so the first viewport still reaches the panel. Dense tables switch to stacked rows below `55rem`: each cell becomes a label/value grid row whose label comes from `data-label` through a `::before`, and the header row is visually hidden rather than removed.

Spacing rhythm: `1.5rem` page padding, `1.25rem` between cards, `0.9rem 1.1rem` inside a stat cell, `1.1rem 1.25rem` inside a card body. Dense is correct here; the operator compares numbers, not sections.

## Elevation & Depth

Effectively flat, and deliberately so. Depth is tonal: paper ground, white card, sunk header band. Cards carry one shared shadow (`0 1px 2px rgba(26,29,33,.06), 0 8px 24px -12px rgba(26,29,33,.18)`) that reads as a lifted sheet of paper rather than a floating panel, and the terminal keeps the same shadow because it is pasted onto the same sheet.

### Named Rules
**The Ruled Sheet Rule.** Separate with a hairline before reaching for a shadow. A new nested card is a smell; a ruled row inside the existing card is the answer.

**The No-Glow Rule.** No coloured glow, no gradient, no blur. The only glow in the product is the 2px focus ring.

## Shapes

Gently rounded and rectilinear. Cards 10px, controls and fields 9px, tabs 8px, inline code chips 6px, status pills fully rounded (999px), the status dot 50%. The pill is the only fully rounded form, which is what makes a state word look pressable and separate from a reading. Borders are hairlines: cards and dividers use Rule, interactive controls use Control Line, and the terminal uses Terminal Rule. Nothing is clipped or masked except the mobile tab rail's edge fade.

## Components

### Buttons
- **Shape:** rounded rectangle (9px), 44px minimum height, 0 1.1rem to 0 1.25rem padding.
- **Primary:** signal green fill, white text, signal-deep border. The login submit, the console Run button, and modlet actions use it. One per surface.
- **Secondary:** card fill, ink text, Control Line border. Refresh, the quick-command chips, and Show/Hide.
- **Hover / Focus:** hover deepens the fill (sunk paper for secondary, Signal Deep for primary); focus is always a 2px signal outline with 2px offset and never removed.
- **Disabled:** 0.45 opacity with a not-allowed cursor; the label says what is happening instead of going blank.

### Chips
- **Style:** status pills: small uppercase-weight word, Signal Wash for ok, Error Wash for bad, Warning Wash for warn, `999px` radius.
- **State:** always a word first. Pills appear beside the reading they describe, never as the only marker of state.

### Cards / Containers
- **Corner Style:** 10px.
- **Background:** Card white on Warm Paper.
- **Shadow Strategy:** the single shared paper shadow.
- **Border:** 1px Rule.
- **Internal Padding:** 1.1rem 1.25rem for bodies, 0.9rem 1.1rem for stat cells.

### Inputs / Fields
- **Style:** Card fill, Control Line border (1.5px), 9px radius, mono text for secrets and commands.
- **Focus:** 2px signal outline, offset 1px, border shifts to signal.
- **Error / Disabled:** error border plus a soft error ring, and the outline turns error-coloured while focused, so a focused invalid field is not mistaken for a normal one.

### Navigation
Tabs are text buttons on paper with a number prefix (`01 Status`). Selected tabs take Signal Wash, Signal Deep text, an underline, and heavier weight; unselected tabs are Ink Muted. Keyboard behaviour follows the tabs pattern: one tab stop, arrow keys on both axes, Home and End, `aria-selected` and `aria-controls` kept in sync. The tablist lives inside a `nav` landmark, because `role="tablist"` on the `nav` itself would replace the landmark role. On mobile the rail scrolls horizontally with a mask fade.

### Terminal surfaces (signature)
The tick chart and the console log: Terminal ground, Terminal Rule hairline, mono text, Terminal Text for output, Terminal Faint for meta and prompts, Terminal OK / Terminal Bad for command outcomes, Terminal Key for the 50 ms budget line on the chart. The chart's palette is read from these tokens at runtime and re-read when forced-colors changes, so high-contrast mode does not leave a hand-picked green behind.

## Do's and Don'ts

### Do:
- **Do** keep the glance band in every tab; health never hides behind navigation.
- **Do** derive one connection state and let the lamp, the word, the chart caption and the banner all read it. Lost contact reads as a neutral "connecting" lamp before the first poll, then an error-toned "no contact"; a stale chart says it is showing last samples instead of reprinting the last good numbers.
- **Do** write the state as a word and let the pill colour confirm it.
- **Do** draw interactive control boundaries with Control Line so every control clears 3:1 against its surface.
- **Do** use mono + tabular figures for anything that came off the wire, and sans for the sentence around it.
- **Do** keep 44px minimum targets and a 2px visible focus ring on everything focusable, including the chart canvas.
- **Do** honour `prefers-reduced-motion` (flash, meter, and toggle motion all stop) and `forced-colors` (tokens remap, canvas palette re-reads).
- **Do** keep the tokens and sign-in chrome in `src/server/webui/shared.css`; `scripts/build-webui-ts.sh` splices the regions into the pages and `scripts/lint-webui.sh` fails when a page drifts from it or a token goes unused.

### Don't:
- **Don't** add a second accent colour, a gradient, a glow, or a coloured shadow.
- **Don't** make any surface dark except the terminal.
- **Don't** animate layout properties; move transforms and opacity.
- **Don't** identify a control by a Rule Strong hairline on its own fill; that is 1.6:1.
- **Don't** introduce a font size within 1.25x of its neighbour in the same band.
- **Don't** let a state exist only as colour, and don't let a failure pass without a line of text saying what happened.
