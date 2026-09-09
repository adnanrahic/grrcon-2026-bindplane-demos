# Pipeline Intelligence — illustrated click guide

The click-by-click version of
[`manual-demo-pipeline-intelligence.md`](manual-demo-pipeline-intelligence.md),
with a screenshot per step. Operational context — pre-flight, recovery, cleanup —
is in [`RUNNING-THESE-DEMOS.md`](RUNNING-THESE-DEMOS.md).

This is the counterweight to the Blueprints demo. `appjson` is the one stream no
native source and no blueprint covers, so every processor here is built by hand —
either from a **Recommendation** chip or by describing the goal in words.

**The screen to understand first:** the processor panel has a log pane on each
side. Left is *"Showing N recent logs"* — raw, before. Right is *"Showing N logs
after processing"* — the same records through your chain, updating as you add to
it. Every step below is really "watch the right pane change".

---

## 1. Open the config

**Configurations → `grrcon-appjson`.**

![Config](manual-demo-pipeline-intelligence-screenshots/01-appjson-config.png)

![Pipeline](manual-demo-pipeline-intelligence-screenshots/02-appjson-pipeline.png)

One TCP source, one destination, no processing.

## 2. Show the raw logs

**Click the source's processor node.**

![Raw JSON](manual-demo-pipeline-intelligence-screenshots/03-raw-json-logs.png)

Three things to point at, because all three get fixed later:

- The body is **one JSON string**, not fields.
- Every row's severity badge reads **`default`** — nothing parsed `level`.
- Every timestamp reads **`1:00:00 AM GMT+1`**. That is not midnight; that is
  **1970-01-01T00:00:00Z** in local time. The classic unset-timestamp tell.

Say the obvious thing: this is what most application logs look like arriving
anywhere. There is no source type for "our app".

## 3. Parse JSON

Take the **Parse JSON** recommendation, or type the goal in the box. Either way
you land on the same processor form.

![Parse JSON recommendation](manual-demo-pipeline-intelligence-screenshots/04-parse-json-recommendation.png)

The form arrives pre-filled — Source Field Type **Body**, Target Field Type
**Body**, empty Source Field meaning "the whole body". **Accept**.

![Parse JSON applied](manual-demo-pipeline-intelligence-screenshots/05-parse-json-applied.png)

**Pause here.** The right pane now shows named fields — and the timestamps are
*still* `1:00:00 AM`, the severities *still* `default`. Parsing the JSON did not
fix either.

That is the point of the whole demo: **"parsed" is not "usable"**, and it is what
earns the next two processors. Do not rush past it.

## 4. Parse Timestamp

![Parse timestamp recommendation](manual-demo-pipeline-intelligence-screenshots/06-parse-timestamp-recommendation.png)

![Parse timestamp applied](manual-demo-pipeline-intelligence-screenshots/07-parse-timestamp-applied.png)

RFC3339, reading the body's own `timestamp` field. The right pane's times become
real. 1970 is gone.

Worth noting: the JSON *always contained* the correct timestamp. Nothing had
promoted it to the record.

## 5. Parse Severity

![Parse severity recommendation](manual-demo-pipeline-intelligence-screenshots/08-parse-severity-recommendation.png)

![Parse severity applied](manual-demo-pipeline-intelligence-screenshots/09-parse-severity-applied.png)

`default` badges become real `info` / `error` severities. Only now can anything
downstream filter, alert or route on severity.

Contrast with CEF from the native-sources demo: it got timestamp *and* severity
free, on ingest, because its source type knew the format. Three processors here
to reach the same place.

## 6. Delete the parsed-out fields

![Delete parsed fields recommendation](manual-demo-pipeline-intelligence-screenshots/10-delete-parsed-fields-recommendation.png)

![Delete parsed fields applied](manual-demo-pipeline-intelligence-screenshots/11-delete-parsed-fields-applied.png)

The timestamp and level now exist as record metadata, so the copies in the body
are dead weight paid for on every event. First volume win.

## 7. Filter debug logs

![Filter debug recommendation](manual-demo-pipeline-intelligence-screenshots/12-filter-debug-recommendation.png)

![Filter debug applied](manual-demo-pipeline-intelligence-screenshots/13-filter-debug-applied.png)

**Only possible because of step 5.** Before severity was parsed, every record
looked identical to a filter. This is the sequencing worth making explicit — the
reduction depends on the parsing.

## 8. Ask for a filter in words

Type the goal instead of picking a processor — for example, keep only one
service.

![Natural language filter](manual-demo-pipeline-intelligence-screenshots/14-filter-by-condition-natural-language.png)

Note **"Thought for 15s"** under the input, then a **Filter by Condition**
processor appears in the chain, configured. This is the part people came to see;
give it a beat.

The numbers at the bottom are the headline:

```
left   Showing 100 recent logs
right  Showing 3 logs after processing
```

**100 → 3**, with parsed bodies and real `info` / `error` badges on the right.
Whatever the exact ratio on the day, read both counts aloud — that is the ingest
cost argument in one screen.

## 9. Show the finished chain

![Final chain](manual-demo-pipeline-intelligence-screenshots/15-final-processor-chain.png)

```
1  Parse JSON
2  Parse Timestamp        RFC3339, body 'timestamp'
3  Parse Severity Fields
4  Delete Fields          the now-duplicate parsed fields
5  Filter by Severity     drop debug
6  Filter by Condition    the one you asked for in words
```

Six processors, none hand-written, built in the order the data forced. Point at
**Convert to Bundle** — that is how this becomes reusable, and it is the same
mechanism the shipped blueprints use. Good bridge into that demo.

## Where this sits in the set

Run this **before** Full Pipeline Blueprints. The audience should feel the manual
work first; the blueprint demo then lands as "somebody already did this for
Apache and Palo Alto" rather than as a feature tour.

Honest framing to close on: nothing here was hard, but it was **six decisions**,
in an order the data dictated, on a format nothing ships support for. That is the
real cost blueprints remove — and why the streams that *have* one are the lucky
ones.

## Afterwards

`grrcon-appjson` is deliberately unparsed so the next run starts from raw. Reset:

```bash
bindplane apply -f bindplane/20-source-appjson.yaml
bindplane rollout start grrcon-appjson
```

If you saved the chain as a bundle, delete it too, or the next run starts halfway
done. See `RUNNING-THESE-DEMOS.md`.
