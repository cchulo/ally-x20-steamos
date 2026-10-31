# Notifications

Root-side parts of ally-x20-steamos (boot service, RAUC handlers, `probe`,
`self-update --check`) cannot show desktop notifications themselves. They
append events to a queue file; the user-session notifier
(`ally-x20-steamos-notify.service`, a systemd user unit) shows them. Plan
reference: §4.2 item 3, §5 probe policy.

## Queue file

`/var/lib/ally-x20-steamos/state/notifications.queue`, mode `0644`, owned
by root, readable by the `deck` user.

One event per line, three tab-separated fields, no tabs or newlines inside
a field:

```
<ts>\t<level>\t<message>
```

| field | format |
|---|---|
| `ts` | ISO-8601 UTC, `YYYY-MM-DDTHH:MM:SSZ` (sorts lexically) |
| `level` | `info`, `warn` or `error` |
| `message` | one line of plain text for a human; may name a command to run |

Example:

```
2026-10-30T09:12:44Z	info	audio is now provided by stock SteamOS (superseded). Nothing was removed; to drop our copy run: sudo ally-x20-steamos uninstall --superseded
```

### Producer rules

- Use `notify_enqueue <level> <message>` from `lib/notify.sh`; do not write
  the file by hand. It sanitises the message, honours `--dry-run`, and
  keeps the file bounded: past 500 lines it is rewritten atomically with
  the newest 200 lines.
- Queue an event when something changed, not on every run. `probe --notify`
  queues only when a component **newly** becomes superseded (compared with
  the previous `state/probes.json`); `self-update --check --notify` queues
  once per new release.

### Consumer rules (the notifier)

- The queue is append-only for the consumer: never truncate or edit it (it
  is root-owned anyway).
- Remember progress in the user's own state, e.g.
  `~/.local/state/ally-x20-steamos/notifications.seen`, as the number of
  lines consumed plus the `ts` of the last line shown.
- If the file now has fewer lines than the stored count, it was rotated:
  start from the first line again, skipping lines whose `ts` is older than
  the last one shown.
- Unknown levels are treated as `info`; malformed lines are skipped.

## What the notifier shows

On login (and when the queue changes during the session) it shows **one**
notification that summarises all unseen events instead of one popup per
line:

- title: `ROG Xbox Ally X20 support`;
- body: one bullet per unseen message, newest last, at most 5 (then
  "and N more: run `ally-x20-steamos.sh status`");
- urgency: the highest level among the unseen events (`error` → critical,
  `warn` → normal, `info` → low).

Events that producers queue (current and planned):

| producer | level | when |
|---|---|---|
| `probe --notify` (boot service) | info | a component newly flipped to superseded; nothing is removed, the message names `uninstall --superseded` |
| `self-update --check --notify` (boot service, daily) | info | a newer release is available |
| boot service / RAUC post-install | info | after a SteamOS update: what was re-applied |
| boot service | warn | modules are being rebuilt for a new kernel; effective after the next reboot |
| RAUC pre-install (policy `block`) | error | an update was blocked because modules could not be produced; includes where the build log is |
