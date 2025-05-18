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
    # Start a periodic health check to detect and fix stuck queues
    schedule_health_check()
    {:ok, state}
  end

  # Schedule a health check to run periodically
  defp schedule_health_check do
    # Check every 30 seconds
    Process.send_after(self(), :health_check, 30_000)
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
  def handle_cast(:reset_processing, state) do
    # Reset the processing flag
    {:noreply, %{state | processing: false}}
  end

  @impl true
  def handle_cast({:add_operation, operation, resource, priority}, state = %{queue: queue}) do
    # Check if this operation already exists in the queue
    if operation_exists_in_queue?(queue, operation, resource) do
      Logger.info(
        "Operation #{operation} for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]} already in queue, skipping"
      )

      {:noreply, state}
    else
      # Add operation to queue with priority (lower number = higher priority)
      new_queue = queue ++ [{priority, operation, resource}]
      # Sort by priority
      sorted_queue = Enum.sort(new_queue, fn {p1, _, _}, {p2, _, _} -> p1 <= p2 end)

      Logger.debug(
        "Added operation to queue: #{operation} for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]} with priority #{priority}"
      )

      # Create a concise representation of the queue for logging
      queue_summary =
        Enum.map(sorted_queue, fn {p, op, res} ->
          "#{op} for #{res["metadata"]["namespace"]}/#{res["metadata"]["name"]} (priority: #{p})"
        end)
        |> Enum.join(", ")

      Logger.debug("Current queue: #{queue_summary}")

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
  end

  defp operation_exists_in_queue?(queue, operation, resource) do
    Enum.any?(queue, fn {_, op, res} ->
      op == operation &&
        res["metadata"]["name"] == resource["metadata"]["name"] &&
        res["metadata"]["namespace"] == resource["metadata"]["namespace"]
    end)
  end

  # Handle the process_queue message
  @impl true
  def handle_info(:process_queue, state) do
    queue_length = length(state.queue)
    Logger.debug("CoordinatorAgent processing queue - Items remaining: #{queue_length}")

    # Log the current queue contents in a concise format
    if queue_length > 0 do
      queue_summary =
        Enum.map(state.queue, fn {p, op, res} ->
          "#{op} for #{res["metadata"]["namespace"]}/#{res["metadata"]["name"]} (priority: #{p})"
        end)
        |> Enum.join(", ")

      Logger.debug("Queue contents: #{queue_summary}")
    end

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

  # Handle health check message
  @impl true
  def handle_info(:health_check, state) do
    # Schedule the next health check
    schedule_health_check()

    # Check if there are items in the queue but processing is stuck
    if length(state.queue) > 0 and state.processing do
      # Check how long the processing flag has been set
      # For now, just log and reset the processing flag
      Logger.warning("Queue processing appears to be stuck. Resetting processing flag.")

      # Reset the processing flag and restart queue processing
      Process.send_after(self(), :process_queue, 100)
      {:noreply, %{state | processing: false}}
    else
      {:noreply, state}
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

  defp process_next_operation(%{queue: [{priority, operation, resource} | rest]}) do
    Logger.info(
      "Processing operation: #{operation} for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]} (priority: #{priority})"
    )

    try do
      # Call the appropriate function in SleepSchedule module
      result =
        case operation do
          :scale_down_statefulsets ->
            Logger.debug(
              "Scaling down StatefulSets for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]}"
            )

            Drowzee.K8s.SleepSchedule.scale_down_statefulsets(resource)

          :scale_down_deployments ->
            Logger.debug(
              "Scaling down Deployments for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]}"
            )

            Drowzee.K8s.SleepSchedule.scale_down_deployments(resource)

          :suspend_cronjobs ->
            Logger.debug(
              "Suspending CronJobs for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]}"
            )

            Drowzee.K8s.SleepSchedule.suspend_cronjobs(resource)

          :scale_up_statefulsets ->
            Logger.debug(
              "Scaling up StatefulSets for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]}"
            )

            Drowzee.K8s.SleepSchedule.scale_up_statefulsets(resource)

          :scale_up_deployments ->
            Logger.debug(
              "Scaling up Deployments for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]}"
            )

            Drowzee.K8s.SleepSchedule.scale_up_deployments(resource)

          :resume_cronjobs ->
            Logger.debug(
              "Resuming CronJobs for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]}"
            )

            Drowzee.K8s.SleepSchedule.resume_cronjobs(resource)
        end

      # Log the result - concise info, detailed debug
      Logger.info(
        "Completed #{operation} for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]}: #{elem(result, 0)}"
      )

      # Log the next operations in the queue
      rest_length = length(rest)

      if rest_length > 0 do
        next_summary =
          Enum.take(rest, min(3, rest_length))
          |> Enum.map(fn {p, op, res} ->
            name = res["metadata"]["name"] || "unknown"
            namespace = res["metadata"]["namespace"] || "unknown"
            "#{op} for #{namespace}/#{name} (priority: #{p})"
          end)
          |> Enum.join(", ")

        Logger.debug(
          "Next in queue (showing up to 3): #{next_summary}#{if rest_length > 3, do: " and #{rest_length - 3} more", else: ""}"
        )
      else
        Logger.debug("Queue will be empty after this operation")
      end

      Logger.debug("Operation details: #{operation}: #{inspect(result)}")

      # Return the new state with the operation removed from the queue
      {:ok, %{queue: rest, processing: true}}
    rescue
      e ->
        Logger.error(
          "Error processing operation #{operation} for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]}: #{inspect(e)}"
        )

        Logger.error("Stack trace: #{Exception.format_stacktrace(__STACKTRACE__)}")

        # Check if there are more operations in the queue
        rest_length = length(rest)

        if rest_length > 0 do
          Logger.info("Still #{rest_length} operations in queue after error")
        else
          Logger.info("Queue will be empty after this error")
        end

        {:error, e}
    catch
      kind, reason ->
        Logger.error(
          "Caught #{kind} while processing operation #{operation} for #{resource["metadata"]["namespace"]}/#{resource["metadata"]["name"]}: #{inspect(reason)}"
        )

        Logger.error("Stack trace: #{Exception.format_stacktrace(__STACKTRACE__)}")

        # Check if there are more operations in the queue
        rest_length = length(rest)

        if rest_length > 0 do
          Logger.info("Still #{rest_length} operations in queue after error")
        else
          Logger.info("Queue will be empty after this error")
        end

        {:error, reason}
    end
  end

  # Terminate callback for cleanup
  @impl true
  def terminate(reason, _state) do
    Logger.warning("CoordinatorAgent terminating: #{inspect(reason)}")
    :ok
  end
end
