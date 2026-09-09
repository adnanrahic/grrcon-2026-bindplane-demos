# Full Pipeline Blueprints — illustrated click guide

The click-by-click version of
[`manual-demo-full-pipeline-blueprints.md`](manual-demo-full-pipeline-blueprints.md),
with a screenshot per step. Operational context — pre-flight, recovery, cleanup —
is in [`RUNNING-THESE-DEMOS.md`](RUNNING-THESE-DEMOS.md).

Two halves: **build a config from a blueprint**, then **drop one into a config
that already exists**. Shorthand `SS/` = `manual-demo-full-pipeline-blueprints-screenshots/`.

---

# Part 1 — Build a new config from a blueprint

## 1. Create a configuration

**Configurations → New.** Fill in the Details step.

![Create configuration](manual-demo-full-pipeline-blueprints-screenshots/01-create-configuration.png)

![Details filled](manual-demo-full-pipeline-blueprints-screenshots/02-config-details-filled.png)

## 2. Build from a Blueprint

On the **Add Sources** step, take `Build from a Blueprint` rather than
`Add Source`.

![Build from a blueprint](manual-demo-full-pipeline-blueprints-screenshots/03-build-from-a-blueprint.png)

![Blueprint picker](manual-demo-full-pipeline-blueprints-screenshots/04-blueprint-picker.png)

Each entry carries a **Full Pipeline** badge and its tags — `Palo Alto`,
`Dynatrace`, `Security`, `Enrichment`, `MITRE ATT&CK` on one; `Apache Common`,
`Elasticsearch`, `Parsing`, `Filtering`, `Normalization` on another. Use either:

- **Enrich Palo Alto Security Events for Dynatrace**
- **Ingest and Process Apache Common Logs for Elasticsearch**

## 3. Read the blueprint before taking it

![Apache blueprint detail](manual-demo-full-pipeline-blueprints-screenshots/05-apache-blueprint-detail.png)

Eleven numbered processors, in order — parse, parse timestamp, two filters, map
status to severity, mask, drop high-cardinality, add ECS, sample, deduplicate,
delete empties. Worth reading a few aloud: this is somebody's expert pipeline,
not a parser.

Note the banner: *"This Blueprint has been tested against standard data
patterns. You may need to adjust the configuration to match your specific data
format."* Honest framing — it is a strong starting point, not magic.

## 4. Configure the destination

The **sources are pre-wired** by the blueprint. Only the destination needs
filling in, and dummy values are fine — nothing has to actually arrive.

![Destination form](manual-demo-full-pipeline-blueprints-screenshots/06-destination-form-empty.png)

![Destination dummy data](manual-demo-full-pipeline-blueprints-screenshots/07-destination-form-dummy-data.png)

## 5. Show what you got

![New config](manual-demo-full-pipeline-blueprints-screenshots/08-new-config-created-full.png)

![New config pipeline](manual-demo-full-pipeline-blueprints-screenshots/09-new-config-pipeline.png)

A complete pipeline — source, processor node, destination — from a form and a
dropdown.

## 6. Open the processor node

**Open Advanced Editor → click the processor node.**

![Editor](manual-demo-full-pipeline-blueprints-screenshots/10-new-config-editor.png)

![Eleven processors](manual-demo-full-pipeline-blueprints-screenshots/11-processor-node-11-processors.png)

The bundle expands into its eleven processors, each individually editable. The
blueprint is a starting point you own, not a black box.

## 7. Show the transformation

![Example telemetry](manual-demo-full-pipeline-blueprints-screenshots/12-sample-logs-transformed-ootb.png)

Before in red, after in green:

```
before   body: 203.0.113.45 - - [15/Jan/2024:10:30:45 -0500] "GET /old-dashboard HTTP/1.1" 301 512
         severity_text: (empty)   severity_number: 0   time = observed_time

after    method GET · path /old-dashboard · status_code 301 · response_bytes 512
         severity_text WARN · severity_number 13 · time corrected
         remote_host ****                      <- masked
         event.dataset apache.access · event.kind event
         deployment.environment production · service.name apache
```

**Say what this is:** the blueprint's own **Example Telemetry**, not your live
data. This config has no collectors attached — the editor reads *No Collectors*
and *No recent logs*. It shows what the blueprint does; it is not proof your
data flowed. Claiming otherwise is the one thing that will get caught.

---

# Part 2 — Drop a blueprint into an existing config

## 8. Open `grrcon-winsec`

![Winsec before](manual-demo-full-pipeline-blueprints-screenshots/13-winsec-before.png)

One source, one destination, no processing. This one is live — a real collector,
real Windows Events arriving.

## 9. Add the blueprint

**`Add Blueprint` → "Standardize & Route Windows Events for Google SecOps".**

![Add blueprint](manual-demo-full-pipeline-blueprints-screenshots/14-winsec-add-blueprint.png)

![SecOps blueprint detail](manual-demo-full-pipeline-blueprints-screenshots/15-secops-blueprint-detail.png)

![Pick target node](manual-demo-full-pipeline-blueprints-screenshots/16-pick-target-node.png)

You choose where it attaches — that is the difference from Part 1. The blueprint
inserts as a group into a pipeline that already exists.

## 10. Draft versus live

![Draft vs live](manual-demo-full-pipeline-blueprints-screenshots/17-attached-draft-vs-live.png)

The best screen in this demo. **Rollout Pending 0/1**, with **Discard**,
**Compare** and **Start Rollout**, and a **Live / Draft** toggle above the graph.

Flip between Live and Draft to show the same pipeline before and after. Hit
**Compare** if anyone asks what exactly changed. Nothing has reached the
collector yet — this is a staged change, reviewable before it ships.

## 11. Roll it out

**Start Rollout.**

![Rollout complete](manual-demo-full-pipeline-blueprints-screenshots/18-rollout-complete.png)

![Winsec live](manual-demo-full-pipeline-blueprints-screenshots/19-winsec-live-v5.png)

## 12. Show what it added

![Standardization bundle](manual-demo-full-pipeline-blueprints-screenshots/20-standardization-bundle.png)

The **Standardization** bundle: Google SecOps Standardization, then Copy Field.
This is what stamps `chronicle_log_type` and the ingestion label.

![Routing connector](manual-demo-full-pipeline-blueprints-screenshots/21-routing-connector-ottl.png)

Then **Route by Windows Channel** — five OTTL routes:

```
sysmon      attributes["log_type"] == "windows_event.sysmon"
powershell  attributes["log_type"] == "windows_event.powershell"
dns         attributes["log_type"] == "windows_event.dns_server"
mssql       attributes["log_type"] == "windows_event.mssql"
winevtlog   true                                  <- catch-all
```

Two things worth pointing at. **SecOps ingests per log type**, so each channel
gets its own batch — the routing is functional, not decorative. And the last
route is literally `true`, catching everything the others miss. Contrast
`grrcon-gateway`, which deliberately has *no* catch-all; here the blueprint's
author chose the safer default.

Sidebar now reads **Processor Nodes 6**, up from 0.

## Afterwards

```bash
bindplane apply -f bindplane/20-source-winsec.yaml
bindplane rollout start grrcon-winsec
bindplane delete configuration <the config you created in Part 1>
```

These follow whichever profile is active — check `bindplane profile current`.

A new config can claim an unbound twin collector, so confirm five `bdot-*-unbound`
are still unbound afterwards. If you also run the Advanced Pipeline Editor demo,
add the SecOps blueprint to `grrcon-gateway` there and `grrcon-winsec` here —
not the same target twice. See `RUNNING-THESE-DEMOS.md`.
