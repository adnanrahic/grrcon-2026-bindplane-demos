# Collector type, rebuild, relabel, reset, file map

> Split out of the original long README. Part of the GrrCON Bindplane demo reference.

## Collector Type

Each configuration carries `agent-type: observiq-otel-collector` in
`metadata.labels` — that is what the UI shows as **Collector Type**. Without it
the field renders as `-`. `platform: linux` sits alongside it:

```yaml
metadata:
  name: grrcon-edge
  labels:
    agent-type: observiq-otel-collector
    platform: linux
```

## Rebuilding after the nightly wipe

**A nightly job deletes the `grrcon-*` resources.** Observed empty on the
mornings of 2026-09-07 and 2026-09-08; resources applied during the day survive
until the next night. Assume you are rebuilding every morning.

It is selective, which is the quickest way to recognise it:

| Deleted | Survives |
|---|---|
| Sources, Destinations, Configurations | Fleets, the `grrcon-router` Connector |
| | All 30 collectors, still registered |

The collectors keep running but lose their pipelines -- the edge collectors stop
listening on 5141-5143 and the generators fail with `connection refused`.
Symptoms look like a broken generator; the cause is an empty configuration.

Rebuild from source and roll out:

```bash
bindplane apply -f bindplane/
bindplane rollout start grrcon-gateway
bindplane rollout start grrcon-edge
```

Content comes back identical because `bindplane/*.yaml` is the source of truth.
**Version history does not** -- configurations restart at `:1`. That breaks the
rollback half of the Progressive Rollout demo, which needs a previous version to
roll back to, so make a throwaway change and roll it out before presenting that
one.

Collectors may stay at `CONFIGURATION: -` after the apply; the label toggle in
`.claude/70-operations.md` forces the binding.

## Relabeling a collector that has already registered

Two layers cache labels, and both outrank the env var.

**Server-side wins over everything.** Because the agent ID is pinned, Bindplane
already knows this agent and keeps the labels it holds, ignoring what a
re-registering collector reports. A label edit in `docker-compose.yaml` can look
correct inside the container and still be wrong in the UI -- always confirm with
`bindplane get agents`, not with `cat manager.yaml`.

**`OPAMP_LABELS` only seeds `manager.yaml` on first boot.** Once a collector has
registered, the file wins and editing the env var in `docker-compose.yaml` does
nothing -- `docker compose up -d` will recreate the container and it will
reconnect with its old labels.

To make a label edit stick, drop that collector's volume so the file is
re-seeded:

```bash
docker compose rm -sf bdot-edge-01
docker volume rm grrcon-demos_bdot-edge-01-storage
docker compose up -d bdot-edge-01
```

Because the agent ID is pinned in compose, the *same* agent reconnects under the
new labels -- no orphaned collector left in the UI. Alternatively, relabel
server-side without touching the container:

```bash
bindplane label agent 01K5GRRC0N0000000000BD0T00 fleet=grrcon-edge --overwrite
```

## Reset

```bash
docker compose -f docker-compose.blitz.yaml down   # stop the traffic
docker compose down -v                             # agents reconnect with same IDs
```

## Demo walkthroughs

- [`docs/claude-generated/demo-json-parsing.md`](docs/claude-generated/demo-json-parsing.md) — building JSON
  parsing, timestamp promotion and severity mapping by hand on the `appjson`
  stream, the one pipeline no native source or blueprint covers.
- [`docs/claude-generated/demo-palo-alto-blueprint.md`](docs/claude-generated/demo-palo-alto-blueprint.md) — the
  mirror image: a shipped full-pipeline blueprint that parses 13 PAN-OS log
  types, adds MITRE ATT&CK context and exposes volume-reduction toggles.

- [`docs/claude-generated/demo-native-sources.md`](docs/claude-generated/demo-native-sources.md) — the `apache`
  and `cef` streams, where the source type parses on ingest and you write no
  processors at all, plus the silent failure mode when the data does not match
  what the parser expects.
- [`docs/claude-generated/demo-winsec-secops.md`](docs/claude-generated/demo-winsec-secops.md) — Windows Events to
  Google SecOps, where a native source exists but the `windowseventlog` receiver
  needs a Windows host, so the XML is parsed and standardized downstream instead.

Run them in that order — hand-built, then shipped blueprint, then native source.
Each ran on the same collectors, routing and destinations; only the amount of
work differed, which is the argument none of them makes alone.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yaml` | 30 collectors (25 with a pipeline, 5 unbound), network aliases, per-collector volumes, credentials mount |
| `docker-compose.blitz.yaml` | telemetry generators feeding tcp 5141-5143 and the tailed log files |
| `.env` | secret key and endpoint -- gitignored, never commit |
| `.env.example` | template |
| `credentials.json` | dummy SecOps service account -- gitignored, generate per step 2 |
| `logs/apache2/`, `logs/cef/` | native-format files written by blitz, tailed by the collectors -- gitignored |
| `bindplane/20-source-apache.yaml` | `apache_common` (file) -> Elastic |
| `bindplane/20-source-cef.yaml` | `common_event_format` (file) -> Splunk HEC |
| `bindplane/20-source-panos.yaml` | `tcp` :5141 -> Dynatrace |
| `bindplane/20-source-winsec.yaml` | `tcp` :5142 -> Google SecOps |
| `bindplane/15-destination-google-gcl.yaml` | `grrcon-google-gcl` -- Google Cloud Logging, `auth_type: file` |
| `bindplane/20-source-appjson.yaml` | `tcp` :5143 (JSON parsed) -> Google Cloud |
| `bindplane/50-fleets.yaml` | `grrcon-gateway`, `grrcon-edge`, and one `grrcon-source-*` fleet per source collector |
| `bindplane/30-edge.yaml` | `grrcon-edge` -- the five native sources -> gateway pool |
| `bindplane/10-connector-router.yaml` | routing connector -- splits the pooled stream by `log_type`. numbered `10-` so it applies first: a connector must exist before the config referencing it |
| `bindplane/40-gateway.yaml` | `grrcon-gateway` -- gateway source -> router -> five destinations, progressive rollout |

---

Working rules, verification discipline and the silent failure modes:
[`../CLAUDE.md`](../CLAUDE.md).
