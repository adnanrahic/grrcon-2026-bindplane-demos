# Advanced Pipeline Editor — illustrated click guide

The click-by-click version of
[`manual-demo-advanced-pipeline-editor.md`](manual-demo-advanced-pipeline-editor.md),
with a screenshot per step. Operational context — pre-flight, recovery, cleanup —
is in [`RUNNING-THESE-DEMOS.md`](RUNNING-THESE-DEMOS.md).

Shorthand: `SS/` = `manual-demo-advanced-pipeline-editor-screenshots/`.

---

## 1. Open the edge configuration

**Configurations → `grrcon-edge`.**

![Edge config](manual-demo-advanced-pipeline-editor-screenshots/bpss_01-edge-config-full.png)

Point at the Details block first: **BDOT 1.x**, **rolled out to 10 collectors**,
**API version v2**. Then the graph — five sources fanning into a single
`grrcon-gateway-pool` destination, and the Collectors table below showing
`bdot-edge-01..10` all Connected on version 2.

The story: this is the agent pattern. Collect at the edge, do **no processing
there**, ship everything to a gateway.

## 2. Show the edge Logs graph

![Edge logs graph](manual-demo-advanced-pipeline-editor-screenshots/bpss_02-edge-logs-graph.png)

Every processor node on the source rows is empty. Throughput numbers on the
edges are the only thing happening. Nothing is parsed, filtered or enriched yet.

## 3. Open the gateway configuration

**Configurations → `grrcon-gateway`.**

![Gateway graph](manual-demo-advanced-pipeline-editor-screenshots/bpss_03-gateway-logs-graph.png)

![Gateway config](manual-demo-advanced-pipeline-editor-screenshots/bpss_04-gateway-full.png)

One source in, five destinations out, and a router in the middle. This is where
all the work happens — the gateway pattern.

## 4. Open the Advanced Pipeline Editor

**Pipelines → `Open Advanced Editor`.**

![Advanced Pipeline Editor](manual-demo-advanced-pipeline-editor-screenshots/bpss_05-advanced-pipeline-editor.png)

Walk the left sidebar: **Sources 1**, **Routers 1**, **Processor Nodes 0**,
**Destinations 5**. Then the canvas — `grrcon-gateway-in` → `grrcon-router` →
five backends, with live throughput per route.

Note **Processor Nodes: 0**. Everything you are about to add is new.

## 5. Get Log Types on the source node

**Click the processor node next to `grrcon-gateway-in`.**

![Get log types](manual-demo-advanced-pipeline-editor-screenshots/bpss_06-get-log-types.png)

In the Pipeline Intelligence panel, hit **Get Log Types**. The log columns fill
with detected types — `PAN_FIREWALL`, `APACHE`, `WINEVTLOG`, `APPJSON`.

The point: five different formats arriving on **one** source, identified without
anyone writing a parser. Recommendations appear alongside (Parse JSON, Parse
Severity HTTP Status, Batch for Google SecOps) — mention them, do not apply
them; that is the Pipeline Intelligence demo.

## 6. Show the routing rules

**Click `grrcon-router` on the canvas** (or in the sidebar under Routers).

![Routing rules](manual-demo-advanced-pipeline-editor-screenshots/bpss_07-routing-rules-ottl.png)

Five routes, each an OTTL expression. Read two of them aloud and let the
difference land:

```
winsec   attributes["log_type"] == "windows_event.security"
apache   body["log_type"]       == "apache_common"
```

Apache is the odd one out because `apache_common` parses **into the body**, so
its `log_type` is a body field while every other source sets an attribute.

Also visible: **"All routes have conditions. Consider adding a default route to
handle remaining telemetry."** That warning is deliberate — there is no
catch-all, so a mismatched condition drops the stream silently. Worth saying out
loud; it is the honest cost of routing this way.

## 7. Isolate the SecOps destination

**Click `grrcon-google-secops` in the sidebar under Destinations.**
(The screenshot predates the rename and still shows `Google-SecOps-Linux`.)

![Isolate SecOps](manual-demo-advanced-pipeline-editor-screenshots/bpss_08-sidebar-isolate-secops.png)

The graph collapses to just that path: source → router → SecOps, with only the
`winsec` route carrying traffic. `Show Full Configuration` restores the view.

This is the clearest picture of what the router does — Windows Security events
and nothing else reach SecOps.

## 8. Add the blueprint

**`Add Blueprint` (top right) → "Standardize & Route Windows Events for Google
SecOps".**

![Blueprint preview](manual-demo-advanced-pipeline-editor-screenshots/bpss_09-blueprint-preview.png)

The preview shows what you are about to insert: a **Standardization** processor
node (Google SecOps Standardization + Copy Field), then a **routing connector**
splitting by Windows channel — SYSMON, POWERSHELL, DNS, MSSQL, WINEVTLOG — each
with its own batch.

Why the per-channel batching matters: **SecOps ingests per log type**, so mixed
batches are a problem. This is not cosmetic routing.

Click **Add to pipeline**.

![Blueprint attached](manual-demo-advanced-pipeline-editor-screenshots/bpss_10-blueprint-attached.png)

## 9. Show before and after

**Open the logs view on the SecOps processor node.**

![Before](manual-demo-advanced-pipeline-editor-screenshots/bpss_11-secops-node-logs-BEFORE.png)

![Before and after](manual-demo-advanced-pipeline-editor-screenshots/bpss_12-before-after-log-structure.png)

This is the payoff shot. Left is raw, right is after processing, and the two new
attributes are highlighted green:

```
chronicle_ingestion_label["ingestion_source"]   bdot-edge-01
chronicle_log_type                              WINEVTLOG
```

Pipeline Intelligence also reports **Detected Log Type: WINEVTLOG**, **Detected
Body Format: Windows Event Log**, and offers **Validate SecOps Parser —
WINEVTLOG** on the processed side.

Worth noting honestly: the body is still raw Windows Event XML and `time` is
still `1970-01-01`. The blueprint standardises for SecOps; it does not parse the
XML. That is a different blueprint, and a good hook into the next demo.

## 10. Apply and show it live

**`Done` → roll out.**

![Live isolated](manual-demo-advanced-pipeline-editor-screenshots/bpss_13-blueprint-live-isolated-secops.png)

![Editor live](manual-demo-advanced-pipeline-editor-screenshots/bpss_14-editor-live-v5.png)

![Config live](manual-demo-advanced-pipeline-editor-screenshots/bpss_15-config-live-v5-graph.png)

The version increments and the collectors pick it up. Processor Nodes is no
longer 0.

## Afterwards

Reset so the next run has a "before" to show:

```bash
bindplane apply -f bindplane/40-gateway.yaml
bindplane rollout start grrcon-gateway
```

If you also plan to run the Full Pipeline Blueprints demo, add this blueprint to
`grrcon-winsec` there instead — otherwise you show the same thing twice. See
`RUNNING-THESE-DEMOS.md`.
