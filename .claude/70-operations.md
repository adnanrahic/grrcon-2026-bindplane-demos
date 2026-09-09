# Verify, rollouts, unbound recovery

> Split out of the original long README. Part of the GrrCON Bindplane demo reference.

## Verify

```bash
docker compose ps                                     # 30 up
bindplane get fleets | grep grrcon                    # 7 grrcon fleets
bindplane get agents --selector fleet=grrcon-gateway  # 10 gateways
bindplane get agents --selector fleet=grrcon-edge     # 10 edge
bindplane get agents --selector role=source           # 5 source collectors
bindplane get agents --selector role=source-unbound   # 5 unbound, no fleet
bindplane get agents --selector fleet=grrcon-source-apache   # 1
```

There is no single selector covering all 30 -- the fleet split is what makes
that true. Use `role=edge` / `role=gateway` / `role=source` to slice by tier:
`role=` is the non-exclusive label, which is why the source tier is still
addressable as a unit after being split into five fleets.
No collector publishes 13133, so there is no host-side health curl.

Confirm every collector actually bound to a configuration; a `-` in the
`CONFIGURATION` column means it did not:

```bash
bindplane get agents --selector fleet=grrcon-gateway | awk '{print $2, $6}'
```

Push real telemetry through the front door:

```bash
docker compose -f docker-compose.blitz.yaml up -d
```

### Are all five pipelines carrying data?

Every destination currently fails to export, and those errors are the evidence —
each names its exporter, so a non-zero count per collector proves records reached
it:

```bash
for row in bdot-apache:otlp_http/grrcon-elastic \
           bdot-cef:splunk_hec/grrcon-splunk-hec__logs \
           bdot-panos:otlp_http/grrcon-dynatrace \
           bdot-appjson:googlecloud/grrcon-google-gcl \
           bdot-winsec:chronicle/grrcon-google-secops; do
  n=${row%%:*}; d=${row#*:}
  printf "%-14s %s\n" "$n" \
    "$(docker logs --since 60s $n 2>&1 | grep -c "\"otelcol.component.id\":\"$d\"")"
done
```

All five should be non-zero. A zero on `bdot-apache` or `bdot-cef` almost always
means file permissions — check `docker exec <collector> stat -c '%U %a' <path>`;
it must be readable by `otel`.

Confirm each collector is on its own configuration:

```bash
bindplane get agents --selector fleet=grrcon-edge
```

### Is the gateway tier still healthy?

It carries no blitz logs any more, so the gateway tier should be quiet — that is
expected, not a fault:

```bash
bindplane get agents --selector fleet=grrcon-gateway    # 10, all Connected
```

### Is the pool balanced?### Is the pool balanced? Expect a spread rather than an even split:
`round_robin` balances per gRPC *connection*, not per record, so at low
connection counts some workers run 2-3x others. That is not a fault.

If one collector has everything and the rest are at zero, gRPC load balancing did
not take effect -- check for `balancer_name: round_robin` and
`endpoint: dns:///bdot-pool:4317` in an edge collector's effective config:

```bash
docker exec bdot-edge-01 sh -c 'cat ./config.yaml' | grep -A4 otlp_grpc
```

**No debug exporter any more.** `grrcon-gateway` used to carry
`debug/grrcon-debug-out`, which logged `"msg":"Logs"` and served as a
proof-of-flow sink. It is gone, so grepping a gateway collector for `"msg":"Logs"`
now legitimately returns zero -- use the per-exporter error counts above
instead.

## Progressive rollout demo

`grrcon-gateway` carries progressive rollout options on the **configuration
resource**, so every rollout of it stages by label however it is triggered:

```yaml
spec:
  rollout:
    type: progressive
    parameters:
      - name: stages
        value:
          - {name: Canary, labels: {env: canary}}   # bdot-01, bdot-02
          - {name: Prod,   labels: {env: prod}}     # bdot-03..10
      - name: maxErrors
        value: 0
      - name: phaseAgentCount
        value: {type: adaptive, initial: 0, multiplier: 0, maximum: 0}
```

**This is label-based staging, which `bindplane rollout start` cannot express** —
its flags (`--initial`/`--multiplier`/`--max`) only phase by *count*. Earlier
versions of this README claimed label staging was impossible; that was wrong. It
lives on the configuration, not on the command.

`phaseAgentCount: adaptive` lets the server size each phase from the collector
count; `initial`/`multiplier`/`maximum` are ignored in that mode.

Running it:

```bash
bindplane rollout start  grrcon-gateway    # stage 1: env=canary only
bindplane rollout status grrcon-gateway    # STAGE column shows "Canary"
bindplane get agents --selector env=canary # confirm only these two moved
bindplane rollout resume grrcon-gateway    # advance to stage 2: env=prod
```

**It pauses between stages** — after Canary completes, status goes `Pending` and
waits for `resume`. Observed mid-rollout, which is the moment worth showing:

```
bdot-01  canary  grrcon-gateway:31     <- new version
bdot-02  canary  grrcon-gateway:31
bdot-03  prod    grrcon-gateway:30     <- held back
...
bdot-10  prod    grrcon-gateway:29
```

`maxErrors: 0` halts the rollout on the first collector that fails to start —
observed for real earlier in this project, when a bad SecOps credentials path
stopped a rollout at one collector while the other nine stayed up.

## Recovering an unbound collector

Both recoveries below are about **state the collector or server already holds
beating what you tell it**. The same shape bites when moving between servers:
`manager.yaml` in each storage volume outranks `OPAMP_ENDPOINT`, so switching
needs `docker compose down -v`, not `--force-recreate`. See `90-selfhosted.md`.

If `bindplane get agents` shows `CONFIGURATION: -` on a collector whose labels
clearly include `configuration=<name>`, the binding never fired. Force it by
toggling the label to a throwaway value and back:

```bash
bindplane label agent --selector fleet=grrcon-gateway configuration=none --overwrite
sleep 5
bindplane label agent --selector fleet=grrcon-gateway configuration=grrcon-gateway --overwrite
```

Applying the configurations before `docker compose up -d` avoids this entirely.

---

Working rules, verification discipline and the silent failure modes:
[`../CLAUDE.md`](../CLAUDE.md).
