# CLAUDE.md

## What is this?

K8s operator: scales Deployments/StatefulSets to 0 and suspends CronJobs on a schedule, restores them on wake. Phoenix LiveView UI for status and manual overrides. All state in K8s CRD conditions, no DB.

Built with **Elixir + Phoenix + Bonny**.

## Dev workflow

```bash
mix deps.get && mix assets.build   # first-time setup
mix phx.server                     # start locally
mix test                           # run tests
mix bonny.gen.manifest             # regenerate manifest.yaml after CRD changes
```

See `docs/MINIKUBE.md` for running against a local cluster.

## Architecture

### Scaling flow

1. `SleepScheduleController` receives K8s event (add/modify/reconcile)
2. Checks naptime via `SleepChecker` (timezone-aware, day-of-week filter)
3. Builds operation list from `priorityGroups` (or single batch if none defined)
4. Sends operations to `ScheduleCoordinator` (per-schedule GenServer, `:temporary`)
5. Coordinator executes groups sequentially: `scale_group` → wait/poll readiness → next group
6. `TransitionMonitor` periodic GenServer polls transitioning schedules for completion

### Priority groups

`priorityGroups` in spec defines ordered groups. Each resource has optional `priority` field linking to a group. Wake-up: groups in order. Sleep: reversed. Resources without priority → implicit default group at end. Without `priorityGroups` — all resources in one batch (backward compatible).

### Key modules

- `Drowzee.SleepChecker` — naptime? calculation, parses 12h/24h time formats
- `Drowzee.Controller.SleepScheduleController` — Bonny controller pipeline, operator events
- `Drowzee.ScheduleCoordinator` — per-schedule GenServer via DynamicSupervisor + Registry(`{ns, name}`)
- `Drowzee.K8s.SleepSchedule` — CRD helpers, `scale_up_group/2`, `scale_down_group/2`, `resources_by_priority_groups/1`
- `Drowzee.K8s.Deployment`, `.StatefulSet`, `.CronJob` — scale/suspend + annotation management
- `Drowzee.K8s.ResourceUtils` — error annotations, `check_resource_state/2`
- `Drowzee.TransitionMonitor` — polls transitioning schedules
- `DrowzeeWeb.Live.*` — LiveView UI, PubSub `sleep_schedule:updates`

### Annotations used on managed resources

- `drowzee.io/managed-by` — schedule key (`namespace/name`)
- `drowzee.io/original-replicas` — saved replica count before scale-down
- `drowzee.io/original-suspend` — saved CronJob suspend state
- `drowzee.io/scale-failed`, `drowzee.io/scale-error` — error tracking
- `drowzee.io/suspend-failed`, `drowzee.io/suspend-error` — CronJob error tracking

### CRD conditions

`Sleeping`, `Transitioning`, `ManualOverride`, `Error`, `Heartbeat`

## Testing

Tests use `K8s.Client.DynamicHTTPProvider` to mock K8s API — no real cluster needed. Discovery config in `test/support/discovery.json`. Mock registered per-process via `DynamicHTTPProvider.register(self(), fn ... end)`.

## Configuration

Env vars: `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`.
Operator config: `config/bonny.exs`. Helm values: `chart/values.yaml`.
Namespaces: `NAMESPACES` env (`__ALL__` = cluster-wide).

## Deployment

Helm chart in `./chart/`. CRD manifest in `./manifest.yaml` (Bonny-generated).
CI: GitHub Actions → `ghcr.io/chirpwireless/drowzee:VERSION` → Helm chart to gh-pages.
