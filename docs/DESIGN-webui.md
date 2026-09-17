# Webui design: paper cockpit

<!-- impeccable:design-schema 1 -->

## World

The operator console is a **recompile paper spec sheet with one TMOG
terminal pasted to it**. Warm paper ground (`#f7f5f0`), white 10px cards
with one shadow token, a single green signal (`#0f5c37`) for actions and
live state, pills that carry state as words, sans that reads and mono
that is the machine. The tick chart and the console log are the one dark
terminal (`#101418`): grid, leading-edge markers, live lamp. Everything
else is paper or card. This refuses the dark-ops-dashboard default and
the tab-buried health answer.

## First viewport

The glance band answers "what is the state of the whole system right
now": server tick, players in world, tick p99 against the 50 ms budget
(with a meter that goes hot over budget), blood-moon state as a pill.
Below it the terminal deck carries the live tick tape; below that the
job-file record. The console is one section down, not one tab away.

## Decisions

- **Paper by day, no dark mode.** The scene is daylight ops on a laptop
  next to the game client; the pinned direction chose paper ground with
  the chart as the single terminal. `forced-colors` remaps everything.
- **Sans reads, mono is the machine.** Headings, labels, buttons, stats,
  table cells are sans; ids, source, listings, key names are mono.
  Tabular numerals on every comparable number.
- **State is words in pills**, never bare colour. `ok`/`warn`/`bad`
  pills in tables and the glance band; numeric alerts keep the
  `num warn-text`/`num err` classes on values.
- **Tables stack at ≤55rem** with `data-label` on every cell (the
  Label-Travels rule); wide ledgers keep `min-width:34rem` only at
  desktop widths.
- **TMOG chart grammar kept**: log-compressed history, right-edge live
  markers, faint grid, stacked section fills, scrub cursor, still frame
  under `prefers-reduced-motion`.
- **Accepted deviations**: detector `flat-type-hierarchy` (the mono
  micro-label system is deliberate); `.meter i` width transition (a 10px
  bar easing on 1s polls, disabled under reduced motion).

## Contract

Seed: `zdtd-direction` HTML comment at the top of `shell.html <body>`.
Cockpit answers first; terminal stays the only dark surface; one signal
green; every state a word; numbers beside every signal.
