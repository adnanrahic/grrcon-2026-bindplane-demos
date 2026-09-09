# Self-hosted Bindplane

The whole demo, offline. Server, postgres, prometheus and the transform agent
in one compose project, so nothing depends on conference wifi and nothing you
do here can touch the shared cloud account.

Its own stack, its own directory, its own lifecycle — the 30 demo collectors in
`../docker-compose.yaml` are separate and either can start first.

Two things it fixes beyond the network: **the nightly wipe does not apply**
(resources live in a local postgres volume, so version history survives), and
**apply order is genuinely tested** — a fresh server is the one place
`bindplane/`'s numeric prefixes have to be right. Standing this up is what
caught four destinations that had only ever existed in the cloud UI. They had no
`grrcon-` prefix, so the nightly wipe skipped them, nobody noticed they were
missing from `bindplane/`, and `apply` was quietly overwriting resources other
demos share. They are `grrcon-` prefixed and committed now.

## Start it

```bash
cp selfhosted/.env.example selfhosted/.env
# paste BINDPLANE_LICENSE -- bare, no surrounding quotes
docker compose -f selfhosted/docker-compose.yaml up -d
```

First boot pulls ~2GB and takes a minute or two. Then <http://localhost:3001>,
`admin` / `admin`.

## Create the organization

**Nothing works until you do this** — a fresh server has no project, and every
CLI call returns `403 Forbidden` with `project not in context` in the server
log. Point the CLI at the server first (self-hosted uses basic auth, not an API
key):

```bash
bindplane profile create local
bindplane profile set local --remote-url http://localhost:3001 \
                            --username admin --password admin
bindplane --profile local create organization grrcon
```

That prints the organization and a `Default Project` with a **SECRETKEY**. That
key is what the collectors authenticate with — copy it.

```bash
bindplane --profile local get projects    # read it back any time
```

## Point the collectors at it

In the repo-root `.env`, comment out the two cloud values and uncomment the
self-hosted pair, pasting the key from above:

```bash
BINDPLANE_SECRET_KEY=<SECRETKEY from the project>
OPAMP_ENDPOINT=ws://host.docker.internal:3001/v1/opamp
```

`ws://`, not `wss://` — this stack terminates no TLS. Then **drop the collector
volumes**, which is what actually moves them:

```bash
docker compose down -v && docker compose up -d
```

**`--force-recreate` is not enough, and fails silently.** Each collector
persists `manager.yaml` in its storage volume, holding the endpoint and secret
key it first registered with — and that file wins over `OPAMP_ENDPOINT` and
`OPAMP_SECRET_KEY`. Recreate the containers without dropping the volumes and
every one keeps dialling the old server: `401 Unauthorized`, `websocket: bad
handshake`, retrying forever, while compose reports a clean start. Same family
as the cached-labels problem in `.claude/70-operations.md`.

Dropping the volumes also clears the pinned agent IDs' local state, so they
re-register from scratch — which is what you want when moving servers.

**Remember to change it back afterwards** (the same `down -v` dance). A
half-reverted `.env` leaves some collectors on the wrong server, and they look
connected either way.

## Point the CLI at it

The profile already exists from the step above. Switch to it and back:

```bash
bindplane profile use local        # self-hosted
bindplane profile use default      # cloud
bindplane profile current
```

**Do this or `bindplane apply` keeps writing to the cloud** — silently, with a
success message. It is the likeliest way this bites you mid-demo.

## Seed the demo

A fresh server is empty, so this is the same rebuild the nightly wipe forces —
`bindplane/` is the source of truth either way. Run it from the repo root, with
the `local` profile selected:

```bash
bindplane --profile local apply -f bindplane/
bindplane --profile local rollout start grrcon-gateway   # resume at the Prod gate
bindplane --profile local rollout start grrcon-edge
```

Verified against an empty server: 7 configurations and 6 destinations, no
ordering errors. If the collectors are already pointed here, the `rollout start`
lines are usually no-ops — agents registering against a fresh server pick up the
current version directly and report `Stable`, so the usual "label only binds
when its value changes" trap does not apply.

Then run the normal pre-flight in
[`../docs/manual-demo-flows/RUNNING-THESE-DEMOS.md`](../docs/manual-demo-flows/RUNNING-THESE-DEMOS.md).

## Stop and reset

```bash
docker compose -f selfhosted/docker-compose.yaml down          # keeps everything
docker compose -f selfhosted/docker-compose.yaml down -v       # wipes it clean
```

`down -v` drops the postgres volume: every configuration, rollout history and
registered agent. That is the reset between rehearsals — and the only way to
get the pre-rollout "before" state back once you have rolled something out.

## Gotchas

- **The secret key is the PROJECT's, and it is generated.** There is no
  server-level knob for it — setting `BINDPLANE_SECRET_KEY` on the container
  gets agents a 401. Read the real one from `bindplane get projects`. It is
  stable for the life of the postgres volume, so `down -v` mints a new one and
  `../.env` goes stale.
- **Wait for the type library on a first boot.** A brand-new volume seeds ~105
  source types and ~60 destination types asynchronously, and applying before it
  finishes fails with `unknown SourceType: apache_common`. It takes seconds, so
  just re-run the apply — it is not a broken install.
- **The license is not committed** — this repo is public. Paste it bare; compose
  does not strip quotes, so `'H4sIA...'` is read *with* them and the server
  refuses to start.
- **Server and collector versions are separate tracks.** There is no
  `bindplane-ee:1.106.0` to match `BDOT_VERSION`. `BINDPLANE_VERSION` covers all
  three observIQ images here and moves independently.
- **Agent IDs are pinned ULIDs**, so a collector that already registered against
  the cloud keeps its ID here. Labels are still cached per server, so the
  relabel recovery in `.claude/70-operations.md` applies unchanged.
- **No transform agent, no live preview.** Pipeline Intelligence and the
  blueprint demos lose their before/after pane if that container is down. Check
  it first if a processor panel looks empty.
