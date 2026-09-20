//! Webui dashboard as a Preact app over GET /api/state.json (ADR 0040): one
//! poll renders every panel, the tick chart, and the header glance lamp.
//! Commands POST to /api/cmd and modlet actions to /api/modlet as JSON; a
//! successful modlet action refetches the state. Compiled by
//! scripts/build-webui-ts.sh into the `zdtd-ts:shell` marker of shell.html.

import { Fragment, render } from "preact";
import type { ComponentChildren, RefObject } from "preact";
import { useCallback, useEffect, useRef, useState } from "preact/hooks";
import { attachChart, CHART_HISTORY_OPTIONS, detachChart, redrawChart, setChartCompressed, setChartHistory, setChartStale, showLatestApm } from "./chart";
import type { ApmJson } from "./chart";

const STATE_URL = "/api/state.json";
const CMD_URL = "/api/cmd";
const MODLET_URL = "/api/modlet";
const FETCH_TIMEOUT_MS = 8000;
const HTTP_UNAUTHORIZED = 401;
// The retired per-region poller refreshed status/performance/players every
// second and console/settings/modules every five; the single state poll keeps
// that cadence by active tab.
const POLL_FAST_MS = 1000;
const POLL_SLOW_MS = 5000;
const FLASH_MS = 1200;
const TICK_BUDGET_MS = 50;
const PERCENT_MAX = 100;
const NS_PER_MS = 1_000_000;
const NS_PER_US = 1000;
const SECONDS_PER_MINUTE = 60;
const SECONDS_PER_HOUR = 3600;
const MINUTES_PER_HOUR = 60;
const JSON_ACCEPT = "application/json";
const FORM_CONTENT_TYPE = "application/x-www-form-urlencoded";
const MAX_CMD_LINE = 256;

/** Snapshot scalar fields the dashboard reads (Snapshot in webui.zig). */
type TickState = {
    tick_n: number;
    day: number;
    hours: number;
    bloodmoon_active: boolean;
    bloodmoon_frequency: number;
    bloodmoon_in_days: number;
    joined: number;
    entered: number;
    peers_alive: number;
    max_players: number;
    zombies: number;
    animals: number;
    traders: number;
    vehicles: number;
    turrets: number;
    loot_bags: number;
    players_ent: number;
    chunks: number;
    tick_overruns: number;
    encode_errors: number;
    stream_errors: number;
    net_poll_errors: number;
    net_payload_errors: number;
    net_send_errors: number;
    reliable_window_drops: number;
    persistence_errors: number;
    stale_peers_reaped: number;
    phase_rejects: number;
    ownership_rejects: number;
    bounds_rejects: number;
    movement_rejects: number;
    decode_rejects: number;
    guard_kicks: number;
    guard_would_kicks: number;
    guard_quarantines: number;
    quarantine_rejects: number;
    load_shed_drops: number;
    hard_ceiling_downgrades: number;
    evidence_events: number;
    join_ok: number;
    join_fail: number;
    net_packets_in: number;
    net_packets_out: number;
    net_bytes_in: number;
    net_bytes_out: number;
    packages_encoded: number;
    packages_broadcast: number;
    entities_ticked: number;
    tick_mean_ns: number;
    tick_p50_ns: number;
    tick_p99_ns: number;
    tick_max_ns: number;
    net_mean_ns: number;
    net_p99_ns: number;
    sim_mean_ns: number;
    sim_p99_ns: number;
    repl_mean_ns: number;
    repl_p99_ns: number;
    stream_mean_ns: number;
    stream_p99_ns: number;
    save_mean_ns: number;
    view_radius: number;
    max_streamed_chunks: number;
    interest_range: number;
    max_edit_range: number;
    max_spawned_zombies: number;
    info_port: number;
    webui_port: number;
    authority_correct: boolean;
    password_set: boolean;
    wire_chunks: boolean;
    os_load_1: number;
    os_load_5: number;
    os_load_15: number;
    os_mem_total_mb: number;
    os_mem_avail_mb: number;
    os_proc_cpu_pct: number;
    os_proc_rss_mb: number;
    os_procs: number;
    os_uptime_s: number;
    /** Serialized from the Snapshot `world_name` char array. */
    world_name?: string;
};

/** PlayerRow fields the table uses (webui.zig PlayerRow). */
type PlayerEntry = {
    slot: number;
    entity_id: number;
    joined: boolean;
    entered: boolean;
    x: number;
    y: number;
    z: number;
    name: string;
};

/** ModuleRow fields the table uses (webui.zig ModuleRow). */
type ModuleEntry = { name: string; disabled: boolean };

/** One XML-only modlet from the roster (assets/modlets.zig). */
type ModletEntry = { name: string; version: string; has_code: boolean; disabled: boolean };

/** The whole dashboard state: one poll, one render. */
type StateJson = {
    csrf: string;
    tick: TickState;
    players: Array<PlayerEntry>;
    modules: Array<ModuleEntry>;
    console: Array<string>;
    apm: ApmJson;
    /** Not part of the frozen contract yet; absent renders the no-mods note. */
    modlets?: Array<ModletEntry>;
};

type CommandReply = { ok: boolean; line?: string; reply?: string; error?: string };
type ModletReply = { ok: boolean; reply?: string; error?: string };

/** A rendered command result: the echoed line and the reply text. */
type CommandOutcome = { line: string; text: string; failed: boolean };

/** One stat cell of a grid: label under the value, optional tone class. */
type Stat = { label: string; body: ComponentChildren; tone?: string };

function fetchWithTimeout(url: string, options: RequestInit = {}): Promise<Response> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    return fetch(url, { ...options, signal: controller.signal }).finally(() => clearTimeout(timeout));
}

function queryEl<T extends HTMLElement>(selector: string, kind: new () => T): T {
    const el = document.querySelector(selector);
    if (!(el instanceof kind)) {
        throw new Error(`webui: missing element ${selector}`);
    }
    return el;
}

// Churn visibility: flash the stat cells and table rows whose text changed
// since the previous poll so updates register in peripheral vision. Signatures
// are keyed by position, so a reorder flashes too, which is honest.
const appRoot = queryEl("#app", HTMLElement);
const prevSignatures = new WeakMap<HTMLElement, Map<string, string>>();
let reduceMotion: MediaQueryList | null = null;

function prefersReducedMotion(): boolean {
    if (reduceMotion === null) {
        reduceMotion = globalThis.matchMedia("(prefers-reduced-motion: reduce)");
    }
    return reduceMotion.matches;
}

function flashChanges(region: HTMLElement): void {
    if (prefersReducedMotion()) {
        return;
    }
    const nodes = region.querySelectorAll<HTMLElement>(".stat, tbody tr");
    const prev = prevSignatures.get(region);
    const next = new Map<string, string>();
    const changed: Array<HTMLElement> = [];
    let index = 0;
    for (const node of nodes) {
        next.set(String(index), node.textContent ?? "");
        if (prev !== undefined && prev.size > 0 && prev.get(String(index)) !== next.get(String(index))) {
            changed.push(node);
        }
        index += 1;
    }
    // Clear, then flush layout once, then re-add: one forced reflow restarts
    // every animation at once instead of one reflow per changed node.
    for (const node of changed) {
        node.classList.remove("flash");
    }
    if (changed.length > 0) {
        void region.offsetWidth;
        for (const node of changed) {
            node.classList.add("flash");
            globalThis.setTimeout(() => node.classList.remove("flash"), FLASH_MS);
        }
    }
    prevSignatures.set(region, next);
}

async function fetchState(): Promise<StateJson | null> {
    try {
        const res = await fetchWithTimeout(STATE_URL, {
            credentials: "same-origin",
            headers: { Accept: JSON_ACCEPT },
        });
        if (res.status === HTTP_UNAUTHORIZED) {
            globalThis.location.assign("/login");
            return null;
        }
        if (!res.ok) {
            return null;
        }
        // oxlint-disable-next-line typescript/no-unsafe-type-assertion, anti-slop/require-safety-comment-for-type-assertion -- SAFETY: /api/state.json is this server's own fixed schema (the Snapshot/PlayerRow/ModuleRow JSON in webui.zig); the fields read are declared in StateJson
        return (await res.json()) as StateJson;
        // oxlint-disable-next-line @rikalabs/no-silent-catch-fallback -- deliberate: a failed poll raises the error banner and the next interval retries; rethrowing would only produce an unhandled rejection inside the timer callback
    } catch {
        return null;
    }
}

/** POST /api/cmd. `redirect` means the handler already navigated to /login. */
type CommandPost = { kind: "reply"; outcome: CommandOutcome } | { kind: "redirect" } | { kind: "unreachable" };

async function postCommand(csrf: string, line: string): Promise<CommandPost> {
    try {
        const res = await fetchWithTimeout(CMD_URL, {
            method: "POST",
            credentials: "same-origin",
            headers: { "Content-Type": FORM_CONTENT_TYPE, Accept: JSON_ACCEPT },
            body: new URLSearchParams({ csrf, line }),
        });
        if (res.status === HTTP_UNAUTHORIZED) {
            globalThis.location.assign("/login");
            return { kind: "redirect" };
        }
        // oxlint-disable-next-line typescript/no-unsafe-type-assertion, anti-slop/require-safety-comment-for-type-assertion -- SAFETY: /api/cmd answers the documented {ok,line,reply,error} body (handleCmdPost in webui.zig); only those fields are read
        const reply = (await res.json()) as CommandReply;
        const failed = !res.ok || reply.ok !== true;
        const text = reply.ok === true ? reply.reply ?? "" : reply.error ?? reply.reply ?? "";
        return { kind: "reply", outcome: { line: reply.line ?? line, text, failed } };
        // oxlint-disable-next-line @rikalabs/no-silent-catch-fallback -- deliberate: the failure is rendered in #cmd-out as a role=alert pre; rethrowing would only produce an unhandled rejection in the submit listener
    } catch {
        return { kind: "unreachable" };
    }
}

/** POST /api/modlet. */
type ModletPost = { kind: "ok" } | { kind: "failed"; note: string } | { kind: "redirect" };

async function postModlet(csrf: string, name: string, action: string): Promise<ModletPost> {
    try {
        const res = await fetchWithTimeout(MODLET_URL, {
            method: "POST",
            credentials: "same-origin",
            headers: { "Content-Type": FORM_CONTENT_TYPE, Accept: JSON_ACCEPT },
            body: new URLSearchParams({ csrf, name, action }),
        });
        if (res.status === HTTP_UNAUTHORIZED) {
            globalThis.location.assign("/login");
            return { kind: "redirect" };
        }
        // oxlint-disable-next-line typescript/no-unsafe-type-assertion, anti-slop/require-safety-comment-for-type-assertion -- SAFETY: /api/modlet answers the documented {ok,reply,error} body (handleModletPost in webui.zig); only those fields are read
        const reply = (await res.json()) as ModletReply;
        if (!res.ok || reply.ok !== true) {
            return { kind: "failed", note: `Modlet action failed (${reply.error ?? `HTTP ${res.status}`}; no change was applied. Retry.)` };
        }
        return { kind: "ok" };
        // oxlint-disable-next-line @rikalabs/no-silent-catch-fallback -- deliberate: the failure is rendered inline in the modules pane as role=alert text
    } catch {
        return { kind: "failed", note: "Modlet action failed (not received; its outcome is unknown. Reload before retrying.)" };
    }
}

// ---- Shared presentations -------------------------------------------------------

function toneFor(count: number, severe: boolean): string {
    if (count === 0) {
        return "num";
    }
    return severe ? "num err" : "num warn-text";
}

function StatGrid({ heading, stats, flush }: { heading?: string; stats: Array<Stat>; flush?: boolean }): ComponentChildren {
    return (
        <Fragment>
            {heading === undefined ? null : <h3 class={flush === true ? "flush" : undefined}>{heading}</h3>}
            <ul class="grid">
                {stats.map((stat) => (
                    <li class="stat" key={stat.label}>
                        <b class={stat.tone ?? "num"}>{stat.body}</b>
                        <span>{stat.label}</span>
                    </li>
                ))}
            </ul>
        </Fragment>
    );
}

function Pill({ tone, children }: { tone: string; children: ComponentChildren }): ComponentChildren {
    return <span class={`pill ${tone}`}>{children}</span>;
}

function pad2(part: number): string {
    return String(part).padStart(2, "0");
}

function worldTimeText(tick: TickState): string {
    const hh = Math.floor(tick.hours);
    const mm = Math.floor((tick.hours - hh) * MINUTES_PER_HOUR);
    return `d${tick.day} ${pad2(hh)}:${pad2(mm)}`;
}

function worldName(tick: TickState): ComponentChildren {
    const name = tick.world_name ?? "";
    if (name === "") {
        return <span class="meta">(unnamed)</span>;
    }
    return name;
}

function isOverBudget(apm: ApmJson): boolean {
    return apm.tick_p99_ns / NS_PER_MS > TICK_BUDGET_MS;
}

function msText(ns: number): number {
    return Math.floor(ns / NS_PER_MS);
}

function usText(ns: number): number {
    return Math.floor(ns / NS_PER_US);
}

function statusCells(tick: TickState): Array<Stat> {
    const blood = tick.bloodmoon_active;
    return [
        { label: "server tick", body: String(tick.tick_n) },
        { label: "world time", body: worldTimeText(tick) },
        { label: `blood moon · next in ${tick.bloodmoon_in_days}d`, body: <Pill tone={blood ? "bad" : "ok"}>{blood ? "ACTIVE" : "idle"}</Pill> },
        { label: "joined / max", body: `${tick.joined}/${tick.max_players}` },
        { label: "entered world", body: String(tick.entered) },
        { label: "peers connected", body: String(tick.peers_alive) },
        { label: "chunks in memory", body: String(tick.chunks) },
        { label: "tick overruns", body: String(tick.tick_overruns), tone: toneFor(tick.tick_overruns, false) },
    ];
}

function entityCells(tick: TickState): Array<Stat> {
    return [
        { label: "zombies / cap", body: `${tick.zombies}/${tick.max_spawned_zombies}` },
        { label: "animals", body: String(tick.animals) },
        { label: "player entities", body: String(tick.players_ent) },
        { label: "traders", body: String(tick.traders) },
        { label: "vehicles", body: String(tick.vehicles) },
        { label: "turrets", body: String(tick.turrets) },
        { label: "loot bags", body: String(tick.loot_bags) },
    ];
}

function serverCells(tick: TickState): Array<Stat> {
    return [
        { label: "world", body: worldName(tick), tone: "" },
        { label: "info port", body: String(tick.info_port) },
        { label: "game port", body: String(tick.info_port + 2) },
        { label: "webui port", body: String(tick.webui_port) },
        { label: "view radius", body: String(tick.view_radius) },
        { label: "max streamed chunks", body: String(tick.max_streamed_chunks) },
        { label: "interest range (m)", body: String(Math.round(tick.interest_range)) },
        { label: "edit range (m)", body: String(Math.round(tick.max_edit_range)) },
        { label: "authority mode", body: tick.authority_correct ? "correct" : "observe", tone: tick.authority_correct ? "" : "num warn-text" },
        { label: "password", body: tick.password_set ? "set" : "not set", tone: "" },
        { label: "chunk streaming", body: tick.wire_chunks ? "on" : "off", tone: "" },
    ];
}

function hostCells(tick: TickState): Array<Stat> {
    const upH = Math.floor(tick.os_uptime_s / SECONDS_PER_HOUR);
    const upM = Math.floor((tick.os_uptime_s % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE);
    const loads = `${tick.os_load_1.toFixed(2)} / ${tick.os_load_5.toFixed(2)} / ${tick.os_load_15.toFixed(2)}`;
    return [
        { label: "load 1 / 5 / 15 min", body: loads },
        { label: "ram free+buf / total", body: `${tick.os_mem_avail_mb} / ${tick.os_mem_total_mb} MiB` },
        { label: "proc cpu (of host uptime)", body: `${tick.os_proc_cpu_pct.toFixed(1)}%` },
        { label: "proc rss peak", body: `${tick.os_proc_rss_mb} MiB` },
        { label: "processes", body: String(tick.os_procs) },
        { label: "host uptime", body: `${upH}h ${upM}m` },
    ];
}

function latencyCells(tick: TickState): Array<Stat> {
    const budgetNs = TICK_BUDGET_MS * NS_PER_MS;
    return [
        { label: "tick mean", body: `${msText(tick.tick_mean_ns)} ms` },
        { label: "tick p50 / p99", body: `${msText(tick.tick_p50_ns)} / ${msText(tick.tick_p99_ns)} ms`, tone: tick.tick_p99_ns > budgetNs ? "num warn-text" : "num" },
        { label: "tick max", body: `${msText(tick.tick_max_ns)} ms`, tone: tick.tick_max_ns > budgetNs ? "num warn-text" : "num" },
        { label: "net mean / p99", body: `${usText(tick.net_mean_ns)} / ${usText(tick.net_p99_ns)} µs` },
        { label: "sim mean / p99", body: `${usText(tick.sim_mean_ns)} / ${usText(tick.sim_p99_ns)} µs` },
        { label: "repl mean / p99", body: `${usText(tick.repl_mean_ns)} / ${usText(tick.repl_p99_ns)} µs` },
        { label: "stream mean / p99", body: `${usText(tick.stream_mean_ns)} / ${usText(tick.stream_p99_ns)} µs` },
        { label: "save mean", body: `${usText(tick.save_mean_ns)} µs` },
    ];
}

function trafficCells(tick: TickState): Array<Stat> {
    return [
        { label: "packets in", body: String(tick.net_packets_in) },
        { label: "packets out", body: String(tick.net_packets_out) },
        { label: "bytes in", body: String(tick.net_bytes_in) },
        { label: "bytes out", body: String(tick.net_bytes_out) },
        { label: "packages encoded", body: String(tick.packages_encoded) },
        { label: "packages sent", body: String(tick.packages_broadcast) },
        { label: "entities ticked", body: String(tick.entities_ticked) },
    ];
}

function errorCells(tick: TickState): Array<Stat> {
    const counters: ReadonlyArray<{ label: string; count: number; severe: boolean }> = [
        { label: "tick overruns", count: tick.tick_overruns, severe: false },
        { label: "encode errors", count: tick.encode_errors, severe: true },
        { label: "stream errors", count: tick.stream_errors, severe: true },
        { label: "net poll errors", count: tick.net_poll_errors, severe: true },
        { label: "payload errors", count: tick.net_payload_errors, severe: true },
        { label: "send errors", count: tick.net_send_errors, severe: true },
        { label: "window drops", count: tick.reliable_window_drops, severe: false },
        { label: "persist errors", count: tick.persistence_errors, severe: true },
        { label: "stale peers reaped", count: tick.stale_peers_reaped, severe: false },
        { label: "phase rejects", count: tick.phase_rejects, severe: false },
        { label: "ownership rejects", count: tick.ownership_rejects, severe: false },
        { label: "bounds rejects", count: tick.bounds_rejects, severe: false },
        { label: "movement rejects", count: tick.movement_rejects, severe: false },
        { label: "decode rejects", count: tick.decode_rejects, severe: false },
    ];
    const cells: Array<Stat> = [{ label: "join ok / fail", body: `${tick.join_ok}/${tick.join_fail}`, tone: toneFor(tick.join_fail, true) }];
    for (const counter of counters) {
        cells.push({ label: counter.label, body: String(counter.count), tone: toneFor(counter.count, counter.severe) });
    }
    return cells;
}

function guardCells(tick: TickState): Array<Stat> {
    return [
        { label: "guard kicks", body: String(tick.guard_kicks), tone: toneFor(tick.guard_kicks, true) },
        { label: "guard would-kicks", body: String(tick.guard_would_kicks), tone: toneFor(tick.guard_would_kicks, false) },
        { label: "guard quarantines", body: String(tick.guard_quarantines), tone: toneFor(tick.guard_quarantines, false) },
        { label: "quarantine rejects", body: String(tick.quarantine_rejects), tone: toneFor(tick.quarantine_rejects, false) },
        { label: "load-shed drops", body: String(tick.load_shed_drops), tone: toneFor(tick.load_shed_drops, false) },
        { label: "hard-ceiling downgrades", body: String(tick.hard_ceiling_downgrades), tone: toneFor(tick.hard_ceiling_downgrades, false) },
        { label: "evidence events", body: String(tick.evidence_events), tone: toneFor(tick.evidence_events, false) },
    ];
}

function settingsCells(tick: TickState): Array<Stat> {
    return [
        { label: "world", body: worldName(tick), tone: "" },
        { label: "max players", body: String(tick.max_players) },
        { label: "info port", body: String(tick.info_port) },
        { label: "game port", body: String(tick.info_port + 2) },
        { label: "webui port", body: String(tick.webui_port) },
        { label: "blood moon every (days)", body: String(tick.bloodmoon_frequency) },
        { label: "view radius", body: String(tick.view_radius) },
        { label: "max streamed chunks", body: String(tick.max_streamed_chunks) },
        { label: "interest range (m)", body: String(Math.round(tick.interest_range)) },
        { label: "edit range (m)", body: String(Math.round(tick.max_edit_range)) },
        { label: "max spawned zombies", body: String(tick.max_spawned_zombies) },
        { label: "authority mode", body: tick.authority_correct ? "correct" : "observe", tone: tick.authority_correct ? "" : "num warn-text" },
        { label: "password", body: tick.password_set ? "set" : "not set", tone: "" },
        { label: "chunk streaming", body: tick.wire_chunks ? "on" : "off", tone: "" },
    ];
}

// ---- Panels ---------------------------------------------------------------------

function GlanceBand({ apm }: { apm: ApmJson }): ComponentChildren {
    const p99Ms = apm.tick_p99_ns / NS_PER_MS;
    const over = isOverBudget(apm);
    const blood = apm.bm;
    const fill = Math.round(Math.min(1, p99Ms / TICK_BUDGET_MS) * PERCENT_MAX);
    return (
        <div class="glance-band" role="region" aria-label="Server health at a glance">
            <div class="glance-cell">
                <b class="num" id="glance-tick">{String(apm.tick)}</b>
                <span>server tick</span>
            </div>
            <div class="glance-cell">
                <b class="num" id="glance-players">{`${apm.entered}/${apm.joined}`}</b>
                <span>players in world</span>
            </div>
            <div class="glance-cell">
                <b class="num" id="glance-p99">{`${p99Ms.toFixed(1)} ms`}</b>
                <span>tick p99 / 50 ms budget</span>
                <div
                    class={over ? "meter hot" : "meter"}
                    role="img"
                    id="glance-meter"
                    aria-label={`${p99Ms.toFixed(1)} milliseconds tick p99, ${over ? "over" : "within"} the 50 millisecond budget`}
                >
                    <i id="glance-meter-fill" style={{ transform: `scaleX(${fill / PERCENT_MAX})` }}></i>
                </div>
            </div>
            <div class="glance-cell">
                <b id="glance-state">{blood ? "ACTIVE" : "idle"}</b>
                <span id="glance-state-label">blood moon</span>
                <span class={`pill ${blood ? "bad" : "ok"} glance-pill`} id="glance-pill">{blood ? "blood moon" : "live"}</span>
            </div>
        </div>
    );
}

function onCompressChange(event: Event): void {
    const target = event.currentTarget;
    if (target instanceof HTMLInputElement) {
        setChartCompressed(target.checked);
    }
}

function onHistoryChange(event: Event): void {
    const target = event.currentTarget;
    if (target instanceof HTMLSelectElement) {
        setChartHistory(Number(target.value));
    }
}

function ChartToolbar({ historyRef }: { historyRef: RefObject<HTMLSelectElement> }): ComponentChildren {
    return (
        <span class="chart-tools-right">
            <label class="refresh-ctrl" for="chart-history">history</label>
            <select id="chart-history" aria-label="History window" ref={historyRef} onChange={onHistoryChange}>
                {CHART_HISTORY_OPTIONS.map((option) => (
                    <option value={String(option.value)} key={option.value}>{option.label}</option>
                ))}
            </select>
            <label class="refresh-ctrl" for="chart-compress">
                <input type="checkbox" id="chart-compress" checked onChange={onCompressChange} /> Compress history
            </label>
        </span>
    );
}

function ChartCanvas({ canvasRef }: { canvasRef: RefObject<HTMLCanvasElement> }): ComponentChildren {
    return (
        <div class="deck-body">
            <canvas
                id="apm-canvas"
                ref={canvasRef}
                width={600}
                height={150}
                role="img"
                tabindex={0}
                aria-label="Live tick latency and section means."
                aria-describedby="apm-chart-data apm-chart-live apm-chart-keys"
            >
                Live performance graphs require JavaScript.
            </canvas>
        </div>
    );
}

function ChartReadout({ liveRef, tableRef }: { liveRef: RefObject<HTMLParagraphElement>; tableRef: RefObject<HTMLTableSectionElement> }): ComponentChildren {
    return (
        <Fragment>
            <p id="apm-chart-live" class="sr-only" role="status" ref={liveRef}>collecting samples…</p>
            <p id="apm-chart-keys" class="sr-only">
                Focus and use left and right arrows to inspect past samples, Escape for live. Drag across the chart to inspect.
            </p>
            <table id="apm-chart-data" class="sr-only">
                <caption>Newest tick section means, milliseconds</caption>
                <thead>
                    <tr>
                        <th scope="col">Section</th>
                        <th scope="col">Mean</th>
                    </tr>
                </thead>
                <tbody ref={tableRef}></tbody>
            </table>
        </Fragment>
    );
}

function ChartDeck({ apm, visible, stale }: { apm: ApmJson; visible: boolean; stale: boolean }): ComponentChildren {
    const canvasRef = useRef<HTMLCanvasElement>(null);
    const captionRef = useRef<HTMLSpanElement>(null);
    const liveRef = useRef<HTMLParagraphElement>(null);
    const tableRef = useRef<HTMLTableSectionElement>(null);
    const historyRef = useRef<HTMLSelectElement>(null);

    useEffect(() => {
        const canvas = canvasRef.current;
        const caption = captionRef.current;
        const live = liveRef.current;
        const tableBody = tableRef.current;
        const historySelect = historyRef.current;
        if (canvas === null || caption === null || live === null || tableBody === null || historySelect === null) {
            return undefined;
        }
        attachChart({ canvas, caption, live, tableBody, historySelect });
        return () => {
            detachChart();
        };
    }, []);

    useEffect(() => {
        if (visible) {
            showLatestApm(apm);
            redrawChart();
        }
    }, [apm, visible]);

    useEffect(() => {
        if (stale) {
            setChartStale();
        }
    }, [stale]);

    return (
        <div class="deck" id="apm-chart-wrap">
            <div class="deck-head">
                <span class="job">tick · live</span>
                <span class="meta" id="apm-chart-caption" ref={captionRef}>collecting samples…</span>
                <ChartToolbar historyRef={historyRef} />
            </div>
            <ChartCanvas canvasRef={canvasRef} />
            <ChartReadout liveRef={liveRef} tableRef={tableRef} />
        </div>
    );
}

function StatusPanel({ state, visible, stale }: { state: StateJson; visible: boolean; stale: boolean }): ComponentChildren {
    const { tick } = state;
    return (
        <section id="status-section" role="tabpanel" tabindex={0} aria-labelledby="tab-status" hidden={!visible}>
            <h2 id="status-heading">Tick tape</h2>
            <p class="deck-sub">Live latency on the terminal. Numbers beside every signal; exact values in Performance.</p>
            <ChartDeck apm={state.apm} visible={visible} stale={stale} />
            <h3>Job file</h3>
            <div id="status">
                <StatGrid stats={statusCells(tick)} />
                <StatGrid heading="Entities" stats={entityCells(tick)} />
                <StatGrid heading="Server" stats={serverCells(tick)} />
                <StatGrid heading="Host" stats={hostCells(tick)} />
            </div>
        </section>
    );
}

function ApmPanel({ tick, visible }: { tick: TickState; visible: boolean }): ComponentChildren {
    return (
        <section id="apm-section" role="tabpanel" tabindex={0} aria-labelledby="tab-apm" hidden={!visible}>
            <h2 id="apm-heading">Performance and counters</h2>
            <div id="apm">
                <StatGrid heading="Latency (tick budget 50 ms)" stats={latencyCells(tick)} flush />
                <StatGrid heading="Traffic" stats={trafficCells(tick)} />
                <StatGrid heading="Errors and rejections" stats={errorCells(tick)} />
                <StatGrid heading="Guard policy" stats={guardCells(tick)} />
            </div>
        </section>
    );
}

function playerStateLabel(player: PlayerEntry): string {
    if (player.entered) {
        return "in world";
    }
    if (player.joined) {
        return "joined";
    }
    return "connecting";
}

function playerStateTone(player: PlayerEntry): string {
    if (player.entered) {
        return "ok";
    }
    if (player.joined) {
        return "warn";
    }
    return "";
}

function PlayersPanel({ players, visible }: { players: Array<PlayerEntry>; visible: boolean }): ComponentChildren {
    return (
        <section id="players-section" role="tabpanel" tabindex={0} aria-labelledby="tab-players" hidden={!visible}>
            <h2 id="players-heading">Players</h2>
            <div id="players" role="region" aria-label="Connected players table" tabindex={0}>
                <table class="stack">
                    <caption class="sr-only">Connected players</caption>
                    <thead>
                        <tr>
                            <th scope="col">Slot</th>
                            <th scope="col">Name</th>
                            <th scope="col">Entity ID</th>
                            <th scope="col">Position</th>
                            <th scope="col">State</th>
                        </tr>
                    </thead>
                    <tbody>
                        {players.length === 0 ? (
                            <tr>
                                <td colspan={5} class="empty-note">
                                    No players are connected. They appear here when clients join.
                                </td>
                            </tr>
                        ) : (
                            players.map((player) => (
                                <tr key={player.slot}>
                                    <td class="num" data-label="Slot">{String(player.slot)}</td>
                                    <th scope="row" data-label="Name">{player.name}</th>
                                    <td class="num" data-label="Entity ID">{String(player.entity_id)}</td>
                                    <td class="num" data-label="Position">{`${Math.round(player.x)},${Math.round(player.y)},${Math.round(player.z)}`}</td>
                                    <td data-label="State">
                                        <Pill tone={playerStateTone(player)}>{playerStateLabel(player)}</Pill>
                                    </td>
                                </tr>
                            ))
                        )}
                    </tbody>
                </table>
            </div>
        </section>
    );
}

function SettingsPanel({ tick, visible }: { tick: TickState; visible: boolean }): ComponentChildren {
    return (
        <section id="settings-section" role="tabpanel" tabindex={0} aria-labelledby="tab-settings" hidden={!visible}>
            <h2 id="settings-heading">Settings</h2>
            <p class="deck-sub">
                Read-only snapshot of the running server. Change these in <code>zdtd.toml</code> or the process flags, then restart.
            </p>
            <div id="settings" aria-live="polite" aria-atomic="true">
                <StatGrid heading="Server" stats={settingsCells(tick)} flush />
            </div>
        </section>
    );
}

function ModuleTable({ modules }: { modules: Array<ModuleEntry> }): ComponentChildren {
    return (
        <table class="stack">
            <caption class="sr-only">Loaded modules</caption>
            <thead>
                <tr>
                    <th scope="col">#</th>
                    <th scope="col">Module</th>
                    <th scope="col">State</th>
                </tr>
            </thead>
            <tbody>
                {modules.length === 0 ? (
                    <tr>
                        <td colspan={3} class="empty-note">
                            No modules loaded. Drop a .wasm under mods/ and restart, or run `plugin reload &lt;name&gt;`.
                        </td>
                    </tr>
                ) : (
                    modules.map((module, index) => (
                        <tr key={module.name}>
                            <td class="num" data-label="#">{String(index + 1)}</td>
                            <th scope="row" data-label="Module">{module.name}</th>
                            <td data-label="State">
                                <Pill tone={module.disabled ? "bad" : "ok"}>{module.disabled ? "disabled" : "enabled"}</Pill>
                            </td>
                        </tr>
                    ))
                )}
            </tbody>
        </table>
    );
}

/** XML-only modlets: the operator enables or disables each one. */
function ModletTable({
    modlets,
    csrf,
    pending,
    onAction,
}: {
    modlets: Array<ModletEntry>;
    csrf: string;
    pending: string | null;
    onAction: (name: string, action: string) => void;
}): ComponentChildren {
    return (
        <table class="stack">
            <caption class="sr-only">Game modlets</caption>
            <thead>
                <tr>
                    <th scope="col">#</th>
                    <th scope="col">Modlet</th>
                    <th scope="col">Version</th>
                    <th scope="col">State</th>
                    <th scope="col">Action</th>
                </tr>
            </thead>
            <tbody>
                {modlets.map((modlet, index) => (
                    <tr key={modlet.name}>
                        <td class="num" data-label="#">{String(index + 1)}</td>
                        <th scope="row" data-label="Modlet">
                            {modlet.name}
                            {modlet.has_code ? <span class="meta"> (code mod: XML only)</span> : null}
                        </th>
                        <td class="num" data-label="Version">{modlet.version}</td>
                        <td data-label="State">
                            <Pill tone={modlet.disabled ? "bad" : "ok"}>{modlet.disabled ? "disabled" : "enabled"}</Pill>
                        </td>
                        <td data-label="Action">
                            <form
                                method="post"
                                action={MODLET_URL}
                                onSubmit={(event) => {
                                    event.preventDefault();
                                    onAction(modlet.name, modlet.disabled ? "enable" : "disable");
                                }}
                            >
                                <input type="hidden" name="csrf" value={csrf} />
                                <input type="hidden" name="name" value={modlet.name} />
                                <input type="hidden" name="action" value={modlet.disabled ? "enable" : "disable"} />
                                <button type="submit" class="mod-btn" disabled={pending === modlet.name} aria-busy={pending === modlet.name}>
                                    {modlet.disabled ? "Enable" : "Disable"}
                                    <span class="sr-only"> {modlet.name}</span>
                                </button>
                            </form>
                        </td>
                    </tr>
                ))}
            </tbody>
        </table>
    );
}

function confirmModletDisable(name: string): boolean {
    // oxlint-disable-next-line no-alert -- deliberate: disabling a modlet needs a restart to take effect
    return globalThis.confirm(`Disable "${name}"? The change is saved now and applies after a server restart.`);
}

function modletSavedNote(name: string, action: string): string {
    const verb = action === "disable" ? "Disabled" : "Enabled";
    return `${verb} ${name}. Restart the server for the change to take effect.`;
}

function ModletFeedback({ failure, success }: { failure: string | null; success: string | null }): ComponentChildren {
    return (
        <Fragment>
            {failure === null ? null : (
                <p class="err modlet-err" role="alert">
                    {failure}
                </p>
            )}
            {success === null ? null : (
                <p class="ok modlet-ok" role="status">
                    {success}
                </p>
            )}
        </Fragment>
    );
}

function ModulesPanel({ state, visible, reload }: { state: StateJson; visible: boolean; reload: () => Promise<boolean> }): ComponentChildren {
    const [pending, setPending] = useState<string | null>(null);
    const [failure, setFailure] = useState<string | null>(null);
    const [success, setSuccess] = useState<string | null>(null);
    const modlets = state.modlets ?? [];
    const csrf = state.csrf;

    const runAction = async (name: string, action: string): Promise<void> => {
        if (pending !== null) {
            return;
        }
        if (action === "disable" && !confirmModletDisable(name)) {
            return;
        }
        setPending(name);
        setFailure(null);
        setSuccess(null);
        const post = await postModlet(csrf, name, action);
        setPending(null);
        if (post.kind === "redirect") {
            return;
        }
        if (post.kind === "failed") {
            setFailure(post.note);
            return;
        }
        if (!(await reload())) {
            setFailure("Modlet change was saved, but the dashboard could not refresh. Reload the page to confirm the new state.");
            return;
        }
        setSuccess(modletSavedNote(name, action));
    };

    return (
        <section id="modules-section" role="tabpanel" tabindex={0} aria-labelledby="tab-modules" hidden={!visible}>
            <h2 id="modules-heading">Modules</h2>
            <div id="modules" role="region" aria-label="Loaded module list" tabindex={0}>
                <ModuleTable modules={state.modules} />
                <h3>Game modlets</h3>
                <p class="deck-sub">
                    Enable or disable XML-only mods. A change is saved and applies after a restart (patches and item ids are resolved at startup).
                </p>
                <ModletFeedback failure={failure} success={success} />
                {modlets.length === 0 ? (
                    <p class="deck-sub">No mods scanned (no Mods/ dir under the game dir and no --mods-dir).</p>
                ) : (
                    <ModletTable
                        modlets={modlets}
                        csrf={csrf}
                        pending={pending}
                        onAction={(name, action) => {
                            void runAction(name, action);
                        }}
                    />
                )}
            </div>
        </section>
    );
}

const QUICK_COMMANDS: ReadonlyArray<{ line: string; label: string }> = [
    { line: "help", label: "help" },
    { line: "status", label: "status" },
    { line: "lp", label: "list players" },
    { line: "save", label: "save world" },
    { line: "settime day", label: "set day" },
    { line: "settime night", label: "set night" },
];

const DESTRUCTIVE_VERBS = new Set(["shutdown", "killall", "ka", "kick", "kickall", "ban", "wipeplayer"]);
const UNREACHABLE_REPLY = "The command response was not received, so its outcome is unknown. Check the command history below before running it again.";

function confirmDestructive(line: string): boolean {
    const verb = line.split(/\s+/u, 1)[0].toLowerCase();
    if (!DESTRUCTIVE_VERBS.has(verb)) {
        return true;
    }
    // oxlint-disable-next-line no-alert -- deliberate: destructive admin commands use a native confirm
    return globalThis.confirm(`Run "${verb}"? This can interrupt players or erase saved data.`);
}

const DECLINED_REPLY = "Not run: the confirmation was declined or blocked by the browser, so nothing was sent. Run it again to be asked again.";

/** A submitted line, or why it was not sent. An empty line reports itself. */
type LineDecision = { kind: "run"; line: string } | { kind: "empty" } | { kind: "declined"; line: string };

/** Trim and confirm the line. */
function validatedLine(input: HTMLInputElement, raw: string): LineDecision {
    const line = raw.trim();
    if (line === "") {
        input.setCustomValidity("Enter a command.");
        input.reportValidity();
        return { kind: "empty" };
    }
    input.setCustomValidity("");
    // A cancelled dialog and a browser-suppressed one both answer false; the
    // caller reports the refusal rather than dropping the command silently.
    if (!confirmDestructive(line)) {
        return { kind: "declined", line };
    }
    return { kind: "run", line };
}


function CommandForm({
    csrf,
    pending,
    inputRef,
    onRun,
}: {
    csrf: string;
    pending: boolean;
    inputRef: RefObject<HTMLInputElement>;
    onRun: (line: string) => void;
}): ComponentChildren {
    return (
        <Fragment>
            <form
                id="cmd-form"
                class="cmd-row"
                method="post"
                action={CMD_URL}
                onSubmit={(event) => {
                    event.preventDefault();
                    onRun(inputRef.current?.value ?? "");
                }}
            >
                <input type="hidden" name="csrf" value={csrf} />
                <label for="cmd-line" class="sr-only">Admin command</label>
                <input
                    type="text"
                    name="line"
                    id="cmd-line"
                    ref={inputRef}
                    placeholder="help · status · settime day"
                    aria-describedby="cmd-help-inline"
                    autocomplete="off"
                    spellcheck={false}
                    maxlength={MAX_CMD_LINE}
                    required
                    readOnly={pending}
                    aria-busy={pending}
                />
                <button type="submit" disabled={pending}>{pending ? "Running…" : "Run"}</button>
            </form>
            <div class="quick-row" id="quick-commands" role="group" aria-label="Quick commands">
                {QUICK_COMMANDS.map((quick) => (
                    <button
                        type="button"
                        class="quick-cmd"
                        key={quick.line}
                        data-cmd={quick.line}
                        disabled={pending}
                        onClick={() => {
                            onRun(quick.line);
                        }}
                    >
                        {quick.label}
                    </button>
                ))}
            </div>
        </Fragment>
    );
}

function CommandOutput({ pending, outcome }: { pending: boolean; outcome: CommandOutcome | null }): ComponentChildren {
    if (pending) {
        return <pre class="meta">Running command…</pre>;
    }
    if (outcome === null) {
        return null;
    }
    return (
        <pre class={outcome.failed ? "cmd-out err" : "cmd-out"} tabindex={0} data-command-error={outcome.failed ? "true" : undefined}>
            <span class="in">&gt; {outcome.line}</span>
            {"\n"}
            {outcome.text}
        </pre>
    );
}

/** The command output live region, plus the stable alert that carries failures.
 * The region keeps one role for its whole life: a role flipping between status
 * and alert is unreliably announced, so the alert text has its own node. */
function CommandResult({ pending, outcome }: { pending: boolean; outcome: CommandOutcome | null }): ComponentChildren {
    return (
        <Fragment>
            <div id="cmd-out" aria-live="polite" aria-atomic="true" role="status" aria-busy={pending}>
                <CommandOutput pending={pending} outcome={outcome} />
            </div>
            <p class="sr-only" role="alert">
                {outcome !== null && outcome.failed ? `${outcome.line}: ${outcome.text}` : ""}
            </p>
        </Fragment>
    );
}

function ConsoleHistory({ lines }: { lines: Array<string> }): ComponentChildren {
    return (
        <div id="console-log" aria-label="Recent commands" role="region" tabindex={-1}>
            <pre class="cmd-log" tabindex={0}>
                {lines.length === 0 ? (
                    <span class="meta">No commands run yet. Enter a command above and choose Run.</span>
                ) : (
                    lines.join("\n")
                )}
            </pre>
        </div>
    );
}

function ConsolePanel({ csrf, lines, visible, reload }: { csrf: string; lines: Array<string>; visible: boolean; reload: () => Promise<boolean> }): ComponentChildren {
    const inputRef = useRef<HTMLInputElement>(null);
    const [pending, setPending] = useState(false);
    const [outcome, setOutcome] = useState<CommandOutcome | null>(null);

    const runLine = async (raw: string): Promise<void> => {
        const input = inputRef.current;
        if (input === null || pending) {
            return;
        }
        const decision = validatedLine(input, raw);
        if (decision.kind !== "run") {
            if (decision.kind === "declined") {
                setOutcome({ line: decision.line, text: DECLINED_REPLY, failed: true });
                input.focus();
            }
            return;
        }
        setPending(true);
        setOutcome(null);
        const post = await postCommand(csrf, decision.line);
        setPending(false);
        if (post.kind === "redirect") {
            return;
        }
        if (post.kind === "unreachable") {
            setOutcome({ line: decision.line, text: UNREACHABLE_REPLY, failed: true });
            input.focus();
            return;
        }
        setOutcome(post.outcome);
        if (!post.outcome.failed) {
            input.value = "";
        }
        input.focus();
        void reload();
    };

    return (
        <section id="console-section" role="tabpanel" tabindex={0} aria-labelledby="tab-console" hidden={!visible}>
            <h2 id="console-heading">Console</h2>
            <p class="deck-sub">Same commands as the admin telnet console. Destructive verbs ask first.</p>
            <div class="deck">
                <div class="deck-head">
                    <span class="job">admin · stdout</span>
                    <span class="meta" id="cmd-help-inline">history keeps the last 24 lines</span>
                </div>
                <div class="deck-body">
                    <CommandForm
                        csrf={csrf}
                        pending={pending}
                        inputRef={inputRef}
                        onRun={(line) => void runLine(line)}
                    />
                    <CommandResult pending={pending} outcome={outcome} />
                    <ConsoleHistory lines={lines} />
                </div>
            </div>
        </section>
    );
}

// ---- App ------------------------------------------------------------------------

const TAB_SLUGS = ["status", "apm", "players", "console", "settings", "modules"] as const;
type TabSlug = (typeof TAB_SLUGS)[number];
const FAST_TABS: ReadonlySet<TabSlug> = new Set<TabSlug>(["status", "apm", "players"]);

function slugFromHash(): TabSlug | null {
    const raw = globalThis.location.hash.replace(/^#/u, "");
    return TAB_SLUGS.find((slug) => slug === raw) ?? null;
}

function tabSlug(button: HTMLButtonElement): string {
    return button.id.replace(/^tab-/u, "");
}

function nextTabIndex(key: string, index: number, last: number): number {
    if (key === "ArrowRight" || key === "ArrowDown") {
        return index + 1 > last ? 0 : index + 1;
    }
    if (key === "ArrowLeft" || key === "ArrowUp") {
        return index - 1 < 0 ? last : index - 1;
    }
    if (key === "Home") {
        return 0;
    }
    return last;
}

type SelectTab = (next: TabSlug) => void;

function useTabHash(select: SelectTab): void {
    // Registered once for the page lifetime: setState identity is stable and
    // the app root never unmounts, so the listener is not re-registered.
    useEffect(() => {
        globalThis.addEventListener("hashchange", () => {
            select(slugFromHash() ?? "status");
        });
    }, [select]);
}

// The nav is static markup, so the roving tabindex and aria-selected move with
// the active tab here instead of being rendered.
function useTabSelection(activeTab: TabSlug): void {
    useEffect(() => {
        const buttons = document.querySelectorAll<HTMLButtonElement>(".page-nav .tab");
        for (const button of buttons) {
            const on = tabSlug(button) === activeTab;
            button.setAttribute("aria-selected", String(on));
            if (on) {
                button.removeAttribute("tabindex");
            } else {
                button.tabIndex = -1;
            }
        }
        const hash = activeTab === "status" ? "" : `#${activeTab}`;
        const url = `${globalThis.location.pathname}${globalThis.location.search}${hash}`;
        const current = `${globalThis.location.pathname}${globalThis.location.search}${globalThis.location.hash}`;
        if (current !== url) {
            globalThis.history.replaceState(null, "", url);
        }
    }, [activeTab]);
}

function useTabNav(select: SelectTab): void {
    useEffect(() => {
        const nav = document.querySelector<HTMLElement>(".page-nav");
        if (nav === null) {
            return undefined;
        }
        const buttons = [...nav.querySelectorAll<HTMLButtonElement>(".tab")];
        const onClick = (event: Event): void => {
            const target = event.target;
            if (!(target instanceof HTMLButtonElement)) {
                return;
            }
            const slug = TAB_SLUGS.find((candidate) => candidate === tabSlug(target));
            if (slug !== undefined) {
                select(slug);
            }
        };
        // Both axes plus Home/End move per the APG tabs pattern.
        const onKeyDown = (event: KeyboardEvent): void => {
            const keys = new Set(["ArrowRight", "ArrowLeft", "ArrowDown", "ArrowUp", "Home", "End"]);
            if (!keys.has(event.key)) {
                return;
            }
            const index = buttons.findIndex((button) => button === document.activeElement);
            if (index < 0) {
                return;
            }
            event.preventDefault();
            const target = buttons[nextTabIndex(event.key, index, buttons.length - 1)];
            const slug = TAB_SLUGS.find((candidate) => candidate === tabSlug(target));
            if (slug !== undefined) {
                select(slug);
            }
            target.focus();
        };
        nav.addEventListener("click", onClick);
        nav.addEventListener("keydown", onKeyDown);
        return () => {
            nav.removeEventListener("click", onClick);
            nav.removeEventListener("keydown", onKeyDown);
        };
    }, [select]);
}

function useTabRouting(): TabSlug {
    const [activeTab, setActiveTab] = useState<TabSlug>(() => slugFromHash() ?? "status");
    useTabHash(setActiveTab);
    useTabSelection(activeTab);
    useTabNav(setActiveTab);
    return activeTab;
}

function useDashboard(autoEnabled: boolean, pageHidden: boolean, cadenceMs: number) {
    const [state, setState] = useState<StateJson | null>(null);
    const [failed, setFailed] = useState(false);

    /** Returns true when a fresh snapshot was applied. */
    const reload = useCallback(async (): Promise<boolean> => {
        const next = await fetchState();
        if (next === null) {
            setFailed(true);
            return false;
        }
        setFailed(false);
        setState(next);
        return true;
    }, []);

    useEffect(() => {
        if (!autoEnabled || pageHidden) {
            return undefined;
        }
        const poll = async (): Promise<void> => {
            await reload();
        };
        void poll();
        const timer = setInterval(() => {
            void poll();
        }, cadenceMs);
        return () => {
            clearInterval(timer);
        };
    }, [autoEnabled, pageHidden, cadenceMs, reload]);

    return { state, failed, reload };
}

const autoRefreshEl = queryEl("#auto-refresh", HTMLInputElement);
const refreshNowEl = queryEl("#refresh-now", HTMLButtonElement);
const refreshStateEl = queryEl("#refresh-state", HTMLElement);
const glanceLampEl = queryEl("#glance-lamp", HTMLElement);
const glanceWordEl = queryEl("#glance-word", HTMLElement);

/** The header word for the derived connection state. */
function glanceWord(failed: boolean, state: StateJson | null, over: boolean): string {
    if (failed) {
        return "no contact";
    }
    if (state === null) {
        return "connecting";
    }
    return over ? "over budget" : "operational";
}

function autoRefreshLabel(autoEnabled: boolean, pageHidden: boolean): string {
    if (!autoEnabled) {
        return "Auto-refresh paused";
    }
    if (pageHidden) {
        return "Auto-refresh paused while tab is hidden";
    }
    return "Auto-refresh on";
}

function Panels({ state, activeTab, failed, reload }: {
    state: StateJson;
    activeTab: TabSlug;
    failed: boolean;
    reload: () => Promise<boolean>;
}): ComponentChildren {
    return (
        <Fragment>
            <GlanceBand apm={state.apm} />
            <StatusPanel state={state} visible={activeTab === "status"} stale={failed} />
            <ApmPanel tick={state.tick} visible={activeTab === "apm"} />
            <PlayersPanel players={state.players} visible={activeTab === "players"} />
            <ConsolePanel csrf={state.csrf} lines={state.console} visible={activeTab === "console"} reload={reload} />
            <SettingsPanel tick={state.tick} visible={activeTab === "settings"} />
            <ModulesPanel state={state} visible={activeTab === "modules"} reload={reload} />
        </Fragment>
    );
}

function useAutoRefresh() {
    const [autoEnabled, setAutoEnabled] = useState(autoRefreshEl.checked);
    const [pageHidden, setPageHidden] = useState(document.hidden);
    const [refreshNote, setRefreshNote] = useState<string | null>(null);
    useEffect(() => {
        // A toggle or a tab switch overwrites the last manual-refresh note, as
        // the retired poller's applyRefresh did.
        const onToggle = (): void => {
            setAutoEnabled(autoRefreshEl.checked);
            setRefreshNote(null);
        };
        const onVisibility = (): void => {
            setPageHidden(document.hidden);
            setRefreshNote(null);
        };
        autoRefreshEl.addEventListener("change", onToggle);
        document.addEventListener("visibilitychange", onVisibility);
        return () => {
            autoRefreshEl.removeEventListener("change", onToggle);
            document.removeEventListener("visibilitychange", onVisibility);
        };
    }, []);
    return { autoEnabled, pageHidden, refreshNote, setRefreshNote };
}

function App(): ComponentChildren {
    const activeTab = useTabRouting();
    const { autoEnabled, pageHidden, refreshNote, setRefreshNote } = useAutoRefresh();
    const cadence = FAST_TABS.has(activeTab) ? POLL_FAST_MS : POLL_SLOW_MS;
    const { state, failed, reload } = useDashboard(autoEnabled, pageHidden, cadence);

    useEffect(() => {
        if (state !== null) {
            flashChanges(appRoot);
        }
    }, [state]);

    useEffect(() => {
        refreshStateEl.textContent = refreshNote ?? autoRefreshLabel(autoEnabled, pageHidden);
    }, [refreshNote, autoEnabled, pageHidden]);

    // One derived connection state for the header: the lamp and the word must
    // never describe the last good reading while the poll is failing.
    useEffect(() => {
        const over = state !== null && isOverBudget(state.apm);
        glanceLampEl.classList.toggle("bad", failed || over);
        glanceLampEl.classList.toggle("idle", state === null && !failed);
        glanceWordEl.textContent = glanceWord(failed, state, over);
    }, [state, failed]);

    const runRefresh = useCallback(async (): Promise<void> => {
        refreshNowEl.disabled = true;
        setRefreshNote("Refreshing…");
        const ok = await reload();
        refreshNowEl.disabled = false;
        refreshNowEl.focus();
        if (!ok) {
            setRefreshNote("Refresh failed - check the connection");
            return;
        }
        setRefreshNote(autoRefreshEl.checked ? "Refreshed (auto-refresh on)" : "Refreshed (auto-refresh paused)");
    }, [reload]);

    // Registered once: runRefresh identity is stable (reload is a stable callback).
    useEffect(() => {
        refreshNowEl.addEventListener("click", () => {
            void runRefresh();
        });
    }, [runRefresh]);

    const banner = failed ? (
        <p class="err banner-err" role="alert">
            Live data is unavailable. Check the connection; retrying automatically.
        </p>
    ) : null;
    let body: ComponentChildren;
    if (state !== null) {
        body = <Panels state={state} activeTab={activeTab} failed={failed} reload={reload} />;
    } else if (failed) {
        body = <p class="meta" role="status">Waiting for the server…</p>;
    } else {
        body = <p class="meta" role="status" aria-live="polite">Loading dashboard…</p>;
    }
    return (
        <Fragment>
            {banner}
            {body}
        </Fragment>
    );
}

render(<App />, appRoot);
