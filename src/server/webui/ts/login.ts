//! Webui login form: show/hide the shared secret.
//! Injected into login.html (plain and failure states share the markup; the
//! banner and input attrs are server-rendered placeholders).
//! Compiled by scripts/build-webui-ts.sh.

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
