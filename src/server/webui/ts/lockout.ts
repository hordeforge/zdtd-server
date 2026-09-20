//! Webui lockout page: count down the remaining wait, then reload /login.
//! `__ZDTD_RETRY_S__` is substituted server-side by webui.zig renderTemplate;
//! the compiled JS keeps the reference so the substituted seconds reach the
//! browser. Compiled by scripts/build-webui-ts.sh and injected into
//! login_lockout.html.

// oxlint-disable-next-line no-redeclare -- deliberate: __ZDTD_RETRY_S__ is a server-injected global; the declare types it for the classic script, so the config has no globals entry
declare const __ZDTD_RETRY_S__: number;

const message = document.querySelector<HTMLElement>('#login-err');
if (message === null) {
    throw new Error('webui: missing element #login-err');
}
const seconds = document.querySelector<HTMLElement>('#retry-seconds');
if (seconds === null) {
    throw new Error('webui: missing element #retry-seconds');
}
const liveCandidate = document.querySelector<HTMLElement>('#retry-live');
if (liveCandidate === null) {
    throw new Error('webui: missing element #retry-live');
}
const liveRegion: HTMLElement = liveCandidate;
message.focus();

let remaining = __ZDTD_RETRY_S__;
const COUNTDOWN_TICK_MS = 1000;
// Announce at a few milestones only: a per-second polite live region would
// flood screen readers (WCAG 2.2.1 / 4.1.3).
const ANNOUNCE_AT_2M = 120;
const ANNOUNCE_AT_90S = 90;
const ANNOUNCE_AT_1M = 60;
const ANNOUNCE_AT_30S = 30;
const ANNOUNCE_AT_15S = 15;
const ANNOUNCE_AT_10S = 10;
const ANNOUNCE_AT_5S = 5;
const ANNOUNCE_AT = new Set([
    ANNOUNCE_AT_2M,
    ANNOUNCE_AT_90S,
    ANNOUNCE_AT_1M,
    ANNOUNCE_AT_30S,
    ANNOUNCE_AT_15S,
    ANNOUNCE_AT_10S,
    ANNOUNCE_AT_5S,
]);

function announceRemaining(n: number): void {
    liveRegion.textContent = n === 1 ? 'Try again in 1 second.' : `Try again in ${n} seconds.`;
}

const countdown = setInterval(() => {
    remaining -= 1;
    seconds.textContent = String(remaining);
    if (ANNOUNCE_AT.has(remaining)) {
        announceRemaining(remaining);
    }
    if (remaining <= 0) {
        clearInterval(countdown);
        globalThis.location.replace('/login');
    }
}, COUNTDOWN_TICK_MS);
