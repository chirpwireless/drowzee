defmodule DrowzeeWeb.HomeLive.Index do
  use DrowzeeWeb, :live_view

  require Logger
  import Drowzee.K8s.SleepSchedule

  # Refresh interval in milliseconds (5 minutes)
  @refresh_interval 300_000

  # Performance optimization: precompute dependency relationships
  defp precompute_dependency_data(sleep_schedules) do
    # Create lookup maps for O(1) access
    schedule_lookup =
      sleep_schedules
      |> Enum.map(fn schedule ->
        key = "#{schedule["metadata"]["namespace"]}/#{schedule["metadata"]["name"]}"
        {key, schedule}
      end)
      |> Map.new()

    # Precompute reverse dependencies (who depends on whom)
    reverse_deps =
      sleep_schedules
      |> Enum.reduce(%{}, fn schedule, acc ->
        needs = schedule["spec"]["needs"] || []

        Enum.reduce(needs, acc, fn need, inner_acc ->
          dependency_key = "#{need["namespace"]}/#{need["name"]}"
          dependent_key = "#{schedule["metadata"]["namespace"]}/#{schedule["metadata"]["name"]}"

          Map.update(inner_acc, dependency_key, [dependent_key], fn existing ->
            [dependent_key | existing]
          end)
        end)
      end)

    # Precompute dependency status for each schedule
    dependency_status =
      sleep_schedules
      |> Enum.map(fn schedule ->
        key = "#{schedule["metadata"]["namespace"]}/#{schedule["metadata"]["name"]}"
        needs = schedule["spec"]["needs"] || []

        resolved_deps =
          needs
          |> Enum.map(fn need ->
            dep_key = "#{need["namespace"]}/#{need["name"]}"
            case Map.get(schedule_lookup, dep_key) do
              nil ->
                %{
                  name: need["name"],
                  namespace: need["namespace"],
                  status: "not_found",
                  display: "Not found"
                }
              dep_schedule ->
                sleeping_condition = get_condition(dep_schedule, "Sleeping")
                is_sleeping = sleeping_condition["status"] == "True"
                %{
                  name: need["name"],
                  namespace: need["namespace"],
                  status: if(is_sleeping, do: "sleeping", else: "awake"),
                  display: if(is_sleeping, do: "Currently sleeping", else: "Currently awake")
                }
            end
          end)

        {key, resolved_deps}
      end)
      |> Map.new()

    %{
      schedule_lookup: schedule_lookup,
      reverse_deps: reverse_deps,
      dependency_status: dependency_status
    }
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to PubSub updates
      Phoenix.PubSub.subscribe(Drowzee.PubSub, "sleep_schedule:updates")

      # Schedule periodic refresh to prevent connection issues
      Process.send_after(self(), :refresh_schedules, @refresh_interval)
    end

    socket =
      socket
      |> assign(:namespace, nil)
      |> assign(:name, nil)
      |> assign(:search, "")
      |> assign(:filtered_sleep_schedules, nil)
      |> assign(:visible_schedules, MapSet.new())
      |> load_sleep_schedules()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"namespace" => namespace, "name" => name}, _url, socket) do
    socket =
      socket
      |> assign(:page_title, "#{namespace} / #{name}")
      |> assign(:namespace, namespace)
      |> assign(:name, name)
      |> load_sleep_schedules()

    {:noreply, socket}
  end

  @impl true
  def handle_params(%{"namespace" => namespace}, _url, socket) do
    socket =
      socket
      |> assign(:page_title, "#{namespace}")
      |> assign(:namespace, namespace)
      |> load_sleep_schedules()

    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    socket =
      socket
      |> assign(:page_title, "All Namespaces")
      |> load_sleep_schedules()

    {:noreply, socket}
  end

  @impl true
  def handle_event("wake_schedule", %{"name" => name, "namespace" => namespace}, socket) do
    sleep_schedule = Drowzee.K8s.get_sleep_schedule!(name, namespace)

    socket =
      case Drowzee.K8s.manual_wake_up(sleep_schedule) do
        {:ok, sleep_schedule} ->
          # Note: Bit of a hack to make the UI update immediately rather than waiting for the controller to handle the ManualOverride action
          sleep_schedule =
            Drowzee.K8s.SleepSchedule.put_condition(
              sleep_schedule,
              "Transitioning",
              "True",
              "WakingUp",
              "Waking up"
            )

          replace_sleep_schedule(socket, sleep_schedule)

        {:error, error} ->
          socket
          |> load_sleep_schedules()
          |> put_flash(:error, "Failed to wake up #{name}: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("sleep_schedule", %{"name" => name, "namespace" => namespace}, socket) do
    sleep_schedule = Drowzee.K8s.get_sleep_schedule!(name, namespace)

    socket =
      case Drowzee.K8s.manual_sleep(sleep_schedule) do
        {:ok, sleep_schedule} ->
          # Note: Bit of a hack to make the UI update immediately rather than waiting for the controller to handle the ManualOverride action
          sleep_schedule =
            Drowzee.K8s.SleepSchedule.put_condition(
              sleep_schedule,
              "Transitioning",
              "True",
              "Sleeping",
              "Going to sleep"
            )

          replace_sleep_schedule(socket, sleep_schedule)

        {:error, error} ->
          socket
          |> load_sleep_schedules()
          |> put_flash(:error, "Failed to sleep #{name}: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_override", %{"name" => name, "namespace" => namespace}, socket) do
    sleep_schedule = Drowzee.K8s.get_sleep_schedule!(name, namespace)

    socket =
      case Drowzee.K8s.remove_override(sleep_schedule) do
        {:ok, sleep_schedule} ->
          replace_sleep_schedule(socket, sleep_schedule)

        {:error, error} ->
          socket
          |> load_sleep_schedules()
          |> put_flash(:error, "Failed to sleep #{name}: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_enabled", %{"name" => name, "namespace" => namespace}, socket) do
    sleep_schedule = Drowzee.K8s.get_sleep_schedule!(name, namespace)
    new_enabled = not Map.get(sleep_schedule["spec"], "enabled", true)

    updated_sleep_schedule =
      put_in(sleep_schedule, ["spec", "enabled"], new_enabled)
      |> Drowzee.K8s.update_sleep_schedule()
      |> case do
        {:ok, s} -> s
        {:error, _} -> sleep_schedule
      end

    socket = replace_sleep_schedule(socket, updated_sleep_schedule)
    {:noreply, socket}
  end

  @impl true
  def handle_event("sleep_all_schedules", %{"namespace" => namespace}, socket)
      when is_binary(namespace) do
    sleep_schedules = Drowzee.K8s.sleep_schedules(namespace)

    results =
      Enum.map(sleep_schedules, fn sleep_schedule ->
        Drowzee.K8s.manual_sleep(sleep_schedule)
      end)

    # Wait a second before reloading all the schedules
    Process.sleep(1000)
    socket = load_sleep_schedules(socket)

    has_error =
      Enum.any?(results, fn
        {:error, _error} -> true
        _ -> false
      end)

    socket =
      if has_error,
        do: put_flash(socket, :error, "Failed to sleep at least one schedule"),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("wake_all_schedules", %{"namespace" => namespace}, socket)
      when is_binary(namespace) do
    sleep_schedules = Drowzee.K8s.sleep_schedules(namespace)

    results =
      Enum.map(sleep_schedules, fn sleep_schedule ->
        Drowzee.K8s.manual_wake_up(sleep_schedule)
      end)

    # Wait a second before reloading all the schedules
    Process.sleep(1000)
    socket = load_sleep_schedules(socket)

    has_error =
      Enum.any?(results, fn
        {:error, _error} -> true
        _ -> false
      end)

    socket =
      if has_error,
        do: put_flash(socket, :error, "Failed to wake up at least one schedule"),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_resources", %{"id" => schedule_id}, socket) do
    visible_schedules = socket.assigns.visible_schedules

    updated_visible_schedules =
      if MapSet.member?(visible_schedules, schedule_id) do
        MapSet.delete(visible_schedules, schedule_id)
      else
        MapSet.put(visible_schedules, schedule_id)
      end

    {:noreply, assign(socket, :visible_schedules, updated_visible_schedules)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    socket =
      socket
      |> assign(:search, search)
      |> filter_sleep_schedules(search)

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_search", _, socket) do
    socket =
      socket
      |> assign(:search, "")
      |> assign(:filtered_sleep_schedules, nil)

    {:noreply, socket}
  end

  defp filter_sleep_schedules(socket, nil) do
    assign(socket, :filtered_sleep_schedules, nil)
  end

  defp filter_sleep_schedules(socket, "") do
    assign(socket, :filtered_sleep_schedules, nil)
  end

  defp filter_sleep_schedules(socket, search) do
    search = String.downcase(search)

    filtered_sleep_schedules =
      Enum.filter(socket.assigns.sleep_schedules, fn sleep_schedule ->
        String.contains?(sleep_schedule["metadata"]["name"], search) ||
          String.contains?(sleep_schedule["metadata"]["namespace"], search)
      end)

    assign(socket, :filtered_sleep_schedules, filtered_sleep_schedules)
  end

  @impl true
  @spec handle_info({:sleep_schedule_updated}, map()) :: {:noreply, map()}
  def handle_info({:sleep_schedule_updated}, socket) do
    Logger.debug("LiveView: Received sleep schedule update")
    {:noreply, load_sleep_schedules(socket)}
  end

  @impl true
  def handle_info(:refresh_schedules, socket) do
    Logger.debug("LiveView: Performing periodic refresh of sleep schedules")

    # Schedule the next refresh
    if connected?(socket) do
      Process.send_after(self(), :refresh_schedules, @refresh_interval)
    end

    # Reload the schedules
    {:noreply, load_sleep_schedules(socket)}
  end

  defp load_sleep_schedules(socket) do
    # Fetch sleep schedules based on the current view
    {sleep_schedules, deployments_by_name, statefulsets_by_name, cronjobs_by_name,
     missing_resources,
     resolved_wildcard_names} =
      case {socket.assigns.namespace, socket.assigns.name} do
        # Main page: fetch all sleep schedules
        {nil, nil} ->
          {Drowzee.K8s.sleep_schedules(:all), %{}, %{}, %{}, [], %{}}

        # Namespace page: fetch schedules for the namespace
        {namespace, nil} ->
          {Drowzee.K8s.sleep_schedules(namespace), %{}, %{}, %{}, [], %{}}

        # Schedule page: fetch a specific schedule and its resources
        {namespace, name} ->
          # Fetch the specific schedule
          schedules =
            case Drowzee.K8s.get_sleep_schedule(name, namespace) do
              {:ok, schedule} -> [schedule]
              {:error, _} -> []
            end

          # Only fetch resources if we have a specific schedule
          {deployments, statefulsets, cronjobs, missing_resources} =
            case schedules do
              [schedule] ->
                try do
                  # Get missing resources
                  missing = get_missing_resources(schedule)

                  # Get deployments, statefulsets and cronjobs
                  deps = Drowzee.K8s.get_deployments_for_schedule(schedule)
                  sts = Drowzee.K8s.get_statefulsets_for_schedule(schedule)
                  cjs = Drowzee.K8s.get_cronjobs_for_schedule(schedule)

                  # Return all resources
                  {deps, sts, cjs, missing}
                rescue
                  e ->
                    # Log the error and continue with empty values
                    Logger.error("Error fetching resources for sleep schedule: #{inspect(e)}")
                    {[], [], [], []}
                end

              _ ->
                # No schedules found
                {[], [], [], []}
            end

          # Create maps for each resource type
          deps_by_name = Map.new(deployments, &{&1["metadata"]["name"], &1})
          sts_by_name = Map.new(statefulsets, &{&1["metadata"]["name"], &1})

          # Create a map of CronJob names to CronJobs
          cjs_by_name = Map.new(cronjobs, &{&1["metadata"]["name"], &1})

          # Extract resolved wildcard names from schedules
          resolved_wildcard_names =
            case schedules do
              [schedule] ->
                annotations = get_in(schedule, ["metadata", "annotations"]) || %{}
                resolved_names_json = Map.get(annotations, "drowzee.io/resolved-wildcard-names")

                if resolved_names_json do
                  case Jason.decode(resolved_names_json) do
                    {:ok, resolved_names} -> resolved_names
                    _ -> %{}
                  end
                else
                  %{}
                end

              _ ->
                %{}
            end

          # Return the schedules and resource maps
          {schedules, deps_by_name, sts_by_name, cjs_by_name, missing_resources,
           resolved_wildcard_names}
      end

    # Handle namespace statuses based on the current view
    # Use a single API call approach to improve performance
    {all_namespaces, namespace_statuses, current_namespace_status} =
      cond do
        # On main page: fetch all schedules once and calculate everything
        socket.assigns.namespace == nil ->
          # Get all schedules for the main page (single API call)
          all_schedules = Drowzee.K8s.sleep_schedules(:all)

          # Extract unique namespaces
          namespaces =
            all_schedules
            |> Enum.map(fn schedule -> schedule["metadata"]["namespace"] end)
            |> Enum.uniq()
            |> Enum.sort()

          # Calculate all namespace statuses at once
          {namespaces, calculate_namespace_statuses(all_schedules), nil}

        # On namespace page: we already have the schedules from above
        true ->
          # Reuse the already fetched schedules to calculate namespace status
          # This avoids an additional API call
          {[], %{}, calculate_namespace_status(sleep_schedules)}
      end

    # Precompute dependency relationships
    dependency_data = precompute_dependency_data(sleep_schedules)

    socket
    |> assign(:sleep_schedules, sleep_schedules)
    |> assign(:all_namespaces, all_namespaces)
    |> assign(:namespace_statuses, namespace_statuses)
    |> assign(:current_namespace_status, current_namespace_status)
    |> assign(:deployments_by_name, deployments_by_name)
    |> assign(:statefulsets_by_name, statefulsets_by_name)
    |> assign(:cronjobs_by_name, cronjobs_by_name)
    |> assign(:missing_resources, missing_resources)
    |> assign(:resolved_wildcard_names, resolved_wildcard_names)
    |> assign(:dependency_data, dependency_data)
    |> assign(:loading, false)
    |> filter_sleep_schedules(socket.assigns.search)
  end

  def sleep_schedule_host(sleep_schedule) do
    (sleep_schedule["status"]["hosts"] || []) |> List.first()
  end

  def condition_class(sleep_schedule, type) do
    if get_condition(sleep_schedule, type)["status"] == "True" do
      "text-green-600"
    else
      "text-red-600"
    end
  end

  def last_transaction_time(sleep_schedule, type) do
    get_condition(sleep_schedule, type)["lastTransitionTime"]
    |> Timex.parse!("{ISO:Extended}")
    |> Timex.to_datetime(sleep_schedule["spec"]["timezone"])
    |> Timex.format!("{h12}:{m}{am}")
  end

  def format_day_of_week(day_of_week) do
    cond do
      day_of_week in ["*", "", nil] ->
        "ALL DAYS"

      String.match?(day_of_week, ~r/^\d/) ->
        # Handle numeric format (0,6 or 1-5)
        day_of_week
        |> String.split([",", "-"])
        |> Enum.map(fn d ->
          case d do
            "0" -> "SUN"
            "1" -> "MON"
            "2" -> "TUE"
            "3" -> "WED"
            "4" -> "THU"
            "5" -> "FRI"
            "6" -> "SAT"
            _ -> d
          end
        end)
        |> Enum.join(", ")
        |> String.replace(", ", "-", global: false)

      true ->
        # Handle text format (MON-FRI or SUN,SAT)
        String.upcase(day_of_week)
    end
  end

  # Calculate the status for a single namespace based on its schedules
  defp calculate_namespace_status([]), do: "disabled"

  defp calculate_namespace_status(schedules) do
    # Filter enabled schedules first - use pattern matching for better performance
    enabled_schedules = Enum.reject(schedules, &(Map.get(&1["spec"], "enabled") == false))

    # Early return if no enabled schedules
    if enabled_schedules == [] do
      "disabled"
    else
      # Check sleeping status - use fast enumeration with early termination
      # First check if any schedule is awake (not sleeping)
      case Enum.find(enabled_schedules, fn schedule ->
             get_condition(schedule, "Sleeping")["status"] != "True"
           end) do
        # If we found an awake schedule
        %{} ->
          # Check if any schedule is sleeping
          case Enum.find(enabled_schedules, fn schedule ->
                 get_condition(schedule, "Sleeping")["status"] == "True"
               end) do
            # If we found a sleeping schedule, it's mixed
            %{} -> "mixed"
            # If no sleeping schedules found, all are awake
            nil -> "awake"
          end

        # If we didn't find any awake schedule, all are sleeping
        nil ->
          "sleeping"
      end
    end
  end

  # Calculate the status of each namespace based on its schedules
  defp calculate_namespace_statuses(schedules) do
    # Group schedules by namespace - use for_reduce for better performance
    schedules
    |> Enum.reduce(%{}, fn schedule, acc ->
      namespace = schedule["metadata"]["namespace"]
      schedules_list = Map.get(acc, namespace, [])
      Map.put(acc, namespace, [schedule | schedules_list])
    end)
    |> Enum.map(fn {namespace, ns_schedules} ->
      # Reuse the calculate_namespace_status function
      {namespace, calculate_namespace_status(ns_schedules)}
    end)
    |> Map.new()
  end

  # Extract missing resources from the sleep schedule annotation
  def get_missing_resources(sleep_schedule) do
    annotations = get_in(sleep_schedule, ["metadata", "annotations"]) || %{}
    missing_resources_json = Map.get(annotations, "drowzee.io/missing-resources")

    if missing_resources_json do
      case Jason.decode(missing_resources_json) do
        {:ok, resources} -> resources
        _ -> []
      end
    else
      []
    end
  end

  # Check if a resource is missing based on the missing_resources list
  def resource_missing?(missing_resources, kind, name) do
    Enum.any?(missing_resources, fn resource ->
      resource["kind"] == kind && resource["name"] == name
    end)
  end

  def replace_sleep_schedule(socket, updated_sleep_schedule) do
    sleep_schedules =
      Enum.map(socket.assigns.sleep_schedules, fn sleep_schedule ->
        if sleep_schedule["metadata"]["name"] == updated_sleep_schedule["metadata"]["name"] &&
             sleep_schedule["metadata"]["namespace"] ==
               updated_sleep_schedule["metadata"]["namespace"] do
          updated_sleep_schedule
        else
          sleep_schedule
        end
      end)

    assign(socket, :sleep_schedules, sleep_schedules)
  end
end
