# Cookbook

Numbered how-tos for the changes a contributor makes most often. Each recipe
names the files to touch, the existing code to copy the shape from, the gates to
run, and one verify step that proves the change landed. Design rationale lives
in the linked ADR or RFC, never here.

Both recipes that land wire or sim behavior end their verify step with a
loadgen smoke (`scripts/smoke-navezgane.sh`) or a stock client run when the
change is client-visible; unit green alone is not evidence (see
[testing.md](../testing.md)).

| Recipe | Use it when |
|---|---|
| [adding-a-tunable.md](adding-a-tunable.md) | a new operator knob or sim parameter is needed |
| [adding-a-stock-package-body.md](adding-a-stock-package-body.md) | the client must be sent a stock package zdtd does not build yet |
| [adding-a-c2s-handler.md](adding-a-c2s-handler.md) | the client sends a package zdtd does not answer yet |
| [adding-a-scenario.md](adding-a-scenario.md) | a join, spawn, chunk or inventory path needs an in-process test |
| [adding-a-core-plugin.md](adding-a-core-plugin.md) | first-party behavior ships as a Wasm plugin under `plugins/` |
| [adding-a-doc-page.md](adding-a-doc-page.md) | a reference page, catalog or series document is needed |

The rule behind every recipe: [docs/AGENTS.md](../AGENTS.md) owns where a fact
lives; this folder owns how to land the change that adds it.
