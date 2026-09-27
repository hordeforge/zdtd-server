# ADR 0041: The webui design system is the shadcn/ui contract plus a vendored component layer

- **Status:** accepted
- **Date:** 2026-09-27
- **Related:** [ADR 0040](0040-webui-preact-json-state.md), [WEBUI.md](../WEBUI.md), [DESIGN-webui.md](../DESIGN-webui.md)

## Context

ADR 0040 made the dashboard a Preact client and the Tailwind v4 port put every
style in utilities, with the design tokens in `@theme` in
`src/server/webui/webui.css`. That landed the utilities but left the page
without a design system in the shadcn sense: the tokens were named after the
paper cockpit's own roles (`bg-panel`, `border-line`, `text-ink`,
`bg-paper2`), so there was no semantic layer a component could be written
against, and the same chrome string
(`overflow-hidden rounded-card border border-border bg-card shadow-card`)
was copied into six panels, three table headers, the three ledgers and every
button.

The obvious alternative was to stop at utilities. It was rejected twice: the
repeated chrome is where a design drifts, and `@shadcn/lint` - already in the
webui lint gate - can only enforce `no-restyle` against a *component* layer.
The lint README is explicit that the plugin works without shadcn/ui, which is
also exactly the gap: token rules were enforced, restyle rules were not.

## Decision

1. **The shadcn token contract is the design system's vocabulary.**
   `webui.css` carries a `:root` block of shadcn semantic tokens
   (`--background`, `--card`, `--primary`, `--muted-foreground`, `--accent`,
   `--destructive`, `--border`, `--input`, `--ring`, `--radius`,
   `--chart-1..5`) holding the paper-cockpit values, published as Tailwind
   colors by an `@theme inline` block. The paper cockpit is the *values*, not
   the *names*; one name per value, so `bg-card` is the only way to say "card
   surface". The deck's own concepts shadcn has no name for stay in `@theme`
   (the terminal palette, the type scale, the card radius) and the status
   extensions the paper cockpit needs (`destructive-soft`, `border-strong`,
   `success-border`, `warning-*`) join the contract.
2. **The component layer is vendored, not depended on.** `shadcn/ui` is a
   source-copier, so its components live in
   `src/server/webui/ts/components/ui/` as our files: the registry source
   (new-york, v4) restyled to the paper cockpit, each carrying `data-slot` and
   `cva` variants. `components.json` at the repo root declares the aliases so
   `@shadcn/lint` finds them, and `@/...` maps to the `ts/` directory in
   `tsconfig.json`. `cn()` (`clsx` + `tailwind-merge`) lives in
   `src/server/webui/ts/lib/utils.ts`.
3. **`className`, not Preact's `class`, is the merge prop.** `@shadcn/lint`
   reads `className` when it decides whether a call site restyles a component.
   `shell.tsx` uses it throughout, including on plain elements, so the rule is
   not half-enabled.
4. **`shadcn/no-restyle` is on**, with layout classes allowed at a call site
   and the `components/ui` directory exempt (the component owns its own
   classes, per the plugin's own monorepo recipe). A restyle a page genuinely
   needs becomes a variant in the component, not a class at the call site.
5. **Server-rendered pages stay static markup on the same contract.** The
   login, lockout and header chrome carry the same token names as utilities;
   they cannot call the TSX primitives because there is no component layer
   there. Where the design calls for a variant, an `@utility` in `webui.css`
   carries it (`signin-shell`, `cmd-hint`, `chart-surface`).
6. **The contract has one home and every page imports it.** `webui.css` is the
   only place the tokens are declared. The other UI surface in the repo, the
   generated provenance dashboard, gets a Tailwind entry
   (`docs/provenance.css`) that imports the theme by path, so it shares the
   vocabulary instead of carrying a second token block. Its CSS is a second
   build step, because its markup is generated: `scripts/gen_provenance.py`
   writes the utilities with an empty CSS region and
   `scripts/build-doc-css.sh` compiles the entry against the committed page
   and splices the bundle in. Both the freshness gate and the splice fail when a
   class in the page has no generated rule, since a utility the theme cannot
   generate otherwise drops a style with no error anywhere.

## Consequences

The dashboard's repeated presentations have one home: a change to the card
chrome, a state pill or a ledger is one edit in a component file, and the
`no-restyle` rule is what keeps it that way. The token layer is a published
contract, so a dark or high-contrast mode is a `:root` override, and the
forced-colors fallback now remaps the contract rather than the palette.

The costs are real. Three more JS dependencies (`clsx`,
`tailwind-merge`, `class-variance-authority`) are pinned in
`scripts/webui-ts-project.sh` and fetched by the same `bun add` as `preact`,
so the offline fallback has to cover them too, and the dashboard bundle grows
by about 30 KB. The vendored components have already diverged from the
registry (no `asChild`/radix Slot, `CardTitle` is an `<h2>`, `Badge` has state
variants, `Table` has `TableEmpty`), which means a future `shadcn add` is a
port, not a drop-in - that is the price of a design system the paper cockpit
actually wanted. The static chrome in the server-rendered pages duplicates the
button and label class strings that the primitives also carry, and a generated
page has no component layer at all; that duplication is the honest cost of a
design system whose component layer lives only in the TSX, and it is bounded
to the header, the nav, the two sign-in pages and the provenance dashboard. One
retirement came with the second consumer: `src/server/webui/shared.css`, the
hand-written token source the first Tailwind pass kept for provenance, is gone
now that no page needs a stylesheet that is not the compiled theme.

---
Register the ADR in [README.md](README.md). Statuses are **accepted**,
**superseded**, **deprecated**. A decision still being made is an RFC, not a
proposed ADR; a later reversal supersedes this record - never edit the
decision out of it.
