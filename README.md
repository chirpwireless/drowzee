<div align="center">
  <img src="./priv/static/images/logo.png" alt="Droezee Logo" width="300">
</div>

# Drowzee

Drowzee is a K8s operator that scales down Deployments, StatefulSets and suspends CronJobs on a schedule — and brings them back up when it's time. Saves costs by sleeping non-prod workloads outside working hours.

Comes with a Phoenix LiveView web UI for viewing schedules, status, and manual overrides. Supports ingress redirection so users hitting a sleeping service get the Drowzee UI instead.

## SleepSchedule

A `SleepSchedule` is a custom resource that defines what to sleep and when.

### Basic example

```yaml
apiVersion: drowzee.challengr.io/v1beta1
kind: SleepSchedule
metadata:
  name: my-app
spec:
  sleepTime: "10:00pm"
  wakeTime: "09:00am"
  dayOfWeek: "mon-fri"
  timezone: "Australia/Sydney"
  deployments:
    - name: my-service
    - name: my-worker
  statefulsets:
    - name: my-database
  cronjobs:
    - name: my-backup
  ingressName: my-service
```

### Priority groups

Control the order resources wake up and sleep. Wake-up follows the defined order; sleep is reversed.

```yaml
spec:
  priorityGroups:
    - name: database
      timeoutSeconds: 120
      waitForReady: true # polls readiness before proceeding
    - name: app
      timeoutSeconds: 60
      waitForReady: true
    - name: background
      timeoutSeconds: 10
      waitForReady: false # fixed wait, no readiness check

  deployments:
    - name: my-service
      priority: app
  statefulsets:
    - name: my-database
      priority: database
  cronjobs:
    - name: my-backup
      priority: background
```

Resources without a `priority` field go into an implicit default group at the end.

### Dependencies

A schedule can depend on other schedules via `needs`. Dependencies are woken first during manual wake-up.

```yaml
spec:
  needs:
    - name: infra-schedule
      namespace: shared
```

### On-demand mode

With `onDemand: true`, the schedule auto-sleeps at `sleepTime` but does **not** auto-wake. Wake-up is manual only.

### Installation / Upgrade

```
helm repo add drowzee https://col.github.io/drowzee
helm repo update
helm upgrade --install drowzee drowzee/drowzee --namespace default -f values.yaml
```

## Configuration

Drowzee can either run in a single namespace or cluster mode.

In single namespace mode, Drowzee will only detect sleep schedules and manage resources in the same namespace as the Drowzee deployment.

In cluster mode, Drowzee will detect sleep schedules and manage resources across multiple namespaces.

### Single namespace

```yaml
mode: single_namespace

app:
  host: "drowzee.dev.example.com"

secrets:
  secretKeyBase: "MSDuI5nQY0KTF2B3gjkUQeE4jDL7hkzmBhqqhXgG1pMRk7meVP8rOXW9Y1IJ1X04"

# Optional but required in order to access the Drowzee Web UI
ingress:
  enabled: true
  annotations:
    kubernetes.io/ingress.class: "nginx"
  hosts:
    - host: drowzee.dev.example.com
      paths:
        - path: /
          pathType: ImplementationSpecific
```

### Cluster mode

```yaml
mode: cluster

app:
  host: "drowzee.nonprod.example.com"
  # Use `__ALL__` to manage all namespaces
  namespaces: "dev,qa,staging"

secrets:
  secretKeyBase: "MSDuI5nQY0KTF2B3gjkUQeE4jDL7hkzmBhqqhXgG1pMRk7meVP8rOXW9Y1IJ1X04"

# Optional but required in order to access the Drowzee Web UI
ingress:
  enabled: true
  annotations:
    kubernetes.io/ingress.class: "nginx"
  hosts:
    - host: drowzee.nonprod.example.com
      paths:
        - path: /
          pathType: ImplementationSpecific
```

### Resources

Drowzee is reasonably light weight but really depends on the number of sleep schedules and the number of resources being managed. `100m` CPU and `256Mi` memory is a safe starting point.

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

### Uninstall

```
helm uninstall drowzee
```

## Sleep Schedule Status

For a description of the conditions used to determine the sleep schedule status see [Sleep Schedule Status](SleepScheduleStatus.md).

## UI Preview

A static mockup of the web UI is available at [docs/ui-mockup.html](docs/ui-mockup.html) — open in a browser to see the schedule list and detail views.

## Acknowledgements

This project was inspired by [Snorlax](https://github.com/moonbeam-nyc/snorlax). Unfortunately I had issues while trying to run Snorlax and wanted to address some of those by creating my own operator. The main areas of improvement were:

- A simplier approach to managing ingresses
  - Drowzee uses a single annotation to redirect traffic rather than re-writing the whole ingress record.
  - The downside it that Drowzee currently only supports Nginx ingress controllers.
- More explicit wake up
  - Snorlax immediately wakes up a deployment whenever the ingress receives a request.
  - Drowzee requires the user to click the wake up button. This avoids unexpected wakeups.
- Feature rich UI
  - Drowzee provides a much more feature rich web interface to view and manage sleep schedules.

This project makes use of the [Bonny framework](https://github.com/coryodaniel/bonny) which makes the creation of K8s operators easy using Elixir. This project would not exist without it!
