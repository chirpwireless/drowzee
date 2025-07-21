defmodule Drowzee.Controller.CronJobWatcherController do
  @moduledoc """
  Watches CronJobs for drift from expected state based on their SleepSchedule.
  Only monitors CronJobs that have the 'drowzee.io/managed-by' annotation.
  """

  use Bonny.ControllerV2
  import Drowzee.Axn
  require Logger

  step(Bonny.Pluggable.SkipObservedGenerations)
  step(:handle_event)

  def handle_event(%Bonny.Axn{resource: cronjob} = axn, _opts) do
    # Only process CronJobs that are managed by Drowzee
    case get_managed_by(cronjob) do
      nil ->
        # Not managed by Drowzee, skip with success_event
        success_event(axn)

      sleep_schedule_key ->
        Logger.metadata(
          cronjob: cronjob["metadata"]["name"],
          namespace: cronjob["metadata"]["namespace"],
          managed_by: sleep_schedule_key
        )

        Logger.debug("CronJob change detected for managed resource")
        check_and_reconcile_cronjob(axn, sleep_schedule_key)
    end
  end

  defp get_managed_by(cronjob) do
    annotations = get_in(cronjob, ["metadata", "annotations"]) || %{}
    Map.get(annotations, "drowzee.io/managed-by")
  end

  defp check_and_reconcile_cronjob(axn, sleep_schedule_key) do
    cronjob = axn.resource

    # Parse the sleep schedule key (format: "namespace/name")
    case String.split(sleep_schedule_key, "/", parts: 2) do
      [schedule_namespace, schedule_name] ->
        # Get the SleepSchedule to check its current state
        case Drowzee.K8s.get_sleep_schedule(schedule_name, schedule_namespace) do
          {:ok, sleep_schedule} ->
            reconcile_based_on_schedule_state(axn, cronjob, sleep_schedule)

          {:error, reason} ->
            Logger.warning("Could not find SleepSchedule #{sleep_schedule_key}: #{inspect(reason)}")
            axn
        end

      _ ->
        Logger.warning("Invalid sleep_schedule_key format: #{sleep_schedule_key}")
        axn
    end
  end

  defp reconcile_based_on_schedule_state(axn, cronjob, sleep_schedule) do
    # Check if the schedule is disabled
    if Map.get(sleep_schedule["spec"], "enabled", true) == false do
      Logger.debug("Schedule is disabled - skipping reconciliation, allowing user control")
      axn
    else
      # Check if the schedule is currently sleeping or awake
      sleeping_condition = Drowzee.K8s.SleepSchedule.get_condition(sleep_schedule, "Sleeping")
      is_sleeping = sleeping_condition["status"] == "True"

      if is_sleeping do
        # Only reconcile during sleep time - enforce suspended state
        current_suspend = cronjob["spec"]["suspend"] || false

        if not current_suspend do
          Logger.info("CronJob should be sleeping but is not suspended - reconciling to suspended")
          reconcile_cronjob_suspend(axn, cronjob, true)
        else
          Logger.debug("CronJob is correctly sleeping")
          axn
        end
      else
        # During wake time: don't reconcile, let users have control
        Logger.debug("Schedule is awake - allowing user control, no reconciliation")
        axn
      end
    end
  end

  defp reconcile_cronjob_suspend(axn, cronjob, should_suspend) do
    action = if should_suspend, do: "Suspending", else: "Resuming"
    Logger.info("#{action} CronJob")

    # Update the cronjob suspend state
    updated_cronjob = put_in(cronjob["spec"]["suspend"], should_suspend)

    case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(updated_cronjob)) do
      {:ok, _} ->
        Logger.info("Successfully reconciled CronJob suspend state")
        axn

      {:error, reason} ->
        Logger.error("Failed to reconcile CronJob: #{inspect(reason)}")
        axn
    end
  end
end
