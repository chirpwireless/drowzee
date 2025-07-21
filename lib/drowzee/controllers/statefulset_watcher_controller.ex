defmodule Drowzee.Controller.StatefulSetWatcherController do
  @moduledoc """
  Watches StatefulSets for drift from expected state based on their SleepSchedule.
  Only monitors StatefulSets that have the 'drowzee.io/managed-by' annotation.
  """

  use Bonny.ControllerV2
  require Logger

  step(Bonny.Pluggable.SkipObservedGenerations)
  step(:handle_event)

  def handle_event(%Bonny.Axn{resource: statefulset} = axn, _opts) do
    # Only process StatefulSets that are managed by Drowzee
    case get_managed_by(statefulset) do
      nil ->
        # Not managed by Drowzee, skip
        axn

      sleep_schedule_key ->
        Logger.metadata(
          statefulset: statefulset["metadata"]["name"],
          namespace: statefulset["metadata"]["namespace"],
          managed_by: sleep_schedule_key
        )

        Logger.debug("StatefulSet change detected for managed resource")
        check_and_reconcile_statefulset(axn, sleep_schedule_key)
    end
  end

  defp get_managed_by(statefulset) do
    annotations = get_in(statefulset, ["metadata", "annotations"]) || %{}
    Map.get(annotations, "drowzee.io/managed-by")
  end

  defp check_and_reconcile_statefulset(axn, sleep_schedule_key) do
    statefulset = axn.resource

    # Parse the sleep schedule key (format: "namespace/name")
    case String.split(sleep_schedule_key, "/", parts: 2) do
      [schedule_namespace, schedule_name] ->
        # Get the SleepSchedule to check its current state
        case Drowzee.K8s.get_sleep_schedule(schedule_name, schedule_namespace) do
          {:ok, sleep_schedule} ->
            reconcile_based_on_schedule_state(axn, statefulset, sleep_schedule)

          {:error, reason} ->
            Logger.warning("Could not find SleepSchedule #{sleep_schedule_key}: #{inspect(reason)}")
            axn
        end

      _ ->
        Logger.warning("Invalid sleep_schedule_key format: #{sleep_schedule_key}")
        axn
    end
  end

  defp reconcile_based_on_schedule_state(axn, statefulset, sleep_schedule) do
    # Check if the schedule is disabled
    if Map.get(sleep_schedule["spec"], "enabled", true) == false do
      Logger.debug("Schedule is disabled - skipping reconciliation, allowing user control")
      axn
    else
      # Check if the schedule is currently sleeping or awake
      sleeping_condition = Drowzee.K8s.SleepSchedule.get_condition(sleep_schedule, "Sleeping")
      is_sleeping = sleeping_condition["status"] == "True"

      if is_sleeping do
        # Only reconcile during sleep time - enforce 0 replicas
        current_replicas = statefulset["spec"]["replicas"] || 0

        if current_replicas > 0 do
          Logger.info("StatefulSet should be sleeping but has #{current_replicas} replicas - reconciling to 0")
          reconcile_statefulset_replicas(axn, statefulset, 0)
        else
          Logger.debug("StatefulSet is correctly sleeping")
          axn
        end
      else
        # During wake time: don't reconcile, let users have control
        Logger.debug("Schedule is awake - allowing user control, no reconciliation")
        axn
      end
    end
  end

  defp reconcile_statefulset_replicas(axn, statefulset, target_replicas) do
    Logger.info("Reconciling StatefulSet to #{target_replicas} replicas")

    # Update the statefulset replicas
    updated_statefulset = put_in(statefulset["spec"]["replicas"], target_replicas)

    case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(updated_statefulset)) do
      {:ok, _} ->
        Logger.info("Successfully reconciled StatefulSet replicas")
        axn

      {:error, reason} ->
        Logger.error("Failed to reconcile StatefulSet: #{inspect(reason)}")
        axn
    end
  end
end
