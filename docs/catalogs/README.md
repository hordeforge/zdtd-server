# Catalogs

Generated, exhaustive reference tables. Every page here is rendered from source
by `tools/gen_docs_catalogs.py` and carries a `file:line` citation on every row.
Do not hand-edit a page: edit the source, run

    make docs-catalogs

and commit both the source change and the regenerated page. `make check` runs
`python3 tools/gen_docs_catalogs.py --check` and fails when a page is stale, the
same way `docs/provenance.html` and the webui pages are gated.

| Catalog | Holds |
|---|---|
| [config.md](config.md) | every operator tunable: serverconfig.xml keys, zdtd.toml fields, and the sim rule parameters a mode pack can set |
| [admin-verbs.md](admin-verbs.md) | the admin TCP command union and its subcommands, the in-process console verbs, and the bot and plugin host verbs |
| [save-formats.md](save-formats.md) | every on-disk artifact zdtd reads or writes: file, magic, reader and writer, and whether it is durable |
| [module-graph.md](module-graph.md) | the package dependency edges that exist in `src/`, next to the allowed and forbidden edges enforced by `scripts/lint-architecture.sh` |

These are lookup tables. The semantics behind them live on the subsystem pages
([docs/subsystems/](../subsystems/README.md)); the operator-facing narrative
lives in [GAME_OPTIONS.md](../GAME_OPTIONS.md), [RULES_CONFIG.md](../RULES_CONFIG.md)
and [APM.md](../APM.md).
