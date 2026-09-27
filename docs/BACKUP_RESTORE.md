# Backup and restore runbook

What zdtd keeps on disk, how to copy it off the host, how to put it back, and
how to tell that either worked. The subsystem reference for the save formats
themselves is [subsystems/world-store.md](subsystems/world-store.md) and
[subsystems/persistence.md](subsystems/persistence.md); this page is the
operator procedure.

## What is durable

One directory, `world_dir` (the `--world` path): chunk files `c_X_Z.zch`,
`players.zsv`, `entities.zen`, `claims.zlc`, `containers.zct`,
`workstations.zws`, `vending.zvn`, `allies.zal`, `sleepers_cleared.zsc`,
`sleepers_triggered.zst`, `traders.zst`, `blockmeta.zbm`, `weather.zwt` and
`clock.zcl`. The full inventory and the write path are in
[subsystems/persistence.md](subsystems/persistence.md).

Nothing else needs backing up. Config (`zdtd.toml`, `serverconfig.xml`),
presets, mods and plugin sources are in git. The catalog caches under
`.zdtd_cfg_cache/` and the generated asset tables are derived from the
operator `game-dir` and rebuild on the next start. Plugin runtime state,
apm counters, interest caches and the peer table are per-process by design and
hold nothing worth recovering.

Player records and container contents are the part that cannot be
regenerated, so treat the backup of `world_dir` as the recovery point for the
whole server.

## What each disaster costs

| Disaster | RPO | RTO | Cover |
|---|---|---|---|
| Process crash, `kill -9` | 5 s (the autosave interval, `save_interval_ticks = 100` ticks at 20 TPS) | seconds, restart the daemon | the atomic write path: every store is fsynced and renamed |
| Host or disk loss | the backup schedule interval | restore time plus daemon start | `scripts/backup-world.sh` to a filesystem off the host |
| Accidental `rm -rf world_dir` | the last backup | one `restore-world.sh` run | the backup copy |
| Logical corruption (bad deploy writing bad data) | up to the last backup, plus every write since | one `restore-world.sh` run | the backup copy; there is no point-in-time history, only the last 7 copies |
| Malicious or fat-fingered deletion | the last backup, if it is off-host | one `restore-world.sh` run | off-host copies under a credential the world process does not hold |

The RPO for the last two rows is bounded by how often a backup runs, not by
anything the daemon does. Backup the world more often than you can tolerate
losing, and verify it: a copy nobody has read back is a hypothesis.

## Schedule

`backup-world.sh` copies `world_dir` into a timestamped directory under
`backup_root` and rotates the old ones. It refuses a `backup_root` on the same
filesystem as `world_dir`, because a disk failure would take both; the default
`<world_dir>/../backups` is a same-host convenience, not a backup. Set
`ZDTD_BACKUP_ALLOW_SAME_FS=1` only for a scratch copy you understand.

A five-minute cron entry on a dedicated backup filesystem:

```bash
*/5 * * * * ZDTD_BACKUP_ALLOW_SAME_FS= /srv/zdtd/scripts/backup-world.sh \
  /srv/zdtd/worlds/navezgane /mnt/backupvol/zdtd 288
```

Then copy `/mnt/backupvol/zdtd` off the host. Everything the host can reach,
the host can also lose.

Alert on the check, not on the job's exit code alone. A job that stops
running, loses its credentials, or writes nothing leaves a green runbook and an
empty disk:

```bash
scripts/check-backup-freshness.sh /srv/zdtd/worlds/navezgane /mnt/backupvol/zdtd 900
```

It exits non-zero when no backup exists for the world, or when the newest
complete copy is older than the budget. A scheduled run that fails should page.

## Restore

Stop the daemon first. A running server holds the world in memory and will
write over the restored files.

```bash
scripts/restore-world.sh /mnt/backupvol/zdtd/navezgane-20260927T021500Z \
  /srv/zdtd/worlds/navezgane --force
```

Without `--force` the tool refuses a non-empty target, which keeps a mistyped
path from overwriting a live world. With it, the existing directory is moved to
`navezgane.prerestore.<stamp>` first, so a bad restore is recoverable too.
Start the daemon on the target and confirm the log reaches
`zdtd --once complete` or a normal tick.

## Prove the restore

`make smoke-backup-restore` (also run by `scripts/smoke-release.sh` in CI) takes
a generated world through backup, a fail-closed unforced restore, a real
restore, a per-file hash comparison of backup against restored tree, a daemon
boot on the restored world, the pre-restore archive, and the freshness check.
A hand-run restore is worth the same check:

```bash
diff <(cd backup_dir && find . -type f | sort | xargs sha256sum) \
     <(cd restored   && find . -type f | sort | xargs sha256sum)
```

## Format compatibility

Every store file carries a version in its magic (`ZPV`, `ZEN`, `ZCH`, `ZCL`,
`ZWTH`, `ZBM`, `ZCT`, `ZWS`). Readers accept the older versions they were
written to understand, so a world saved by a newer build is not guaranteed to
load on an older binary: roll the binary back before rolling the world back,
or restore a backup taken before the upgrade. Upgrades are not a reason to
hold backups, but they are the one case where rollback needs a pre-upgrade
copy.

## Gaps

- No point-in-time recovery: the realistic corruption disaster loses
  everything since the last backup, up to the schedule interval. Shorten the
  interval if that window is unacceptable.
- Retention is `keep` copies, not a policy. An operator deletes
  `backup_root` the same way the world is deleted.
- The schedule, the off-host copy and the alert are operator-side. Nothing in
  this repository runs them, so an installation that skips them has no backup
  despite the tooling being present.

## See also

- [subsystems/persistence.md](subsystems/persistence.md) - save ladder,
  formats, and the atomic write path.
- [subsystems/world-store.md](subsystems/world-store.md) - chunk, container and
  workstation stores.
- [THREAT_MODEL.md](THREAT_MODEL.md) - who can delete what.
- [testing.md](testing.md) - what each gate proves.
