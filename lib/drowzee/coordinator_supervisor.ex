defmodule Drowzee.CoordinatorSupervisor do
  @moduledoc """
  Supervisor for the SleepScheduleController.Coordinator.
  Ensures the coordinator can recover from crashes.
  """

  use Supervisor
  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Logger.info("Starting CoordinatorSupervisor")

    children = [
      # Start the coordinator as a supervised process
      {Drowzee.CoordinatorAgent, []}
    ]

    # Use :one_for_one strategy - if the coordinator crashes, only restart it
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Drowzee.CoordinatorAgent do
  @moduledoc """
  GenServer implementation for the SleepScheduleController.Coordinator.
  Provides a more robust implementation than using Agent directly.
  """

  use GenServer
  require Logger

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{queue: [], processing: false},
      name: Drowzee.Controller.SleepScheduleController.Coordinator
    )
  end

  # Server callbacks

  @impl true
  def init(state) do
    Logger.info("Starting CoordinatorAgent")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_and_update_processing, _from, state = %{processing: true}) do
    # Already processing, do nothing
    {:reply, false, state}
  end

  @impl true
  def handle_call(:get_and_update_processing, _from, state = %{queue: []}) do
    # Nothing to process
    {:reply, false, state}
  end

  @impl true
  def handle_call(:get_and_update_processing, _from, state = %{processing: false, queue: _}) do
    # Start processing
    {:reply, true, %{state | processing: true}}
  end

  @impl true
  def handle_call(:get_next_operation, _from, state = %{queue: []}) do
    # Queue is empty, stop processing
    {:reply, :done, %{state | processing: false}}
  end

  @impl true
  def handle_call(
        :get_next_operation,
        _from,
        state = %{queue: [{_priority, operation, resource} | rest]}
      ) do
    # Get the next operation and update the queue
    {:reply, {operation, resource}, %{state | queue: rest}}
  end

  @impl true
  def handle_cast({:add_operation, operation, resource, priority}, state = %{queue: queue}) do
    # Add operation to queue with priority (lower number = higher priority)
    new_queue = queue ++ [{priority, operation, resource}]
    # Sort by priority
    sorted_queue = Enum.sort(new_queue, fn {p1, _, _}, {p2, _, _} -> p1 <= p2 end)

    # Log the operation being added
    Logger.debug("Added operation to queue: #{inspect(operation)} with priority #{priority}")
    Logger.debug("Current queue: #{inspect(sorted_queue)}")

    # Automatically start processing if not already processing
    new_state =
      if not state.processing and length(sorted_queue) > 0 do
        # Mark as processing directly in the state
        # Don't call ourselves - that would cause a deadlock
        # Just send the process_queue message
        Process.send_after(self(), :process_queue, 100)
        # Update the state to mark as processing
        %{state | queue: sorted_queue, processing: true}
      else
        # Just update the queue
        %{state | queue: sorted_queue}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:reset_processing, state) do
    # Reset the processing flag
    {:noreply, %{state | processing: false}}
  end

  # Handle the process_queue message
  @impl true
  def handle_info(:process_queue, state) do
    Logger.debug("CoordinatorAgent processing queue")
    # Process one item from the queue
    case process_next_operation(state) do
      {:ok, new_state} ->
        # Schedule processing of the next item if there are more items in the queue
        if length(new_state.queue) > 0 do
          # Add delay between operations
          Process.send_after(self(), :process_queue, 500)
        end

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Error processing queue: #{inspect(reason)}")
        # Reset processing state and try again later
        Process.send_after(self(), :process_queue, 1000)
        {:noreply, %{state | processing: false}}
    end
  end

  # Handle unexpected messages
  @impl true
  def handle_info(msg, state) do
    Logger.warning("CoordinatorAgent received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Process the next operation in the queue
  defp process_next_operation(%{queue: []}) do
    # Queue is empty, nothing to process
    {:ok, %{queue: [], processing: false}}
  end

  defp process_next_operation(%{queue: [{_priority, operation, resource} | rest]}) do
    try do
      # Call the appropriate function in SleepSchedule module
      result =
        case operation do
          :scale_down_statefulsets -> Drowzee.K8s.SleepSchedule.scale_down_statefulsets(resource)
          :scale_down_deployments -> Drowzee.K8s.SleepSchedule.scale_down_deployments(resource)
          :suspend_cronjobs -> Drowzee.K8s.SleepSchedule.suspend_cronjobs(resource)
          :scale_up_statefulsets -> Drowzee.K8s.SleepSchedule.scale_up_statefulsets(resource)
          :scale_up_deployments -> Drowzee.K8s.SleepSchedule.scale_up_deployments(resource)
          :resume_cronjobs -> Drowzee.K8s.SleepSchedule.resume_cronjobs(resource)
        end

      # Log the result
      Logger.info("Processed operation #{inspect(operation)}: #{inspect(result)}")

      # Return the new state with the operation removed from the queue
      {:ok, %{queue: rest, processing: true}}
    rescue
      e ->
        Logger.error("Error processing operation #{inspect(operation)}: #{inspect(e)}")
        {:error, e}
    end
  end

  # Terminate callback for cleanup
  @impl true
  def terminate(reason, _state) do
    Logger.warning("CoordinatorAgent terminating: #{inspect(reason)}")
    :ok
  end
end
