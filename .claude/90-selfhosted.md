# Self-hosted Bindplane

Everything here is about `selfhosted/` — a complete Bindplane server in Docker,
so the demo runs with no internet and cannot disturb the shared cloud account.
Operator-facing steps are in [`../selfhosted/README.md`](../selfhosted/README.md);
this file is the why and the failure modes.

## The stack

Four containers, its own compose project (`bindplane-selfhosted`), separate from
the 30 collectors. Either stack can start first.

| Service | Role |
|---|---|
| `bindplane` | Server. UI, CLI and OpAMP all on port 3001 |
| `postgres` | Resource store. **The volume is the account** — configs, versions, rollout history |
| `prometheus` | Throughput numbers on the pipeline graph |
| `transform` | Live before/after in the processor panel |

Drop `transform` and Pipeline Intelligence and the blueprint demos lose their
preview pane while still looking healthy — check it first if a processor panel
is blank.

Collectors reach it at `ws://host.docker.internal:3001/v1/opamp`. **`ws://`, not
`wss://`** — nothing terminates TLS. Verified resolving from `bdot-net`; the
collector anchor also carries `extra_hosts: host-gateway` so it works on plain
Linux Docker, not just Docker Desktop.

## The secret key is the project's, and it is generated

The biggest difference from cloud, and the one that wastes the most time.

EE is multi-project. The key collectors authenticate with belongs to the
**project**, minted by `bindplane create organization`. There is no server-side
knob for it: setting `BINDPLANE_SECRET_KEY` on the container gets agents a
`401 Unauthorized` / `websocket: bad handshake`. Tested both ways.

```bash
bindplane --profile local get projects     # the SECRETKEY column
```

It is stable for the life of the postgres volume, so `down -v` mints a new one
and the root `.env` goes stale.

## A fresh server needs two things before it works

**1. An organization.** Until one exists every CLI call returns `403 Forbidden`,
with `project not in context` in the server log. Nothing else is wrong.

**2. Its type library.** A brand-new volume seeds ~105 source types and ~60
destination types asynchronously. Applying in the first seconds fails with
`unknown SourceType: apache_common`. Re-run the apply; it is not a broken
install. Only a genuinely new volume shows this, which is why a restart never
reproduces it.

## Switching the collectors: `down -v`, never `--force-recreate`

Each collector persists `manager.yaml` in its storage volume — agent id,
endpoint, secret key from first registration — and **that file outranks
`OPAMP_ENDPOINT` and `OPAMP_SECRET_KEY`**. Recreating containers changes
nothing: all 30 keep dialling the old server and sit on `401`, retrying forever,
while compose reports a clean start and the new server shows no agents.

```bash
# edit .env: comment the cloud pair, uncomment the self-hosted pair
docker compose down -v && docker compose up -d
```

Same family as the server-side label caching in `70-operations.md` — state the
collector already holds beats what you tell it.

Two consequences worth knowing:

- **Blitz loses its network.** `down` removes `bdot-net`; the generators stay
  attached to the deleted one. `docker compose -f docker-compose.blitz.yaml up
  -d --force-recreate` afterwards.
- **Binding just works.** A fresh server has no cached labels, so collectors
  bind on first registration and land on the current version already `Stable`.
  The `configuration=` toggle dance in `70-operations.md` is a cloud problem;
  `rollout start` here is usually a no-op.

## Switching the CLI

Self-hosted uses basic auth, not an API key.

```bash
bindplane profile create local
bindplane profile set local --remote-url http://localhost:3001 \
                            --username admin --password admin
bindplane profile use local      # `use default` goes back to cloud
bindplane profile current
```

**Do this, or `bindplane apply` keeps writing to cloud** — silently, reporting
success. The likeliest way self-hosted bites you mid-demo.

## What it is better at than cloud

- **No nightly wipe.** Resources live in the local postgres volume, so version
  history survives between rehearsals — which the Progressive Rollouts demo
  needs and cloud cannot give you most mornings.
- **It actually tests `bindplane/`.** A fresh account is the only place apply
  order fails; cloud always has leftovers. Standing this up is what caught four
  destinations that had never been committed at all.
- **Nothing shared to break.** Every resource is `grrcon-` prefixed and owned by
  the repo — see `30-pipelines.md`.

## Reset

```bash
docker compose -f selfhosted/docker-compose.yaml down      # keep everything
docker compose -f selfhosted/docker-compose.yaml down -v   # wipe the account
```

`down -v` drops configurations, rollout history and registered agents, and mints
a new project secret key. It is the reset between rehearsals, and the only way
back to a pre-rollout "before" state.

## Gotchas

- **The license is not committed** — this repo is public. Paste it bare into
  `selfhosted/.env`; compose does not strip quotes, so `'H4sIA...'` is read
  *with* them and the server refuses to start.
- **Server and collector versions are separate tracks.** There is no
  `bindplane-ee:1.106.0` to match `BDOT_VERSION`. `BINDPLANE_VERSION` covers all
  three observIQ images.
- **`.env.bak-*` is gitignored** but holds the cloud secret key. Do not rename it
  to something the ignore rules miss.
