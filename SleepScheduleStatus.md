# SleepSchedule CRD Conditions

The `SleepSchedule` CRD manages sleeping and waking of Kubernetes Deployments, StatefulSets, and CronJobs based on a schedule or manual triggers. State is tracked via conditions in the `status` field.

---

## Conditions Overview

| **Condition**    | **Description**                               | **Values**       | **Reason Examples**                                                |
| ---------------- | --------------------------------------------- | ---------------- | ------------------------------------------------------------------ |
| `Sleeping`       | Whether resources are asleep                  | `True` / `False` | `ScheduledSleep`, `ManualSleep`, `ScheduledWakeUp`, `ManualWakeUp` |
| `Transitioning`  | Whether a sleep/wake operation is in progress | `True` / `False` | `Sleeping`, `WakingUp`, `NoTransition`                             |
| `ManualOverride` | Whether current state was triggered manually  | `True` / `False` | `Sleep`, `WakeUp`, `NoOverride`                                    |
| `Error`          | Whether the last operation failed             | `True` / `False` | `ScaleFailed`, `IngressUpdateFailed`, `NoError`                    |
| `Heartbeat`      | Toggled periodically by TransitionMonitor     | `True` / `False` | `StayingAlive`                                                     |

---

## Condition Details

### `Sleeping`

- **True**: Deployments/StatefulSets scaled to 0, CronJobs suspended, ingress redirected to sleep page.
- **False**: Resources running at original replica counts, ingress in original state.
- **Reasons**:
  - `ScheduledSleep`: Sleep initiated by schedule.
  - `ManualSleep`: Sleep manually triggered.
  - `ScheduledWakeUp`: Wake initiated by schedule.
  - `ManualWakeUp`: Wake manually triggered.
  - `InitialValue`: Initial value for a new schedule.

### `Transitioning`

- **True**: A sleep or wake operation is in progress (possibly across multiple priority groups).
- **False**: No ongoing operations.
- **Reasons**:
  - `Sleeping`: Resources going to sleep.
  - `WakingUp`: Resources waking up.
  - `NoTransition`: No transition in progress.

### `ManualOverride`

- **True**: Current state was triggered manually via the web UI.
- **False**: State was set by the schedule.
- **Reasons**:
  - `WakeUp`: Manual wake-up requested.
  - `Sleep`: Manual sleep requested.
  - `NoOverride`: No manual intervention.

### `Error`

- **True**: The last operation failed.
- **False**: No errors in the most recent operation.
- **Reasons**:
  - `ScaleFailed`: Failed to scale Deployments/StatefulSets or suspend CronJobs.
  - `IngressSleepFailed`: Failed to update ingress to sleep page.
  - `IngressWakeUpFailed`: Failed to restore ingress.
  - `NoError`: No errors present.

### `Heartbeat`

Toggled by `TransitionMonitor` to trigger reconciliation events for schedules that are mid-transition. Not meaningful for end users.

---

## Example Status

```yaml
status:
  conditions:
    - type: Sleeping
      status: "True"
      lastTransitionTime: "2025-02-21T23:00:00Z"
      reason: ScheduledSleep
      message: "Resources have been scaled down and ingress updated."

    - type: Transitioning
      status: "False"
      lastTransitionTime: "2025-02-21T23:01:00Z"
      reason: NoTransition

    - type: ManualOverride
      status: "False"
      lastTransitionTime: "2025-02-21T23:02:00Z"
      reason: NoManualOverride

    - type: Error
      status: "False"
      lastTransitionTime: "2025-02-21T23:01:00Z"
      reason: NoError

    - type: Heartbeat
      status: "True"
      lastTransitionTime: "2025-02-21T23:05:00Z"
      reason: StayingAlive
```

---

## Condition Lifecycle

### Sleep Flow (Scheduled)

1. Set `Transitioning=True` with `reason=Sleeping`.
2. For each priority group (in reverse order, or all at once if no groups defined):
   - Scale down Deployments/StatefulSets to 0, suspend CronJobs.
   - Wait (fixed timeout or poll readiness) before next group.
3. Update ingress to redirect to Drowzee.
4. Set `Sleeping=True`, `Transitioning=False` with `reason=ScheduledSleep`.

### Wake Flow (Manual)

1. User triggers wake via web UI.
2. Set `ManualOverride=True` and `Transitioning=True` with `reason=ManualWakeUp`.
3. If the schedule has `needs`, wake dependencies first.
4. For each priority group (in defined order):
   - Scale up Deployments/StatefulSets to original replicas, resume CronJobs.
   - Wait (fixed timeout or poll readiness) before next group.
5. Restore ingress to original state.
6. Set `Sleeping=False`, `Transitioning=False` with `reason=ManualWakeUp`.
7. `ManualOverride` is automatically cleared at the next scheduled event (sleep or wake).

### Wake Flow (Scheduled)

Same as manual but without `ManualOverride`. Does not trigger if `onDemand: true`.

### Error Handling

- On error during sleep or wake:
  - Set `Error=True` with appropriate `reason` and `message`.
  - `Transitioning=False` indicates the operation stopped.
  - Per-resource errors are also recorded as annotations on the affected resources.

---

## Notes

- `lastTransitionTime` reflects when the condition last changed.
- `ManualOverride=True` persists until the next scheduled state change.
- `Error=True` resets to `False` after a successful subsequent operation.
- With `onDemand: true`, the schedule auto-sleeps but does not auto-wake.
