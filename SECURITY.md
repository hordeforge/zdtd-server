# Security policy

## Supported versions

Only the newest development release on the `0.x` line is supported. There is no
security backport branch or EOL schedule. Compatibility and release rules live in
[docs/RELEASES.md](docs/RELEASES.md).

## Reporting a vulnerability

This repository does not list a private disclosure contact or mail address.

Do not open a public issue that includes an exploit, proof of concept, or
weaponized reproduction. Prefer a short description of the affected surface and
impact class so maintainers can reproduce from source.

Security-relevant fixes are recorded in [CHANGELOG.md](CHANGELOG.md) without
exploit detail until operators can upgrade, as stated in
[docs/RELEASES.md](docs/RELEASES.md).

## What this project claims

zdtd is a research dedicated server for the stock client wire (EAC off). The
living attack-surface map is [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

Operator HTTP (webui, MCP) refuses non-loopback binds in-process; admin TCP
without a password binds loopback only. Those defaults are controls, not a
substitute for host firewall policy on a shared machine. There is no in-process
TLS terminator.

Known authority exceptions (for example client-trusted player hold inventory)
are named in the threat model and in [docs/AUTHORITY.md](docs/AUTHORITY.md); they
are not silent guarantees of full server-authoritative inventory.
