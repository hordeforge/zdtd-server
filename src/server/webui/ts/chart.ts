//! Tick latency chart for the operator dashboard: draws the time series on
//! #apm-canvas from the `apm` object of the /api/state.json poll. The x-axis
//! maps sample age through a log curve (COMPRESS_TAU_MS knee) so recent samples
//! keep full pixel width while older history compresses toward the left;
//! #chart-compress switches to a plain linear scale. The faint grid marks even
//! time/value intervals through the active mapping, so the leftward bunching is
//! the compression made visible. Attached by the ChartDeck component in
//! shell.tsx; both are bundled into the committed page.

/** The /api/apm.json object, nested under `apm` (renderApmJson in webui.zig). */
export type ApmJson = {
    tick_mean_ns: number;
    tick_p99_ns: number;
    tick: number;
    joined: number;
    entered: number;
    bm: boolean;
    net_mean_ns: number;
    sim_mean_ns: number;
    repl_mean_ns: number;
    stream_mean_ns: number;
    save_mean_ns: number;
};

const TICK_BUDGET_MS = 50;
const NS_PER_MS = 1_000_000;
const SEC_MS = 1000;
const SECONDS_PER_MINUTE = 60;
// The right-edge value animation spans exactly one state poll, so the drawn
// line catches up to the true value just as the next sample arrives.
const EDGE_LERP_MS = 1000;
const CHART_SAMPLES_MAX = 600;
const COMPRESS_TAU_MS = 60000;
const EDGE_PAD_PX = 2;
const LABEL_GUTTER_PX = 30;
const BOTTOM_GUTTER_PX = 14;
const LABEL_PAD_PX = 4;
const MAX_TIME_GRID_LINES = 12;
const MAX_VALUE_GRID_LINES = 10;
const LINE_WIDTH_PX = 1.5;
const ALPHA_GRID = 0.5;
const ALPHA_FILL = 0.3;
const ALPHA_GHOST = 0.45;
const ALPHA_LINE = 0.95;
const ALPHA_BUDGET = 0.85;
const DASH_LEN_PX = 4;
const DASH_GAP_PX = 3;
const EDGE_MARKER_RADIUS_PX = 3;
const GHOST_MARKER_RADIUS_PX = 2.5;
// Structure shown while the first samples arrive: the grid renders at the
// nominal window/scale so the empty instrument is visible immediately.
const PLACEHOLDER_WINDOW_MS = 60000;
const CHART_FONT = "10px ui-monospace, Menlo, Consolas, monospace";
const CAPTION_STALE = "live data unavailable - showing last samples";
const CAPTION_COLLECTING = "collecting samples…";
const CIRCLE = 2;
const HISTORY_STORAGE_KEY = "zdtd.apmHistoryMs";
const HISTORY_DEFAULT_MS = 300000;
const HISTORY_2_MIN_MS = 120000;
const HISTORY_5_MIN_MS = 300000;
const HISTORY_10_MIN_MS = 600000;
const HISTORY_WINDOW_MS: ReadonlySet<number> = new Set([
    HISTORY_2_MIN_MS,
    HISTORY_5_MIN_MS,
    HISTORY_10_MIN_MS,
]);
const TIME_GRID_5_S = 5000;
const TIME_GRID_10_S = 10000;
const TIME_GRID_15_S = 15000;
const TIME_GRID_30_S = 30000;
const TIME_GRID_60_S = 60000;
const TIME_GRID_120_S = 120000;
const TIME_GRID_300_S = 300000;
const TIME_GRID_600_S = 600000;
const VALUE_GRID_5_MS = 5;
const VALUE_GRID_10_MS = 10;
const VALUE_GRID_25_MS = 25;
const VALUE_GRID_50_MS = 50;
const VALUE_GRID_100_MS = 100;
const VALUE_GRID_250_MS = 250;
const VALUE_GRID_500_MS = 500;
const TIME_GRID_STEPS_MS: ReadonlyArray<number> = [
    TIME_GRID_5_S,
    TIME_GRID_10_S,
    TIME_GRID_15_S,
    TIME_GRID_30_S,
    TIME_GRID_60_S,
    TIME_GRID_120_S,
    TIME_GRID_300_S,
    TIME_GRID_600_S,
];
const VALUE_GRID_STEPS_MS: ReadonlyArray<number> = [
    VALUE_GRID_5_MS,
    VALUE_GRID_10_MS,
    VALUE_GRID_25_MS,
    VALUE_GRID_50_MS,
    VALUE_GRID_100_MS,
    VALUE_GRID_250_MS,
    VALUE_GRID_500_MS,
];
const SECTION_NS_KEYS: ReadonlyArray<keyof ApmJson> = ["net_mean_ns", "sim_mean_ns", "repl_mean_ns", "stream_mean_ns", "save_mean_ns"];
const SECTION_NAMES: ReadonlyArray<string> = ["network", "sim", "replication", "chunk stream", "save"];

type ApmSample = { at: number; tickMeanMs: number; tickP99Ms: number; sectionsMs: ReadonlyArray<number> };
type EdgeLerp = { fromMs: number; targetMs: number; startAt: number };

function cssVar(name: string): string {
    const styles = globalThis.getComputedStyle(document.documentElement);
    return styles.getPropertyValue(name).trim() || "#6b7280";
}

// The palette is re-read rather than frozen: forced-colors swaps the CSS
// variables, and the canvas is not recoloured by the browser.
let CHART_LINE_COLOR = "#6b7280";
let CHART_GHOST_COLOR = "#6b7280";
let CHART_GRID_COLOR = "#6b7280";
let CHART_LABEL_COLOR = "#6b7280";
let CHART_BUDGET_COLOR = "#6b7280";
let SECTION_FILL_COLORS: ReadonlyArray<string> = [];

function refreshChartPalette(): void {
    CHART_LINE_COLOR = cssVar("--term-ok");
    CHART_GHOST_COLOR = cssVar("--term-faint");
    CHART_GRID_COLOR = cssVar("--term-line");
    CHART_LABEL_COLOR = cssVar("--term-faint");
    CHART_BUDGET_COLOR = cssVar("--term-key");
    SECTION_FILL_COLORS = [
        cssVar("--term-line"),
        cssVar("--term-band1"),
        cssVar("--term-band2"),
        cssVar("--term-faint"),
        cssVar("--term-text"),
    ];
}

refreshChartPalette();

function loadHistoryMs(): number {
    // URL wins (?history=120000), then the stored preference, then the default.
    // Unknown values fall back down the chain (missing beats fake).
    const param = Number(new URLSearchParams(globalThis.location.search).get("history"));
    if (HISTORY_WINDOW_MS.has(param)) {
        return param;
    }
    // oxlint-disable-next-line @rikalabs/no-json-parse-default-fallback -- deliberate: localStorage holds a bare integer written by this page, not JSON; a Number() parse failure falls back to the default window
    const stored = Number(globalThis.localStorage.getItem(HISTORY_STORAGE_KEY));
    return HISTORY_WINDOW_MS.has(stored) ? stored : HISTORY_DEFAULT_MS;
}

// The drawing code runs from animation frames and pointer listeners rather
// than from a render, so it keeps the canvas and its readout elements as
// module handles, attached and released by the ChartDeck component.
let chartCanvas: HTMLCanvasElement | null = null;
let chartCtx: CanvasRenderingContext2D | null = null;
let chartCaption: HTMLElement | null = null;
let chartLive: HTMLElement | null = null;
let chartTableBody: HTMLElement | null = null;
const samples: Array<ApmSample> = [];
let chartCompressed = true;
let chartCssW = 0;
let chartCssH = 0;
let chartDpr = 1;
let chartMaxAgeMs = 0;
let chartYMaxMs = 0;
let chartRafId: number | null = null;
let resizeRafId: number | null = null;
let chartStale = false;
let edgeMean: EdgeLerp | null = null;
let edgeP99: EdgeLerp | null = null;
let scrubIndex: number | null = null;
let historyMs = loadHistoryMs();
let lastApm: ApmJson | null = null;
let reduceMotion: MediaQueryList | null = null;
let forcedColors: MediaQueryList | null = null;

function prefersReducedMotion(): boolean {
    if (reduceMotion === null) {
        reduceMotion = globalThis.matchMedia("(prefers-reduced-motion: reduce)");
    }
    return reduceMotion.matches;
}

function syncHistoryUrl(ms: number): void {
    const url = new URL(globalThis.location.href);
    if (url.searchParams.get("history") === String(ms)) {
        return;
    }
    if (ms === HISTORY_DEFAULT_MS) {
        url.searchParams.delete("history");
    } else {
        url.searchParams.set("history", String(ms));
    }
    globalThis.history.replaceState(null, "", `${url.pathname}${url.search}${url.hash}`);
}

function pruneHistory(): void {
    const cutoff = Date.now() - historyMs;
    while (samples.length > 0 && samples[0].at < cutoff) {
        samples.shift();
    }
}

function pickGridStep(steps: ReadonlyArray<number>, max: number, maxLines: number): number {
    for (const step of steps) {
        if (max / step <= maxLines) {
            return step;
        }
    }
    return steps[steps.length - 1];
}

function chartX(ageMs: number, maxAgeMs: number, plotW: number, compressed: boolean): number {
    if (maxAgeMs <= 0) {
        return plotW;
    }
    if (!compressed) {
        return plotW * (1 - ageMs / maxAgeMs);
    }
    const scaledAge = Math.log(1 + ageMs / COMPRESS_TAU_MS);
    const scaledMax = Math.log(1 + maxAgeMs / COMPRESS_TAU_MS);
    return plotW * (1 - scaledAge / scaledMax);
}

function edgeValueMs(edge: EdgeLerp | null, nowMs: number, currentMs: number): number {
    if (edge === null) {
        return currentMs;
    }
    const t = Math.min(1, (nowMs - edge.startAt) / EDGE_LERP_MS);
    return edge.fromMs + (edge.targetMs - edge.fromMs) * t;
}

function plotDims() {
    return { w: chartCssW - LABEL_GUTTER_PX - EDGE_PAD_PX, h: chartCssH - BOTTOM_GUTTER_PX - EDGE_PAD_PX };
}

function formatAge(ms: number): string {
    const totalSecs = Math.round(ms / SEC_MS);
    const mins = Math.floor(totalSecs / SECONDS_PER_MINUTE);
    if (mins > 0) {
        return `${mins}m`;
    }
    return `${totalSecs}s`;
}

function sizeChartCanvas(): boolean {
    if (chartCanvas === null) {
        return false;
    }
    const cssW = chartCanvas.clientWidth;
    const cssH = chartCanvas.clientHeight;
    if (cssW < 2 || cssH < 2) {
        return false;
    }
    const dpr = Math.max(1, globalThis.devicePixelRatio || 1);
    const pxW = Math.round(cssW * dpr);
    const pxH = Math.round(cssH * dpr);
    if (chartCanvas.width !== pxW || chartCanvas.height !== pxH) {
        chartCanvas.width = pxW;
        chartCanvas.height = pxH;
    }
    chartDpr = dpr;
    chartCssW = cssW;
    chartCssH = cssH;
    return true;
}

function drawPlaceholder(ctx: CanvasRenderingContext2D): void {
    ctx.fillStyle = CHART_LABEL_COLOR;
    ctx.font = CHART_FONT;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(CAPTION_COLLECTING, EDGE_PAD_PX + plotDims().w / 2, EDGE_PAD_PX + plotDims().h / 2);
}

function drawGrid(ctx: CanvasRenderingContext2D): void {
    const plot = plotDims();
    ctx.strokeStyle = CHART_GRID_COLOR;
    ctx.fillStyle = CHART_LABEL_COLOR;
    ctx.font = CHART_FONT;
    ctx.lineWidth = 1;
    ctx.globalAlpha = ALPHA_GRID;
    const timeStep = pickGridStep(TIME_GRID_STEPS_MS, chartMaxAgeMs, MAX_TIME_GRID_LINES);
    for (let k = 1; k * timeStep <= chartMaxAgeMs; k++) {
        const age = k * timeStep;
        const x = EDGE_PAD_PX + chartX(age, chartMaxAgeMs, plot.w, chartCompressed);
        ctx.beginPath();
        ctx.moveTo(x, EDGE_PAD_PX);
        ctx.lineTo(x, EDGE_PAD_PX + plot.h);
        ctx.stroke();
        ctx.textAlign = "center";
        ctx.textBaseline = "alphabetic";
        ctx.fillText(formatAge(age), x, chartCssH - LABEL_PAD_PX);
    }
    const valueStep = pickGridStep(VALUE_GRID_STEPS_MS, chartYMaxMs, MAX_VALUE_GRID_LINES);
    for (let v = valueStep; v <= chartYMaxMs; v += valueStep) {
        const y = EDGE_PAD_PX + plot.h * (1 - v / chartYMaxMs);
        ctx.beginPath();
        ctx.moveTo(EDGE_PAD_PX, y);
        ctx.lineTo(EDGE_PAD_PX + plot.w, y);
        ctx.stroke();
        ctx.textAlign = "left";
        ctx.textBaseline = "middle";
        ctx.fillText(String(v), EDGE_PAD_PX + plot.w + LABEL_PAD_PX, y);
    }
    ctx.globalAlpha = 1;
}

function drawStackedSections(ctx: CanvasRenderingContext2D, nowMs: number): void {
    const count = samples.length;
    const plot = plotDims();
    const xAt = (i: number): number => {
        const age = nowMs - samples[i].at;
        return EDGE_PAD_PX + chartX(age, chartMaxAgeMs, plot.w, chartCompressed);
    };
    const yAt = (ms: number): number => EDGE_PAD_PX + plot.h * (1 - ms / chartYMaxMs);
    ctx.globalAlpha = ALPHA_FILL;
    for (let s = 0; s < SECTION_FILL_COLORS.length; s++) {
        ctx.fillStyle = SECTION_FILL_COLORS[s];
        ctx.beginPath();
        let cum = 0;
        ctx.moveTo(xAt(0), yAt(0));
        for (let i = 0; i < count; i++) {
            cum += samples[i].sectionsMs[s];
            ctx.lineTo(xAt(i), yAt(cum));
        }
        for (let i = count - 1; i >= 0; i--) {
            ctx.lineTo(xAt(i), yAt(cum - samples[i].sectionsMs[s]));
        }
        ctx.closePath();
        ctx.fill();
    }
    ctx.globalAlpha = 1;
}

function traceLine(
    ctx: CanvasRenderingContext2D,
    nowMs: number,
    pick: (sample: ApmSample) => number,
    edge: EdgeLerp | null,
): void {
    const plot = plotDims();
    ctx.beginPath();
    // Fixed polyline through every sample but the newest, then one animated
    // segment from the previous sample to the right edge whose endpoint value
    // lerps toward the newest sample across the poll interval.
    const fixedCount = samples.length - 1;
    for (let i = 0; i < fixedCount; i++) {
        const sample = samples[i];
        const age = nowMs - sample.at;
        const x = EDGE_PAD_PX + chartX(age, chartMaxAgeMs, plot.w, chartCompressed);
        const y = EDGE_PAD_PX + plot.h * (1 - pick(sample) / chartYMaxMs);
        if (i === 0) {
            ctx.moveTo(x, y);
        } else {
            ctx.lineTo(x, y);
        }
    }
    const last = samples[fixedCount - 1];
    ctx.lineTo(EDGE_PAD_PX + plot.w, EDGE_PAD_PX + plot.h * (1 - edgeValueMs(edge, nowMs, pick(last)) / chartYMaxMs));
    ctx.stroke();
}

function drawSeries(ctx: CanvasRenderingContext2D, nowMs: number): void {
    ctx.setLineDash([DASH_LEN_PX, DASH_GAP_PX]);
    ctx.strokeStyle = CHART_GHOST_COLOR;
    ctx.globalAlpha = ALPHA_GHOST;
    ctx.lineWidth = 1;
    traceLine(ctx, nowMs, (sample) => sample.tickP99Ms, edgeP99);
    ctx.setLineDash([]);
    ctx.strokeStyle = CHART_LINE_COLOR;
    ctx.globalAlpha = ALPHA_LINE;
    ctx.lineWidth = LINE_WIDTH_PX;
    traceLine(ctx, nowMs, (sample) => sample.tickMeanMs, edgeMean);
    ctx.globalAlpha = 1;
}

function drawBudgetLine(ctx: CanvasRenderingContext2D): void {
    if (TICK_BUDGET_MS > chartYMaxMs) {
        return;
    }
    const plot = plotDims();
    const y = EDGE_PAD_PX + plot.h * (1 - TICK_BUDGET_MS / chartYMaxMs);
    ctx.strokeStyle = CHART_BUDGET_COLOR;
    ctx.globalAlpha = ALPHA_BUDGET;
    ctx.setLineDash([DASH_LEN_PX, DASH_GAP_PX]);
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(EDGE_PAD_PX, y);
    ctx.lineTo(EDGE_PAD_PX + plot.w, y);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.globalAlpha = 1;
}

function setCaption(text: string): void {
    if (chartCaption !== null && chartCaption.textContent !== text) {
        chartCaption.textContent = text;
    }
}

function markChartLive(): void {
    chartStale = false;
    setCaption(CAPTION_COLLECTING);
}

function markChartStale(): void {
    // The caption is rewritten by every frame, so staleness is a flag the
    // frame respects rather than a one-shot write the next frame erases.
    chartStale = true;
    setCaption(CAPTION_STALE);
    if (chartLive !== null) {
        chartLive.textContent = CAPTION_STALE;
    }
}

// Non-visual equivalent of the canvas: the newest section means as a
// visually-hidden table, so a screen-reader operator gets the same numbers the
// graph shows. Built as DOM nodes, never as HTML text.
function updateChartTable(): void {
    if (chartTableBody === null || samples.length === 0) {
        return;
    }
    const newest = samples[samples.length - 1];
    const signature = SECTION_NAMES.map((name, i) => `${name}=${newest.sectionsMs[i].toFixed(2)}`).join("|");
    if (chartTableBody.dataset.sig === signature) {
        return;
    }
    const built = SECTION_NAMES.map((name, i) => {
        const row = document.createElement("tr");
        const head = document.createElement("th");
        head.setAttribute("scope", "row");
        head.textContent = name;
        const cell = document.createElement("td");
        cell.textContent = `${newest.sectionsMs[i].toFixed(2)} ms`;
        row.append(head, cell);
        return row;
    });
    chartTableBody.replaceChildren(...built);
    chartTableBody.dataset.sig = signature;
}

// Keyboard scrub: the canvas is focusable and ArrowLeft/Right move an
// inspection cursor through the samples; the readout (same element as the live
// caption) announces that sample. Any new sample or resize clears the cursor.
function scrubSample(): ApmSample | null {
    if (scrubIndex === null || scrubIndex < 0 || scrubIndex >= samples.length) {
        return null;
    }
    return samples[scrubIndex];
}

function announceScrub(): void {
    if (chartLive === null) {
        return;
    }
    const sample = scrubSample();
    if (sample === null) {
        return;
    }
    const ageS = Math.max(0, Math.round((Date.now() - sample.at) / SEC_MS));
    const sections = sample.sectionsMs.map((ms, i) => `${SECTION_NAMES[i]} ${ms.toFixed(1)}`).join(", ");
    const text = `sample ${ageS}s ago: mean ${sample.tickMeanMs.toFixed(1)}, p99 ${sample.tickP99Ms.toFixed(1)} ms. ${sections} ms`;
    if (chartLive.textContent !== text) {
        chartLive.textContent = text;
    }
}

function announceLive(): void {
    if (chartStale || chartLive === null || scrubIndex !== null || samples.length === 0) {
        return;
    }
    const newest = samples[samples.length - 1];
    const text = `live: mean ${newest.tickMeanMs.toFixed(1)}, p99 ${newest.tickP99Ms.toFixed(1)} ms`;
    if (chartLive.textContent !== text) {
        chartLive.textContent = text;
    }
}

function clearScrub(): void {
    scrubIndex = null;
}

const SCRUB_BACK = -1;
const SCRUB_FWD = 1;
type ScrubDir = typeof SCRUB_BACK | typeof SCRUB_FWD;

// Leading-edge markers plus their paired numeric readout: the eye anchor and
// the stable-position numbers for the newest mean/p99 values.
function finishChartFrame(ctx: CanvasRenderingContext2D, nowMs: number): void {
    const plot = plotDims();
    const x = EDGE_PAD_PX + plot.w;
    const newest = samples[samples.length - 1];
    const yAt = (ms: number): number => EDGE_PAD_PX + plot.h * (1 - ms / chartYMaxMs);
    const p99Now = edgeValueMs(edgeP99, nowMs, newest.tickP99Ms);
    const meanNow = edgeValueMs(edgeMean, nowMs, newest.tickMeanMs);
    ctx.globalAlpha = 1;
    ctx.beginPath();
    ctx.arc(x, yAt(p99Now), GHOST_MARKER_RADIUS_PX, 0, CIRCLE * Math.PI);
    ctx.fillStyle = CHART_GHOST_COLOR;
    ctx.fill();
    ctx.beginPath();
    ctx.arc(x, yAt(meanNow), EDGE_MARKER_RADIUS_PX, 0, CIRCLE * Math.PI);
    ctx.fillStyle = CHART_LINE_COLOR;
    ctx.fill();
    if (!chartStale) {
        setCaption(`mean ${meanNow.toFixed(1)} · p99 ${p99Now.toFixed(1)} ms · budget ${TICK_BUDGET_MS} ms`);
    }
    updateChartTable();
    announceLive();
}

function drawScrubCursor(ctx: CanvasRenderingContext2D, nowMs: number): void {
    const sample = scrubSample();
    if (sample === null) {
        return;
    }
    const plot = plotDims();
    const x = EDGE_PAD_PX + chartX(nowMs - sample.at, chartMaxAgeMs, plot.w, chartCompressed);
    const yAt = (ms: number): number => EDGE_PAD_PX + plot.h * (1 - ms / chartYMaxMs);
    ctx.save();
    ctx.strokeStyle = CHART_LINE_COLOR;
    ctx.globalAlpha = 1;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x, EDGE_PAD_PX);
    ctx.lineTo(x, EDGE_PAD_PX + plot.h);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(x, yAt(sample.tickMeanMs), EDGE_MARKER_RADIUS_PX + 1, 0, CIRCLE * Math.PI);
    ctx.fillStyle = CHART_LINE_COLOR;
    ctx.fill();
    ctx.restore();
}

function drawChart(nowMs: number): void {
    if (chartCtx === null || chartCanvas === null || !sizeChartCanvas()) {
        return;
    }
    const ctx = chartCtx;
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, chartCanvas.width, chartCanvas.height);
    ctx.restore();
    ctx.setTransform(chartDpr, 0, 0, chartDpr, 0, 0);
    if (samples.length < 2) {
        // Render the empty structure at nominal scales: absence of signal is
        // visible as an unlit instrument, not a blank box.
        chartMaxAgeMs = PLACEHOLDER_WINDOW_MS;
        chartYMaxMs = TICK_BUDGET_MS;
        drawGrid(ctx);
        drawPlaceholder(ctx);
        return;
    }
    // Ages are wall-clock relative so the whole chart slides left smoothly
    // between polls; the rAF loop below keeps it animating while visible.
    chartMaxAgeMs = nowMs - samples[0].at;
    let rawMax = TICK_BUDGET_MS;
    for (const sample of samples) {
        rawMax = Math.max(rawMax, sample.tickMeanMs, sample.tickP99Ms);
    }
    const stepMs = pickGridStep(VALUE_GRID_STEPS_MS, rawMax, MAX_VALUE_GRID_LINES);
    chartYMaxMs = stepMs * Math.ceil(rawMax / stepMs);
    drawGrid(ctx);
    drawStackedSections(ctx, nowMs);
    drawSeries(ctx, nowMs);
    drawBudgetLine(ctx);
    drawScrubCursor(ctx, nowMs);
    finishChartFrame(ctx, nowMs);
    // The frame loop animates the edge lerp and the wall-clock slide. Under
    // reduced motion the per-sample redraw is the still frame. Once the lerp
    // settles the slide moves sub-pixel per frame, so the chain stops and the
    // next sample redraws.
    const lerping = (edgeMean !== null && nowMs - edgeMean.startAt < EDGE_LERP_MS) || (edgeP99 !== null && nowMs - edgeP99.startAt < EDGE_LERP_MS);
    if (!prefersReducedMotion() && lerping && chartRafId === null) {
        chartRafId = globalThis.requestAnimationFrame(() => {
            chartRafId = null;
            drawChart(Date.now());
        });
    }
}

function stepScrub(dir: ScrubDir): void {
    if (samples.length === 0) {
        return;
    }
    if (scrubIndex === null) {
        scrubIndex = samples.length - 1;
    } else {
        scrubIndex = Math.min(samples.length - 1, Math.max(0, scrubIndex + dir));
    }
    announceScrub();
    drawChart(Date.now());
}

function toSample(json: ApmJson): ApmSample {
    return {
        at: Date.now(),
        tickMeanMs: json.tick_mean_ns / NS_PER_MS,
        tickP99Ms: json.tick_p99_ns / NS_PER_MS,
        sectionsMs: SECTION_NS_KEYS.map((key) => {
            const value = json[key];
            return typeof value === "number" ? value / NS_PER_MS : 0;
        }),
    };
}

function pushSample(sample: ApmSample): void {
    samples.push(sample);
    if (samples.length > CHART_SAMPLES_MAX) {
        samples.splice(0, samples.length - CHART_SAMPLES_MAX);
    }
    pruneHistory();
    // New data invalidates the inspection cursor; the live edge is the truth.
    clearScrub();
}

function startEdgeLerp(): void {
    const count = samples.length;
    if (count < 2) {
        edgeMean = null;
        edgeP99 = null;
        return;
    }
    const newest = samples[count - 1];
    const prev = samples[count - 2];
    const now = Date.now();
    edgeMean = { fromMs: prev.tickMeanMs, targetMs: newest.tickMeanMs, startAt: now };
    edgeP99 = { fromMs: prev.tickP99Ms, targetMs: newest.tickP99Ms, startAt: now };
}

function chartStopRaf(): void {
    if (chartRafId !== null) {
        globalThis.cancelAnimationFrame(chartRafId);
        chartRafId = null;
    }
    if (resizeRafId !== null) {
        globalThis.cancelAnimationFrame(resizeRafId);
        resizeRafId = null;
    }
}

function pointerScrubTo(event: PointerEvent): void {
    if (chartCanvas === null || samples.length === 0 || !sizeChartCanvas()) {
        return;
    }
    const plot = plotDims();
    if (plot.w <= 0) {
        return;
    }
    const rect = chartCanvas.getBoundingClientRect();
    const frac = (event.clientX - rect.left - EDGE_PAD_PX) / plot.w;
    const nowMs = Date.now();
    let best = 0;
    let bestDist = Number.POSITIVE_INFINITY;
    for (let i = 0; i < samples.length; i++) {
        const x = EDGE_PAD_PX + chartX(nowMs - samples[i].at, chartMaxAgeMs, plot.w, chartCompressed);
        const dist = Math.abs(x / plot.w - frac);
        if (dist < bestDist) {
            bestDist = dist;
            best = i;
        }
    }
    scrubIndex = best;
    announceScrub();
    drawChart(nowMs);
}

function onChartKeyDown(event: KeyboardEvent): void {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight" && event.key !== "Escape") {
        return;
    }
    event.preventDefault();
    if (event.key === "Escape") {
        clearScrub();
        drawChart(Date.now());
        return;
    }
    stepScrub(event.key === "ArrowLeft" ? SCRUB_BACK : SCRUB_FWD);
}

// ---- Component-facing API -------------------------------------------------------

export type ChartHandles = {
    canvas: HTMLCanvasElement;
    caption: HTMLElement;
    live: HTMLElement;
    tableBody: HTMLElement;
    historySelect: HTMLSelectElement;
};

export const CHART_HISTORY_OPTIONS: ReadonlyArray<{ value: number; label: string }> = [
    { value: HISTORY_2_MIN_MS, label: "2 min" },
    { value: HISTORY_5_MIN_MS, label: "5 min" },
    { value: HISTORY_10_MIN_MS, label: "10 min" },
];

let scrubbing = false;

function onChartPointerDown(event: PointerEvent): void {
    if (chartCanvas === null || samples.length < 2) {
        return;
    }
    scrubbing = true;
    chartCanvas.setPointerCapture(event.pointerId);
    pointerScrubTo(event);
}

function onChartPointerMove(event: PointerEvent): void {
    if (scrubbing) {
        pointerScrubTo(event);
    }
}

function onChartPointerUp(): void {
    scrubbing = false;
}

function onChartResize(): void {
    // One redraw per frame: a drag-resize fires far more events than frames.
    if (resizeRafId !== null) {
        return;
    }
    resizeRafId = globalThis.requestAnimationFrame(() => {
        resizeRafId = null;
        drawChart(Date.now());
    });
}

function onColorSchemeChange(): void {
    refreshChartPalette();
    drawChart(Date.now());
}

/** Bind the canvas and its readout elements; wires scrub, keyboard, resize. */
export function attachChart(handles: ChartHandles): void {
    chartCanvas = handles.canvas;
    chartCtx = handles.canvas.getContext("2d");
    chartCaption = handles.caption;
    chartLive = handles.live;
    chartTableBody = handles.tableBody;
    handles.historySelect.value = String(historyMs);
    handles.canvas.addEventListener("keydown", onChartKeyDown);
    handles.canvas.addEventListener("pointerdown", onChartPointerDown);
    handles.canvas.addEventListener("pointermove", onChartPointerMove);
    handles.canvas.addEventListener("pointerup", onChartPointerUp);
    handles.canvas.addEventListener("pointercancel", onChartPointerUp);
    globalThis.addEventListener("resize", onChartResize);
    if (forcedColors === null) {
        forcedColors = globalThis.matchMedia("(forced-colors: active)");
    }
    forcedColors.addEventListener("change", onColorSchemeChange);
    refreshChartPalette();
}

export function detachChart(): void {
    if (chartCanvas !== null) {
        chartCanvas.removeEventListener("keydown", onChartKeyDown);
        chartCanvas.removeEventListener("pointerdown", onChartPointerDown);
        chartCanvas.removeEventListener("pointermove", onChartPointerMove);
        chartCanvas.removeEventListener("pointerup", onChartPointerUp);
        chartCanvas.removeEventListener("pointercancel", onChartPointerUp);
    }
    globalThis.removeEventListener("resize", onChartResize);
    forcedColors?.removeEventListener("change", onColorSchemeChange);
    chartStopRaf();
    chartCanvas = null;
    chartCtx = null;
    chartCaption = null;
    chartLive = null;
    chartTableBody = null;
}

/** Push a new sample from the state poll and animate the live edge. */
export function showLatestApm(apm: ApmJson): void {
    if (apm === lastApm) {
        return;
    }
    lastApm = apm;
    pushSample(toSample(apm));
    startEdgeLerp();
    markChartLive();
}

export function redrawChart(): void {
    drawChart(Date.now());
}

export function setChartCompressed(compressed: boolean): void {
    chartCompressed = compressed;
    drawChart(Date.now());
}

export function setChartStale(): void {
    markChartStale();
}

export function setChartHistory(ms: number): void {
    if (!HISTORY_WINDOW_MS.has(ms)) {
        return;
    }
    historyMs = ms;
    syncHistoryUrl(ms);
    try {
        globalThis.localStorage.setItem(HISTORY_STORAGE_KEY, String(ms));
        // oxlint-disable-next-line @rikalabs/no-silent-catch-fallback -- deliberate: persistence is best-effort (storage can be blocked in private mode); the chosen window still applies to this session
    } catch {
        // The chosen window still applies to this session.
    }
    pruneHistory();
    drawChart(Date.now());
}
