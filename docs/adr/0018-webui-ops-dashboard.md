# ADR 0018: Operator WebUI (WU0–WU2 shipped shape)

- **Status:** accepted
- **Date:** 2026-08-05
- **Related:** [WEBUI.md](../WEBUI.md), [AUTHORITY.md](../AUTHORITY.md), [APM.md](../APM.md)

## Context

Operators need live health and the same privileged commands as admin TCP without
a Node SPA or a second authority path. WU0 design left four open choices; the
implementation settled them.

## Decision

1. **HTTP stack:** `util/tcp_listen` + `std.http.Server` for parse/respond. No
   custom full HTTP parser beyond accept buffering.
2. **Assets:** **inline** HTML/CSS/JS in the binary for single-binary ops. Vendor
   htmx/Alpine embed and `/static/*` are WU3 optional; not required for WU0–WU2.
3. **Session:** per-secret **HMAC session token** (not the shared secret) in a
   cookie; form CSRF = same token (shared secret still accepted for API tools).
   The token derives deterministically from the secret (`HMAC(secret, fixed
   label)`), so a still-valid cookie survives a server restart without a
   re-login; browser Max-Age and logout still bound it. No multi-session
   server-side map (one secret → one session material).
4. **Command identity:** commands run through the same admin line parser as TCP;
   audit ring labels them as webui ops (not peer game traffic).
5. **Tick coupling:** `Game.step` polls webui non-blocking (one client slot, short
   timeout). No dedicated HTTP thread; keep work small so 50 ms tick holds.
6. **Default off:** `--webui-port` 0; loopback bind; min secret length enforced.

## Consequences

- One binary, no npm in CI for core ops UI.
- Long/slow HTTP work on the tick thread can stall sim; keep responses tiny.
- WAN exposure still requires TLS reverse proxy + strong secret + firewall.

## Alternatives considered

| Option | Notes |
|---|---|
| Minimal hand-rolled HTTP only | Rejected once std.http.Server fit |
| Disk static tree always | Harder single-binary; disk override remains optional later |
| Server-side session map (cap 16) | Extra state; HMAC cookie sufficient for loopback ops |
| Separate HTTP thread | Extra sync with sim snapshot; poll-from-tick is simpler for now |
