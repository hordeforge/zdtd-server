//! Webui login form: show/hide the shared secret.
//! Shared by login.html and login_failed.html (same markup, different error
//! state). Compiled by scripts/build-webui-ts.sh and injected into both pages.

const token = document.querySelector<HTMLInputElement>('#login-token');
if (token === null) {
    throw new Error('webui: missing element #login-token');
}
const toggle = document.querySelector<HTMLButtonElement>('#toggle-secret');
if (toggle === null) {
    throw new Error('webui: missing element #toggle-secret');
}

toggle.addEventListener('click', () => {
    const shown = token.type === 'text';
    token.type = shown ? 'password' : 'text';
    toggle.textContent = shown ? 'Show' : 'Hide';
    toggle.setAttribute('aria-pressed', String(!shown));
    token.focus();
});
