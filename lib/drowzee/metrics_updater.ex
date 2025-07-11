defmodule Drowzee.MetricsUpdater do
  @moduledoc """
  GenServer that periodically updates metrics for active sleep schedules.

  This server runs on a configurable interval and updates the uptime duration
  metrics for all active sleep schedules.
  """

  use GenServer
  require Logger
  alias Drowzee.Metrics

  # Default update interval in milliseconds (30 seconds)
  @default_interval 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule_update(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:update_metrics, state) do
    update_all_schedule_metrics()
    schedule_update(state.interval)
    {:noreply, state}
  end

  defp schedule_update(interval) do
    Process.send_after(self(), :update_metrics, interval)
  end

  defp update_all_schedule_metrics do
    try do
      # Get all active schedules from the ETS table
      case :ets.tab2list(:drowzee_schedule_state) do
        [] ->
          Logger.debug("No active schedules found for metrics update")

        entries ->
          # Filter for wake_time entries and update their metrics
          entries
          |> Enum.filter(fn {{_, _, key}, _} -> key == :wake_time end)
          |> Enum.each(fn {{namespace, name, :wake_time}, _} ->
            # Update the uptime counter for this schedule
            Metrics.update_uptime(namespace, name)
          end)
      end
    rescue
      e ->
        Logger.error("Failed to update schedule metrics: #{inspect(e)}")
    end
  end
end
