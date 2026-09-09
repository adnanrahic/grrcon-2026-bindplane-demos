# GrrCON 2026 — Bindplane demos

Thirty [Bindplane](https://bindplane.com) OpenTelemetry collectors in Docker,
managed from Bindplane Cloud over OpAMP. Five log formats, five backends, and a
gateway tier that routes between them.

Nothing here defines a pipeline — pipelines live in `bindplane/` and are applied
to the account separately.

## The five streams

| Stream | Source type | Ingest | Backend |
|---|---|---|---|
| Apache access | `apache_common` (file) | `/var/log/apache2/access.log` | Elastic |
| CEF | `common_event_format` (file) | `/var/log/cef/events.log` | Splunk HEC |
| Palo Alto PAN-OS | `tcp` | `:5141` | Dynatrace |
| Windows Security | `tcp` | `:5142` | Google SecOps |
| Mixed JSON app logs | `tcp` | `:5143` | Google Cloud Logging |

## The tiers

| Tier | Collectors | Fleet(s) | Role |
|---|---|---|---|
| Source | 5 | `grrcon-source-*` (one each) | One pipeline each, straight to a backend |
| Edge | 10 | `grrcon-edge` | All five sources, forwarding to the gateway pool |
| Gateway | 10 | `grrcon-gateway` | Receive the merged stream, fan out via a routing connector |
| Unbound twins | 5 | none | Deliberately no configuration — for demoing the unbound state |

## Quick start

```bash
cp .env.example .env                  # fill in BINDPLANE_SECRET_KEY
mkdir -p logs/apache2 logs/cef && chmod 777 logs/apache2 logs/cef
# generate the dummy SecOps key -- see .claude/20-setup.md
bindplane apply -f bindplane/         # MUST come before docker compose
docker compose up -d
bindplane rollout start grrcon-gateway
bindplane rollout start grrcon-edge
docker compose -f docker-compose.blitz.yaml up -d
```

**`apply` before `up`.** A collector's `configuration=` label binds only when its
value changes while the named configuration already exists. Start the collectors
first and they sit at `CONFIGURATION: -` permanently.

## Run it without the cloud

[`selfhosted/`](selfhosted/README.md) brings up a complete Bindplane server —
server, postgres, prometheus, transform agent — as its own compose stack, so the
demo survives conference wifi and cannot disturb the shared cloud account. The
collectors move over by editing two lines in `.env`; nothing in
`docker-compose.yaml` changes.

The nightly wipe does not reach it either, so rollout history survives between
rehearsals — which the Progressive Rollouts demo needs and cloud rarely has.

Two things that will catch you: switching needs `docker compose down -v`, not
`--force-recreate` (each collector persists the endpoint it first registered
with, and that file wins), and the CLI is pointed separately from the collectors
— `bindplane profile use local`, or `apply` keeps writing to cloud and says it
worked.

## Verify

```bash
docker compose ps                                     # 30 up
bindplane get agents --selector role=source           # 5
bindplane get agents --selector role=source-unbound   # 5 unbound, no fleet
bindplane get agents --selector fleet=grrcon-edge     # 10
bindplane get agents --selector fleet=grrcon-gateway  # 10
```

Every backend fails to export — stale tenants, placeholder tokens, a mocked
service-account key. That is fine: Bindplane measures throughput at the
pipeline, and the export errors are themselves the proof records arrived.

## Demo quick start

**Read [`docs/manual-demo-flows/RUNNING-THESE-DEMOS.md`](docs/manual-demo-flows/RUNNING-THESE-DEMOS.md)
before presenting.** It has the 5-minute pre-flight, what looks broken but
isn't, how to recover on stage, and what to clean up afterwards.

A nightly job wipes the `grrcon-*` resources, so most mornings you start with:

```bash
bindplane get configurations | grep grrcon    # 7 -- if empty, rebuild:
bindplane apply -f bindplane/
bindplane rollout start grrcon-gateway        # then resume at the Prod gate
bindplane rollout start grrcon-edge
```

Then run the flows in order — topology, build one by hand, get one for free,
ship it safely. Each has a terse **flow** doc and an **illustrated** guide with a
screenshot per step:

| # | Demo | Shows | Flow | Illustrated |
|---|---|---|---|---|
| 1 | Advanced Pipeline Editor | Edge/gateway architecture and the routing connector | [flow](docs/manual-demo-flows/manual-demo-advanced-pipeline-editor.md) | [screenshots](docs/manual-demo-flows/manual-demo-advanced-pipeline-editor-illustrated.md) |
| 2 | Pipeline Intelligence | Building a pipeline by hand on the unparsed JSON stream | [flow](docs/manual-demo-flows/manual-demo-pipeline-intelligence.md) | [screenshots](docs/manual-demo-flows/manual-demo-pipeline-intelligence-illustrated.md) |
| 3 | Full Pipeline Blueprints | Not building one — parse, enrich and reduce, shipped | [flow](docs/manual-demo-flows/manual-demo-full-pipeline-blueprints.md) | [screenshots](docs/manual-demo-flows/manual-demo-full-pipeline-blueprints-illustrated.md) |
| 4 | Progressive Rollouts and Rollbacks | Canary → prod staging, halting on error, rollback | [flow](docs/manual-demo-flows/manual-demo-progressive-rollouts-and-rollbacks.md) | [screenshots](docs/manual-demo-flows/manual-demo-progressive-rollouts-and-rollbacks-illustrated.md) |

Use the illustrated guide when rehearsing or handing a demo to someone who has
not run it — it shows the paused and half-migrated states that read as faults.
Use the flow doc live; it is the shorter prompt.

Per-stream background is in [`docs/claude-generated/`](docs/claude-generated/).

## Layout

| Path | Contents |
|---|---|
| `bindplane/` | Sources, destinations, connector, configurations, fleets. Applied in filename order. |
| `selfhosted/` | A full Bindplane server in Docker — run the demo with no cloud account |
| `docker-compose.yaml` | The 30 collectors |
| `docker-compose.blitz.yaml` | Telemetry generators |
| `samples/` | Replay data, vendored so no blitz checkout is required |
| `docs/manual-demo-flows/` | Each demo twice — terse flow and illustrated click guide — plus the runbook and screenshots |
| `docs/claude-generated/` | Per-stream background — one walkthrough per stream |
| `.claude/` | Full reference, split by topic. Start at `.claude/00-index.md`. |

## Requirements

Docker, the `bindplane` CLI, and either a Bindplane Cloud account or the
self-hosted stack in [`selfhosted/`](selfhosted/README.md) (which needs a
Bindplane EE license).

No [blitz](https://github.com/observIQ/blitz) checkout is needed — every sample
the generators replay is vendored into `samples/`. Refreshing the Palo Alto
lines from upstream is the one task that wants a clone, via
`samples/vendor-palo-alto.sh` (honours `BLITZ_REPO`).
