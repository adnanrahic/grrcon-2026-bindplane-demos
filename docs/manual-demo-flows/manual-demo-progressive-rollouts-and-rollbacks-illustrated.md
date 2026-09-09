# Progressive Rollouts and Rollbacks — illustrated click guide

The click-by-click version of
[`manual-demo-progressive-rollouts-and-rollbacks.md`](manual-demo-progressive-rollouts-and-rollbacks.md),
with a screenshot per step. Operational context — pre-flight, recovery, cleanup —
is in [`RUNNING-THESE-DEMOS.md`](RUNNING-THESE-DEMOS.md).

The other three demos change what a pipeline *does*. This one is about shipping
that change to ten collectors without breaking anything — and undoing it.

> **Check this before you present.** The rollback half needs a *previous*
> version to go back to, and the nightly wipe resets every config to `v1`. Run
> `bindplane get configurations | grep grrcon`; if `grrcon-gateway` is at `1`,
> make a throwaway change and roll it out first so History has two rows.

---

## 1. Starting point

**Configurations → `grrcon-gateway`.**

![Before](manual-demo-progressive-rollouts-and-rollbacks-screenshots/01-gateway-before.png)

Scroll to the **Collectors** table and stay there a moment. Ten collectors, all
on the same Configuration Version, and the Labels column showing
**`env: canary`** on `bdot-01` and `bdot-02`, **`env: prod`** on the other eight.

Those labels are the whole demo. Everything that follows keys off them.

## 2. Make a change

Anything visible will do — a processor, a filter, a destination tweak.

![Make a change](manual-demo-progressive-rollouts-and-rollbacks-screenshots/02-make-a-change.png)

![Change proposal](manual-demo-progressive-rollouts-and-rollbacks-screenshots/03-change-proposal.png)

![Change applied](manual-demo-progressive-rollouts-and-rollbacks-screenshots/04-change-applied.png)

## 3. Nothing has shipped yet

![Rollout pending](manual-demo-progressive-rollouts-and-rollbacks-screenshots/05-rollout-pending.png)

**Rollout Pending 0/10**, with **Discard**, **Compare** and **Start Rollout**.
The change exists as a version; no collector has it. Use **Compare** if anyone
wants to see exactly what changed.

## 4. Rollout Options

**Click `Rollout Options`** in the Details block.

![Rollout options](manual-demo-progressive-rollouts-and-rollbacks-screenshots/06-rollout-options.png)

![Standard vs progressive](manual-demo-progressive-rollouts-and-rollbacks-screenshots/07-rollout-types-standard-vs-progressive.png)

Four things to walk through:

- **Rollout Type** — *Standard* or *Progressive*. Progressive "will deploy a new
  configuration in stages to collectors based on labels".
- **Stages** — `Canary` targeting `env: canary`, then `Prod` targeting
  `env: prod`. Stages are *label selectors*, not counts. That is the part worth
  saying twice.
- **Max Collector Errors: 0** — one collector failing to start halts the whole
  rollout. Set deliberately.
- **Rollout Rate: Adaptive** — the server sizes each phase from the collector
  count.

## 5. Start the rollout — Canary first

![Rolling out canary](manual-demo-progressive-rollouts-and-rollbacks-screenshots/08-rolling-out-canary.png)

![Collectors filtered to canary](manual-demo-progressive-rollouts-and-rollbacks-screenshots/09-collectors-filtered-canary.png)

Filter the Collectors table by `canary` to show it is exactly the two you
pointed at in step 1. No guessing which collectors moved.

## 6. It stops on its own

![Paused after canary](manual-demo-progressive-rollouts-and-rollbacks-screenshots/10-paused-after-canary.png)

The best screen in the demo:

```
Rollout to Canary Complete        2/10        [ Continue Rollout to Prod ]
```

And in the Collectors table below, the proof:

```
bdot-01   env: canary   Configuration Version 2
bdot-02   env: canary   Configuration Version 2
bdot-03   env: prod     Configuration Version 1
...
bdot-10   env: prod     Configuration Version 1
```

Two moved. Eight held. **Nobody is waiting on a human to notice** — it stopped
itself and is waiting for a decision. This is where you say that a bad config
reaches two collectors, not ten.

## 7. Continue to Prod

![Rolling out prod](manual-demo-progressive-rollouts-and-rollbacks-screenshots/11-rolling-out-prod.png)

![Rollout complete](manual-demo-progressive-rollouts-and-rollbacks-screenshots/12-rollout-complete.png)

All ten on the new version.

---

# The rollback half

## 8. Open History

**Click `History`** next to the version number.

![History](manual-demo-progressive-rollouts-and-rollbacks-screenshots/13-history-versions.png)

**Rollout History** — Version, Status, Errors, Timestamp, and a `⋮` per row.
Every rollout is recorded with its error count.

## 9. Go back to the previous version

**`⋮` on the older version → "Roll forward to this version".**

![Roll forward menu](manual-demo-progressive-rollouts-and-rollbacks-screenshots/14-roll-forward-menu.png)

![Roll forward confirm](manual-demo-progressive-rollouts-and-rollbacks-screenshots/15-roll-forward-confirm.png)

**Read the menu label out loud — it says "roll forward", on the *older*
version.** That is not a UI quirk, it is the model: versions are append-only.
Going back to v1's content creates a *new* version containing it rather than
rewinding to v1. Your history stays intact and the rollback is itself an
auditable event.

![Rollout options prompt](manual-demo-progressive-rollouts-and-rollbacks-screenshots/16-rollout-options-prompt.png)

![New version pending](manual-demo-progressive-rollouts-and-rollbacks-screenshots/17-new-version-pending.png)

You are prompted for rollout options again, and land back at **Pending** — a
staged change like any other.

## 10. The rollback stages too

![Rollback started](manual-demo-progressive-rollouts-and-rollbacks-screenshots/18-rollback-rollout-started.png)

![Rollback paused at canary](manual-demo-progressive-rollouts-and-rollbacks-screenshots/19-rollback-paused-canary.png)

![Rollback complete](manual-demo-progressive-rollouts-and-rollbacks-screenshots/20-rollback-complete.png)

**The rollback pauses at Canary exactly like the rollout did.** Worth landing
deliberately: the safety applies to the undo as well. A panicked rollback at
3am still only touches two collectors before it stops and asks.

That is the closing point of the whole demo — not "you can roll back", but "the
rollback is as controlled as the rollout".

## Afterwards

The nightly wipe resets everything to `v1` anyway, but if you are running
another demo the same day, put the config back:

```bash
bindplane apply -f bindplane/40-gateway.yaml
bindplane rollout start grrcon-gateway   # then Continue Rollout to Prod
```

Leaving it mid-rollout is fine and honest — a paused rollout is a valid state,
not a broken one. Just do not let the next presenter mistake it for an outage;
`RUNNING-THESE-DEMOS.md` covers that.
