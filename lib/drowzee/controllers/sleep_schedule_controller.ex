defmodule Drowzee.Controller.SleepScheduleController do
  @moduledoc """
  Drowzee: SleepScheduleController controller.
  """

  use Bonny.ControllerV2
  import Drowzee.Axn
  require Logger
  alias Drowzee.K8s.{SleepSchedule, Ingress, Deployment, StatefulSet, CronJob}

  step(Bonny.Pluggable.SkipObservedGenerations)
  step(:handle_event)

  def handle_event(%Bonny.Axn{resource: %{"spec" => spec}} = axn, _opts) do
    Logger.metadata(
      schedule: axn.resource["metadata"]["name"],
      namespace: axn.resource["metadata"]["namespace"]
    )

    if Map.get(spec, "enabled", true) == false do
      Logger.info("Schedule is disabled. Skipping...")
      axn
    else
      handle_event_enabled(axn)
    end
  end

  def handle_event_enabled(%Bonny.Axn{action: action} = axn)
      when action in [:add, :modify, :reconcile] do
    Logger.metadata(
      schedule: axn.resource["metadata"]["name"],
      namespace: axn.resource["metadata"]["namespace"]
    )

    axn
    |> add_default_conditions()
    |> set_naptime_assigns()
    |> update_state()
    # TODO: Only publish an event when something changes
    |> publish_event()
    |> success_event()
  end

  # delete the resource
  def handle_event_enabled(%Bonny.Axn{action: :delete} = axn, _opts) do
    Logger.warning("Delete Action - Not yet implemented!")
    # TODO:
    # - Make sure applications are awake
    axn
  end

  defp publish_event(axn) do
    Task.start(fn ->
      Process.sleep(500)

      Phoenix.PubSub.broadcast(
        Drowzee.PubSub,
        "sleep_schedule:updates",
        {:sleep_schedule_updated}
      )
    end)

    axn
  end

  defp add_default_conditions(axn) do
    axn
    |> set_default_condition("Sleeping", false, "InitialValue", "New wake schedule")
    |> set_default_condition("Transitioning", false, "NoTransition", "No transition in progress")
    |> set_default_condition(
      "ManualOverride",
      false,
      "NoManualOverride",
      "No manual override present"
    )
    |> set_default_condition("Error", false, "NoError", "No error present")
    |> set_default_condition(
      "Heartbeat",
      false,
      "StayingAlive",
      "Triggers events from transition monitor"
    )
  end

  defp set_naptime_assigns(%Bonny.Axn{resource: resource} = axn) do
    sleep_time = resource["spec"]["sleepTime"]
    wake_time = resource["spec"]["wakeTime"]
    timezone = resource["spec"]["timezone"]
    day_of_week = resource["spec"]["dayOfWeek"] || "*"

    # Log if wake_time is not defined (resources will remain down indefinitely)
    if is_nil(wake_time) or wake_time == "" do
      Logger.info(
        "Wake time is not defined. Resources will remain scaled down/suspended indefinitely."
      )
    end

    # Log day of week configuration if not default
    if day_of_week != "*" do
      Logger.info("Schedule is active only on days matching: #{day_of_week}")
    end

    # For schedules with nil wake time, check if they're already sleeping
    # If they are, keep them asleep regardless of sleep time changes
    {manual_override_exists, manual_override_type} =
      case get_condition(axn, "ManualOverride") do
        {:ok, condition} ->
          if condition["status"] == "True" do
            override_type =
              case condition["reason"] do
                "WakeUp" -> "wake_up_override"
                "Sleep" -> "sleep_override"
                _ -> nil
              end

            {true, override_type}
          else
            {false, nil}
          end

        _ ->
          {false, nil}
      end

    already_sleeping =
      case get_condition(axn, "Sleeping") do
        {:ok, condition} -> condition["status"] == "True"
        _ -> false
      end

    # If schedule has no wake time, is already sleeping, and has no manual override,
    # keep it asleep regardless of sleep time changes
    force_naptime =
      (is_nil(wake_time) or wake_time == "") and
        already_sleeping and
        not manual_override_exists

    # Pass the manual override to the SleepChecker
    case Drowzee.SleepChecker.naptime?(
           sleep_time,
           wake_time,
           timezone,
           day_of_week,
           manual_override_type
         ) do
      # We've removed the :inactive_day return value from the sleep checker
      # Now it always returns true/false for naptime
      {:ok, naptime} ->
        # Force naptime to true if conditions are met
        final_naptime = naptime or force_naptime
        %{axn | assigns: Map.put(axn.assigns, :naptime, final_naptime)}

      {:error, reason} ->
        Logger.error("Error checking naptime: #{reason}")

        set_condition(
          axn,
          "Error",
          true,
          "InvalidSleepSchedule",
          "Invalid sleep schedule: #{reason}"
        )
    end
  end

  defp update_state(%Bonny.Axn{} = axn) do
    with {:ok, sleeping} <- get_condition(axn, "Sleeping"),
         {:ok, transitioning} <- get_condition(axn, "Transitioning"),
         {:ok, manual_override} <- get_condition(axn, "ManualOverride") do
      naptime = if axn.assigns[:naptime], do: :naptime, else: :not_naptime
      sleeping_value = if sleeping["status"] == "True", do: :sleeping, else: :awake

      transitioning_value =
        if transitioning["status"] == "True", do: :transition, else: :no_transition

      manual_override_value =
        case {manual_override["status"], manual_override["reason"]} do
          {"True", "WakeUp"} -> :wake_up_override
          {"True", "Sleep"} -> :sleep_override
          {_, _} -> :no_override
        end

      Logger.debug(
        inspect({sleeping_value, transitioning_value, manual_override_value, naptime},
          label: "Updating state with:"
        )
      )

      case {sleeping_value, transitioning_value, manual_override_value, naptime} do
        # Trigger action from manual override
        {:awake, :no_transition, :sleep_override, _} ->
          initiate_sleep(axn)

        {:sleeping, :no_transition, :wake_up_override, _} ->
          initiate_wake_up(axn)

        # Auto-remove manual override when schedule state matches override state
        {:sleeping, :no_transition, :sleep_override, :naptime} ->
          Logger.info("Auto-removing sleep override as schedule is now naturally in sleep state")
          remove_manual_override(axn)

        {:awake, :no_transition, :wake_up_override, :not_naptime} ->
          Logger.info("Auto-removing wake-up override as schedule is now naturally in wake state")
          remove_manual_override(axn)

        # Preserve manual overrides when schedule state differs from override state
        {:awake, :no_transition, :wake_up_override, :naptime} ->
          Logger.info("Sleep time reached but respecting manual wake-up override")
          axn

        # When a schedule is sleeping with a sleep override and it's not naptime,
        # we respect the manual override and do nothing
        {:sleeping, :no_transition, :sleep_override, :not_naptime} ->
          Logger.debug("Wake time reached but respecting manual sleep override")
          axn

        # Trigger scheduled actions
        {:awake, :no_transition, :no_override, :naptime} ->
          initiate_sleep(axn)

        {:sleeping, :no_transition, :no_override, :not_naptime} ->
          initiate_wake_up(axn)

        # Await transitions (could be moved to background process)
        {:awake, :transition, _, _} ->
          check_sleep_transition(axn, manual_override: manual_override_value != :no_override)

        {:sleeping, :transition, _, _} ->
          check_wake_up_transition(axn, manual_override: manual_override_value != :no_override)

        {_, _, _, _} ->
          Logger.debug("No action required for current state.")
          axn
      end
    else
      # Conditions should be present except for the first event
      {:error, _error} -> axn
    end
  end

  defp initiate_sleep(axn) do
    Logger.info("Initiating sleep")

    axn
    |> update_hosts()
    |> set_condition("Transitioning", true, "Sleeping", "Going to sleep")
    |> scale_down_applications()
    |> start_transition_monitor()
  end

  defp initiate_wake_up(axn) do
    Logger.info("Initiating wake up")

    axn
    |> set_condition("Transitioning", true, "WakingUp", "Waking up")
    |> scale_up_applications()
    |> start_transition_monitor()
  end

  defp start_transition_monitor(axn) do
    Drowzee.TransitionMonitor.start_transition_monitor(
      axn.resource["metadata"]["name"],
      axn.resource["metadata"]["namespace"]
    )

    axn
  end

  # Coordination mechanism for scaling operations with prioritization
  # Uses an Agent to coordinate scaling operations across multiple schedules

  # Start the coordinator when the application starts - this is now handled by CoordinatorSupervisor
  def start_coordinator do
    # This is kept for backwards compatibility but is now a no-op
    # The actual coordinator is started by the CoordinatorSupervisor
    :ok
  end

  # Add a scaling operation to the queue with priority
  defp queue_scaling_operation(operation, resource, priority) do
    Logger.info(
      "Queueing operation #{operation} for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]} with priority #{priority}"
    )

    # Use GenServer.cast instead of Agent.update
    GenServer.cast(
      __MODULE__.Coordinator,
      {:add_operation, operation, resource, priority}
    )
  end

  # Prioritized scaling down: StatefulSets (1) -> Deployments (2) -> CronJobs (3)
  defp scale_down_applications(axn) do
    # Queue operations with priority (lower number = higher priority)
    queue_scaling_operation(:scale_down_statefulsets, axn.resource, 1)
    queue_scaling_operation(:scale_down_deployments, axn.resource, 2)
    queue_scaling_operation(:suspend_cronjobs, axn.resource, 3)
    axn
  end

  # Prioritized scaling up: StatefulSets (1) -> Deployments (2) -> CronJobs (3)
  defp scale_up_applications(axn) do
    # Queue operations with priority (lower number = higher priority)
    queue_scaling_operation(:scale_up_statefulsets, axn.resource, 1)
    queue_scaling_operation(:scale_up_deployments, axn.resource, 2)
    queue_scaling_operation(:resume_cronjobs, axn.resource, 3)
    axn
  end

  defp update_hosts(axn) do
    case SleepSchedule.get_ingress(axn.resource) do
      {:ok, ingress} ->
        update_status(axn, fn status ->
          Map.put(status, "hosts", Ingress.get_hosts(ingress))
        end)

      {:error, :ingress_name_not_set} ->
        update_status(axn, fn status ->
          Map.put(status, "hosts", [])
        end)

      {:error, error} ->
        Logger.error("Failed to get ingress: #{inspect(error)}")
        axn
    end
  end

  defp check_sleep_transition(axn, opts) do
    Logger.info("Checking sleep transition...")

    case check_application_status(axn, &application_status_asleep?/3) do
      {:ok, true} ->
        Logger.debug("All applications are asleep")

        axn
        |> put_ingress_to_sleep()
        |> complete_sleep_transition(opts)

      {:ok, false} ->
        Logger.debug("Applications have not yet scaled down...")
        scale_down_applications(axn)

      {:error, [error | _]} ->
        Logger.error("Failed to check application status: #{inspect(error)}")
        set_condition(axn, "Error", true, "ApplicationNotFound", error.message)

      {:error, error} ->
        Logger.error("Failed to check application status: #{inspect(error)}")
        axn
    end
  end

  defp check_wake_up_transition(axn, opts) do
    Logger.info("Checking wake up transition...")

    case check_application_status(axn, &application_status_ready?/3) do
      {:ok, true} ->
        Logger.debug("All applications are ready")

        axn
        |> wake_up_ingress()
        |> complete_wake_up_transition(opts)

      {:ok, false} ->
        Logger.debug("Applications are not ready...")
        scale_up_applications(axn)

      {:error, [error | _]} ->
        Logger.error("Failed to check application status: #{inspect(error)}")
        set_condition(axn, "Error", true, "ApplicationNotFound", error.message)

      {:error, error} ->
        Logger.error("Failed to check applications status: #{inspect(error)}")
        axn
    end
  end

  defp application_status_ready?(metadata, spec, status) do
    name = Map.get(metadata, "name")
    namespace = Map.get(metadata, "namespace")

    original_replicas = Map.get(metadata["annotations"] || %{}, "drowzee.io/original-replicas")
    spec_replicas = Map.get(spec, "replicas")
    suspended = Map.get(status, "suspended", true)

    Logger.debug(
      "Ready check for #{namespace}/#{name} - spec_replicas: #{spec_replicas}, original_replicas: #{original_replicas}, suspended: #{suspended}"
    )

    cond do
      # For newly added apps without original_replicas annotation
      is_nil(original_replicas) and not is_nil(spec_replicas) ->
        # Consider them always ready
        true

      # For apps with original_replicas annotation during scale up
      not is_nil(original_replicas) and not is_nil(spec_replicas) ->
        # Check if spec.replicas matches original_replicas
        try do
          spec_replicas == String.to_integer(original_replicas)
        rescue
          _ ->
            Logger.error("Failed to convert original_replicas to integer: #{original_replicas}")
            false
        end

      # For CronJobs: considered ready if not suspended
      true ->
        suspended == false
    end
  end

  defp application_status_asleep?(metadata, spec, status) do
    name = Map.get(metadata, "name")
    namespace = Map.get(metadata, "namespace")

    spec_replicas = Map.get(spec, "replicas")
    suspended = Map.get(status, "suspended", nil)

    Logger.debug(
      "Asleep check for #{namespace}/#{name} - spec_replicas: #{spec_replicas}, suspended: #{suspended}"
    )

    cond do
      not is_nil(suspended) ->
        suspended == true

      true ->
        spec_replicas == 0
    end
  end

  defp check_application_status(axn, check_fn) do
    with {:ok, deployments} <- SleepSchedule.get_deployments(axn.resource),
         {:ok, statefulsets} <- SleepSchedule.get_statefulsets(axn.resource),
         {:ok, cronjobs} <- SleepSchedule.get_cronjobs(axn.resource) do
      deployments_result =
        Enum.all?(deployments, fn deployment ->
          Logger.debug(
            "Deployment #{Deployment.name(deployment)} replicas: #{Deployment.replicas(deployment)}, readyReplicas: #{Deployment.ready_replicas(deployment)}"
          )

          check_fn.(
            deployment["metadata"],
            deployment["spec"],
            deployment["status"]
          )
        end)

      statefulsets_result =
        Enum.all?(statefulsets, fn statefulset ->
          Logger.debug(
            "StatefulSet #{StatefulSet.name(statefulset)} replicas: #{StatefulSet.replicas(statefulset)}, readyReplicas: #{StatefulSet.ready_replicas(statefulset)}"
          )

          check_fn.(
            statefulset["metadata"],
            statefulset["spec"],
            statefulset["status"]
          )
        end)

      cronjobs_result =
        Enum.all?(cronjobs, fn cronjob ->
          suspended = CronJob.suspend(cronjob)

          Logger.debug("CronJob #{CronJob.name(cronjob)} suspended: #{suspended}")

          # check_fn determines if suspended is the expected state (true for sleep, false for wake)
          check_fn.(
            cronjob["metadata"],
            cronjob["spec"],
            %{"suspended" => suspended}
          )
        end)

      # Determine which resources we need to check based on what's present
      has_deployments = Enum.any?(deployments)
      has_statefulsets = Enum.any?(statefulsets)
      has_cronjobs = Enum.any?(cronjobs)

      case {has_deployments, has_statefulsets, has_cronjobs} do
        {false, false, false} -> {:ok, true}
        {true, false, false} -> {:ok, deployments_result}
        {false, true, false} -> {:ok, statefulsets_result}
        {false, false, true} -> {:ok, cronjobs_result}
        {true, true, false} -> {:ok, deployments_result && statefulsets_result}
        {true, false, true} -> {:ok, deployments_result && cronjobs_result}
        {false, true, true} -> {:ok, statefulsets_result && cronjobs_result}
        {true, true, true} -> {:ok, deployments_result && statefulsets_result && cronjobs_result}
      end
    else
      {:error, error} -> {:error, error}
    end
  end

  defp complete_sleep_transition(axn, opts) do
    Logger.info("Sleep transition complete")
    manual_override = Keyword.get(opts, :manual_override, false)
    wake_time = axn.resource["spec"]["wakeTime"]
    permanent_sleep = is_nil(wake_time) or wake_time == ""

    sleep_reason =
      cond do
        manual_override -> "ManualSleep"
        permanent_sleep -> "PermanentSleep"
        true -> "ScheduledSleep"
      end

    sleep_message =
      if permanent_sleep do
        "Deployments, StatefulSets, and CronJobs have been scaled down/suspended indefinitely and ingress redirected."
      else
        "Deployments, StatefulSets, and CronJobs have been scaled down/suspended and ingress redirected."
      end

    axn
    |> set_condition("Transitioning", false, "NoTransition", "No transition in progress")
    |> set_condition("Sleeping", true, sleep_reason, sleep_message)
    |> set_condition("Error", false, "None", "No error")
  end

  defp complete_wake_up_transition(axn, opts) do
    Logger.info("Wake up transition complete")
    manual_override = Keyword.get(opts, :manual_override, false)
    wake_reason = if manual_override, do: "ManualWakeUp", else: "ScheduledWakeUp"

    axn
    |> set_condition("Transitioning", false, "NoTransition", "No transition in progress")
    |> set_condition(
      "Sleeping",
      false,
      wake_reason,
      "Deployments and StatefulSets have been scaled up, CronJobs have been resumed, and ingress restored."
    )
    |> set_condition("Error", false, "None", "No error")
  end

  defp put_ingress_to_sleep(axn) do
    case SleepSchedule.put_ingress_to_sleep(axn.resource) do
      {:ok, _} ->
        Logger.info("Updated ingress to redirect to Drowzee",
          name: SleepSchedule.ingress_name(axn.resource)
        )

        # register_event(axn, nil, :Normal, "SleepIngress", "Ingress has been redirected to Drowzee")
        axn

      {:error, :ingress_name_not_set} ->
        Logger.info("No ingressName has been provided so there is nothing to redirect")
        axn

      {:error, error} ->
        Logger.error("Failed to redirect ingress to Drowzee: #{inspect(error)}",
          name: SleepSchedule.ingress_name(axn.resource)
        )

        axn
    end
  end

  defp wake_up_ingress(axn) do
    case SleepSchedule.wake_up_ingress(axn.resource) do
      {:ok, _} ->
        Logger.info("Removed Drowzee redirect from ingress",
          name: SleepSchedule.ingress_name(axn.resource)
        )

        # register_event(axn, nil, :Normal, "WakeUpIngress", "Ingress has been restored")
        axn

      {:error, :ingress_name_not_set} ->
        Logger.info("No ingressName has been provided so there is nothing to restore")
        axn

      {:error, error} ->
        Logger.error("Failed to remove Drowzee redirect from ingress: #{inspect(error)}",
          name: SleepSchedule.ingress_name(axn.resource)
        )

        axn
    end
  end

  # Helper function to remove manual override
  defp remove_manual_override(%Bonny.Axn{} = axn) do
    sleep_schedule = axn.resource

    # Call the K8s module to remove the override
    case Drowzee.K8s.remove_override(sleep_schedule) do
      {:ok, _updated} ->
        # Return the original axn to continue processing
        # The override removal will trigger a new event
        axn

      {:error, error} ->
        Logger.error("Failed to remove manual override", error: inspect(error))
        axn
    end
  end
end
