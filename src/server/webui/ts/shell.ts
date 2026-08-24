//! Webui dashboard shell: htmx-style poller for the [hx-get] partials,
//! auto-refresh toggle, and the admin console form (POST /api/cmd).
//! Compiled by scripts/build-webui-ts.sh and injected into shell.html.

const FETCH_TIMEOUT_MS = 8000;
const HTTP_UNAUTHORIZED = 401;
const POLL_SLOW_MS = 5000;
const POLL_FAST_MS = 2000;

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

// Poller swap factory: one closure per polled region, created here so hxPoll
// stays a thin wiring function. Inlining it would push hxPoll past the
// 60-line function cap the strict preset enforces; the
// @rikalabs/no-single-use-trivial-helpers off entry covers this.
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
const CHART_SAMPLES_MAX = 300;
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
const CHART_FONT = '10px ui-monospace, Menlo, Consolas, monospace';
const CAPTION_DEFAULT = 'tick mean / p99 · section means · 50 ms budget';
const CAPTION_STALE = 'live data unavailable - showing last samples';
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
};

type ApmJson = {
    tick_mean_ns: number;
    tick_p99_ns: number;
    net_mean_ns: number;
    sim_mean_ns: number;
    repl_mean_ns: number;
    stream_mean_ns: number;
    save_mean_ns: number;
};

type EdgeLerp = {
    fromMs: number;
    targetMs: number;
    startAt: number;
};

const SECTION_KEYS: ReadonlyArray<keyof ApmJson> = ['net_mean_ns', 'sim_mean_ns', 'repl_mean_ns', 'stream_mean_ns', 'save_mean_ns'];

function cssVar(name: string): string {
    const styles = globalThis.getComputedStyle(document.documentElement);
    return styles.getPropertyValue(name).trim() || '#6b7280';
}

const CHART_LINE_COLOR = cssVar('--fg');
const CHART_GHOST_COLOR = cssVar('--muted');
const CHART_GRID_COLOR = cssVar('--line');
const CHART_LABEL_COLOR = cssVar('--muted2');
const CHART_BUDGET_COLOR = cssVar('--warn');
const SECTION_FILL_COLORS: ReadonlyArray<string> = [
    cssVar('--line2'),
    cssVar('--edge'),
    cssVar('--muted3'),
    cssVar('--muted2'),
    cssVar('--muted'),
];

const chartCanvas = queryEl<HTMLCanvasElement>('#apm-canvas');
const chartCtx = chartCanvas.getContext('2d');
const compressEl = queryEl<HTMLInputElement>('#chart-compress');
const chartCaption = document.querySelector<HTMLElement>('#apm-chart-caption');
const chartWrap = document.querySelector<HTMLElement>('#apm-chart-wrap');

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
    ctx.fillText('collecting samples…', chartCssW / 2, chartCssH / 2);
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
    if (chartRafId === null) {
        chartRafId = globalThis.requestAnimationFrame(() => {
            chartRafId = null;
            drawChart(Date.now());
        });
    }
}

function toSample(json: ApmJson): ApmSample {
    return {
        at: Date.now(),
        tickMeanMs: json.tick_mean_ns / NS_PER_MS,
        tickP99Ms: json.tick_p99_ns / NS_PER_MS,
        sectionsMs: SECTION_KEYS.map((key) => json[key] / NS_PER_MS),
    };
}

function pushSample(sample: ApmSample): void {
    samples.push(sample);
    if (samples.length > CHART_SAMPLES_MAX) {
        samples.splice(0, samples.length - CHART_SAMPLES_MAX);
    }
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

function setCaption(text: string): void {
    if (chartCaption !== null && chartCaption.textContent !== text) {
        chartCaption.textContent = text;
    }
}

function markChartLive(): void {
    if (chartWrap !== null) {
        delete chartWrap.dataset.loadError;
    }
    setCaption(CAPTION_DEFAULT);
}

function markChartStale(): void {
    if (chartWrap !== null) {
        chartWrap.dataset.loadError = 'true';
    }
    setCaption(CAPTION_STALE);
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

function selectTab(button: HTMLButtonElement): void {
    for (const tab of tabButtons) {
        const isOn = tab === button;
        tab.setAttribute('aria-selected', String(isOn));
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
    drawChart(Date.now());
    void fetchApmSample();
}

function wireTabs(): void {
    for (const tab of tabButtons) {
        tab.addEventListener('click', () => selectTab(tab));
    }
    const nav = document.querySelector<HTMLElement>('.page-nav');
    nav?.addEventListener('keydown', (e: KeyboardEvent) => {
        if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') {
            return;
        }
        const index = tabButtons.findIndex((tab) => tab === document.activeElement);
        if (index < 0) {
            return;
        }
        e.preventDefault();
        const last = tabButtons.length - 1;
        let next = e.key === 'ArrowRight' ? index + 1 : index - 1;
        if (next > last) {
            next = 0;
        }
        if (next < 0) {
            next = last;
        }
        selectTab(tabButtons[next]);
        tabButtons[next].focus();
    });
}

function initChart(): void {
    compressEl.addEventListener('change', () => {
        chartCompressed = compressEl.checked;
        drawChart(Date.now());
    });
    globalThis.addEventListener('resize', () => drawChart(Date.now()));
}

wireTabs();
initChart();

function applyRefresh(): void {
    const on = autoEl.checked;
    const active = on && !document.hidden;
    let stateLabel = 'Auto-refresh paused';
    if (active) {
        stateLabel = 'Auto-refresh on';
    } else if (on) {
        stateLabel = 'Auto-refresh paused while tab is hidden';
    }
    for (const pollEl of polls) {
        if (active) {
            pollEl._hxStart?.();
        } else {
            pollEl._hxStop?.();
        }
    }
    if (active) {
        chartStart();
    } else {
        chartStop();
    }
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
document.addEventListener('visibilitychange', applyRefresh);
cmdForm.addEventListener('submit', (e) => {
    e.preventDefault();
    void submitCommand();
});
applyRefresh();
