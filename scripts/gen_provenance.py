#!/usr/bin/env python3
"""Regenerate docs/provenance.html from docs/GAP_ANALYSIS.md.

The dashboard is a standalone HTML page (opened from the repo or file://, never
served) on the repo's Tailwind v4 + shadcn design system: the markup below is
Tailwind utilities written against the token contract in
`src/server/webui/webui.css` (ADR 0041), and the compiled CSS is spliced into
the page by `scripts/build-doc-css.sh` between the `zdtd-css:provenance`
markers. The page therefore carries no hand-written stylesheet and no second
copy of the tokens. It mirrors the GAP scorecard and embeds every per-category
GAP feature row so the page is browsable without opening the markdown. Run
from the repo root:

    python3 scripts/gen_provenance.py          # markup only, empty CSS region
    make docs-provenance                       # the above, then compile the CSS

The per-area WORKS/PARTIAL/MISSING counts are recounted from the live markers
(the documented source of truth); the per-category status and provenance prose
below is hand-maintained and must stay in sync with the GAP sections.
"""

import argparse
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
GAP = ROOT / "docs" / "GAP_ANALYSIS.md"

# The CSS region this page's compiled Tailwind goes into. Named for humans
# reading the marker; build-doc-css.sh fills it and nothing else reads it.
CSS_REGION = "provenance"


def css_region(compiled: str) -> str:
    """The page's style region: the compiled bundle, or empty on a bare run."""
    return f"/* zdtd-css:{CSS_REGION} */\n{compiled.rstrip()}\n/* /zdtd-css:{CSS_REGION} */"

# Section header -> display name (order matches the GAP scorecard table).
SECTIONS = [
    ("4. Quests", "Quests"),
    ("5. Traders", "Traders"),
    ("6. Blood moon", "Blood moon"),
    ("7. POIs and prefabs", "POIs and prefabs"),
    ("8. Entities and AI", "Entities and AI"),
    ("9. Items, crafting and loot", "Items, crafting, loot"),
    ("10. Player progression", "Player progression"),
    ("11. World systems", "World systems"),
    ("12. Net and ops", "Net and ops"),
]

# Hand-maintained prose: status + provenance per category (mirrors the GAP
# section bottom lines and PROVENANCE.md buckets).
CATEGORY_PROSE = {
    "Quests": (
        "Template-derived defs non-empty; stock accept marker wired; "
        "<variable> substitution lands; challenge reward quests + stock-shaped journal wire complete; "
        "markers track the phase nav_object at the real objective position; objective events mirror to party members; "
        "per-objective CurrentValue is stock-shaped; PositionData writes QuestGiver; "
        "LootItem group rewards roll and quest chains grant; POI lockout reports bed/claim homes; "
        "offers and rally POIs land in the tag/tier/biome-filtered POI stock picks; "
        "journal restores quests by name with their POI rect; "
        "ClearSleepers kills gate to the bound POI and clear it permanently (target = the POI's live sleeper count); "
        "phases advance only when all their objectives complete; objective counts parse value/count/item_count",
        "A: quests.xml · R: quests-challenges.md, protocol-packages.md · Z: objective-kind map + quest policy",
    ),
    "Traders": (
        "Per-trader stock (direct + group rolls), hours, live wallet, lazy full-reroll restock, "
        "stock persistence, turn-in on open and the WorldAreas compound package land; "
        "quest offers (NPCQuestList exchange complete); sell any item at EconomicValue x markdown "
        "(quality lerp from the root quality_mod); trader POI NPCs spawn at their IndexedBlockOffsets",
        "A: traders.xml, npc.xml, items.xml EconomicValue · R: npc-dialog.md · Z: TraderInfo roll, wallet, quest offers",
    ),
    "Blood moon": (
        "Horde runs dusk to dawn; ladder composition + jittered schedule + stat 58/red clock/music + "
        "1.9x budget + per-party cap + dawn-end + jittered spawn bearings; "
        "party wave spawner with stage-frozen gsScaling and group maxAlive; "
        "ladder classes carry their own HP (no flat multiplier); "
        "settime takes stock world time; ops gettime/webui use the jittered countdown; horde music is per-party",
        "A: gamestages.xml · R: aidirector.md, sandbox-options.md · Z: party grouping, IsBloodMoonDead",
    ),
    "POIs and prefabs": (
        "Ids, rotation and height now correct; POI water planes wet; trader compounds ship their areas; "
        "parts paint; multi-block children regenerate; parts carry their sleeper volumes; "
        "authored block damage lands in the chunk plane; POI pads flatten to the stock deco.y-1 level; "
        "TileEntityType constants match stock; authored sleeper spawns use the full Class=Sleeper set; "
        "sleeper volumes rotate stock-clockwise; prefab TE scan seeds containers; "
        "SleeperVolumeGroupId cascade (TouchGroup)",
        "A: prefabs.xml + .tts/.nim, biome_layers subbiomes · R: block-shapes.md, server-browser-prefabs.md · Z: paint and rotation paths",
    ),
    "Entities and AI": (
        "Real fights with real stakes and real A*; per-class sight cone + LOS sensing; "
        "9 EAI task classes; all stock entitygroups + gamestage sleeper resolution; "
        "per-biome wildlife variety; timid animals flee; spawns ground-snap and quest ambushes resolve gamestage; "
        "zombie block probe chews feet-to-head cover; doors open on both halves; population is still thin",
        "A: entityclasses/entitygroups/gamestages/buffs.xml · R: entity-ai.md, entity-movement.md, combat-damage.md, aidirector.md · Z: ECS SoA sim, path, interest",
    ),
    "Items, crafting, loot": (
        "Containers roll their own tables and render their real grid size; items stack like stock; "
        "death bags carry the real inventory; recipes enforce craft_area and their exp data is all-zero; "
        "Extends inheritance complete; tool durability wears + quality rolls by loot stage; "
        "workstation fuel burn matches FuelValue; Navezgane-scale container discovery (4096 + world eviction); "
        "stock InvTx applies to the player inventory; InventoryDataRequest loop is closed; "
        "destroy_on_close containers break on unlock",
        "A: items.xml, recipes.xml, loot.xml · R: items.md, crafting-recipes.md, loot-economy.md",
    ),
    "Player progression": (
        "Level, XP, survival stats and active buffs survive a restart (ZPV3 buffs + ZPV11 skill tail, saved on reap); "
        "eating caps like stock; death bags drop the real inventory; DeathPenalty is a real option; "
        "respawn targets the bedroll with a stock-order confirm; clean curve loader; "
        "biome + quest stage modifiers feed gameStageOf; "
        "server-validated perk spend (SetSkillLevelServer, parent/cost/max gates) with level-scaled "
        "perk passives through the passive VM; the PlayerStats S2C blob and EntityAddExpClient pushes "
        "ride the server ledger; the on_perk_spend verdict (ADR 0033) gates spending",
        "A: progression.xml, buffs.xml · R: progression.md, entity-stats.md, save-persistence.md · Z: ZPV3/ZPV11 persist, survival knobs",
    ),
    "World systems": (
        "Walk, dig, build, persist; upgrades validate against the blocks.xml UpgradeBlock table; "
        "placed-block rotation/meta rides the chunk raw plane and ZCH3; POIs and parts place and paint; "
        "lakes and POI pools wet, claims expire, repair heals, supports collapse; "
        "per-cell biome ids follow the biome map; block damage persists per-cell in ZCH3; "
        "explosions carry per-entity ExplosionData + material bonuses; "
        "stream budget covers the full stock view (25x25); land-claim Count/DeadZone enforced",
        "A: biomes.xml + biome_layers, blocks.xml, spawning.xml · R: chunk-providers.md, light-mesh-water.md, entity-ai.md · Z: stability plane, ZCH3 store, leveler, falling groups",
    ),
    "Net and ops": (
        "Join works, telnet is stock-shaped; bans/whitelist/admin gates are stock-authorizer faithful; "
        "C2S/S2C coverage complete; in-game player console complete (allowlist + admin routing); "
        "the ops verb set is complete; web dashboard is the stock-WebDashboard surface "
        "(operator-only, non-client-visible); Net and ops 48/48",
        "A: serveradmin.xml, ConfigFile lists · R: protocol.md, protocol-packages.md, network.md · Z: LiteNet, admin TCP, GSI, webui",
    ),
}


def parse_gap():
    lines = GAP.read_text(encoding="utf-8").splitlines()
    sections = {}  # section header -> list[(title, marker)]
    cur = None
    for line in lines:
        m = re.match(r"^## (\d+\.\s.*)$", line)
        if m:
            cur = m.group(1)
            sections.setdefault(cur, [])
            continue
        if cur is None:
            continue
        m2 = re.match(r"^[-*] \*\*(.*?)\*\* `([^`]+)`", line)
        if m2:
            sections[cur].append((m2.group(1).strip(), m2.group(2).strip()))

    out = []
    for header, name in SECTIONS:
        rows = sections.get(header, [])
        works = partial = missing = 0
        for _t, st in rows:
            if st == "WORKS":
                works += 1
            elif st == "PARTIAL":
                partial += 1
            elif st == "MISSING":
                missing += 1
        out.append((name, works, partial, missing, rows))
    # The scorecard table is the count authority (the footer and the recount
    # note both say "GAP_ANALYSIS scorecard wins on conflict"). The live-marker
    # counts above are a cross-check; override each area's counts with the
    # `## 2. Scorecard` rows so the dashboard can never drift from the doc.
    in_score = False
    score_rows = []
    for line in lines:
        if line.startswith("## 2. Scorecard"):
            in_score = True
            continue
        if in_score and line.startswith("## "):
            break
        if not in_score:
            continue
        m = re.match(r"^\|\s*\[[^]]+\]\(#[0-9]+-[a-z-]+\)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|", line)
        if m:
            score_rows.append(tuple(int(x) for x in m.groups()))
    if len(score_rows) == len(out):
        for i, (w, p, m, _t) in enumerate(score_rows):
            name, _w, _p, _m, rows = out[i]
            out[i] = (name, w, p, m, rows)
    return out


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def state_of(marker):
    if marker.startswith("WORKS"):
        return "WORKS"
    if marker.startswith("PARTIAL"):
        return "PARTIAL"
    if marker.startswith("MISSING"):
        return "MISSING"
    return "ad-hoc"


# One class vocabulary for the whole page, on the shadcn contract. Named
# constants rather than repeated literals so a token change is one edit, and so
# the page reads as the design system rather than as a wall of utilities.
# The webui's type scale is the design system's scale (ADR 0041), so this page
# uses it instead of a second set of --fs-* steps.
# The score cell's four states live in the theme's `score-cell` utility
# (src/server/webui/webui.css): the page repeats the cell ~300 times, so the
# variant set cannot be a class list at each call site. State rides data-state.
CELL = "score-cell"
TH = "border-b border-border px-2 py-1.5 text-left font-sans text-body2 font-semibold text-muted-foreground"
TD = "border-b border-border px-2 py-1.5 align-top text-left font-mono text-ui tabular-nums"
# The sortable-header arrows are content, so they ride ::after like any other.
SORT_TH = "cursor-pointer select-none whitespace-nowrap after:pl-1 after:opacity-40 after:content-['\u21c5'] hover:text-foreground data-[sort=asc]:after:content-['\u25b2'] data-[sort=desc]:after:content-['\u25bc']"


# Filter chips: the four feature states, each carrying the colours it takes when
# pressed. The pressed classes are per state on purpose: a shared
# `aria-pressed:border-transparent` would race the state-specific border, since
# Tailwind resolves equal-specificity utilities by stylesheet order, not by the
# order they appear in the class attribute.
CHIP_BASE = "cursor-pointer rounded-full border border-input bg-card px-2.5 py-1 font-mono text-body2 text-muted-foreground aria-pressed:border-transparent"
CHIPS = (
    ("WORKS", "WORKS", "aria-pressed:bg-primary aria-pressed:text-primary-foreground"),
    ("PARTIAL", "PARTIAL", "aria-pressed:border-warning-border aria-pressed:bg-warning-soft aria-pressed:text-warning"),
    ("MISSING", "MISSING", "aria-pressed:border-destructive-border aria-pressed:bg-destructive-soft aria-pressed:text-destructive"),
    ("ad-hoc", "waived / other", "aria-pressed:bg-primary aria-pressed:text-primary-foreground"),
)

# The page's controls. Plain browser script (no bundler for a docs page), and it
# drives appearance only through data-state / data-sort, the shadcn idiom, so
# the stylesheet needs no class hooks of its own.
CONTROLS_JS = """(function () {
  "use strict";
  var filter = document.getElementById("filter");
  var chips = Array.from(document.querySelectorAll("[data-state][aria-pressed]"));
  var cats = Array.from(document.querySelectorAll("tr[data-name][aria-expanded]"));
  var feats = Array.from(document.querySelectorAll("tr[data-state]"));
  var shownCats = document.getElementById("shown-cats");
  var shownFeats = document.getElementById("shown-feats");
  var stateFilter = {};
  chips.forEach(function (c) { stateFilter[c.dataset.state] = c.getAttribute("aria-pressed") === "true"; });

  function matches(el, q) {
    var hay = (el.dataset.name || "") + " " + (el.textContent || "");
    return hay.toLowerCase().indexOf(q) >= 0;
  }

  function setState(el, open) {
    el.dataset.state = open ? "open" : "closed";
    el.setAttribute("aria-expanded", open ? "true" : "false");
  }

  function apply() {
    var q = filter.value.trim().toLowerCase();
    var catShown = 0;
    var featShown = 0;
    cats.forEach(function (cat) {
      var open = cat.dataset.state === "open";
      var body = cat.nextElementSibling;
      var catOk = matches(cat, q);
      var anyFeat = false;
      body.querySelectorAll("tr[data-state]").forEach(function (f) {
        var ok = stateFilter[f.dataset.state] !== false && matches(f, q);
        f.hidden = !ok;
        if (ok) anyFeat = true;
      });
      var show = catOk && (!open || anyFeat);
      cat.hidden = !show;
      body.hidden = !(open && show);
      if (show) catShown += 1;
      if (open && anyFeat) featShown += 1;
    });
    shownCats.textContent = String(catShown);
    shownFeats.textContent = String(featShown);
  }

  filter.addEventListener("input", apply);

  chips.forEach(function (c) {
    c.addEventListener("click", function () {
      var on = c.getAttribute("aria-pressed") === "true";
      c.setAttribute("aria-pressed", on ? "false" : "true");
      stateFilter[c.dataset.state] = !on;
      apply();
    });
  });

  cats.forEach(function (cat) {
    cat.addEventListener("click", function () { setState(cat, cat.dataset.state !== "open"); apply(); });
    cat.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); cat.click(); }
    });
  });

  // Defrag map: a tile drills into its category. Clearing the text filter
  // first means a tile always lands on its rows even when a filter is active.
  Array.from(document.querySelectorAll("[data-state][data-name][aria-label]")).forEach(function (tile) {
    tile.addEventListener("click", function () {
      var name = tile.dataset.name;
      var target = null;
      cats.forEach(function (cat) { if (cat.dataset.name === name) { target = cat; } });
      if (!target) { return; }
      filter.value = "";
      cats.forEach(function (cat) { setState(cat, cat === target); });
      Array.from(document.querySelectorAll("[data-state][data-name][aria-label]")).forEach(function (t) {
        t.dataset.state = t === tile ? "open" : "closed";
      });
      apply();
      target.scrollIntoView({ block: "center" });
      target.focus();
    });
  });

  // Sortable numeric headers (and the name column).
  var sortOf = {};
  Array.from(document.querySelectorAll("th[data-key]")).forEach(function (th) {
    th.addEventListener("click", function () {
      var key = th.dataset.key;
      var dir = sortOf[key] === "asc" ? "desc" : "asc";
      sortOf[key] = dir;
      document.querySelectorAll("th[data-key]").forEach(function (o) { o.dataset.sort = "none"; });
      th.dataset.sort = dir;
      var tbody = document.querySelector("#score tbody");
      var rows = Array.from(tbody.querySelectorAll("tr[data-name]"));
      rows.sort(function (a, b) {
        var av, bv;
        if (key === "name") {
          av = a.dataset.name; bv = b.dataset.name;
          return dir === "asc" ? av.localeCompare(bv) : bv.localeCompare(av);
        }
        var cell = key === "w" ? 2 : key === "p" ? 3 : 4;
        av = parseInt(a.cells[cell].textContent, 10);
        bv = parseInt(b.cells[cell].textContent, 10);
        return dir === "asc" ? av - bv : bv - av;
      });
      rows.forEach(function (r) { tbody.appendChild(r); tbody.appendChild(r.nextElementSibling); });
    });
  });

  apply();
}());
"""


def build(compiled=""):
    cats = parse_gap()
    total_w = sum(c[1] for c in cats)
    total_p = sum(c[2] for c in cats)
    total_m = sum(c[3] for c in cats)
    total_rows = total_w + total_p + total_m
    pct = total_w * 100 // total_rows if total_rows else 0
    any_pct = (total_w + total_p) * 100 // total_rows if total_rows else 0

    score_rows = []
    # Defrag map: one cell per scored feature, grouped by category, so the whole
    # 300-feature surface is legible in a single view. Clicking a tile drills
    # into that category's expanded rows.
    # The map's job is the one no number on the page does: show *where* the
    # unfinished work sits. Categories carrying PARTIAL/MISSING sort first and
    # are badged; the cells themselves are outlined as well as coloured, which
    # the theme's score-cell utility does (see CELL above).
    map_blocks = []
    for name, w, p, m, _rows in sorted(cats, key=lambda c: (c[2] + c[3] == 0, c[0])):
        total = w + p + m
        # Cells follow the scorecard counts, not the prose rows: the counts are
        # the documented source of truth and the two can differ (a category's
        # feature bullets are a subset of its scored total).
        cells = (["WORKS"] * w) + (["PARTIAL"] * p) + (["MISSING"] * m)
        cell_html = "".join(f'<i data-state="{c}" class="{CELL}"></i>' for c in cells)
        pct_cat = w * 100 // total if total else 0
        open_n = p + m
        # The open/closed state rides data-state, the shadcn idiom, so a
        # selected tile is styled by the same mechanism the rows use.
        badge = (
            f'<span class="rounded-full border border-warning-border bg-warning-soft px-1.5 py-0.5 font-mono text-body2 text-warning whitespace-nowrap">{open_n} open</span>'
            if open_n else
            '<span class="rounded-full border border-border px-1.5 py-0.5 font-mono text-body2 text-muted-foreground whitespace-nowrap">done</span>'
        )
        has_open = "true" if open_n else "false"
        map_blocks.append(
            f'<button type="button" data-state="closed" data-open="{has_open}" '
            # A category with open work keeps a warm edge so the eye lands there first.
            f'class="flex w-full cursor-pointer flex-col items-start rounded-md border border-border bg-muted p-2.5 text-left font-sans text-foreground '
            f'data-[open=true]:border-warning-border hover:border-input data-[state=open]:border-primary" '
            f'data-name="{esc(name)}" '
            f'aria-label="{esc(name)}: {w} of {total} features ported, {p} partial, {m} missing">'
            f'<span class="mb-1.5 flex w-full items-baseline justify-between gap-2">'
            f'<span class="font-sans text-ui">{esc(name)}</span>{badge}</span>'
            f'<span class="flex flex-1 flex-wrap content-start gap-0.5">{cell_html}</span>'
            f'<span class="mt-1.5 font-mono text-body2 text-muted-foreground tabular-nums">{pct_cat}% \u00b7 {total} features</span></button>'
        )
    defrag_map = "\n".join(map_blocks)

    for name, w, p, m, rows in cats:
        total = w + p + m
        pct_cat = w * 100 // total if total else 0
        status, prov = CATEGORY_PROSE[name]
        feats = "\n".join(
            f'<tr class="hover:bg-muted/50">'
            f'<td data-state="{state_of(st)}" class="feat-state">{esc(st)}</td>'
            f'<td class="{TD} font-sans">{esc(t)}</td></tr>'
            for t, st in rows
        )
        # The progress fill is the one place a value must reach the paint: its
        # width is a data-driven utility (w-(--p)) off the custom property,
        # never a per-row class.
        score_rows.append(f"""<tr class="cursor-pointer" data-name="{esc(name)}" data-state="closed" tabindex="0" aria-expanded="false">
<th scope="row" class="px-2 py-1.5 align-top text-left font-sans text-ui font-semibold text-foreground after:pl-1.5 data-[state=open]:text-accent-foreground data-[state=closed]:after:content-['\u25b8'] data-[state=open]:after:content-['\u25be'] data-[state=closed]:after:text-muted-foreground">{esc(name)}</th>
<td class="{TD}"><span role="progressbar" aria-valuenow="{pct_cat}" aria-valuemin="0" aria-valuemax="100" style="--p:{pct_cat}%" class="mr-1.5 inline-block h-[0.55rem] w-[4.5rem] overflow-hidden align-middle rounded-[3px] bg-muted before:block before:h-full before:w-(--p) before:rounded-[3px] before:bg-primary"><span class="sr-only">{pct_cat}% ported</span></span> {pct_cat}%</td>
<td class="{TD}">{w}</td><td class="{TD}">{p}</td><td class="{TD}">{m}</td>
<td class="border-b border-border px-2 py-1.5 align-top text-left font-sans text-ui">{esc(status)}</td><td class="border-b border-border px-2 py-1.5 align-top text-left font-sans text-ui">{esc(prov)}</td></tr>
<tr hidden><td colspan="7" class="bg-muted p-2.5"><div class="max-h-[22rem] overflow-auto rounded-md border border-border"><table class="w-full border-collapse text-ui"><caption class="sr-only">{esc(name)} GAP features</caption><tbody>
{feats}
</tbody></table></div></td></tr>""")
    score_table = "\n".join(score_rows)
    chip_html = "\n".join(
        f'<button type="button" data-state="{state}" aria-pressed="{on}" class="{CHIP_BASE} {pressed}">{label}</button>'
        for state, label, pressed, on in (
            (state, label, pressed, "false" if state == "ad-hoc" else "true")
            for state, label, pressed in CHIPS
        )
    )

    html = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Porting and provenance \u00b7 zdtd</title>
<style>
/* Standalone provenance dashboard, regenerated by scripts/gen_provenance.py.
   Self-contained HTML/CSS/JS (no network) so it can be opened directly from
   the repo (double-click or file://) - it is NOT served by the server. Data
   mirrors docs/GAP_ANALYSIS.md (scorecard + per-category features, recounted
   from the live markers) and docs/PROVENANCE.md (A/R/Z buckets); STATUS.md
   wins on conflict. */
/* Styling is Tailwind v4 on the shadcn token contract (ADR 0041): the markup
   below is utilities written against the contract in
   src/server/webui/webui.css, and what follows is that stylesheet compiled for
   this page and spliced in by scripts/build-doc-css.sh. No hand-written CSS
   and no second copy of the tokens. */
{css_region(compiled)}
</style></head>
<body class="bg-background font-sans text-foreground antialiased">
<header class="border-b border-border bg-card">
<div class="mx-auto flex w-full max-w-6xl items-center gap-3 px-5 py-4 max-sm:px-3">
<svg class="size-9 flex-none" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="7" fill="#0f5c37"/><g transform="translate(4 4)" fill="none" stroke="#f7f5f0" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 5h12L9.5 12H15l-9 7h12"/></g></svg>
<div><h1 class="m-0 font-sans text-stat font-bold tracking-tight1 text-foreground">BloodWire porting and provenance</h1>
<p class="m-0 font-mono text-body2 text-muted-foreground">zdtd \u00b7 standalone page, not served by the server \u00b7 regenerated by scripts/gen_provenance.py</p></div>
</div>
</header>
<main id="main-content" class="mx-auto grid w-full max-w-6xl gap-4 px-5 py-4 max-sm:px-3">
<section id="scorecard" aria-labelledby="scorecard-heading" class="rounded-card border border-border bg-card p-4 shadow-card max-sm:p-3">
<h2 id="scorecard-heading" class="m-0 mb-2.5 font-sans text-body2 font-semibold tracking-eyebrow text-accent-foreground uppercase">Stock game systems \u00b7 GAP_ANALYSIS scorecard</h2>
<p class="mb-2 font-sans text-ui text-muted-foreground">Overall: <b class="font-mono tabular-nums">{total_w}</b> WORKS / <b class="font-mono tabular-nums">{total_p}</b> PARTIAL / <b class="font-mono tabular-nums">{total_m}</b> MISSING of <b class="font-mono tabular-nums">{total_rows}</b> scored features = <b>{pct}%</b> fully ported, <b>{any_pct}%</b> at least partial (recounted from the live GAP_ANALYSIS markers; GAP_ANALYSIS scorecard wins on conflict).</p>
<div class="mb-3 grid grid-cols-3 gap-2.5 max-md:grid-cols-2 max-sm:grid-cols-1">
{defrag_map}
</div>
<div class="mb-2.5 flex flex-wrap items-center gap-2">
<label class="sr-only" for="filter">Filter categories and features</label>
<input id="filter" type="search" placeholder="Filter categories and features\u2026 (e.g. sleeper, trader, ZPV, quest)" autocomplete="off" class="min-w-48 flex-1 rounded-md border-2 border-input bg-card px-3 py-2 font-sans text-ui text-foreground focus:border-primary">
<div class="flex flex-wrap gap-1.5" role="group" aria-label="Feature state filter">
{chip_html}
</div>
</div>
<table id="score" class="w-full border-collapse text-ui">
<caption class="sr-only">Game systems porting progress by category; click a row to expand its GAP features, click a numeric header to sort</caption>
<thead><tr><th scope="col" data-key="name" data-sort="none" class="{SORT_TH} {TH}">Category</th><th scope="col" class="{TH}">Ported</th><th scope="col" data-key="w" data-sort="none" class="{SORT_TH} {TH}">WORKS</th><th scope="col" data-key="p" data-sort="none" class="{SORT_TH} {TH}">PARTIAL</th><th scope="col" data-key="m" data-sort="none" class="{SORT_TH} {TH}">MISSING</th><th scope="col" class="{TH} w-2/5">Status</th><th scope="col" class="{TH}">Provenance</th></tr></thead>
<tbody>
{score_table}
</tbody></table>
<p class="mt-1 mb-0 font-sans text-body2 text-muted-foreground">Showing <span id="shown-cats">9</span>/9 categories \u00b7 <span id="shown-feats">0</span> features expanded \u00b7 click a category row to expand its GAP feature list; numeric headers sort.</p>
</section>
<section id="engineering" aria-labelledby="engineering-heading" class="rounded-card border border-border bg-card p-4 shadow-card max-sm:p-3">
<h2 id="engineering-heading" class="m-0 mb-2.5 font-sans text-body2 font-semibold tracking-eyebrow text-accent-foreground uppercase">zdtd-owned engineering surface (not stock-parity scored)</h2>
<table class="w-full border-collapse text-ui"><caption class="sr-only">zdtd-owned engineering surfaces</caption>
<thead><tr><th scope="col" class="{TH}">Surface</th><th scope="col" class="{TH}">Status</th><th scope="col" class="{TH}">Provenance</th></tr></thead>
<tbody>
<tr><th scope="row" class="font-sans text-ui font-semibold text-foreground">Wire and package parity</th><td class="{TD}">190-pkg catalog; 33/33 ToServer handled; 46 S2C emitted</td><td class="border-b border-border px-2 py-1.5 text-left font-sans text-ui">R: protocol.md, protocol-packages.md, parity tooling \u00b7 docs/wire/PACKAGES.md</td></tr>
<tr><th scope="row" class="font-sans text-ui font-semibold text-foreground">Persistence</th><td class="{TD}">ZPV12 players, entities.zen, claims.zlc, clock.zcl, weather.zwt, blockmeta.zbm, containers.zct, workstations.zws, allies.zal, traders.zst</td><td class="border-b border-border px-2 py-1.5 text-left font-sans text-ui">R: save-persistence.md \u00b7 Z: world/store + persist.zig (ZCH3/ZPV12, zdtd-owned layouts)</td></tr>
<tr><th scope="row" class="font-sans text-ui font-semibold text-foreground">Wasm plugin surface</th><td class="{TD}">23 hooks + sense/queue/query; 12 core plugins + 6 addon mods</td><td class="border-b border-border px-2 py-1.5 text-left font-sans text-ui">Z: ADR 0020, PLUGIN_DEV.md expressibility audit \u00b7 plugins/ (12 core_*: adminverbs, announce, craftgate, damagegate, killfeed, lootgate, perkgate, pricegate, pvp, questgate, rewardgate, tradefeed) \u00b7 mods/ (fps_bot, mcp, parachute, moon_gravity, infinite_world, example_chat_filter)</td></tr>
<tr><th scope="row" class="font-sans text-ui font-semibold text-foreground">Config-driven policy</th><td class="{TD}">Rules + mode packs + serverconfig through one toml_bind; no hand-written key chains</td><td class="border-b border-border px-2 py-1.5 text-left font-sans text-ui">Z: ADR 0021, GAME_OPTIONS.md, src/util/toml_bind.zig</td></tr>
<tr><th scope="row" class="font-sans text-ui font-semibold text-foreground">Bots</th><td class="{TD}">Wasm-only brains; host BotManager is a servant</td><td class="border-b border-border px-2 py-1.5 text-left font-sans text-ui">Z: ADR 0026, PRD 0001, RFC 0001, mods/fps_bot</td></tr>
<tr><th scope="row" class="font-sans text-ui font-semibold text-foreground border-b-0">Native metrics</th><td class="{TD}">apm sections + counters + webui snapshot; 7dtd-server-apm not required</td><td class="border-b-0 px-2 py-1.5 text-left font-sans text-ui">Z: docs/APM.md, src/apm/*</td></tr>
</tbody></table>
</section>
<p class="m-0 font-sans text-body2 text-muted-foreground">Counts: docs/GAP_ANALYSIS.md scorecard (recounted from the per-feature markers by scripts/gen_provenance.py). Provenance buckets: docs/PROVENANCE.md (A stock data / R RE-cited / Z zdtd-owned). Status details: docs/STATUS.md, docs/WORK_PLAN.md.</p>
</main>
<footer class="border-t border-border bg-card px-5 py-3 font-sans text-body2 text-muted-foreground max-sm:px-3">Standalone document \u00b7 not served by the server \u00b7 sources: docs/GAP_ANALYSIS.md, docs/PROVENANCE.md, docs/STATUS.md \u00b7 regenerate: make docs-provenance</footer>
<script>
{CONTROLS_JS}
</script>
</body></html>
"""
    out = ROOT / "docs" / "provenance.html"
    out.write_text(html, encoding="utf-8")
    print(f"wrote {out} ({len(html)} bytes, {total_w}/{total_p}/{total_m} of {total_rows})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--css",
        help="compiled Tailwind bundle to splice into the page's CSS region; "
        "omit to write the markup with an empty region (make docs-provenance does both)",
    )
    args = parser.parse_args()
    compiled = pathlib.Path(args.css).read_text(encoding="utf-8") if args.css else ""
    build(compiled)
