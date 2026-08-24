#!/usr/bin/env python3
"""Regenerate docs/provenance.html from docs/GAP_ANALYSIS.md.

The dashboard is a standalone, dependency-free HTML page (opened from the repo
or file://, never served). It mirrors the GAP scorecard and embeds every
per-category GAP feature row so the page is browsable without opening the
markdown. Run from the repo root:

    python3 scripts/gen_provenance.py

The per-area WORKS/PARTIAL/MISSING counts are recounted from the live markers
(the documented source of truth); the per-category status and provenance prose
below is hand-maintained and must stay in sync with the GAP sections.
"""

import re
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GAP = ROOT / "docs" / "GAP_ANALYSIS.md"

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
        "&lt;variable&gt; substitution lands; challenge reward quests + stock-shaped journal wire complete; "
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
        "(quality lerp from the root quality_mod); POI placement open",
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
        "Level, XP, survival stats and active buffs survive a restart (ZPV9, saved on reap); "
        "eating caps like stock; death bags drop the real inventory; DeathPenalty is a real option; "
        "respawn targets the bedroll with a stock-order confirm; clean curve loader; "
        "biome + quest stage modifiers feed gameStageOf; "
        "perk runtime, stats blob and XP pushes still open",
        "A: progression.xml, buffs.xml · R: progression.md, entity-stats.md, save-persistence.md · Z: ZPV9 persist, survival knobs",
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
    return out


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def state_class(marker):
    if marker.startswith("WORKS"):
        return "WORKS"
    if marker.startswith("PARTIAL"):
        return "PARTIAL"
    if marker.startswith("MISSING"):
        return "MISSING"
    return "ad-hoc"


def build():
    cats = parse_gap()
    total_w = sum(c[1] for c in cats)
    total_p = sum(c[2] for c in cats)
    total_m = sum(c[3] for c in cats)
    total_rows = total_w + total_p + total_m
    pct = total_w * 100 // total_rows if total_rows else 0
    any_pct = (total_w + total_p) * 100 // total_rows if total_rows else 0

    score_rows = []
    for name, w, p, m, rows in cats:
        total = w + p + m
        pct_cat = w * 100 // total if total else 0
        status, prov = CATEGORY_PROSE[name]
        feats = "\n".join(
            f'<tr class="feat" data-state="{state_class(st)}"><td class="st {state_class(st)}">{esc(st)}</td><td>{esc(t)}</td></tr>'
            for t, st in rows
        )
        score_rows.append(f"""<tr class="cat" data-name="{esc(name)}" tabindex="0" aria-expanded="false">
<th scope="row">{esc(name)}</th>
<td><span class="pbar" role="progressbar" aria-valuenow="{pct_cat}" aria-valuemin="0" aria-valuemax="100" style="--p:{pct_cat}%"><span class="sr-only">{pct_cat}% ported</span></span> {pct_cat}%</td>
<td class="num">{w}</td><td class="num">{p}</td><td class="num">{m}</td>
<td>{esc(status)}</td><td>{esc(prov)}</td></tr>
<tr class="feat-row" hidden><td colspan="7"><div class="feat-wrap"><table class="feat"><caption class="sr-only">{esc(name)} GAP features</caption><tbody>
{feats}
</tbody></table></div></td></tr>""")
    score_table = "\n".join(score_rows)

    html = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Porting and provenance · zdtd</title>
<style>
/* Standalone provenance dashboard, regenerated by scripts/gen_provenance.py.
   Self-contained HTML/CSS/JS (no network) so it can be opened directly from
   the repo (double-click or file://) - it is NOT served by the server. Data
   mirrors docs/GAP_ANALYSIS.md (scorecard + per-category features, recounted
   from the live markers) and docs/PROVENANCE.md (A/R/Z buckets); STATUS.md
   wins on conflict. */
:root{{color-scheme:dark;--bg:#12141a;--card:#1c2030;--sunken:#141824;--line:#2a3144;--edge:#6a738c;--fg:#e8eaef;--muted:#aab2c2;--acc:#72b3e4;--ok:#82d68b;--warn:#f0b64f;--err:#ff8585;--sans:system-ui,sans-serif;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--fs-micro:0.8125rem;--fs-sm:0.875rem;--fs-lead:1.125rem;--fs-title:1.25rem}}
*{{box-sizing:border-box}}body{{font-family:var(--sans);margin:0;background:var(--bg);color:var(--fg);line-height:1.45}}
:focus-visible{{outline:3px solid var(--warn);outline-offset:3px}}
header{{padding:1rem 1.25rem;border-bottom:1px solid var(--line);background:var(--bg)}}
header h1{{font-size:var(--fs-title);margin:0;font-weight:600;letter-spacing:0.02em}}header .meta{{color:var(--muted);font-family:var(--mono);font-size:var(--fs-micro)}}
main{{padding:1rem 1.25rem;display:grid;gap:1rem;max-width:64rem;width:100%;margin-inline:auto}}
section{{background:var(--card);border-radius:8px;padding:0.85rem 1rem;border:1px solid var(--line)}}
section h2{{font-size:var(--fs-sm);color:var(--acc);text-transform:uppercase;letter-spacing:0.08em;font-weight:600;margin:0 0 0.6rem}}
h3{{font-size:var(--fs-micro);color:var(--muted);font-weight:600;text-transform:uppercase;letter-spacing:0.06em;margin:1rem 0 0.5rem}}
table{{width:100%;border-collapse:collapse;font-size:var(--fs-sm)}}th,td{{text-align:left;padding:0.35rem 0.5rem;border-bottom:1px solid var(--line)}}th{{color:var(--muted);font-weight:600}}
td{{font-family:var(--mono);font-variant-numeric:tabular-nums}}.num{{font-family:var(--mono);font-variant-numeric:tabular-nums}}
.sr-only{{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}}
.pbar{{display:inline-block;width:4.5rem;height:0.55rem;border-radius:3px;background:var(--sunken);vertical-align:middle;overflow:hidden;margin-right:0.4rem}}.pbar::before{{content:"";display:block;height:100%;width:var(--p);background:var(--ok);border-radius:3px}}
.toolbar{{display:flex;gap:0.5rem;flex-wrap:wrap;align-items:center;margin:0 0 0.6rem}}
.toolbar input[type=search]{{flex:1;min-width:12rem;background:var(--sunken);border:1px solid var(--line);color:var(--fg);border-radius:6px;padding:0.4rem 0.6rem;font:inherit}}
.chips{{display:flex;gap:0.35rem;flex-wrap:wrap}}
.chip{{background:var(--sunken);border:1px solid var(--line);color:var(--muted);border-radius:999px;padding:0.2rem 0.7rem;font-size:var(--fs-micro);cursor:pointer;font-family:var(--mono)}}
.chip[aria-pressed=true]{{color:var(--bg);border-color:transparent}}
.chip[aria-pressed=true].chip-w{{background:var(--ok)}}.chip[aria-pressed=true].chip-p{{background:var(--warn)}}.chip[aria-pressed=true].chip-m{{background:var(--err)}}.chip[aria-pressed=true].chip-a{{background:var(--acc)}}
.cat{{cursor:pointer}}
.cat:hover,.cat:focus-visible{{background:var(--sunken)}}
.cat.open th{{color:var(--acc)}}
.cat.open::after{{content:"▾";color:var(--acc);padding-left:0.4rem}}
.cat:not(.open)::after{{content:"▸";color:var(--muted);padding-left:0.4rem}}
.feat-row td{{background:var(--sunken);padding:0.4rem 0.6rem}}
.feat-wrap{{max-height:22rem;overflow:auto;border:1px solid var(--line);border-radius:6px}}
table.feat td{{font-family:var(--sans);border-bottom:1px solid var(--line)}}
table.feat .st{{font-family:var(--mono);font-size:var(--fs-micro);white-space:nowrap;width:7rem}}
.st.WORKS{{color:var(--ok)}}.st.PARTIAL{{color:var(--warn)}}.st.MISSING{{color:var(--err)}}.st.ad-hoc{{color:var(--acc)}}
th.sortable{{cursor:pointer;user-select:none;white-space:nowrap}}
th.sortable:hover{{color:var(--fg)}}th.sortable::after{{content:"⇅";opacity:0.4;padding-left:0.25rem}}th.sortable.asc::after{{content:"▲"}}th.sortable.desc::after{{content:"▼"}}
.count-line{{color:var(--muted);font-size:var(--fs-micro);margin:0.25rem 0 0}}
footer{{padding:0.75rem 1.25rem;color:var(--muted);font-size:var(--fs-micro)}}
@media(max-width:36rem){{main,header,footer{{padding-left:0.75rem;padding-right:0.75rem}}section{{padding:0.75rem}}}}
@media(forced-colors:active){{:root{{--bg:Canvas;--card:Canvas;--sunken:Canvas;--line:CanvasText;--edge:ButtonText;--fg:CanvasText;--muted:GrayText;--acc:LinkText;--ok:CanvasText;--warn:Highlight;--err:MarkText}}body,section{{background:Canvas;color:CanvasText;border-color:CanvasText}}:focus-visible{{outline:3px solid Highlight}}}}
</style></head>
<body>
<header><h1>zdtd</h1><span class="meta">Porting and provenance dashboard · standalone (not served by the server) · regenerated by scripts/gen_provenance.py</span></header>
<main id="main-content">
<section id="scorecard" aria-labelledby="scorecard-heading">
<h2 id="scorecard-heading">Stock game systems · GAP_ANALYSIS scorecard</h2>
<p style="margin:0 0 0.5rem;color:var(--muted);font-size:var(--fs-sm)">Overall: <b class="num">{total_w}</b> WORKS / <b class="num">{total_p}</b> PARTIAL / <b class="num">{total_m}</b> MISSING of <b class="num">{total_rows}</b> scored features = <b>{pct}%</b> fully ported, <b>{any_pct}%</b> at least partial (recount 2026-08-22 from the live markers; GAP_ANALYSIS scorecard wins on conflict).</p>
<div class="toolbar">
<label class="sr-only" for="filter">Filter categories and features</label>
<input id="filter" type="search" placeholder="Filter categories and features… (e.g. sleeper, trader, ZPV, quest)" autocomplete="off">
<div class="chips" role="group" aria-label="Feature state filter">
<button class="chip chip-w" data-state="WORKS" aria-pressed="true">WORKS</button>
<button class="chip chip-p" data-state="PARTIAL" aria-pressed="true">PARTIAL</button>
<button class="chip chip-m" data-state="MISSING" aria-pressed="true">MISSING</button>
<button class="chip chip-a" data-state="ad-hoc" aria-pressed="false">waived / other</button>
</div>
</div>
<table id="score"><caption class="sr-only">Game systems porting progress by category; click a row to expand its GAP features, click a numeric header to sort</caption>
<thead><tr><th scope="col" class="sortable" data-key="name">Category</th><th scope="col">Ported</th><th scope="col" class="sortable num" data-key="w">WORKS</th><th scope="col" class="sortable num" data-key="p">PARTIAL</th><th scope="col" class="sortable num" data-key="m">MISSING</th><th scope="col">Status</th><th scope="col">Provenance</th></tr></thead>
<tbody>
{score_table}
</tbody></table>
<p class="count-line">Showing <span id="shown-cats">9</span>/9 categories · <span id="shown-feats">0</span> features expanded · click a category row to expand its GAP feature list; numeric headers sort.</p>
</section>
<section id="engineering" aria-labelledby="engineering-heading">
<h2 id="engineering-heading">zdtd-owned engineering surface (not stock-parity scored)</h2>
<table><caption class="sr-only">zdtd-owned engineering surfaces</caption>
<thead><tr><th scope="col">Surface</th><th scope="col">Status</th><th scope="col">Provenance</th></tr></thead>
<tbody>
<tr><th scope="row">Wire and package parity</th><td>190-pkg catalog; 33/33 ToServer handled; 46 S2C emitted</td><td>R: protocol.md, protocol-packages.md, parity tooling · docs/wire/PACKAGES.md</td></tr>
<tr><th scope="row">Persistence</th><td>ZPV9 players, claims.zlc, containers.zct, blockmeta.zbm, entities.zen, weather.zwt, workstations.zws, allies.zal</td><td>R: save-persistence.md · Z: world/store + persist.zig (ZCH3/ZPV9, zdtd-owned layouts)</td></tr>
<tr><th scope="row">Wasm plugin surface</th><td>16 verdict/event hooks + sense/queue/query; 6 reference modules</td><td>Z: ADR 0020, PLUGIN_DEV.md expressibility audit · plugins/ (bot, core_killfeed, core_pvp, core_questgate, core_craftgate, core_lootgate)</td></tr>
<tr><th scope="row">Config-driven policy</th><td>Rules + mode packs + serverconfig through one toml_bind; no hand-written key chains</td><td>Z: ADR 0021, GAME_OPTIONS.md, src/util/toml_bind.zig</td></tr>
<tr><th scope="row">Bots</th><td>Wasm-only brains; host BotManager is a servant</td><td>Z: ADR 0026, PRD 0001, RFC 0001, mods/fps_bot</td></tr>
<tr><th scope="row">Native metrics</th><td>apm sections + counters + webui snapshot; 7dtd-server-apm not required</td><td>Z: docs/APM.md, src/apm/*</td></tr>
</tbody></table>
</section>
<p style="margin:0;color:var(--muted);font-size:var(--fs-micro)">Counts: docs/GAP_ANALYSIS.md scorecard (recounted from the per-feature markers by scripts/gen_provenance.py). Provenance buckets: docs/PROVENANCE.md (A stock data / R RE-cited / Z zdtd-owned). Status details: docs/STATUS.md, docs/WORK_PLAN.md.</p>
</main>
<footer>Standalone document · not served by the server · sources: docs/GAP_ANALYSIS.md, docs/PROVENANCE.md, docs/STATUS.md · regenerate: python3 scripts/gen_provenance.py</footer>
<script>
(function () {{
  "use strict";
  var filter = document.getElementById("filter");
  var chips = Array.prototype.slice.call(document.querySelectorAll(".chip"));
  var cats = Array.prototype.slice.call(document.querySelectorAll("tr.cat"));
  var feats = Array.prototype.slice.call(document.querySelectorAll("tr.feat"));
  var shownCats = document.getElementById("shown-cats");
  var shownFeats = document.getElementById("shown-feats");
  var stateFilter = {{}};
  chips.forEach(function (c) {{ stateFilter[c.dataset.state] = c.getAttribute("aria-pressed") === "true"; }});

  function matches(el, q) {{
    var hay = (el.dataset.name || "") + " " + (el.textContent || "");
    return hay.toLowerCase().indexOf(q) >= 0;
  }}

  function apply() {{
    var q = filter.value.trim().toLowerCase();
    var catShown = 0;
    var featShown = 0;
    cats.forEach(function (cat) {{
      var open = cat.classList.contains("open");
      var body = cat.nextElementSibling;
      var catOk = matches(cat, q);
      var anyFeat = false;
      cat.nextElementSibling.querySelectorAll("tr.feat").forEach(function (f) {{
        var ok = stateFilter[f.dataset.state] !== false && matches(f, q);
        f.hidden = !ok;
        if (ok) anyFeat = true;
      }});
      var show = catOk && (!open || anyFeat);
      cat.hidden = !show;
      body.hidden = !(open && show);
      if (show) catShown += 1;
      if (open && anyFeat) featShown += 1;
    }});
    shownCats.textContent = String(catShown);
    shownFeats.textContent = String(featShown);
  }}

  filter.addEventListener("input", apply);

  chips.forEach(function (c) {{
    c.addEventListener("click", function () {{
      var on = c.getAttribute("aria-pressed") === "true";
      c.setAttribute("aria-pressed", on ? "false" : "true");
      stateFilter[c.dataset.state] = !on;
      apply();
    }});
  }});

  cats.forEach(function (cat) {{
    cat.addEventListener("click", function () {{
      var open = cat.classList.toggle("open");
      cat.setAttribute("aria-expanded", open ? "true" : "false");
      apply();
    }});
    cat.addEventListener("keydown", function (e) {{
      if (e.key === "Enter" || e.key === " ") {{ e.preventDefault(); cat.click(); }}
    }});
  }});

  // Sortable numeric headers (and the name column).
  var asc = {{}};
  Array.prototype.slice.call(document.querySelectorAll("th.sortable")).forEach(function (th) {{
    th.addEventListener("click", function () {{
      var key = th.dataset.key;
      var dir = asc[key] === "asc" ? "desc" : "asc";
      asc[key] = dir;
      document.querySelectorAll("th.sortable").forEach(function (t) {{
        t.classList.remove("asc", "desc");
      }});
      th.classList.add(dir);
      var tbody = document.querySelector("#score tbody");
      var rows = Array.prototype.slice.call(tbody.querySelectorAll("tr.cat"));
      rows.sort(function (a, b) {{
        var av, bv;
        if (key === "name") {{ av = a.dataset.name; bv = b.dataset.name; return dir === "asc" ? av.localeCompare(bv) : bv.localeCompare(av); }}
        var cell = key === "w" ? 2 : key === "p" ? 3 : 4;
        av = parseInt(a.cells[cell].textContent, 10);
        bv = parseInt(b.cells[cell].textContent, 10);
        return dir === "asc" ? av - bv : bv - av;
      }});
      rows.forEach(function (r) {{ tbody.appendChild(r); tbody.appendChild(r.nextElementSibling); }});
    }});
  }});

  apply();
}})();
</script>
</body></html>
"""
    out = ROOT / "docs" / "provenance.html"
    out.write_text(html, encoding="utf-8")
    print(f"wrote {out} ({len(html)} bytes, {total_w}/{total_p}/{total_m} of {total_rows})")


if __name__ == "__main__":
    build()
