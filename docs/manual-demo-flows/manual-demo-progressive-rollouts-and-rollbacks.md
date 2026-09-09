# Progressive Rollout and Rollback - Demo Flow

- Make changes to the `grrcon-gateway` config
- Click `Rollout Options`
- Explain Rollout Types as Standard and Progressive
- Explain Stages as defined labels - setting labels will queue the rollout
- Click `Start Rollout`
- View the `Canary` rollout - explain two collectors are labeled as `canary` - scroll down to `Collectors` component and filter by canary to show two collectors with the label
- Back in the `grrcon-gateway` config, show the rollout paused after canary rollout - click `Continue Rollout to Prod`
- After rollout completed, click `History` to show configuration versions - roll forward to a previous version - click `Start Rollout`
- Needs a previous version to exist. Cloud's nightly wipe resets to `v1`; `selfhosted/` keeps history, so run this one there
