# ADR 0040: WebUI dashboard as a Preact client over a JSON state endpoint

- **Status:** accepted
- **Date:** 2026-09-18
- **Related:** [ADR 0018](0018-webui-ops-dashboard.md), [WEBUI.md](../WEBUI.md), [DESIGN-webui.md](../DESIGN-webui.md), [subsystems/webui.md](../subsystems/webui.md)

## Context

ADR 0018 shipped the operator dashboard as server-rendered HTML partials
(`/partials/status`, `/partials/settings`, `/partials/players`,
`/partials/modules`, `/partials/apm`, `/partials/console`) swapped into the page
by a hand-rolled poller in `src/server/webui/ts/shell.ts`, with the markup for
every tab living in `src/server/webui/shell.html` and in Zig renderers. Only
`/api/apm.json` speaks JSON.

That shape has three costs. Rendering lives in two languages with two copies of
every field. Every view change touches the Zig renderer, the HTML skeleton and
the poller. And the client cannot hold state (sort order, expanded rows,
selection) without re-deriving it from freshly swapped markup.

ADR 0018 decision 2 chose "inline HTML/CSS/JS, no vendor bundle, no SPA". This
ADR supersedes that decision for the dashboard. It keeps the rest of ADR 0018
(single HTTP stack, HMAC session token, command identity, tick coupling,
default off).

## Decision

1. **One state endpoint.** `GET /api/state.json` returns the whole dashboard
   state: the `Snapshot` scalar fields under their Zig field names, plus
   `players`, `modules`, `console`, `csrf` and `apm` (the existing
   `/api/apm.json` object, nested). The serializer walks `Snapshot` with
   `@typeInfo` at comptime, so a new Snapshot field appears in the JSON without
   a second hand-maintained list.
2. **The dashboard is a Preact app.** `src/server/webui/ts/shell.tsx` renders
   every tab as components from that state. Authoring is JSX with
   `jsxImportSource: preact`.
3. **Bundled inline, still no runtime file reads.** `scripts/build-webui-ts.sh`
   runs `tsc` for the type error pass and `bun build --format=iife` per page
   entry, then splices the bundle between the existing `zdtd-ts:<page>` markers
   in the committed HTML. `preact` is pinned and fetched into a cache directory
   the same way the anti-slop plugin is vendored; the emitted bundle is the only
   artifact the server embeds with `@embedFile`.
4. **`/partials/*` retires.** Those routes answer 404. The client fetches
   `/api/state.json`. `/api/apm.json` stays: it is documented in
   [APM.md](../APM.md) and consumed by tools.
5. **Mutations answer JSON too.** `POST /api/cmd` and `POST /api/modlet` reply
   `application/json` when the request carries `Accept: application/json`, which
   the dashboard sends. The plain and HTML reply paths stay for API tools.
6. **Login and lockout stay server-rendered.** The auth pages must work with
   JavaScript disabled, so `login.html` and `login_lockout.html` keep their
   server-rendered forms and their small classic scripts.
7. **Third-party code ships in the binary.** Preact is bundled into the
   committed pages, so the MIT text joins the inventory in
   [THIRD_PARTY.md](../../THIRD_PARTY.md).

## Consequences

- The dashboard has one owner per field: the Zig snapshot writes state, the
  Preact components render it. The HTML skeleton keeps only the document, the
  CSS tokens, the app mount point and the bundle marker.
- `max_shell_html` grows to hold the bundle; the shell page assertion tests move
  from markup fragments to the JSON contract and the mount point.
- The freshness gate in `scripts/lint-webui.sh` still covers the committed
  pages: a `.tsx` edit without a rebuild fails `make lint`.
- Rendering `/api/state.json` happens on the webui poll path, which shares the
  50 ms tick thread. Its cost is bounded by the snapshot size and is measured by
  the existing poll budget; a client that stops polling costs nothing.
- A cache-cold checkout needs network once for the pinned preact tarball, as the
  anti-slop plugin already does. The Zig build stays offline: it embeds the
  committed pages and never runs the JS toolchain.
