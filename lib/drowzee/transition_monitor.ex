defmodule Drowzee.TransitionMonitor do
  @moduledoc """
  Drowzee: TransitionMonitor

  Monitors the status of a transition every 10 seconds.
  If the transition is complete, the periodic task is stopped.
  If the transition is not complete, the heartbeat is updated to trigger a :modify event to the SleepSchedule controller.
  The monitor will expire after 10 attempts (100 seconds). After that we'll rely on the reconcile loop to update the state.
  """

  require Logger

  # Increased from 5000ms to 10000ms for more time between checks
  @check_interval 10000
  # Increased from 5 to 10 attempts for longer monitoring
  @max_attempts 10

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
          if attempt > @max_attempts do
            {:stop, "Failed to get sleep schedule after #{@max_attempts} attempts"}
          else
            {:ok, [name, namespace, attempt + 1]}
          end
      end
    rescue
      e ->
        Logger.error("TransitionMonitor - Exception during monitoring: #{inspect(e)}")
        # Retry on next interval if we haven't exceeded max attempts
        if attempt > @max_attempts do
          {:stop, "Transition monitor failed after #{@max_attempts} attempts due to exceptions"}
        else
          {:ok, [name, namespace, attempt + 1]}
        end
    end
  end

  defp process_transition_state(sleep_schedule, name, namespace, attempt) do
    case {Drowzee.K8s.SleepSchedule.get_condition(sleep_schedule, "Transitioning"), attempt} do
      {%{"status" => "False"}, _} ->
        Logger.warning("TransitionMonitor - Transition complete")
        {:stop, "Transition complete"}

      {_, attempt} when attempt > @max_attempts ->
        Logger.warning("TransitionMonitor - Transition expired after #{@max_attempts} attempts")
        # Mark as no longer transitioning to avoid stuck state
        try_complete_transition(sleep_schedule)
        {:stop, "Transition monitor expired after #{@max_attempts} attempts"}

      _ ->
        Logger.debug("Transition still running... (attempt #{attempt}/#{@max_attempts})")

        Logger.warning(
          "TransitionMonitor - Transition still running... (attempt #{attempt}/#{@max_attempts})"
        )

        try_update_heartbeat(sleep_schedule)
        {:ok, [name, namespace, attempt + 1]}
    end
  end

  # Try to update the heartbeat, but don't fail if it doesn't work
  defp try_update_heartbeat(sleep_schedule) do
    try do
      Drowzee.K8s.SleepSchedule.update_heartbeat(sleep_schedule)
    rescue
      e ->
        Logger.error("TransitionMonitor - Failed to update heartbeat: #{inspect(e)}")
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
