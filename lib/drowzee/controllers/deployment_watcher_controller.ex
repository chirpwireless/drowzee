defmodule Drowzee.Controller.DeploymentWatcherController do
  @moduledoc """
  Watches Deployments for drift from expected state based on their SleepSchedule.
  Only monitors Deployments that have the 'drowzee.io/managed-by' annotation.
  """

  use Bonny.ControllerV2
  import Drowzee.Axn
  require Logger

  step(Bonny.Pluggable.SkipObservedGenerations)
  step(:handle_event)

  def handle_event(%Bonny.Axn{resource: deployment} = axn, _opts) do
    # Only process Deployments that are managed by Drowzee
    case get_managed_by(deployment) do
      nil ->
        # Not managed by Drowzee, skip with success_event
        success_event(axn)

      sleep_schedule_key ->
        Logger.metadata(
          deployment: deployment["metadata"]["name"],
          namespace: deployment["metadata"]["namespace"],
          managed_by: sleep_schedule_key
        )

        Logger.debug("Deployment change detected for managed resource")
        check_and_reconcile_deployment(axn, sleep_schedule_key)
    end
  end

  defp get_managed_by(deployment) do
    annotations = get_in(deployment, ["metadata", "annotations"]) || %{}
    Map.get(annotations, "drowzee.io/managed-by")
  end

  defp check_and_reconcile_deployment(axn, sleep_schedule_key) do
    deployment = axn.resource

    # Parse the sleep schedule key (format: "namespace/name")
    case String.split(sleep_schedule_key, "/", parts: 2) do
      [schedule_namespace, schedule_name] ->
        # Get the SleepSchedule to check its current state
        case Drowzee.K8s.get_sleep_schedule(schedule_name, schedule_namespace) do
          {:ok, sleep_schedule} ->
            reconcile_based_on_schedule_state(axn, deployment, sleep_schedule)

          {:error, reason} ->
            Logger.warning("Could not find SleepSchedule #{sleep_schedule_key}: #{inspect(reason)}")
            axn
        end

      _ ->
        Logger.warning("Invalid sleep_schedule_key format: #{sleep_schedule_key}")
        axn
    end
  end

  defp reconcile_based_on_schedule_state(axn, deployment, sleep_schedule) do
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
        current_replicas = deployment["spec"]["replicas"] || 0

        if current_replicas > 0 do
          Logger.info("Deployment should be sleeping but has #{current_replicas} replicas - reconciling to 0")
          reconcile_deployment_replicas(axn, deployment, 0)
        else
          Logger.debug("Deployment is correctly sleeping")
          axn
        end
      else
        # During wake time: don't reconcile, let users have control
        Logger.debug("Schedule is awake - allowing user control, no reconciliation")
        axn
      end
    end
  end

  defp reconcile_deployment_replicas(axn, deployment, target_replicas) do
    Logger.info("Reconciling Deployment to #{target_replicas} replicas")

    # Update the deployment replicas
    updated_deployment = put_in(deployment["spec"]["replicas"], target_replicas)

    case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(updated_deployment)) do
      {:ok, _} ->
        Logger.info("Successfully reconciled Deployment replicas")
        axn

      {:error, reason} ->
        Logger.error("Failed to reconcile Deployment: #{inspect(reason)}")
        axn
    end
  end
end
