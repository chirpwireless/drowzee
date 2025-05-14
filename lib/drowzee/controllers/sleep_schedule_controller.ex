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
    manual_override_exists =
      case get_condition(axn, "ManualOverride") do
        {:ok, condition} -> condition["status"] == "True"
        _ -> false
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

    case Drowzee.SleepChecker.naptime?(sleep_time, wake_time, timezone, day_of_week) do
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
    # Use GenServer.cast instead of Agent.update
    GenServer.cast(
      __MODULE__.Coordinator,
      {:add_operation, operation, resource, priority}
    )

    # Start processing if not already running
    spawn(fn -> process_queue() end)
  end

  # Process the queue of scaling operations
  defp process_queue do
    # Try to acquire the processing lock using GenServer.call
    case GenServer.call(__MODULE__.Coordinator, :get_and_update_processing) do
      # Already processing or nothing to do
      false -> :ok
      # Start processing
      true -> do_process_queue()
    end
  rescue
    e ->
      Logger.error("Error in process_queue when calling coordinator: #{inspect(e)}")
      # Wait a bit and try again
      Process.sleep(1000)
      process_queue()
  end

  # Process the queue items one by one with improved error handling and rate limiting
  defp do_process_queue do
    try do
      # Use GenServer.call instead of Agent.get_and_update
      case GenServer.call(__MODULE__.Coordinator, :get_next_operation) do
        :done ->
          :ok

        {operation, resource} ->
          # Execute the operation with timeout protection
          execute_operation_with_timeout(operation, resource)

          # Process the next item regardless of success/failure
          # Add a longer delay between operations to avoid overwhelming the Kubernetes API
          # Increased from 200ms to 500ms
          Process.sleep(500)
          do_process_queue()
      end
    rescue
      e ->
        Logger.error("Error in process_queue: #{inspect(e)}")
        # Mark the coordinator as not processing so it can be restarted
        reset_coordinator_state()
        # Continue processing the queue despite errors
        Process.sleep(1000)
        do_process_queue()
    end
  end

  # Reset the coordinator state if it gets stuck
  defp reset_coordinator_state do
    try do
      Agent.update(__MODULE__.Coordinator, fn state ->
        %{state | processing: false}
      end)
    rescue
      _ -> :ok
    end
  end

  # Execute an operation with timeout protection
  defp execute_operation_with_timeout(operation, resource) do
    # Use Task.yield_many with a longer timeout (30 seconds instead of default 5)
    task = Task.async(fn -> apply_scaling_operation_safely(operation, resource) end)

    # Wait for the task to complete with a timeout
    case Task.yield(task, 30_000) || Task.shutdown(task) do
      {:ok, result} ->
        # Task completed successfully
        handle_operation_result(result, resource)

      nil ->
        # Task didn't complete within the timeout
        Logger.error("Operation timed out: #{inspect(operation)}")
        # Update the resource with an error condition
        updated_resource = add_timeout_error(resource, operation)
        update_resource_status(updated_resource)
    end
  end

  # Apply scaling operation with additional error handling
  defp apply_scaling_operation_safely(operation, resource) do
    try do
      apply_scaling_operation(operation, resource)
    rescue
      e ->
        Logger.error("Error executing scaling operation: #{inspect(operation)}, #{inspect(e)}")
        {:error, "Exception: #{inspect(e)}", resource}
    catch
      kind, reason ->
        Logger.error("Caught #{kind} in scaling operation: #{inspect(reason)}")
        {:error, "Caught #{kind}: #{inspect(reason)}", resource}
    end
  end

  # Handle the result of an operation
  defp handle_operation_result(result, _resource) do
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
  end

  # Add a timeout error to the resource
  defp add_timeout_error(resource, operation) do
    resource
    |> put_in(
      ["status", "conditions"],
      (resource["status"]["conditions"] || [])
      |> Enum.reject(fn condition -> condition["type"] == "Error" end)
      |> Enum.concat([
        %{
          "type" => "Error",
          "status" => "True",
          "reason" => "OperationTimeout",
          "message" => "Operation timed out: #{inspect(operation)}",
          "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      ])
    )
  end

  # Apply the actual scaling operation
  defp apply_scaling_operation(operation, resource) do
    result =
      case operation do
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
        # Some operations failed or resources were missing
        # Categorize errors into scaling failures and missing resources
        {scaling_errors, missing_resources} = categorize_errors(errors)

        # Log the errors and update failed resources in Kubernetes
        failed_resources =
          Enum.map(scaling_errors, fn
            {:error, failed_resource, error_msg} ->
              Logger.error("Scaling operation partially failed: #{error_msg}")
              # Update the failed resource in Kubernetes to mark it as failed
              update_failed_resource(failed_resource)
              {failed_resource, error_msg}

            {:error, error_msg} ->
              Logger.error("Scaling operation partially failed: #{error_msg}")
              nil
          end)
          |> Enum.reject(&is_nil/1)

        # Log missing resources
        unless Enum.empty?(missing_resources) do
          missing_names =
            Enum.map(missing_resources, fn res ->
              "#{res["kind"]} #{res["name"]}"
            end)
            |> Enum.join(", ")

          Logger.warning("Resources not found: #{missing_names}")
        end

        # Set error condition on the sleep schedule but continue processing
        error_details =
          cond do
            Enum.empty?(failed_resources) and Enum.empty?(missing_resources) ->
              "Some resources failed to scale, but processing continued. Check logs for details."

            Enum.empty?(failed_resources) and not Enum.empty?(missing_resources) ->
              missing_names =
                Enum.map(missing_resources, fn res ->
                  "#{res["kind"]} #{res["name"]}"
                end)
                |> Enum.join(", ")

              "Resources not found: #{missing_names}. Processing continued."

            not Enum.empty?(failed_resources) and Enum.empty?(missing_resources) ->
              resource_names =
                failed_resources
                |> Enum.map(fn {res, _} -> res["metadata"]["name"] end)
                |> Enum.join(", ")

              "Failed to scale resources: #{resource_names}. Processing continued."

            true ->
              # Build error message parts
              parts = []

              # Add failed resources if any
              parts =
                if not Enum.empty?(failed_resources) do
                  failed_names =
                    failed_resources
                    |> Enum.map(fn {res, _} -> res["metadata"]["name"] end)
                    |> Enum.join(", ")

                  parts ++ ["Failed to scale resources: #{failed_names}"]
                else
                  parts
                end

              # Add missing resources if any
              parts =
                if not Enum.empty?(missing_resources) do
                  missing_names =
                    Enum.map(missing_resources, fn res ->
                      "#{res["kind"]} #{res["name"]}"
                    end)
                    |> Enum.join(", ")

                  parts ++ ["Resources not found: #{missing_names}"]
                else
                  parts
                end

              # Join all parts and add final message
              Enum.join(parts, ". ") <> ". Processing continued."
          end

        # Update the resource with error condition
        updated_resource =
          resource
          |> put_in(
            ["status", "conditions"],
            (resource["status"]["conditions"] || [])
            |> Enum.reject(fn condition -> condition["type"] == "Error" end)
            |> Enum.concat([
              %{
                "type" => "Error",
                "status" => "True",
                "reason" => "ScalingPartialFailure",
                "message" => error_details,
                "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
            ])
          )

        # Add annotation for missing resources if any
        updated_resource = add_missing_resources_annotation(updated_resource, missing_resources)

        {:partial, results, errors, updated_resource}

      {:error, error} ->
        # Complete failure
        error_details = "Scaling failed: #{inspect(error)}"
        Logger.error(error_details)

        # Update the resource with error condition
        updated_resource =
          resource
          |> put_in(
            ["status", "conditions"],
            (resource["status"]["conditions"] || [])
            |> Enum.reject(fn condition -> condition["type"] == "Error" end)
            |> Enum.concat([
              %{
                "type" => "Error",
                "status" => "True",
                "reason" => "ScalingFailed",
                "message" => error_details,
                "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
            ])
          )

        {:error, error, updated_resource}
    end
  end

  # Categorize errors into scaling failures and missing resources
  defp categorize_errors(errors) do
    # Separate scaling failures from missing resources
    {scaling_errors, missing_resources} =
      Enum.split_with(errors, fn
        # Scaling failures
        {:error, _, _} ->
          true

        # Missing resources
        %{"status" => "NotFound"} ->
          false

        # Default to scaling failures for any other format
        _ ->
          true
      end)

    {scaling_errors, missing_resources}
  end

  # Update the resource status in the Kubernetes API
  defp update_resource_status(resource) do
    case K8s.Client.update(resource) do
      {:ok, updated_resource} ->
        Logger.debug("Updated resource status in Kubernetes API")
        {:ok, updated_resource}

      {:error, error} ->
        Logger.error("Failed to update resource status in Kubernetes API: #{inspect(error)}")
        {:error, error}
    end
  end

  # Add annotation for missing resources to the sleep schedule
  defp add_missing_resources_annotation(resource, []), do: resource

  defp add_missing_resources_annotation(resource, missing_resources) do
    missing_json = Jason.encode!(missing_resources)

    resource =
      update_in(
        resource,
        ["metadata", "annotations"],
        fn annotations ->
          annotations = annotations || %{}
          Map.put(annotations, "drowzee.io/missing-resources", missing_json)
        end
      )

    # Update the resource in Kubernetes
    case K8s.Client.update(resource) do
      {:ok, updated_resource} -> updated_resource
      # Return original if update fails
      {:error, _} -> resource
    end
  end

  # Update a failed resource in Kubernetes to mark it as failed
  defp update_failed_resource(resource) do
    kind = resource["kind"]
    name = resource["metadata"]["name"]
    namespace = resource["metadata"]["namespace"]

    Logger.info("Updating failed resource in Kubernetes",
      kind: kind,
      name: name,
      namespace: namespace
    )

    # Create an update operation for the resource
    operation = K8s.Client.update(resource)

    # Execute the update
    case K8s.Client.run(Drowzee.K8s.conn(), operation) do
      {:ok, updated} ->
        Logger.info("Successfully marked resource as failed",
          kind: kind,
          name: name,
          namespace: namespace
        )

        {:ok, updated}

      {:error, reason} ->
        Logger.error("Failed to update resource with failure status: #{inspect(reason)}",
          kind: kind,
          name: name,
          namespace: namespace
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Error updating failed resource: #{inspect(e)}",
        kind: resource["kind"] || "unknown",
        name: resource["metadata"]["name"] || "unknown"
      )

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
end
