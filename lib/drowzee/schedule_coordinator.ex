defmodule Drowzee.ScheduleCoordinator do
  @moduledoc """
  Per-schedule coordinator GenServer.

  Manages ordered execution of priority group operations for a single SleepSchedule.
  Started on-demand via DynamicSupervisor, registered in Registry by {namespace, name}.
  Terminates after processing all operations (`:temporary` restart).
  """
  use GenServer, restart: :temporary

  require Logger

  @readiness_poll_interval 5_000

  # --- Client API ---

  @doc """
  Starts a coordinator for the given schedule or returns :already_running.

  operations — list of operations:
    - {:scale_group, :up | :down, sleep_schedule, %{deployments: [...], statefulsets: [...], cronjobs: [...]}}
    - {:wait_ms, ms}
    - {:wait_for_ready, :up | :down, sleep_schedule, %{deployments: [...], statefulsets: [...]}, max_timeout_ms}

  opts — optional overrides for testability:
    - :scale_executor — fn(direction, sleep_schedule, names_map) -> result
    - :readiness_checker — fn(direction, sleep_schedule, names_map) -> boolean
  """
  def start_or_enqueue(namespace, name, operations, opts \\ []) do
    child_spec = %{
      id: {__MODULE__, namespace, name},
      start: {__MODULE__, :start_link, [{namespace, name, operations, opts}]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Drowzee.ScheduleSupervisor, child_spec) do
      {:ok, pid} ->
        Logger.info("Started coordinator for #{namespace}/#{name}", pid: inspect(pid))
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Coordinator already running for #{namespace}/#{name}", pid: inspect(pid))
        {:already_running, pid}

      {:error, reason} ->
        Logger.error("Failed to start coordinator for #{namespace}/#{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def start_link({namespace, name, operations, opts}) do
    GenServer.start_link(
      __MODULE__,
      %{operations: operations, opts: opts, namespace: namespace, name: name},
      name: via(namespace, name)
    )
  end

  defp via(namespace, name) do
    {:via, Registry, {Drowzee.ScheduleRegistry, {namespace, name}}}
  end

  # --- Server ---

  @impl true
  def init(%{operations: operations, opts: opts, namespace: namespace, name: name}) do
    Logger.metadata(schedule: name, namespace: namespace)
    Logger.info("Coordinator starting with #{length(operations)} operations")

    state = %{
      queue: operations,
      namespace: namespace,
      name: name,
      scale_executor: Keyword.get(opts, :scale_executor, &default_scale_executor/3),
      readiness_checker: Keyword.get(opts, :readiness_checker, &default_readiness_checker/3),
      poll_interval: Keyword.get(opts, :poll_interval, @readiness_poll_interval)
    }

    {:ok, state, {:continue, :process_next}}
  end

  @impl true
  def handle_continue(:process_next, %{queue: []} = state) do
    Logger.info("All operations complete, coordinator stopping")
    {:stop, :normal, state}
  end

  def handle_continue(:process_next, %{queue: [{:wait_ms, ms} | rest]} = state) do
    Logger.debug("Waiting #{ms}ms before next operation")
    Process.send_after(self(), :continue, ms)
    {:noreply, %{state | queue: rest}}
  end

  def handle_continue(:process_next, %{queue: [{:wait_for_ready, direction, schedule, names, max_ms} | rest]} = state) do
    Logger.info("Starting readiness poll (direction=#{direction}, max_timeout=#{max_ms}ms)")
    start_time = System.monotonic_time(:millisecond)
    send(self(), {:check_readiness, direction, schedule, names, start_time, max_ms})
    {:noreply, %{state | queue: rest}}
  end

  def handle_continue(:process_next, %{queue: [{:scale_group, direction, sleep_schedule, names} | rest]} = state) do
    Logger.info("Executing scale_group (direction=#{direction})")
    state.scale_executor.(direction, sleep_schedule, names)
    {:noreply, %{state | queue: rest}, {:continue, :process_next}}
  end

  @impl true
  def handle_info(:continue, state) do
    {:noreply, state, {:continue, :process_next}}
  end

  def handle_info({:check_readiness, direction, schedule, names, start_time, max_ms}, state) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    cond do
      elapsed >= max_ms ->
        Logger.warning("Readiness timeout after #{elapsed}ms (max #{max_ms}ms), proceeding")
        {:noreply, state, {:continue, :process_next}}

      state.readiness_checker.(direction, schedule, names) ->
        Logger.info("All resources ready after #{elapsed}ms, proceeding")
        {:noreply, state, {:continue, :process_next}}

      true ->
        poll_ms = state.poll_interval
        Logger.debug("Resources not ready yet (#{elapsed}ms elapsed), polling again in #{poll_ms}ms")
        Process.send_after(self(), {:check_readiness, direction, schedule, names, start_time, max_ms}, poll_ms)
        {:noreply, state}
    end
  end

  # --- Default implementations (production) ---

  defp default_scale_executor(direction, sleep_schedule, names) do
    alias Drowzee.K8s.SleepSchedule, as: SS

    case direction do
      :up -> SS.scale_up_group(sleep_schedule, names)
      :down -> SS.scale_down_group(sleep_schedule, names)
    end
  end

  defp default_readiness_checker(direction, sleep_schedule, names) do
    namespace = sleep_schedule["metadata"]["namespace"]
    dep_names = Map.get(names, :deployments, [])
    sts_names = Map.get(names, :statefulsets, [])

    deps_ready = check_resources_ready(dep_names, namespace, &Drowzee.K8s.get_deployment/2, direction)
    sts_ready = check_resources_ready(sts_names, namespace, &Drowzee.K8s.get_statefulset/2, direction)

    deps_ready and sts_ready
  end

  defp check_resources_ready(names, namespace, get_fn, direction) do
    Enum.all?(names, fn name ->
      case get_fn.(name, namespace) do
        {:ok, resource} ->
          case direction do
            :up ->
              ready = resource["status"]["readyReplicas"] || 0
              desired = resource["spec"]["replicas"] || 0
              ready >= desired

            :down ->
              current = resource["status"]["replicas"] || 0
              current == 0
          end

        {:error, reason} ->
          Logger.warning("Failed to check readiness for #{namespace}/#{name}: #{inspect(reason)}")
          false
      end
    end)
  end
end
