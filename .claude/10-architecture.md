# Architecture and rationale

> Split out of the original long README. Part of the GrrCON Bindplane demo reference.

# GrrCON demo: Bindplane-managed gateway topology

Thirty BDOT collectors in Docker, all managed from Bindplane Cloud over OpAMP.
Twenty-five run a pipeline; five are deliberately unbound (see [Unbound
twins](#unbound-twins)).

Three tiers, seven fleets -- the two multi-collector tiers get one fleet each,
and every source collector gets its own:

- **`grrcon-source-apache` / `-cef` / `-panos` / `-winsec` / `-appjson`** -- five
  collectors, one per source+destination pipeline, each with its own
  configuration, shipping straight to a backend. One fleet per collector, so any
  single source can be upgraded, restarted or rolled on its own. They all keep
  `role=source`, so `--selector role=source` still addresses the tier at once.
  Each of these fleets holds exactly one collector -- the unbound twins are
  deliberately kept out of every fleet, for a reason worth knowing before you
  add one: see [Unbound twins](#unbound-twins).
- **`grrcon-edge`** -- ten collectors (`bdot-edge-01..10`) all running the same
  configuration: the five native sources, forwarding to the gateway pool.
  Simulates a fleet of edge hosts.
- **`grrcon-gateway`** -- ten collectors behind the `bdot-pool` alias. Receive the
  merged stream from the edge tier and fan it out to the five backends via the
  routing connector.

```
  EDGE TIER -- one collector per pipeline, one configuration each

  blitz-winsec ──tcp:5142──▶ bdot-winsec  (grrcon-winsec)  ──▶ Google SecOps
  blitz-palo-alto ─tcp:5141▶ bdot-panos   (grrcon-panos)   ──▶ Dynatrace
  blitz-json ────tcp:5143──▶ bdot-appjson (grrcon-appjson) ──▶ Google Cloud
  blitz-cef ─────file──────▶ bdot-cef     (grrcon-cef)     ──▶ Splunk HEC
  blitz-apache-native ─file▶ bdot-apache  (grrcon-apache)  ──▶ Elastic

  EDGE + GATEWAY TIERS -- the ten edge collectors run the same five native
  sources and forward EVERYTHING to the pool; the gateway tier does the fan-out.

  apache (file) ┐
  cef (file)    │   bdot-edge-01..10
  panos  :5141  ├─▶ (alias bdot-edge-pool) ─▶ bdot-pool ─▶ router ─▶ backends
  winsec :5142  │                            (bdot-01..10)
  appjson:5143  ┘
```

Every stream therefore arrives at its backend **twice** — once via its edge
collector, once via the gateway path. That is deliberate; see "Duplicate
generators" below.

Nothing in `docker-compose.yaml` defines a pipeline. The collectors register,
report their labels, and pull their configuration from Bindplane. Pipelines
live in `bindplane/` -- one `edge-*.yaml` per pipeline.

**One configuration per source+destination pair** is the organising idea. A
collector can only hold one configuration, so each pipeline gets its own
collector. That is also the shape Bindplane's `full_pipeline_blueprint`s are
written in (`elasticsearch-apache-common-full-pipeline`,
`dynatrace-palo-alto-security-full-pipeline`), so each config here can adopt its
blueprint without disturbing the others.

## Why it is shaped this way

**`bdot-pool` is a shared Docker network alias**, declared by all ten gateway collectors.
Docker's embedded DNS returns all ten container IPs for that one name, so the
edge destination targets a single hostname with gRPC load balancing enabled.
Add or remove workers and the Bindplane config never changes.

**Each edge collector owns its ingest.** `bdot-panos`, `bdot-winsec` and
`bdot-appjson` listen on 5141/5142/5143; `bdot-apache` and `bdot-cef` tail files
instead. blitz reaches them by container name on `bdot-net`, so the published
ports exist only so you can send test traffic from the laptop.

**The gateway tier is logs-only.** The OTLP source was removed once nothing used
it, so the edge tier publishes no ports at all. Every native source is
logs-only, and the worker gateway source is now `telemetry_types: [Logs]` — which
also stops v2 auto-generating metrics/traces routes to every destination.

Re-adding OTLP means restoring three things together: the source and its route,
the 4317/4318 ports on the `bdot-edge-*` containers, and `Metrics`/`Traces` on
the worker gateway source.

**The edge tier lives in its own fleet.** A collector can belong to exactly one
fleet at a time, so `fleet=` is the one mutually exclusive label here: the ten
edge collectors are `fleet=grrcon-edge`, the ten gateways are
`fleet=grrcon-gateway`. The front door can be upgraded, restarted, or rolled
without touching the pool, and a fleet-wide action aimed at the gateway tier can
never reach it.

**The edge tier is not labeled `env=`.** `bdot-winsec` is the only source-tier collector
that needs `credentials.json` -- it is the one exporting to Google SecOps, and
the chronicle exporter reads that file at startup.

**Agent IDs are pinned ULIDs**, so the same twenty-five agents reconnect after
any restart -- even `docker compose down -v`.
Without pinning, every teardown mints new agents and orphans the old ones.

**Both configurations use `apiVersion: bindplane.observiq.com/v2`**, which adds
advanced routing: explicit source-to-destination connections instead of an
implicit fan-out. See "Configuration v2" below.

---

Working rules, verification discipline and the silent failure modes:
[`../CLAUDE.md`](../CLAUDE.md).
