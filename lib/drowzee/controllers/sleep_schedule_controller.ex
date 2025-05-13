defmodule Drowzee.Controller.SleepScheduleController do
  @moduledoc """
  Drowzee: SleepScheduleController controller.
  """

  use Bonny.ControllerV2
  import Drowzee.Axn
  require Logger
  alias Drowzee.K8s.{SleepSchedule, Ingress, Deployment, StatefulSet, CronJob}

  step Bonny.Pluggable.SkipObservedGenerations
  step :handle_event

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
    |> publish_event() # TODO: Only publish an event when something changes
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
      Phoenix.PubSub.broadcast(Drowzee.PubSub, "sleep_schedule:updates", {:sleep_schedule_updated})
    end)
    axn
  end

  defp add_default_conditions(axn) do
    axn
    |> set_default_condition("Sleeping", false, "InitialValue", "New wake schedule")
    |> set_default_condition("Transitioning", false, "NoTransition", "No transition in progress")
    |> set_default_condition("ManualOverride", false, "NoManualOverride", "No manual override present")
    |> set_default_condition("Error", false, "NoError", "No error present")
    |> set_default_condition("Heartbeat", false, "StayingAlive", "Triggers events from transition monitor")
  end

  defp set_naptime_assigns(%Bonny.Axn{resource: resource} = axn) do
    sleep_time = resource["spec"]["sleepTime"]
    wake_time = resource["spec"]["wakeTime"]
    timezone = resource["spec"]["timezone"]
    day_of_week = resource["spec"]["dayOfWeek"] || "*"

    # Log if wake_time is not defined (resources will remain down indefinitely)
    if is_nil(wake_time) or wake_time == "" do
      Logger.info("Wake time is not defined. Resources will remain scaled down/suspended indefinitely.")
    end

    # Log day of week configuration if not default
    if day_of_week != "*" do
      Logger.info("Schedule is active only on days matching: #{day_of_week}")
    end
    
    # For schedules with nil wake time, check if they're already sleeping
    # If they are, keep them asleep regardless of sleep time changes
    manual_override_exists = case get_condition(axn, "ManualOverride") do
      {:ok, condition} -> condition["status"] == "True"
      _ -> false
    end
    
    already_sleeping = case get_condition(axn, "Sleeping") do
      {:ok, condition} -> condition["status"] == "True"
      _ -> false
    end
    
    # If schedule has no wake time, is already sleeping, and has no manual override,
    # keep it asleep regardless of sleep time changes
    force_naptime = (is_nil(wake_time) or wake_time == "") and 
                    already_sleeping and 
                    not manual_override_exists
    
    case Drowzee.SleepChecker.naptime?(sleep_time, wake_time, timezone, day_of_week) do
      # We've removed the :inactive_day return value from the sleep checker
      # Now it always returns true/false for naptime
      {:ok, naptime} ->
        # Force naptime to true if conditions are met
        final_naptime = naptime or force_naptime
        %{axn | assigns: Map.put(axn.assigns, :naptime, final_naptime)}
      {:error, reason} ->
        Logger.error("Error checking naptime: #{reason}")
        set_condition(axn, "Error", true, "InvalidSleepSchedule", "Invalid sleep schedule: #{reason}")
    end
  end

  defp update_state(%Bonny.Axn{} = axn) do
    with {:ok, sleeping} <- get_condition(axn, "Sleeping"),
         {:ok, transitioning} <- get_condition(axn, "Transitioning"),
         {:ok, manual_override} <- get_condition(axn, "ManualOverride") do

      naptime = if axn.assigns[:naptime], do: :naptime, else: :not_naptime
      sleeping_value = if sleeping["status"] == "True", do: :sleeping, else: :awake
      transitioning_value = if transitioning["status"] == "True", do: :transition, else: :no_transition
      manual_override_value = case {manual_override["status"], manual_override["reason"]} do
        {"True", "WakeUp"} -> :wake_up_override
        {"True", "Sleep"} -> :sleep_override
        {_, _} -> :no_override
      end

      Logger.debug(inspect({sleeping_value, transitioning_value, manual_override_value, naptime}, label: "Updating state with:"))
      case {sleeping_value, transitioning_value, manual_override_value, naptime} do
        # Trigger action from manual override
        {:awake, :no_transition, :sleep_override, _} -> initiate_sleep(axn)
        {:sleeping, :no_transition, :wake_up_override, _} -> initiate_wake_up(axn)
        # Preserve all manual overrides until explicitly removed
        {:awake, :no_transition, :wake_up_override, :not_naptime} -> 
          Logger.debug("Preserving manual wake-up override")
          axn
        # When a schedule is awake with a wake-up override and it's past sleep time,
        # we respect the manual override and do nothing
        {:awake, :no_transition, :wake_up_override, :naptime} ->
          Logger.info("Sleep time reached but respecting manual wake-up override")
          axn
        # When a schedule is sleeping with a sleep override and it's naptime,
        # we respect the manual override and do nothing
        {:sleeping, :no_transition, :sleep_override, :naptime} -> 
          Logger.debug("Sleep time reached but respecting manual sleep override")
          axn
        # Trigger scheduled actions
        {:awake, :no_transition, :no_override, :naptime} -> initiate_sleep(axn)
        {:sleeping, :no_transition, :no_override, :not_naptime} -> initiate_wake_up(axn)
        # Await transitions (could be moved to background process)
        {:awake, :transition, _, _} -> check_sleep_transition(axn, manual_override: manual_override_value != :no_override)
        {:sleeping, :transition, _, _} -> check_wake_up_transition(axn, manual_override: manual_override_value != :no_override)
        {_, _, _, _} ->
          Logger.debug("No action required for current state.")
          axn
      end
    else
      {:error, _error} -> axn # Conditions should be present except for the first event
    end
  end

  # Helper function to check if a schedule has a wake time defined
  defp has_wake_time?(resource) do
    wake_time = resource["spec"]["wakeTime"]
    not (is_nil(wake_time) or wake_time == "")
  end

  defp clear_manual_override(axn) do
    Logger.info("Clearing manual override")
    set_condition(axn, "ManualOverride", false, "NoOverride", "No manual override in effect")
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
    Drowzee.TransitionMonitor.start_transition_monitor(axn.resource["metadata"]["name"], axn.resource["metadata"]["namespace"])
    axn
  end

  # Coordination mechanism for scaling operations with prioritization
  # Uses an Agent to coordinate scaling operations across multiple schedules
  
  # Start the coordinator when the application starts
  def start_coordinator do
    Agent.start_link(fn -> %{queue: [], processing: false} end, name: __MODULE__.Coordinator)
  end
  
  # Add a scaling operation to the queue with priority
  defp queue_scaling_operation(operation, resource, priority) do
    Agent.update(__MODULE__.Coordinator, fn state = %{queue: queue} ->
      # Add operation to queue with priority (lower number = higher priority)
      new_queue = queue ++ [{priority, operation, resource}]
      # Sort by priority
      sorted_queue = Enum.sort(new_queue, fn {p1, _, _}, {p2, _, _} -> p1 <= p2 end)
      %{state | queue: sorted_queue}
    end)
    
    # Start processing if not already running
    spawn(fn -> process_queue() end)
  end
  
  # Process the queue of scaling operations
  defp process_queue do
    # Try to acquire the processing lock
    Agent.get_and_update(__MODULE__.Coordinator, fn
      %{processing: true} = state ->
        # Already processing, do nothing
        {false, state}
      %{processing: false, queue: []} = state ->
        # Nothing to process
        {false, state}
      %{processing: false, queue: queue} = state ->
        # Start processing
        {true, %{state | processing: true}}
    end)
    |> case do
      false -> :ok  # Already processing or nothing to do
      true -> do_process_queue()
    end
  end
  
  # Process the queue items one by one
  defp do_process_queue do
    Agent.get_and_update(__MODULE__.Coordinator, fn
      %{queue: []} = state ->
        # Queue is empty, stop processing
        {:done, %{state | processing: false}}
      %{queue: [{_priority, operation, resource} | rest]} = state ->
        # Get the next operation and update the queue
        {{operation, resource}, %{state | queue: rest}}
    end)
    |> case do
      :done -> :ok
      {operation, resource} ->
        # Execute the operation
        try do
          result = apply_scaling_operation(operation, resource)
          
          # Handle the result based on its type
          case result do
            {:ok, _results} ->
              # Operation succeeded, continue normally
              :ok
              
            {:partial, _results, _errors, updated_resource} ->
              # Some operations failed but we continue
              # Update the resource in the K8s API with the error condition
              update_resource_status(updated_resource)
              
            {:error, _error, updated_resource} ->
              # Operation failed completely but we continue
              # Update the resource in the K8s API with the error condition
              update_resource_status(updated_resource)
          end
          
          # Small delay to avoid overwhelming the Kubernetes API
          Process.sleep(200)
        rescue
          e ->
            Logger.error("Error executing scaling operation: #{inspect(operation)}, #{inspect(e)}")
        end
        # Process the next item regardless of success/failure
        do_process_queue()
    end
  end
  
  # Apply the actual scaling operation
  defp apply_scaling_operation(operation, resource) do
    result = case operation do
      :scale_down_statefulsets -> SleepSchedule.scale_down_statefulsets(resource)
      :scale_down_deployments -> SleepSchedule.scale_down_deployments(resource)
      :suspend_cronjobs -> SleepSchedule.suspend_cronjobs(resource)
      :scale_up_statefulsets -> SleepSchedule.scale_up_statefulsets(resource)
      :scale_up_deployments -> SleepSchedule.scale_up_deployments(resource)
      :resume_cronjobs -> SleepSchedule.resume_cronjobs(resource)
    end
    
    # Handle different result types
    case result do
      {:ok, results} -> 
        # All operations succeeded
        {:ok, results}
      
      {:partial, results, errors} ->
        # Some operations failed, but we continue processing
        # Log the errors
        Enum.each(errors, fn {:error, error_msg} ->
          Logger.error("Scaling operation partially failed: #{error_msg}")
        end)
        
        # Set error condition on the sleep schedule but continue processing
        resource = set_error_condition(resource, "ScaleFailed", 
          "Some resources failed to scale, but processing continued. Check logs for details.")
        
        # Return partial success to continue with other operations
        {:partial, results, errors, resource}
      
      {:error, error} ->
        # Complete failure, but we'll still continue with other operations
        Logger.error("Scaling operation failed: #{inspect(error)}")
        
        # Set error condition on the sleep schedule
        resource = set_error_condition(resource, "ScaleFailed", 
          "Failed to scale resources: #{inspect(error)}")
        
        # Return error but with the updated resource to continue processing
        {:error, error, resource}
    end
  end
  
  # Helper to set the error condition on a sleep schedule
  defp set_error_condition(resource, reason, message) do
    # Update the status with the error condition
    conditions = resource["status"]["conditions"] || []
    
    # Find and update or create the Error condition
    error_condition = Enum.find(conditions, %{"type" => "Error", "status" => "False"}, fn condition ->
      condition["type"] == "Error"
    end)
    
    updated_error_condition = error_condition
    |> Map.put("status", "True")
    |> Map.put("reason", reason)
    |> Map.put("message", message)
    |> Map.put("lastTransitionTime", DateTime.utc_now() |> DateTime.to_iso8601())
    
    # Replace or add the error condition
    updated_conditions = if Enum.any?(conditions, fn c -> c["type"] == "Error" end) do
      Enum.map(conditions, fn condition ->
        if condition["type"] == "Error", do: updated_error_condition, else: condition
      end)
    else
      [updated_error_condition | conditions]
    end
    
    # Update the resource with the new conditions
    put_in(resource, ["status", "conditions"], updated_conditions)
  end
  
  # Update the resource status in the Kubernetes API
  defp update_resource_status(resource) do
    Logger.info("Updating resource status with error condition", 
      name: resource["metadata"]["name"],
      namespace: resource["metadata"]["namespace"])
    
    # Create a status subresource update operation
    operation = K8s.Client.update_status(resource)
    
    # Execute the update
    case K8s.Client.run(Drowzee.K8s.conn(), operation) do
      {:ok, updated} ->
        Logger.info("Successfully updated resource status")
        {:ok, updated}
      {:error, reason} ->
        Logger.error("Failed to update resource status: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Error updating resource status: #{inspect(e)}")
      {:error, e}
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
    case check_application_status(axn, &application_status_asleep?/1) do
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
    case check_application_status(axn, &application_status_ready?/1) do
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

  defp application_status_ready?(status) do
    replicas = Map.get(status, "replicas")
    ready_replicas = Map.get(status, "readyReplicas")
    suspended = Map.get(status, "suspended", true)

    cond do
      not is_nil(replicas) and not is_nil(ready_replicas) ->
        replicas == ready_replicas

      true ->
        # For CronJobs: considered ready if not suspended
        suspended == false
    end
  end

  defp application_status_asleep?(status) do
    replicas = Map.get(status, "replicas", 0)
    ready = Map.get(status, "readyReplicas", 0)
    suspended = Map.get(status, "suspended", nil)

    cond do
      not is_nil(suspended) ->
        suspended == true

      true ->
        replicas == 0 and ready == 0
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

          check_fn.(deployment["status"])
        end)

      statefulsets_result =
        Enum.all?(statefulsets, fn statefulset ->
          Logger.debug(
            "StatefulSet #{StatefulSet.name(statefulset)} replicas: #{StatefulSet.replicas(statefulset)}, readyReplicas: #{StatefulSet.ready_replicas(statefulset)}"
          )

          check_fn.(statefulset["status"])
        end)

      cronjobs_result =
      Enum.all?(cronjobs, fn cronjob ->
        suspended = CronJob.suspend(cronjob)

        Logger.debug("CronJob #{CronJob.name(cronjob)} suspended: #{suspended}")

        # check_fn determines if suspended is the expected state (true for sleep, false for wake)
        check_fn.(%{"suspended" => suspended})
      end)

      # Determine which resources we need to check based on what's present
      has_deployments   = Enum.any?(deployments)
      has_statefulsets  = Enum.any?(statefulsets)
      has_cronjobs     = Enum.any?(cronjobs)

      case {has_deployments, has_statefulsets, has_cronjobs} do
        {false, false, false} -> {:ok, true}
        {true,  false, false} -> {:ok, deployments_result}
        {false, true,  false} -> {:ok, statefulsets_result}
        {false, false, true}  -> {:ok, cronjobs_result}
        {true,  true,  false} -> {:ok, deployments_result && statefulsets_result}
        {true,  false, true}  -> {:ok, deployments_result && cronjobs_result}
        {false, true,  true}  -> {:ok, statefulsets_result && cronjobs_result}
        {true,  true,  true}  -> {:ok, deployments_result && statefulsets_result && cronjobs_result}
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

    sleep_reason = cond do
      manual_override -> "ManualSleep"
      permanent_sleep -> "PermanentSleep"
      true -> "ScheduledSleep"
    end

    sleep_message = if permanent_sleep do
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
      |> set_condition("Sleeping", false, wake_reason, "Deployments and StatefulSets have been scaled up, CronJobs have been resumed, and ingress restored.")
      |> set_condition("Error", false, "None", "No error")
  end

  defp put_ingress_to_sleep(axn) do
    case SleepSchedule.put_ingress_to_sleep(axn.resource) do
      {:ok, _} ->
        Logger.info("Updated ingress to redirect to Drowzee", name: SleepSchedule.ingress_name(axn.resource))
        # register_event(axn, nil, :Normal, "SleepIngress", "Ingress has been redirected to Drowzee")
        axn
      {:error, :ingress_name_not_set} ->
        Logger.info("No ingressName has been provided so there is nothing to redirect")
        axn
      {:error, error} ->
        Logger.error("Failed to redirect ingress to Drowzee: #{inspect(error)}", name: SleepSchedule.ingress_name(axn.resource))
        axn
    end
  end

  defp wake_up_ingress(axn) do
    case SleepSchedule.wake_up_ingress(axn.resource) do
      {:ok, _} ->
        Logger.info("Removed Drowzee redirect from ingress", name: SleepSchedule.ingress_name(axn.resource))
        # register_event(axn, nil, :Normal, "WakeUpIngress", "Ingress has been restored")
        axn
      {:error, :ingress_name_not_set} ->
        Logger.info("No ingressName has been provided so there is nothing to restore")
        axn
      {:error, error} ->
        Logger.error("Failed to remove Drowzee redirect from ingress: #{inspect(error)}", name: SleepSchedule.ingress_name(axn.resource))
        axn
    end
  end
end
