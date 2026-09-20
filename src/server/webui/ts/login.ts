//! Webui login form: show/hide the shared secret, and mirror the server's
//! invalid flag into ARIA. Injected into login.html (plain and failure states
//! share the markup; the banner and the invalid flag are server-rendered
//! placeholders in a data attribute, which the HTML checker accepts).
//! Compiled by scripts/build-webui-ts.sh.

const token = document.querySelector<HTMLInputElement>('#login-token');
if (token === null) {
    throw new Error('webui: missing element #login-token');
}
const toggle = document.querySelector<HTMLButtonElement>('#toggle-secret');
if (toggle === null) {
    throw new Error('webui: missing element #toggle-secret');
}

// data-invalid carries the server's verdict; ARIA has to agree with it.
token.setAttribute('aria-invalid', token.dataset.invalid === 'true' ? 'true' : 'false');

toggle.addEventListener('click', () => {
    const shown = token.type === 'text';
    token.type = shown ? 'password' : 'text';
    toggle.textContent = shown ? 'Show secret' : 'Hide secret';
    toggle.setAttribute('aria-pressed', String(!shown));
    token.focus();
});

// Prevent a second submit while the browser is posting: double-clicks on a
// slow link would otherwise send two tokens and burn lockout attempts.
const form = token.closest('form');
if (form !== null) {
    form.addEventListener('submit', () => {
        const submit = form.querySelector<HTMLButtonElement>('button[type="submit"]');
        if (submit !== null) {
            submit.disabled = true;
            submit.textContent = 'Signing in…';
        }
        token.readOnly = true;
    });
}
