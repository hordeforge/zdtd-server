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
    _hxOnce?: () => Promise<unknown>;
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

function createSwap(el: HxPollerElement, u: string): (force?: boolean) => Promise<unknown> {
    let inFlight = false;
    // Force=true skips the focus guard: Refresh now and post-command refreshes
    // must swap even while the operator is reading a focused scroll region.
    return (force = false): Promise<unknown> => {
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
                    window.location.assign('/login');
                    return null;
                }
                return r.ok ? r.text() : Promise.reject(new Error(`HTTP ${r.status}`));
            })
            .then((t) => {
                if (t === null) {
                    return;
                }
                el.innerHTML = t;
                el.removeAttribute('data-load-error');
                el.scrollLeft = regionScroll;
                const npre = el.querySelector('pre');
                if (npre) {
                    npre.scrollTop = preScroll;
                }
            })
            .catch(() => {
                if (!el.hasAttribute('data-load-error')) {
                    el.innerHTML = '<p class="err" role="alert">Live data is unavailable. Check the connection; retrying automatically.</p>';
                }
                el.setAttribute('data-load-error', 'true');
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
    el._hxStart = () => {
        if (timer) {
            return;
        }
        void swap();
        timer = setInterval(() => void swap(), ms);
    };
    el._hxStop = () => {
        if (timer) {
            clearInterval(timer);
            timer = null;
        }
    };
    el._hxOnce = () => swap(true);
}

const polls = Array.from(document.querySelectorAll<HxPollerElement>('[hx-get]'));
polls.forEach(hxPoll);

const autoEl = queryEl<HTMLInputElement>('#auto-refresh');
const refreshState = document.getElementById('refresh-state');

function applyRefresh(): void {
    const on = autoEl.checked;
    const active = on && !document.hidden;
    let stateLabel = 'Auto-refresh paused';
    if (active) {
        stateLabel = 'Auto-refresh on';
    } else if (on) {
        stateLabel = 'Auto-refresh paused while tab is hidden';
    }
    polls.forEach((el) => {
        if (active) {
            el._hxStart?.();
        } else {
            el._hxStop?.();
        }
    });
    if (refreshState) {
        refreshState.textContent = stateLabel;
    }
}

autoEl.addEventListener('change', applyRefresh);
document.addEventListener('visibilitychange', applyRefresh);
applyRefresh();

const refreshNowButton = queryEl<HTMLButtonElement>('#refresh-now');
refreshNowButton.addEventListener('click', () => {
    void refreshNow();
});

async function refreshNow(): Promise<void> {
    refreshNowButton.disabled = true;
    if (refreshState) {
        refreshState.textContent = 'Refreshing…';
    }
    await Promise.all(polls.map((el) => (el._hxOnce ? el._hxOnce() : Promise.resolve())));
    refreshNowButton.disabled = false;
    refreshNowButton.focus();
    if (refreshState) {
        refreshState.textContent = autoEl.checked ? 'Refreshed (auto-refresh on)' : 'Refreshed (auto-refresh paused)';
    }
}

const cmdForm = queryEl<HTMLFormElement>('#cmd-form');
cmdForm.addEventListener('submit', (e) => {
    e.preventDefault();
    void submitCommand();
});

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
    const verb = line.split(/\s+/, 1)[0].toLowerCase();
    const destructive = new Set(['shutdown', 'killall', 'ka', 'kick', 'kickall', 'ban', 'wipeplayer']);
    // oxlint-disable-next-line no-alert -- deliberate: destructive admin commands use a native confirm
    if (destructive.has(verb) && !window.confirm(`Run "${verb}"? This can interrupt players or erase saved data.`)) {
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
            // oxlint-disable-next-line @rikalabs/no-double-type-assertion, typescript/no-unsafe-type-assertion -- browsers accept FormData in the URLSearchParams constructor; the bundled lib.dom type omits it (erased at emit time)
            body: new URLSearchParams(fd as unknown as URLSearchParams),
        });
        if (r.status === HTTP_UNAUTHORIZED) {
            window.location.assign('/login');
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
