# Running these demos in person

The four `manual-demo-*.md` files are the clicks. This is everything else:
what to check first, what will look broken when it isn't, and how to recover.

Suggested order — topology, then build by hand, then get it for free, then ship
it safely:

1. Advanced Pipeline Editor (edge/gateway architecture)
2. Pipeline Intelligence (build a pipeline)
3. Full Pipeline Blueprints (don't build a pipeline)
4. Progressive Rollouts and Rollbacks

## Before you present (5 min)

```bash
docker compose ps | grep -c bdot-          # 30
bindplane get agents --selector role=source          # 5
bindplane get agents --selector fleet=grrcon-edge    # 10
bindplane get agents --selector fleet=grrcon-gateway # 10
```

Then confirm data is actually moving — every source collector should be non-zero:

```bash
for row in bdot-apache:Elastic bdot-cef:Splunk bdot-panos:Dynatrace \
           bdot-appjson:googlecloud bdot-winsec:SecOps; do
  n=${row%%:*}; d=${row##*:}
  printf "%-14s %s\n" "$n" "$(docker logs --since 60s $n 2>&1 | grep -c "$d")"
done
```

Expect roughly 45-90 each (measured). `bdot-winsec` runs lowest — see "fails
quietly" below.

## Things that look broken and are not

- **5 collectors sit at `CONFIGURATION: -`.** The `bdot-*-unbound` twins run no
  config on purpose. Do not "fix" them. Only worry if a collector *without*
  `-unbound` in its name is unbound.
- **Every backend fails to export.** Stale tenants, `REPLACE_ME` tokens, a
  mocked SecOps key. The export errors are the *proof records arrived* — that is
  what you are counting above.
- **Google SecOps fails quietly.** ~7 log lines in 3 min against Splunk's ~1600.
  A low count there is not a broken pipeline. Use Bindplane throughput instead.
- **A progressive rollout pauses mid-flight.** `Paused STAGE=Prod errors=0` is
  stage 1 done, stage 2 waiting. Read the `STAGE` and `errors` columns before
  touching anything. This *is* the Progressive Rollout demo — don't debug it.
- **Apache and CEF volume looks 10x too high.** All ten edge collectors tail the
  same two files. Inherent, documented, fine.

## If it's broken on stage

**No `grrcon-*` configs, or pipeline collectors unbound.** The account has been
wiped several times. Everything rebuilds from the repo:

```bash
bindplane apply -f bindplane/
bindplane rollout start grrcon-gateway   # then resume at the Prod gate
bindplane rollout start grrcon-edge
```

**Still unbound after the apply.** The `configuration=` label only binds when its
value *changes* while the config exists. Force it:

```bash
bindplane label agent --selector fleet=grrcon-edge configuration=none --overwrite
sleep 5
bindplane label agent --selector fleet=grrcon-edge configuration=grrcon-edge --overwrite
```

Same shape for `grrcon-gateway`, and per source: `fleet=grrcon-source-apache` →
`configuration=grrcon-apache`.

**A stream stopped.** Restart its generator, then re-check:

```bash
docker compose -f docker-compose.blitz.yaml restart
```

`connection refused` in the generator logs means the collector had no listener —
i.e. its config was missing. Apply first, then restart.

**Apache or CEF stopped.** Permissions. blitz writes `0600`; collectors run as
`otel`:

```bash
chmod 644 logs/*/*.log
docker exec bdot-apache stat -c '%U %a' /var/log/apache2/access.log   # otel 644
```

## Never do this live

- **Do not run `bindplane apply -f bindplane/` if anyone has unrolled-out UI
  work.** It overwrites the whole config and discards it. Check
  `bindplane get configurations` for a version ahead of what the agents run, and
  apply the single file you need instead. Old versions are recoverable under
  `History`, but not mid-demo.
- **Do not trust a 60s window on the gateway tier.** Elastic is bursty there and
  can legitimately read 0 over a minute while healthy over three. Use
  `--since 3m` before concluding anything is broken.
- **Do not edit `OPAMP_LABELS` in compose and expect it to take.** Agent IDs are
  pinned, so Bindplane keeps its cached labels. Use `bindplane label agent`.

## Per-demo cues

**Advanced Pipeline Editor.** The point is that the edge does no processing and
the gateway does all of it. In the routing connector, note Apache uses
`body["log_type"]` while everything else uses `attributes["log_type"]` — because
`apache_common` parses into the body. There is **no catch-all route**, so a
mismatched condition drops the stream silently with nothing to show for it.

**Pipeline Intelligence.** Pause after the JSON parser lands: fields appear, and
the timestamp is *still* 1970 with severity *still* unset. "Parsed" is not
"usable" — that is what earns the next two processors. Contrast with CEF, which
gets timestamp and severity free from its native source.

**Full Pipeline Blueprints.** UI names differ from CLI names:

| UI | CLI |
|---|---|
| Enrich Palo Alto Security Events for Dynatrace | `dynatrace-palo-alto-security-full-pipeline` |
| Ingest and Process Apache Common Logs for Elasticsearch | `elasticsearch-apache-common-full-pipeline` |
| Standardize & Route Windows Events for Google SecOps | `google-secops-windows-routing-bundle` |

The MITRE fields (`mitre_tactic`, `mitre_technique_id`) are the payoff — a raw
CSV column became `T1078 / Valid Accounts` with nobody writing a detection rule.
Note this demo and the Advanced Pipeline Editor both add the Windows SecOps
blueprint; if you run both, add it to `grrcon-gateway` in one and
`grrcon-winsec` in the other rather than showing the same thing twice.

**Progressive Rollouts.** Two collectors carry `env=canary` (`bdot-01`,
`bdot-02`); the other eight are `env=prod`. `maxErrors` is 0, so one erroring
collector halts the rollout — which is the story, not a fault.

## After you present

The blueprint demo creates configs, and **a new config will claim an unbound
twin collector**, so the next person's pre-flight numbers come out wrong. Clean
up:

```bash
bindplane get configurations | grep -E 'demo|test'   # your leftovers
bindplane delete configuration <name>
```

Then re-check that exactly five `bdot-*-unbound` collectors are unbound. If a
twin is still attached, clear its label:

```bash
bindplane label agent <agent-id> configuration= --overwrite
```

If you added blueprints to `grrcon-winsec` or `grrcon-gateway`, reset them so the
next run has a "before" to show:

```bash
bindplane apply -f bindplane/40-gateway.yaml       # or 20-source-winsec.yaml
bindplane rollout start grrcon-gateway
```

Deeper background per stream is in `docs/claude-generated/`; operational detail
is in `.claude/`.
