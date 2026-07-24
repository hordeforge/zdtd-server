---
description: Read zdtd native APM dumps (not 7dtd-apm)
agent: build
---

Use **zdtd native APM** only (`src/apm/`, docs/APM.md). Do not involve 7dtd-apm.

1. Read `docs/APM.md` for counters and sections.
2. Run the server under the scenario of interest, then inspect exit dumps or configured JSON/text snapshots.
3. Summarize hot sections (net_poll, sim_entities, replicate, net_flush) with concrete numbers.
4. If instrumentation is missing on a hot path you touched, add `apm` section/counter hooks as part of the fix.
