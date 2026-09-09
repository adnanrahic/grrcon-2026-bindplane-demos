# Working in this repo

A GrrCON demo: 30 Bindplane collectors in Docker, five log formats, five
backends, managed from Bindplane Cloud over OpAMP. Changes here touch a **live
account** — treat every apply as production.

## Where things are

- `README.md` — overview, quick start, layout
- [`.claude/00-index.md`](.claude/00-index.md) — **the detail behind this file**;
  the reference is split by topic across `.claude/10-` … `80-`, and every topic
  file links back here
- `docs/` — one demo walkthrough per stream
- `bindplane/` — the resources; applied in **filename order**
- `samples/`, `docker-compose*.yaml`, `logs/` (gitignored)
- `selfhosted/` — a full Bindplane server in Docker, for running the demo with
  no cloud account; has its own README

Every markdown file in this repo is **capped at 200 lines**. Split rather than
exceed it.

## Rules that are load-bearing

**`bindplane apply` before `docker compose up`.** A collector's `configuration=`
label binds only when its value *changes* while the named configuration already
exists. Collectors started first sit at `CONFIGURATION: -` permanently. Recovery
is in `.claude/70-operations.md`.

**`apply` alone never reaches a collector.** It versions the resource; a
`bindplane rollout start <config>` is what pushes it. An apply can report success
while every collector still runs the old version. Always check
`bindplane rollout status`.

**Filename order encodes dependencies** in `bindplane/`. A Connector must exist
before the Configuration referencing it, and Sources before `30-edge.yaml`. Both
only fail against a *fresh* account — with the resources already present a wrong
order silently works. Do not rename these files without re-checking the order.

**Never commit `.env` or `credentials.json`.** Both are gitignored. Scan staged
content before committing.

## Verification discipline

This repo's recurring failure mode is **silent success**: data keeps flowing,
throughput looks healthy, and the thing you changed did nothing. Assume nothing
worked until the running system says so.

- **Check the collector's effective config**, not the apply output:
  `docker exec <collector> sh -c 'cat ./config.yaml'`
- **A format-specific source that cannot parse its input fails silently.** No
  error, records still flow. The tells are a **string body** and a **1970
  timestamp**.
- **`verbosity: basic` prints a count, not a record.** If you need to see a
  record, set `detailed` — and roll out the *destination's* config before the
  config that references it, or the change will not land.
- **Grep patterns lie.** Collector v1.106 logs `"msg":"Logs"`; older builds wrote
  `LogsExporter`. A zero count usually means the wrong pattern, not an outage.
- **A string replace that matches nothing reports success.** Assert the match
  count when scripting edits, and re-read the file after.
- **Check `docker inspect` for mounts**, not just the compose file — an edit that
  did not apply looks identical in YAML.

## Gotchas specific to this setup

**A collector's `manager.yaml` outranks its environment.** Each storage volume
persists the endpoint, agent ID and secret key from first registration, and
that file wins over `OPAMP_ENDPOINT`/`OPAMP_SECRET_KEY`. Moving collectors
between servers needs `docker compose down -v`, not `--force-recreate` — which
fails as 401s in the collector log while compose reports a clean start.

**Agent labels are cached server-side.** Agent IDs are pinned ULIDs, so Bindplane
keeps the labels it already holds and ignores what a re-registering collector
reports. Editing `OPAMP_LABELS` in compose does nothing on its own — relabel with
`bindplane label agent <id> k=v --overwrite`, or drop that collector's volume.

**Every backend fails to export, by design.** Stale tenants, placeholder tokens,
a mocked service-account key. Export errors are the *evidence records arrived* —
count them per exporter to prove a route works. Google SecOps is the exception:
it fails quietly, so a low error count there is not success.

**Every resource this repo owns is `grrcon-` prefixed, destinations included.**
That is what keeps `bindplane apply` from touching the shared account: it used
to reference `Elastic`, `Dynatrace`, `Google-SecOps-Linux` and `Splunk-HEC` by
name and overwrite them. Never add an unprefixed resource to `bindplane/` — and
note the prefix is also what the nightly wipe matches, so anything you add is
rebuilt from the repo, not left behind to mask a gap.

**A nightly job wipes the `grrcon-*` resources.** Assume the account is empty
every morning: check before doing anything, and expect to `bindplane apply -f
bindplane/` plus roll out. Fleets and the router connector survive; sources,
destinations and configurations do not. See `.claude/80-maintenance.md`.

**A paused progressive rollout is not a failure.** `grrcon-gateway` stages
Canary → Prod and reports `Paused … errors=0` between them.
`bindplane rollout resume grrcon-gateway` advances it. Read the `STAGE` and
`errors` columns before debugging.

**`log_type` is not in the same place for every stream.** Apache parses into the
body, so its router condition is `body["log_type"]`; everything else uses
`attributes["log_type"]`. A mismatch matches nothing silently and — with the
router's catch-all removed — the stream is dropped unobserved. See
`.claude/50-routing.md`.

**Files blitz writes are `0600`**, and collectors run as `uid=10005(otel)`. A
root-owned file is unreadable and the source tails nothing *without an error*.

## Working style here

- **Verify against the live system before reporting success.** "Applied cleanly"
  is not "rolled out", and "rolled out" is not "carrying data".
- **Fix the data, not the parser,** when a native source will not parse. That has
  been the right answer every time so far — see `docs/claude-generated/demo-native-sources.md`.
- **Leave the user's uncommitted work alone.** Stage specific paths rather than
  `git add -A` when the tree has edits you did not make.
- **Say when something is unverified.** Several conclusions in this repo were
  wrong first time; flagging the uncertain ones is more useful than a confident
  guess.
