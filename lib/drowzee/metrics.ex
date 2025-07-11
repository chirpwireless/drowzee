defmodule Drowzee.Metrics do
  @moduledoc """
  Metrics for the Drowzee Kubernetes operator.

  This module defines Prometheus metrics for tracking sleep schedule operations:
  - Count of manual starts of the schedule
  - Count of manual stops of the schedule
  - Total amount of seconds when the schedule is up (duration tracking)
  """

  use Prometheus.Metric
  require Logger

  # Define metrics
  @doc "Initialize all metrics"
  def setup do
    # Counter for manual starts of sleep schedules
    Counter.declare(
      name: :drowzee_sleep_schedule_manual_starts_total,
      help: "Total number of manual starts of sleep schedules",
      labels: [:namespace, :name]
    )

    # Counter for manual stops of sleep schedules
    Counter.declare(
      name: :drowzee_sleep_schedule_manual_stops_total,
      help: "Total number of manual stops of sleep schedules",
      labels: [:namespace, :name]
    )

    # Counter for tracking cumulative uptime in seconds
    Counter.declare(
      name: :drowzee_sleep_schedule_uptime_seconds_total,
      help: "Total cumulative seconds the sleep schedule has been in the awake state",
      labels: [:namespace, :name]
    )

    # Gauge for tracking current state (1 = awake, 0 = asleep)
    Gauge.declare(
      name: :drowzee_sleep_schedule_state,
      help: "Current state of the sleep schedule (1 = awake, 0 = asleep)",
      labels: [:namespace, :name]
    )

    # Create ETS table for tracking schedule state
    :ets.new(:drowzee_schedule_state, [:named_table, :public, :set])
  end

  @doc """
  Record a manual start of a sleep schedule.
  """
  def record_manual_start(namespace, name) do
    try do
      # Increment the counter
      Counter.inc(
        name: :drowzee_sleep_schedule_manual_starts_total,
        labels: [namespace, name]
      )

      # Record the wake-up time for duration tracking
      current_time = :os.system_time(:second)
      :ets.insert(:drowzee_schedule_state, {{namespace, name, :wake_time}, current_time})

      # Set state to awake
      Gauge.set(
        name: :drowzee_sleep_schedule_state,
        labels: [namespace, name],
        value: 1
      )

      Logger.debug("Recorded manual start for schedule #{namespace}/#{name}")
    rescue
      e ->
        Logger.error("Failed to record manual start metric: #{inspect(e)}")
    end
  end

  @doc """
  Record a manual stop of a sleep schedule.
  """
  def record_manual_stop(namespace, name) do
    try do
      # Increment the counter
      Counter.inc(
        name: :drowzee_sleep_schedule_manual_stops_total,
        labels: [namespace, name]
      )

      # Update the uptime duration when stopping
      update_uptime_on_sleep(namespace, name)

      # Set state to asleep
      Gauge.set(
        name: :drowzee_sleep_schedule_state,
        labels: [namespace, name],
        value: 0
      )

      Logger.debug("Recorded manual stop for schedule #{namespace}/#{name}")
    rescue
      e ->
        Logger.error("Failed to record manual stop metric: #{inspect(e)}")
    end
  end

  @doc """
  Record a scheduled start of a sleep schedule.
  This doesn't increment the manual counter but does track uptime.
  """
  def record_scheduled_start(namespace, name) do
    try do
      # Record the wake-up time for duration tracking
      current_time = :os.system_time(:second)
      :ets.insert(:drowzee_schedule_state, {{namespace, name, :wake_time}, current_time})

      # Set state to awake
      Gauge.set(
        name: :drowzee_sleep_schedule_state,
        labels: [namespace, name],
        value: 1
      )

      Logger.debug("Recorded scheduled start for schedule #{namespace}/#{name}")
    rescue
      e ->
        Logger.error("Failed to record scheduled start metric: #{inspect(e)}")
    end
  end

  @doc """
  Record a scheduled stop of a sleep schedule.
  This doesn't increment the manual counter but does track uptime.
  """
  def record_scheduled_stop(namespace, name) do
    try do
      # Update the uptime duration when stopping
      update_uptime_on_sleep(namespace, name)

      # Set state to asleep
      Gauge.set(
        name: :drowzee_sleep_schedule_state,
        labels: [namespace, name],
        value: 0
      )

      Logger.debug("Recorded scheduled stop for schedule #{namespace}/#{name}")
    rescue
      e ->
        Logger.error("Failed to record scheduled stop metric: #{inspect(e)}")
    end
  end

  @doc """
  Update the uptime duration metric.
  Called periodically for active schedules.
  """
  def update_uptime(namespace, name) do
    try do
      case :ets.lookup(:drowzee_schedule_state, {namespace, name, :wake_time}) do
        [{{^namespace, ^name, :wake_time}, wake_time}] ->
          current_time = :os.system_time(:second)
          time_since_last_update = get_time_since_last_update(namespace, name)

          # Increment the counter by the time since last update
          Counter.inc(
            name: :drowzee_sleep_schedule_uptime_seconds_total,
            labels: [namespace, name],
            value: time_since_last_update
          )

          # Update the last update time
          :ets.insert(:drowzee_schedule_state, {{namespace, name, :last_update}, current_time})

          Logger.debug("Updated uptime for schedule #{namespace}/#{name}: +#{time_since_last_update} seconds")

        [] ->
          # No wake time recorded, schedule might be asleep
          Logger.debug("No wake time found for schedule #{namespace}/#{name}")
      end
    rescue
      e ->
        Logger.error("Failed to update uptime metric: #{inspect(e)}")
    end
  end

  # Private function to update uptime when a schedule goes to sleep
  defp update_uptime_on_sleep(namespace, name) do
    case :ets.lookup(:drowzee_schedule_state, {namespace, name, :wake_time}) do
      [{{^namespace, ^name, :wake_time}, wake_time}] ->
        current_time = :os.system_time(:second)
        time_since_last_update = get_time_since_last_update(namespace, name)

        # Increment the counter by the time since last update
        Counter.inc(
          name: :drowzee_sleep_schedule_uptime_seconds_total,
          labels: [namespace, name],
          value: time_since_last_update
        )

        # Remove the wake time and last update entries
        :ets.delete(:drowzee_schedule_state, {namespace, name, :wake_time})
        :ets.delete(:drowzee_schedule_state, {namespace, name, :last_update})

        Logger.debug("Schedule #{namespace}/#{name} went to sleep after #{time_since_last_update} seconds since last update")

      [] ->
        Logger.debug("No wake time found for schedule #{namespace}/#{name} when going to sleep")
    end
  end

  # Get time since last update or since wake time if no last update
  defp get_time_since_last_update(namespace, name) do
    current_time = :os.system_time(:second)

    case :ets.lookup(:drowzee_schedule_state, {namespace, name, :last_update}) do
      [{{^namespace, ^name, :last_update}, last_update}] ->
        # Calculate time since last update
        current_time - last_update

      [] ->
        # No last update, use wake time
        case :ets.lookup(:drowzee_schedule_state, {namespace, name, :wake_time}) do
          [{{^namespace, ^name, :wake_time}, wake_time}] ->
            # Initialize last update time
            :ets.insert(:drowzee_schedule_state, {{namespace, name, :last_update}, current_time})
            # Return a small initial value to avoid large jumps on first update
            1

          [] ->
            # No wake time either, return 0
            0
        end
    end
  end
end
