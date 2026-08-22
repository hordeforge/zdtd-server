//! Webui lockout page: count down the remaining wait, then reload /login.
//! `__ZDTD_RETRY_S__` is substituted server-side by webui.zig renderTemplate;
//! the compiled JS keeps the reference so the substituted seconds reach the
//! browser. Compiled by scripts/build-webui-ts.sh and injected into
//! login_lockout.html.

declare const __ZDTD_RETRY_S__: number;

const message = document.querySelector<HTMLElement>('#login-err');
if (message === null) {
    throw new Error('webui: missing element #login-err');
}
const seconds = document.querySelector<HTMLElement>('#retry-seconds');
if (seconds === null) {
    throw new Error('webui: missing element #retry-seconds');
}
message.focus();

let remaining = __ZDTD_RETRY_S__;
const COUNTDOWN_TICK_MS = 1000;
const countdown = setInterval(() => {
    remaining -= 1;
    seconds.textContent = String(remaining);
    if (remaining <= 0) {
        clearInterval(countdown);
        window.location.replace('/login');
    }
}, COUNTDOWN_TICK_MS);
