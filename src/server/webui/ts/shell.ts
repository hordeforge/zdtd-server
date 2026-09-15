//! Webui dashboard shell: htmx-style poller for the [hx-get] partials,
//! auto-refresh toggle, the admin console form (POST /api/cmd), and the
//! hx-post modlet forms (POST /api/modlet, delegated: the Modules partial
//! re-renders every 5s so per-form wiring would die on each poll swap).
//! Compiled by scripts/build-webui-ts.sh and injected into shell.html.

const FETCH_TIMEOUT_MS = 8000;
const HTTP_UNAUTHORIZED = 401;
const POLL_SLOW_MS = 5000;
const POLL_FAST_MS = 1000;

/** Element with the poller handles installed by hxPoll (same shape as the
 * _hxStart/_hxStop/_hxOnce hooks the page scripts use; underscores are
 * deliberate and covered by the no-underscore-dangle off entry). */
type HxPollerElement = HTMLElement & {
    _hxStart?: () => void;
    _hxStop?: () => void;
    _hxOnce?: () => Promise<void>;
};

function fetchWithTimeout(url: string, options: RequestInit = {}): Promise<Response> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    return fetch(url, { ...options, signal: controller.signal }).finally(() => clearTimeout(timeout));
}

function queryEl<T extends HTMLElement>(selector: string): T {
    const el = document.querySelector<T>(selector);
    if (el === null) {
        throw new Error(`webui: missing element ${selector}`);
    }
    return el;
}

// Churn visibility: after a poller swaps in fresh markup, flash the stat cells
// and table rows whose text changed so updates register in peripheral vision.
// Signatures are keyed by position within the region; a reorder therefore
// flashes too, which is honest (the order did change).
const FLASH_MS = 1200;
const prevSigs = new WeakMap<HTMLElement, Map<string, string>>();
let reduceMotion: MediaQueryList | null = null;

function flashChanges(el: HTMLElement): void {
    if (reduceMotion === null) {
        reduceMotion = globalThis.matchMedia('(prefers-reduced-motion: reduce)');
    }
    if (reduceMotion.matches) {
        return;
    }
    const nodes = el.querySelectorAll<HTMLElement>('.stat, tbody tr');
    const prev = prevSigs.get(el);
    const next = new Map<string, string>();
    let index = 0;
    for (const node of nodes) {
        next.set(String(index), node.textContent ?? '');
        if (prev !== undefined && prev.size > 0 && prev.get(String(index)) !== next.get(String(index))) {
            node.classList.remove('flash');
            // Force a reflow so back-to-back flashes restart the animation.
            void node.offsetWidth;
            node.classList.add('flash');
            globalThis.setTimeout(() => node.classList.remove('flash'), FLASH_MS);
        }
        index += 1;
    }
    prevSigs.set(el, next);
}

// Poller swap factory: one closure per polled region, created here so hxPoll
// stays a thin wiring function. Inlining it would push hxPoll past the
// 60-line function cap the strict preset enforces; the
// @rikalabs/no-single-use-trivial-helpers off entry covers this.
// createSwap replaces the region's content with the fetched partial
// (hx-swap is always innerHTML on this page; the attribute stays in markup
// as documentation of the intent, but this poller is the implementation).

function createSwap(el: HxPollerElement, u: string): (force?: boolean) => Promise<void> {
    let inFlight = false;
    // Force=true skips the focus guard: Refresh now and post-command refreshes
    // must swap even while the operator is reading a focused scroll region.
    return (force = false): Promise<void> => {
        if (inFlight || (!force && el.contains(document.activeElement))) {
            return Promise.resolve();
        }
        inFlight = true;
        el.setAttribute('aria-busy', 'true');
        const regionScroll = el.scrollLeft;
        const pre = el.querySelector('pre');
        const preScroll = pre ? pre.scrollTop : 0;
        return fetchWithTimeout(u, { credentials: 'same-origin' })
            .then((r) => {
                if (r.status === HTTP_UNAUTHORIZED) {
                    globalThis.location.assign('/login');
                    return null;
                }
                return r.ok ? r.text() : Promise.reject(new Error(`HTTP ${r.status}`));
            })
            .then((t) => {
                if (t === null) {
                    return;
                }
            el.innerHTML = t;
            delete el.dataset.loadError;
            flashChanges(el);
            el.scrollLeft = regionScroll;
                const npre = el.querySelector('pre');
                if (npre) {
                    npre.scrollTop = preScroll;
                }
            })
            .catch(() => {
                if (!('loadError' in el.dataset)) {
                    el.innerHTML = '<p class="err" role="alert">Live data is unavailable. Check the connection; retrying automatically.</p>';
                }
                el.dataset.loadError = 'true';
            })
            .finally(() => {
                inFlight = false;
                el.removeAttribute('aria-busy');
            });
    };
}

function hxPoll(el: HxPollerElement): void {
    const u = el.getAttribute('hx-get');
    if (!u) {
        return;
    }
    const swap = createSwap(el, u);
    const trigger = el.getAttribute('hx-trigger');
    const ms = trigger && trigger.includes('5s') ? POLL_SLOW_MS : POLL_FAST_MS;
    let timer: ReturnType<typeof setInterval> | null = null;
    el._hxStart = (): void => {
        if (timer) {
            return;
        }
        void swap();
        timer = setInterval(() => void swap(), ms);
    };
    el._hxStop = (): void => {
        if (timer) {
            clearInterval(timer);
            timer = null;
        }
    };
    el._hxOnce = (): Promise<void> => swap(true);
}

const polls = [...document.querySelectorAll<HxPollerElement>('[hx-get]')];
for (const pollEl of polls) {
    hxPoll(pollEl);
}

const autoEl = queryEl<HTMLInputElement>('#auto-refresh');
const refreshState = document.querySelector<HTMLElement>('#refresh-state');
const refreshNowButton = queryEl<HTMLButtonElement>('#refresh-now');
const cmdForm = queryEl<HTMLFormElement>('#cmd-form');

// ---- APM latency chart (tick budget + section means) ----
// Draws a live time-series on #apm-canvas from /api/apm.json. The x-axis maps
// sample age through a log curve (COMPRESS_TAU_MS knee) so recent samples keep
// full pixel width while older history compresses toward the left; the
// #chart-compress toggle switches to a plain linear scale. The faint grid
// marks even time/value intervals through the active mapping, so the leftward
// bunching of the time lines is the compression made visible.

const SEC_MS = 1000;
const MIN_S = 60;
const NS_PER_MS = 1000000;
const APM_POLL_MS = POLL_FAST_MS;
// The right-edge value animation spans exactly one poll interval, so the
// drawn line catches up to the true value just as the next sample arrives.
const EDGE_LERP_MS = APM_POLL_MS;
const CHART_SAMPLES_MAX = 600;
const TICK_BUDGET_MS = 50;
const COMPRESS_TAU_MS = 60000;
const APM_JSON_URL = '/api/apm.json';
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
// Structure shown while the first samples are still arriving: the grid renders
// at the nominal window/scale so the empty instrument is visible immediately.
const PLACEHOLDER_WINDOW_MS = 60000;
const CHART_FONT = '10px ui-monospace, Menlo, Consolas, monospace';
const CAPTION_STALE = 'live data unavailable - showing last samples';
// Configurable history window (rule: depth is a setting, memory proportional
// to what is drawn). Pruned on every push; ceiling = CHART_SAMPLES_MAX polls.
const HISTORY_STORAGE_KEY = 'zdtd.apmHistoryMs';
const HISTORY_DEFAULT_MS = 300000;
const HISTORY_2_MIN_MS = 120000;
const HISTORY_5_MIN_MS = 300000;
const HISTORY_10_MIN_MS = 600000;
const HISTORY_WINDOW_MS: ReadonlyArray<number> = [HISTORY_2_MIN_MS, HISTORY_5_MIN_MS, HISTORY_10_MIN_MS];
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

type ApmSample = {
    at: number;
    tickMeanMs: number;
    tickP99Ms: number;
    sectionsMs: ReadonlyArray<number>;
    tick: number;
    joined: number;
    entered: number;
    bloodmoonActive: boolean;
};

type ApmJson = {
    tick_mean_ns: number;
    tick_p99_ns: number;
    net_mean_ns: number;
    sim_mean_ns: number;
    repl_mean_ns: number;
    stream_mean_ns: number;
    save_mean_ns: number;
    tick: number;
    joined: number;
    entered: number;
    bm: boolean;
};

type EdgeLerp = {
    fromMs: number;
    targetMs: number;
    startAt: number;
};

const SECTION_NS_KEYS: ReadonlyArray<'net_mean_ns' | 'sim_mean_ns' | 'repl_mean_ns' | 'stream_mean_ns' | 'save_mean_ns'> = ['net_mean_ns', 'sim_mean_ns', 'repl_mean_ns', 'stream_mean_ns', 'save_mean_ns'];
const SECTION_NAMES: ReadonlyArray<string> = ['network', 'sim', 'replication', 'chunk stream', 'save'];

function cssVar(name: string): string {
    const styles = globalThis.getComputedStyle(document.documentElement);
    return styles.getPropertyValue(name).trim() || '#6b7280';
}

const CHART_LINE_COLOR = cssVar('--term-ok');
const CHART_GHOST_COLOR = cssVar('--term-faint');
const CHART_GRID_COLOR = cssVar('--term-line');
const CHART_LABEL_COLOR = cssVar('--term-faint');
const CHART_BUDGET_COLOR = cssVar('--term-key');
const SECTION_FILL_COLORS: ReadonlyArray<string> = [
    cssVar('--term-line'),
    cssVar('--term-band1'),
    cssVar('--term-band2'),
    cssVar('--term-faint'),
    cssVar('--term-text'),
];

const chartCanvas = queryEl<HTMLCanvasElement>('#apm-canvas');
const chartCtx = chartCanvas.getContext('2d');
const compressEl = queryEl<HTMLInputElement>('#chart-compress');
const historyEl = queryEl<HTMLSelectElement>('#chart-history');
const chartCaption = document.querySelector<HTMLElement>('#apm-chart-caption');
const chartWrap = document.querySelector<HTMLElement>('#apm-chart-wrap');

function loadHistoryMs(): number {
    // URL wins (?history=120000), then the stored preference, then default.
    // Unknown values fall back down the chain (missing beats fake).
    const param = Number(new URLSearchParams(globalThis.location.search).get('history'));
    if (HISTORY_WINDOW_MS.includes(param)) {
        return param;
    }
    // oxlint-disable-next-line @rikalabs/no-json-parse-default-fallback -- deliberate: localStorage holds a bare integer written by this page, not JSON; Number() parse failure falls back to the default window
    const stored = Number(globalThis.localStorage.getItem(HISTORY_STORAGE_KEY));
    return HISTORY_WINDOW_MS.includes(stored) ? stored : HISTORY_DEFAULT_MS;
}

function syncHistoryUrl(ms: number): void {
    const url = new URL(globalThis.location.href);
    if (url.searchParams.get('history') === String(ms)) {
        return;
    }
    if (ms === HISTORY_DEFAULT_MS) {
        url.searchParams.delete('history');
    } else {
        url.searchParams.set('history', String(ms));
    }
    globalThis.history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
}

const samples: Array<ApmSample> = [];
let chartCompressed = true;
let chartTimer: ReturnType<typeof setInterval> | null = null;
let chartInFlight = false;
let chartCssW = 0;
let chartCssH = 0;
let chartDpr = 1;
let chartMaxAgeMs = 0;
let chartYMaxMs = 0;
let chartRafId: number | null = null;
let edgeMean: EdgeLerp | null = null;
let edgeP99: EdgeLerp | null = null;
let historyMs = loadHistoryMs();

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

function edgeValueMs(edge: EdgeLerp | null, nowMs: number, fallbackMs: number): number {
    if (edge === null) {
        return fallbackMs;
    }
    const t = Math.min(1, (nowMs - edge.startAt) / EDGE_LERP_MS);
    return edge.fromMs + (edge.targetMs - edge.fromMs) * t;
}

function plotDims() {
    return { w: chartCssW - LABEL_GUTTER_PX - EDGE_PAD_PX, h: chartCssH - BOTTOM_GUTTER_PX - EDGE_PAD_PX };
}

function formatAge(ms: number): string {
    const totalSecs = Math.round(ms / SEC_MS);
    const mins = Math.floor(totalSecs / MIN_S);
    if (mins > 0) {
        return `${mins}m`;
    }
    return `${totalSecs}s`;
}

function sizeChartCanvas(): boolean {
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
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText('collecting samples…', EDGE_PAD_PX + plotDims().w / 2, EDGE_PAD_PX + plotDims().h / 2);
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
        ctx.textAlign = 'center';
        ctx.textBaseline = 'alphabetic';
        ctx.fillText(formatAge(age), x, chartCssH - LABEL_PAD_PX);
    }
    const valueStep = pickGridStep(VALUE_GRID_STEPS_MS, chartYMaxMs, MAX_VALUE_GRID_LINES);
    for (let v = valueStep; v <= chartYMaxMs; v += valueStep) {
        const y = EDGE_PAD_PX + plot.h * (1 - v / chartYMaxMs);
        ctx.beginPath();
        ctx.moveTo(EDGE_PAD_PX, y);
        ctx.lineTo(EDGE_PAD_PX + plot.w, y);
        ctx.stroke();
        ctx.textAlign = 'left';
        ctx.textBaseline = 'middle';
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

function traceLine(ctx: CanvasRenderingContext2D, nowMs: number, pick: (sample: ApmSample) => number, edge: EdgeLerp | null): void {
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
    if (chartWrap !== null) {
        delete chartWrap.dataset.loadError;
    }
    // The live readout is written per frame by finishChartFrame.
}

function markChartStale(): void {
    if (chartWrap !== null) {
        chartWrap.dataset.loadError = 'true';
    }
    setCaption(CAPTION_STALE);
}

// Non-visual equivalent of the canvas: the newest section means as a
// visually-hidden table, updated with the caption so screen-reader operators
// get the same numbers the graph shows.
const chartTableBody = document.querySelector<HTMLElement>('#apm-chart-data tbody');

function updateChartTable(): void {
    if (chartTableBody === null || samples.length === 0) {
        return;
    }
    const newest = samples[samples.length - 1];
    const rows = SECTION_NAMES
        .map((name, i) => `<tr><th scope="row">${name}</th><td>${newest.sectionsMs[i].toFixed(2)} ms</td></tr>`)
        .join('');
    if (chartTableBody.dataset.sig !== rows) {
        chartTableBody.innerHTML = rows;
        chartTableBody.dataset.sig = rows;
    }
}

// Keyboard scrub: the canvas is focusable and ArrowLeft/Right move an
// inspection cursor through the samples; the readout (same element as the
// live caption) announces that sample. Any new sample or resize clears the
// cursor back to live.
let scrubIndex: number | null = null;
const chartLive = document.querySelector<HTMLElement>('#apm-chart-live');

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
    const sections = sample.sectionsMs.map((ms, i) => `${SECTION_NAMES[i]} ${ms.toFixed(1)}`).join(', ');
    const text = `sample ${ageS}s ago: mean ${sample.tickMeanMs.toFixed(1)}, p99 ${sample.tickP99Ms.toFixed(1)} ms. ${sections} ms`;
    if (chartLive.textContent !== text) {
        chartLive.textContent = text;
    }
}

// Cockpit glance band: whole-server health in the first viewport, driven by
// the same apm sample as the terminal chart (no second fetch).
// Percent scale for the glance-band budget meter.
const PERCENT_MAX = 100;
const glanceTick = document.querySelector<HTMLElement>('#glance-tick');
const glancePlayers = document.querySelector<HTMLElement>('#glance-players');
const glanceP99 = document.querySelector<HTMLElement>('#glance-p99');
const glanceMeter = document.querySelector<HTMLElement>('#glance-meter');
const glanceMeterFill = document.querySelector<HTMLElement>('#glance-meter-fill');
const glanceState = document.querySelector<HTMLElement>('#glance-state');
const glancePill = document.querySelector<HTMLElement>('#glance-pill');
const glanceLamp = document.querySelector<HTMLElement>('#glance-lamp');
const glanceWord = document.querySelector<HTMLElement>('#glance-word');

function setText(el: HTMLElement | null, text: string): void {
    if (el !== null && el.textContent !== text) {
        el.textContent = text;
    }
}

function updateGlance(newest: ApmSample): void {
    setText(glanceTick, String(newest.tick));
    setText(glancePlayers, `${newest.entered}/${newest.joined}`);
    const p99 = newest.tickP99Ms;
    setText(glanceP99, `${p99.toFixed(1)} ms`);
    const frac = Math.min(1, p99 / TICK_BUDGET_MS);
    if (glanceMeterFill !== null) {
        glanceMeterFill.style.width = `${Math.round(frac * PERCENT_MAX)}%`;
    }
    const over = p99 > TICK_BUDGET_MS;
    if (glanceMeter !== null) {
        glanceMeter.classList.toggle('hot', over);
        glanceMeter.setAttribute('aria-label', over ? 'tick p99 over the 50 ms budget' : 'tick p99 within budget');
    }
    const blood = newest.bloodmoonActive;
    setText(glanceState, blood ? 'ACTIVE' : 'idle');
    if (glancePill !== null) {
        const cls = blood ? 'pill bad glance-pill' : 'pill ok glance-pill';
        if (glancePill.className !== cls) {
            glancePill.className = cls;
        }
        setText(glancePill, blood ? 'blood moon' : 'live');
    }
    if (glanceLamp !== null) {
        glanceLamp.classList.toggle('bad', over);
    }
    setText(glanceWord, over ? 'over budget' : 'operational');
}

function announceLive(): void {
    if (chartLive === null || scrubIndex !== null) {
        return;
    }
    const newest = samples[samples.length - 1];
    const text = `live: mean ${newest.tickMeanMs.toFixed(1)}, p99 ${newest.tickP99Ms.toFixed(1)} ms`;
    if (chartLive.textContent !== text) {
        chartLive.textContent = text;
    }
    updateGlance(newest);
}

function clearScrub(): void {
    scrubIndex = null;
}

type ScrubDir = typeof SCRUB_BACK | typeof SCRUB_FWD;
const SCRUB_BACK = -1;
const SCRUB_FWD = 1;

// Leading-edge markers plus their paired numeric readout: the eye anchor and
// the stable-position numbers for the newest mean/p99 values.
function finishChartFrame(ctx: CanvasRenderingContext2D, nowMs: number): void {
    const plot = plotDims();
    const x = EDGE_PAD_PX + plot.w;
    const yAt = (ms: number): number => EDGE_PAD_PX + plot.h * (1 - ms / chartYMaxMs);
    const p99Now = edgeValueMs(edgeP99, nowMs, samples[samples.length - 1].tickP99Ms);
    ctx.globalAlpha = 1;
    ctx.beginPath();
    ctx.arc(x, yAt(p99Now), GHOST_MARKER_RADIUS_PX, 0, 2 * Math.PI);
    ctx.fillStyle = CHART_GHOST_COLOR;
    ctx.fill();
    ctx.beginPath();
    ctx.arc(x, yAt(edgeValueMs(edgeMean, nowMs, samples[samples.length - 1].tickMeanMs)), EDGE_MARKER_RADIUS_PX, 0, 2 * Math.PI);
    ctx.fillStyle = CHART_LINE_COLOR;
    ctx.fill();
    // Tabular digits via the caption's monospace face; setCaption no-ops
    // when nothing changed.
    setCaption(`mean ${edgeValueMs(edgeMean, nowMs, samples[samples.length - 1].tickMeanMs).toFixed(1)} · p99 ${p99Now.toFixed(1)} ms · budget ${TICK_BUDGET_MS} ms`);
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
    ctx.arc(x, yAt(sample.tickMeanMs), EDGE_MARKER_RADIUS_PX + 1, 0, 2 * Math.PI);
    ctx.fillStyle = CHART_LINE_COLOR;
    ctx.fill();
    ctx.restore();
}

function drawChart(nowMs: number): void {
    if (chartCtx === null || !sizeChartCanvas()) {
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
    // between fetches; the rAF loop below keeps it animating while visible.
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
    // The frame loop animates the edge lerp and the wall-clock slide.
    // Under reduced motion the per-sample redraw is the still frame.
    // Once the lerp settles the slide moves sub-pixel per frame, so the
    // chain stops and the next sample fetch redraws (fetchApmSample draws
    // on every sample; scrub and resize draw on demand).
    if (reduceMotion === null) {
        reduceMotion = globalThis.matchMedia('(prefers-reduced-motion: reduce)');
    }
    const lerping =
        (edgeMean !== null && nowMs - edgeMean.startAt < EDGE_LERP_MS) ||
        (edgeP99 !== null && nowMs - edgeP99.startAt < EDGE_LERP_MS);
    if (!reduceMotion.matches && lerping && chartRafId === null) {
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
        sectionsMs: SECTION_NS_KEYS.map((key) => json[key] / NS_PER_MS),
        tick: json.tick,
        joined: json.joined,
        entered: json.entered,
        bloodmoonActive: json.bm,
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

async function fetchApmSample(): Promise<void> {
    if (chartInFlight) {
        return;
    }
    chartInFlight = true;
    try {
        const res = await fetchWithTimeout(APM_JSON_URL, { credentials: 'same-origin' });
        if (res.status === HTTP_UNAUTHORIZED) {
            globalThis.location.assign('/login');
            return;
        }
        if (!res.ok) {
            return;
        }
        // oxlint-disable-next-line typescript/no-unsafe-type-assertion, anti-slop/require-safety-comment-for-type-assertion -- SAFETY: /api/apm.json is our own server's fixed schema (renderApmJson in webui.zig); only the documented *_ns fields are read
        const json = (await res.json()) as ApmJson;
        pushSample(toSample(json));
        startEdgeLerp();
        markChartLive();
        drawChart(Date.now());
        // oxlint-disable-next-line @rikalabs/no-silent-catch-fallback -- deliberate: a failed poll keeps the last good frame (staleness is surfaced in the caption and retried on the next interval tick); rethrowing would only produce an unhandled rejection inside the timer callback
    } catch {
        markChartStale();
    } finally {
        chartInFlight = false;
    }
}

function chartStart(): void {
    if (chartTimer !== null) {
        return;
    }
    void fetchApmSample();
    chartTimer = setInterval(() => void fetchApmSample(), APM_POLL_MS);
}

function chartStopRaf(): void {
    if (chartRafId !== null) {
        globalThis.cancelAnimationFrame(chartRafId);
        chartRafId = null;
    }
}

function chartStop(): void {
    // The rAF chain is (re)started by drawChart regardless of the poll timer
    // (tab switch, resize, compress toggle), so it must be cancelled even
    // when the interval is already stopped.
    if (chartTimer !== null) {
        clearInterval(chartTimer);
        chartTimer = null;
    }
    chartStopRaf();
}

const tabButtons = [...document.querySelectorAll<HTMLButtonElement>('.tab')];

// Deep-linkable tabs: #players selects the Players tab, plain / reloads to
// Status. Unknown hashes fall back to Status (missing beats fake).
function tabSlug(button: HTMLButtonElement): string {
    return button.id.replace(/^tab-/u, '');
}

function tabBySlug(slug: string): HTMLButtonElement | null {
    return tabButtons.find((tab) => tabSlug(tab) === slug) ?? null;
}

function tabPanel(button: HTMLButtonElement): HTMLElement | null {
    const controls = button.getAttribute('aria-controls');
    if (controls === null) {
        return null;
    }
    return document.querySelector<HTMLElement>(`#${controls}`);
}

function panelPolls(panel: HTMLElement): Array<HxPollerElement> {
    return polls.filter((p) => panel.contains(p));
}

// Only the visible tab's regions poll. Hidden panels keep their last markup
// but stop fetching, so an operator staring at Status does not pay for four
// invisible 1s fetch+innerHTML swaps per second.
function updatePolling(): void {
    const on = autoEl.checked && !document.hidden;
    const selected = tabButtons.find((tab) => tab.getAttribute('aria-selected') === 'true') ?? tabButtons[0];
    const activePanel = selected ? tabPanel(selected) : null;
    const active = new Set<HxPollerElement>(activePanel ? panelPolls(activePanel) : []);
    for (const pollEl of polls) {
        if (on && active.has(pollEl)) {
            pollEl._hxStart?.();
        } else {
            pollEl._hxStop?.();
        }
    }
    const showChart = on && activePanel !== null && activePanel.id === 'status-section';
    if (showChart) {
        chartStart();
    } else {
        chartStop();
    }
}

function selectTab(button: HTMLButtonElement, pushHash = true): void {
    for (const tab of tabButtons) {
        const isOn = tab === button;
        tab.setAttribute('aria-selected', String(isOn));
        if (isOn) {
            tab.removeAttribute('tabindex');
        } else {
            tab.tabIndex = -1;
        }
        const controls = tab.getAttribute('aria-controls');
        if (controls === null) {
            continue;
        }
        const panel = document.querySelector<HTMLElement>(`#${controls}`);
        if (panel === null) {
            continue;
        }
        panel.hidden = !isOn;
    }
    if (pushHash) {
        const slug = tabSlug(button);
        const hash = slug === 'status' ? '' : `#${slug}`;
        globalThis.history.replaceState(null, '', `${globalThis.location.pathname}${globalThis.location.search}${hash}`);
    }
    updatePolling();
    // The chart lives on the Status tab; only refresh it when visible.
    if (button.id === 'tab-status') {
        drawChart(Date.now());
        void fetchApmSample();
    }
}

function selectInitialTab(): void {
    const slug = globalThis.location.hash.replace(/^#/u, '');
    if (slug === '') {
        selectTab(tabButtons[0], false);
        return;
    }
    const target = tabBySlug(slug);
    if (target === null) {
        // Unknown hash names no tab: show Status and drop the stray hash
        // rather than displaying one thing under another's URL.
        selectTab(tabButtons[0], true);
        return;
    }
    selectTab(target, false);
}

function wireTabs(): void {
    for (const tab of tabButtons) {
        tab.addEventListener('click', () => selectTab(tab));
    }
    const nav = document.querySelector<HTMLElement>('.page-nav');
    // Tabs are a vertical tablist on desktop, horizontal bar on mobile; both
    // axes plus Home/End move per the APG tabs pattern.
    nav?.addEventListener('keydown', (e: KeyboardEvent) => {
        const keys = new Set(['ArrowRight', 'ArrowLeft', 'ArrowDown', 'ArrowUp', 'Home', 'End']);
        if (!keys.has(e.key)) {
            return;
        }
        const index = tabButtons.findIndex((tab) => tab === document.activeElement);
        if (index < 0) {
            return;
        }
        e.preventDefault();
        const last = tabButtons.length - 1;
        let next = index;
        if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
            next = index + 1 > last ? 0 : index + 1;
        } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
            next = index - 1 < 0 ? last : index - 1;
        } else if (e.key === 'Home') {
            next = 0;
        } else {
            next = last;
        }
        selectTab(tabButtons[next]);
        tabButtons[next].focus();
    });
}

function scrubToEvent(e: PointerEvent): void {
    if (samples.length === 0 || !sizeChartCanvas()) {
        return;
    }
    const plot = plotDims();
    if (plot.w <= 0) {
        return;
    }
    const rect = chartCanvas.getBoundingClientRect();
    const frac = (e.clientX - rect.left - EDGE_PAD_PX) / plot.w;
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

// Pointer scrub: drag across the canvas to inspect the nearest sample.
// Reuses the keyboard cursor (same readout, same Escape to clear).
function initScrubPointer(): void {
    let scrubPointer = false;
    chartCanvas.addEventListener('pointerdown', (e: PointerEvent) => {
        if (samples.length < 2) {
            return;
        }
        scrubPointer = true;
        chartCanvas.setPointerCapture(e.pointerId);
        scrubToEvent(e);
    });
    chartCanvas.addEventListener('pointermove', (e: PointerEvent) => {
        if (scrubPointer) {
            scrubToEvent(e);
        }
    });
    chartCanvas.addEventListener('pointerup', () => {
        scrubPointer = false;
    });
    chartCanvas.addEventListener('pointercancel', () => {
        scrubPointer = false;
    });
}

function initChartScrub(): void {
    chartCanvas.addEventListener('keydown', (e: KeyboardEvent) => {
        if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight' && e.key !== 'Escape') {
            return;
        }
        e.preventDefault();
        if (e.key === 'Escape') {
            clearScrub();
            drawChart(Date.now());
        } else {
            stepScrub(e.key === 'ArrowLeft' ? SCRUB_BACK : SCRUB_FWD);
        }
    });
    initScrubPointer();
}

function initChart(): void {
    compressEl.addEventListener('change', () => {
        chartCompressed = compressEl.checked;
        drawChart(Date.now());
    });
    initChartScrub();
    historyEl.value = String(historyMs);
    historyEl.addEventListener('change', () => {
        const chosen = Number(historyEl.value);
        if (!HISTORY_WINDOW_MS.includes(chosen)) {
            return;
        }
        historyMs = chosen;
        syncHistoryUrl(chosen);
        try {
            globalThis.localStorage.setItem(HISTORY_STORAGE_KEY, String(historyMs));
            // oxlint-disable-next-line @rikalabs/no-silent-catch-fallback -- deliberate: persistence is best-effort; the chosen window still applies to this session
        } catch {
            // Storage blocked (private mode): keep the session-only window.
        }
        pruneHistory();
        drawChart(Date.now());
    });
    globalThis.addEventListener('resize', () => drawChart(Date.now()));
}

wireTabs();
initChart();
selectInitialTab();
globalThis.addEventListener('hashchange', () => selectInitialTab());

function applyRefresh(): void {
    const on = autoEl.checked;
    const active = on && !document.hidden;
    let stateLabel = 'Auto-refresh paused';
    if (active) {
        stateLabel = 'Auto-refresh on';
    } else if (on) {
        stateLabel = 'Auto-refresh paused while tab is hidden';
    }
    updatePolling();
    if (refreshState) {
        refreshState.textContent = stateLabel;
    }
}

async function refreshNow(): Promise<void> {
    refreshNowButton.disabled = true;
    if (refreshState) {
        refreshState.textContent = 'Refreshing…';
    }
    await Promise.all(polls.map((el) => (el._hxOnce ? el._hxOnce() : Promise.resolve())));
    void fetchApmSample();
    refreshNowButton.disabled = false;
    refreshNowButton.focus();
    if (refreshState) {
        refreshState.textContent = autoEl.checked ? 'Refreshed (auto-refresh on)' : 'Refreshed (auto-refresh paused)';
    }
}

async function submitCommand(): Promise<void> {
    const button = queryEl<HTMLButtonElement>('#cmd-form button');
    const input = queryEl<HTMLInputElement>('#cmd-line');
    const out = queryEl<HTMLElement>('#cmd-out');
    const fd = new FormData(cmdForm);
    const rawLine = fd.get('line');
    const line = typeof rawLine === 'string' ? rawLine.trim() : '';
    if (!line) {
        input.setCustomValidity('Enter a command.');
        input.reportValidity();
        return;
    }
    input.setCustomValidity('');
    const verb = line.split(/\s+/u, 1)[0].toLowerCase();
    // Sync point: the destructive verbs the server accepts live in
    // parseCommand (src/server/admin.zig). A new data-loss verb added there
    // needs an entry here or it ships without a confirm.
    const destructive = new Set(['shutdown', 'killall', 'ka', 'kick', 'kickall', 'ban', 'wipeplayer']);
    // oxlint-disable-next-line no-alert -- deliberate: destructive admin commands use a native confirm
    if (destructive.has(verb) && !globalThis.confirm(`Run "${verb}"? This can interrupt players or erase saved data.`)) {
        return;
    }
    button.disabled = true;
    button.textContent = 'Running…';
    out.setAttribute('role', 'status');
    out.setAttribute('aria-busy', 'true');
    out.innerHTML = '<pre class="meta">Running command…</pre>';
    try {
        const r = await fetchWithTimeout('/api/cmd', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            // oxlint-disable-next-line @rikalabs/no-double-type-assertion, typescript/no-unsafe-type-assertion, anti-slop/no-chained-type-assertions -- SAFETY: browsers accept FormData in the URLSearchParams constructor; the bundled lib.dom type omits it (erased at emit time)
            body: new URLSearchParams(fd as unknown as URLSearchParams),
        });
        if (r.status === HTTP_UNAUTHORIZED) {
            globalThis.location.assign('/login');
            return;
        }
        const response = await r.text();
        const commandFailed = !r.ok || response.includes('data-command-error="true"');
        out.setAttribute('role', commandFailed ? 'alert' : 'status');
        out.innerHTML = response;
        if (!commandFailed) {
            input.value = '';
            input.focus();
        }
        const log = document.querySelector<HxPollerElement>('#console-log');
        if (log && log._hxOnce) {
            void log._hxOnce();
        }
        // oxlint-disable-next-line @rikalabs/no-silent-catch-fallback -- deliberate: the failure is rendered to the operator (role=alert); rethrowing here would be an unhandled rejection in the submit listener
    } catch {
        out.setAttribute('role', 'alert');
        out.innerHTML = '<pre class="err">The command response was not received, so its outcome is unknown. Check the command history below before running it again.</pre>';
    } finally {
        out.removeAttribute('aria-busy');
        button.disabled = false;
        button.textContent = 'Run';
        input.focus();
    }
}

refreshNowButton.addEventListener('click', () => {
    void refreshNow();
});
autoEl.addEventListener('change', applyRefresh);

// Delegated hx-post handler (modlet Enable/Disable forms in the Modules
// partial). The partial re-renders every 5s, so per-form wiring would die on
// each poll swap; document-level delegation survives the swap. Forms without
// hx-post (notably #cmd-form) are ignored.
async function submitHxForm(form: HTMLFormElement): Promise<void> {
    const url = form.getAttribute('hx-post') ?? '';
    const targetSel = form.getAttribute('hx-target') ?? '';
    const target = targetSel === '' ? null : document.querySelector<HTMLElement>(targetSel);
    if (target === null) {
        return;
    }
    const button = form.querySelector<HTMLButtonElement>('button[type="submit"], button:not([type])');
    if (button) {
        button.disabled = true;
    }
    target.setAttribute('aria-busy', 'true');
    try {
        const fd = new FormData(form);
        const r = await fetchWithTimeout(url, {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            // oxlint-disable-next-line @rikalabs/no-double-type-assertion, typescript/no-unsafe-type-assertion, anti-slop/no-chained-type-assertions -- SAFETY: browsers accept FormData in the URLSearchParams constructor; the bundled lib.dom type omits it (erased at emit time)
            body: new URLSearchParams(fd as unknown as URLSearchParams),
        });
        if (r.status === HTTP_UNAUTHORIZED) {
            globalThis.location.assign('/login');
            return;
        }
        if (!r.ok) {
            throw new Error(`HTTP ${r.status}`);
        }
        target.innerHTML = await r.text();
        flashChanges(target);
        // oxlint-disable-next-line @rikalabs/no-silent-catch-fallback -- deliberate: the failure is rendered inline below (role=alert); rethrowing here would be an unhandled rejection in the submit listener
    } catch (err) {
        const status = err instanceof Error ? err.message : 'network error';
        const detail = status.startsWith('HTTP')
            ? `${status}; no change was applied. Retry.`
            : 'not received; its outcome is unknown. Reload before retrying.';
        const prior = target.querySelector('p.modlet-err');
        if (prior) {
            prior.remove();
        }
        const note = document.createElement('p');
        note.className = 'err modlet-err';
        note.setAttribute('role', 'alert');
        note.textContent = `Modlet action failed (${detail})`;
        target.prepend(note);
    } finally {
        target.removeAttribute('aria-busy');
        if (button) {
            button.disabled = false;
        }
    }
}

document.addEventListener('submit', (e) => {
    const form = e.target;
    if (!(form instanceof HTMLFormElement) || !form.hasAttribute('hx-post')) {
        return;
    }
    e.preventDefault();
    void submitHxForm(form);
});
document.addEventListener('visibilitychange', applyRefresh);
cmdForm.addEventListener('submit', (e) => {
    e.preventDefault();
    void submitCommand();
});
applyRefresh();
