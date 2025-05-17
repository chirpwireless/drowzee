defmodule Drowzee.TransitionMonitor do
  @moduledoc """
  Drowzee: TransitionMonitor

  Monitors the status of a transition every 10 seconds.
  If the transition is complete, the periodic task is stopped.
  If the transition is not complete after all attempts (10 attempts, 100 seconds),
  the heartbeat is updated to trigger a :modify event to the SleepSchedule controller.
  This ensures we only trigger a retry once at the end of the monitoring period,
  rather than on every check.
  """

  require Logger

  # Increased from 5000ms to 10000ms for more time between checks
  @check_interval 10000
  # Increased from 5 to 60 attempts for longer monitoring
  @max_attempts 60

  def start_transition_monitor(name, namespace) do
    Logger.info("Monitoring transition...")
    task_name = "monitor_transition_#{name}_#{namespace}" |> String.to_atom()
    Bonny.PeriodicTask.unregister(task_name)

    # Use the new interval constant
    Bonny.PeriodicTask.new(
      task_name,
      {Drowzee.TransitionMonitor, :monitor_transition, [name, namespace, 1]},
      @check_interval
    )
  end

  @spec monitor_transition(binary(), :all | binary(), any()) ::
          {:ok, [:all | binary() | number(), ...]} | {:stop, <<_::152, _::_*192>>}
  def monitor_transition(name, namespace, attempt) do
    try do
      case Drowzee.K8s.get_sleep_schedule(name, namespace) do
        {:ok, sleep_schedule} ->
          process_transition_state(sleep_schedule, name, namespace, attempt)

        {:error, reason} ->
          Logger.error("TransitionMonitor - Failed to get sleep schedule: #{inspect(reason)}")
          # Retry on next interval if we haven't exceeded max attempts
          if attempt >= @max_attempts do
            # At the final attempt, trigger a retry by updating the heartbeat
            Logger.warning("TransitionMonitor - Final attempt failed, triggering retry")
            {:stop, "Failed to get sleep schedule after #{@max_attempts} attempts"}
          else
            # Continue monitoring without triggering a retry
            {:ok, [name, namespace, attempt + 1]}
          end
      end
    rescue
      e ->
        Logger.error("TransitionMonitor - Exception during monitoring: #{inspect(e)}")
        # Retry on next interval if we haven't exceeded max attempts
        if attempt >= @max_attempts do
          # At the final attempt, we'll stop monitoring but won't trigger a retry
          # since there was an exception
          {:stop, "Transition monitor failed after #{@max_attempts} attempts due to exceptions"}
        else
          # Continue monitoring without triggering a retry
          {:ok, [name, namespace, attempt + 1]}
        end
    end
  end

  defp process_transition_state(sleep_schedule, name, namespace, attempt) do
    case {Drowzee.K8s.SleepSchedule.get_condition(sleep_schedule, "Transitioning"), attempt} do
      {%{"status" => "False"}, _} ->
        # Transition is complete, stop monitoring
        Logger.warning("TransitionMonitor - Transition complete")
        {:stop, "Transition complete"}

      {_, attempt} when attempt >= @max_attempts ->
        # This is the final attempt and transition is still not complete
        Logger.warning(
          "TransitionMonitor - Transition not complete after #{@max_attempts} attempts, triggering retry"
        )

        # Trigger a retry by updating the heartbeat
        try_update_heartbeat(sleep_schedule)
        # Mark as no longer transitioning to avoid stuck state
        try_complete_transition(sleep_schedule)
        {:stop, "Transition monitor expired after #{@max_attempts} attempts, retry triggered"}

      _ ->
        # Transition is still in progress and we haven't reached the max attempts
        Logger.debug("Transition still running... (attempt #{attempt}/#{@max_attempts})")

        Logger.warning(
          "TransitionMonitor - Transition still running... (attempt #{attempt}/#{@max_attempts})"
        )

        # Continue monitoring without triggering a retry
        {:ok, [name, namespace, attempt + 1]}
    end
  end

  # Update the heartbeat to trigger a retry via the controller's event handling
  # This is only called at the end of the monitoring period if the transition is still not complete
  defp try_update_heartbeat(sleep_schedule) do
    try do
      Logger.info("TransitionMonitor - Triggering retry by updating heartbeat")
      Drowzee.K8s.SleepSchedule.update_heartbeat(sleep_schedule)
    rescue
      e ->
        Logger.error("TransitionMonitor - Failed to trigger retry via heartbeat: #{inspect(e)}")
    end
  end

  # Try to complete a stuck transition
  defp try_complete_transition(sleep_schedule) do
    try do
      # Force the transition to complete by setting Transitioning to false
      updated_schedule =
        Drowzee.K8s.SleepSchedule.put_condition(
          sleep_schedule,
          "Transitioning",
          false,
          "TransitionExpired",
          "Transition monitor expired, forcing completion"
        )

      # Apply the update
      Bonny.Resource.apply_status(updated_schedule, Drowzee.K8s.conn(), force: true)

      Logger.info("TransitionMonitor - Forced transition completion for stuck schedule")
    rescue
      e ->
        Logger.error("TransitionMonitor - Failed to force transition completion: #{inspect(e)}")
    end
  end
end
