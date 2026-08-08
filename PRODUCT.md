# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

> Primary-user inference (brief "init" without an interview answer; inferred from
> docs/WEBUI.md, AGENTS.md and the repo layout, disclosed here).

Primary user: the operator of a zdtd (Zeven Days to Die) dedicated server,
which is a clean-room Zig rewrite of the 7 Days to Die dedicated server wire
(EAC off). Two concrete operator situations, same surface:

- The zdtd developer/researcher running local or lab servers, checking tick
  budget, joins, peers, chunk streaming, apm counters, and issuing console
  commands from a browser instead of telnet.
- A 7DTD dedicated-server operator who runs zdtd and wants a loopback-secure
  browser dashboard next to the existing admin TCP console.

Their job on a normal day: glance at the dashboard, confirm the server is
healthy and in budget, act safely (kick, give, teleport, settime) when needed,
and read the effective serverconfig without editing files blindly.

## Product Purpose

> Purpose/positioning inferred from the brief and WEBUI.md; the "meaningfully
> different mechanism" is the one the doc itself states: a browser ops console
> embedded in the server binary with zero Node/npm dependency.

zdtd's web UI gives the operator a live, read-only health view plus a safe
command surface for the Zeven Days to Die dedicated server, embedded in the
same binary that serves the game wire. Success means the operator can see
tick health and act on the server from a browser without a separate toolchain,
and the UI never perturbs the 50 ms sim tick.

## Positioning

> Inferred from WEBUI.md non-goals and the HTMX/Alpine rationale; labeled.

A browser ops dashboard for a from-scratch dedicated server, delivered as
server-rendered HTML with zero build step, no SPA, no node_modules in CI, and
a tick-safe read model. What a rival tool could not honestly copy: the console
is a first-class surface of the server process itself, loopback-bound with a
shared-secret or cookie session by default, and reads a snapshot that is
guaranteed off the sim hot path.

## Operating Context

> Confirmed from docs/WEBUI.md and the workspace docs.

- Server: Zig HTTP on a dedicated bind, loopback by default; shared secret
  (X-Zdtd-Secret) or cookie session; no anonymous open-internet admin.
- Companion surfaces: admin TCP (telnet) console, apm dumps, the game wire
  itself. The web UI is one of these, not a replacement for the game client.
- Operator workflow: start zdtd, open the dashboard, poll the live snapshot,
  run console commands through the same surface admin TCP exposes.
- The 50 ms / 20 TPS sim tick is the budget; every UI path is off it
  (or command-queue only).

## Capabilities and Constraints

Confirmed (docs/WEBUI.md "Settled decisions (WU0-WU2)" and architecture):

- Dashboard: live server health (tick budget, joins, peers, chunks, zombies,
  apm counters), player list, serverconfig / effective options (read-only),
  console command surface.
- Server-rendered HTML fragments with an inline vanilla JS poller using
  htmx-style attributes; vendor htmx/alpine embed is an optional later step.
- Security: loopback default bind, shared-secret or cookie session, login
  lockout, CSRF protection on command POSTs.
- No build step, no SPA, no Node toolchain; everything serves from one binary.
- All UI I/O stays out of the 50 ms tick (or command-queue only).

Explicit non-goals (do not treat as gaps): stock Steam browser clone, in-game
HUD, full telnet parity day one, real-time 3D map editor, RWG designer, Node SPA
in the binary, Harmony/ModAPI/Steam browser protocol.

## Brand Commitments

> Confirmed: the product name. Nothing else binding was volunteered.

Name: zdtd (Zeven Days to Die, formerly Zig Days To Die; the zdtd acronym is
unchanged). The web UI is the operator dashboard of that product; it is not
marketed as a separate product.

## Evidence on Hand

> Real evidence present in the repo, with paths. State the absences.

- docs/WEBUI.md: the design doc (goals, non-goals, architecture, security
  model, information architecture, UI sketch, command surface, data snapshot,
  implementation plan, settled WU0-WU2 decisions).
- src/server/webui/: shipped surface (shell.html, login.html,
  login_failed.html, login_lockout.html; the admin/GSI/webui wiring in
  src/server/).
- docs/APM.md: the metrics the dashboard reads (counters, section latency,
  dumps).
- Absent: no marketing copy, no screenshots, no external testimonials or
  customer evidence; do not fabricate any.

## Product Principles

> Derived from confirmed docs; no visual recipes.

1. The 50 ms tick is sacred: the UI observes, never perturbs the sim.
2. Secure by default: loopback, secret or cookie session, CSRF-safe commands,
   no anonymous admin.
3. Zero-toolchain: one binary, server-rendered HTML, no build step to run the
   console.
4. Act like admin TCP: the same command surface, the same validation, the same
   audit trail.
5. Read before write: configuration is visible read-only; commands are the
   only mutation and they go through the existing safe path.

## Accessibility & Inclusion

> No product-specific accessibility requirement was established. The dashboard
> is an operator tool; no claim is made beyond the repo's own notes.

<!-- Product facts are labeled where inferred from the brief + docs rather than
confirmed by an interview answer; see the section notes. -->
