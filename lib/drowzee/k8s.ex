defmodule Drowzee.K8s do
  require Logger

  def sleep_schedule_list(namespace \\ nil) do
    K8s.Client.list("drowzee.challengr.io/v1beta1", "SleepSchedule", namespace: namespace)
    |> K8s.Client.put_conn(conn())
    |> K8s.Client.run()
  end

  def sleep_schedules(namespace \\ nil) do
    case sleep_schedule_list(namespace) do
      {:ok, list} -> list["items"]
      {:error, _error} -> []
    end
  end

  def get_sleep_schedule(name, namespace) do
    K8s.Client.get("drowzee.challengr.io/v1beta1", "SleepSchedule",
      name: name,
      namespace: namespace
    )
    |> K8s.Client.put_conn(conn())
    |> K8s.Client.run()
  end

  def get_sleep_schedule!(name, namespace) do
    {:ok, sleep_schedule} = get_sleep_schedule(name, namespace)
    sleep_schedule
  end

  def manual_wake_up(sleep_schedule) do
    Drowzee.K8s.SleepSchedule.put_condition(
      sleep_schedule,
      "ManualOverride",
      true,
      "WakeUp",
      "Force deployments to wake up"
    )
    # Make sure we handle the modify event rather then wait for a reconcile
    |> decrement_observed_generation()
    |> Bonny.Resource.apply_status(conn(), force: true)
  end

  def manual_sleep(sleep_schedule) do
    Drowzee.K8s.SleepSchedule.put_condition(
      sleep_schedule,
      "ManualOverride",
      true,
      "Sleep",
      "Force deployments to sleep"
    )
    # Make sure we handle the modify event rather then wait for a reconcile
    |> decrement_observed_generation()
    |> Bonny.Resource.apply_status(conn(), force: true)
  end

  def remove_override(sleep_schedule) do
    Drowzee.K8s.SleepSchedule.put_condition(
      sleep_schedule,
      "ManualOverride",
      false,
      "NoOverride",
      "No manual override in effect"
    )
    # Make sure we handle the modify event rather then wait for a reconcile
    |> decrement_observed_generation()
    |> Bonny.Resource.apply_status(conn(), force: true)
  end

  def decrement_observed_generation(resource) do
    generation = get_in(resource, [Access.key("status", %{}), "observedGeneration"]) || 1
    put_in(resource, [Access.key("status", %{}), "observedGeneration"], generation - 1)
  end

  def conn() do
    Drowzee.K8sConn.get!()
  end

  def get_drowzee_ingress() do
    name = "drowzee"
    namespace = drowzee_namespace()
    Logger.debug("Fetching drowzee ingress", name: name, drowzee_namespace: namespace)

    K8s.Client.get("networking.k8s.io/v1", :ingress, name: name, namespace: namespace)
    |> K8s.Client.put_conn(conn())
    |> K8s.Client.run()
  end

  @default_service_account_path "/var/run/secrets/kubernetes.io/serviceaccount"

  def drowzee_namespace() do
    namespace_path = Path.join(@default_service_account_path, "namespace")

    case File.read(namespace_path) do
      {:ok, namespace} -> namespace
      _ -> Application.get_env(:drowzee, :drowzee_namespace, "default")
    end
  end

  def get_deployment(name, namespace) do
    Logger.debug("Fetching deployment", name: name)

    K8s.Client.get("apps/v1", :deployment, name: name, namespace: namespace)
    |> K8s.Client.put_conn(conn())
    |> K8s.Client.run()
  end

  def get_statefulset(name, namespace) do
    Logger.debug("Fetching statefulset", name: name)

    K8s.Client.get("apps/v1", :statefulset, name: name, namespace: namespace)
    |> K8s.Client.put_conn(conn())
    |> K8s.Client.run()
  end

  def get_cronjob(name, namespace) do
    Logger.debug("Fetching cronjob", name: name)

    K8s.Client.get("batch/v1", :cronjob, name: name, namespace: namespace)
    |> K8s.Client.put_conn(conn())
    |> K8s.Client.run()
  end

  # List all CronJobs in a namespace
  def list_cronjobs(namespace) do
    Logger.debug("Listing all cronjobs in namespace", namespace: namespace)

    K8s.Client.list("batch/v1", :cronjob, namespace: namespace)
    |> K8s.Client.put_conn(conn())
    |> K8s.Client.run()
  end

  # Get a CronJob with support for wildcard matching
  def get_cronjob_with_wildcard(name_info, namespace) do
    name = name_info["name"]
    is_wildcard = name_info["is_wildcard"]

    if is_wildcard do
      prefix = Drowzee.K8s.SleepSchedule.get_wildcard_prefix(name)

      case list_cronjobs(namespace) do
        {:ok, cronjob_list} ->
          # Filter CronJobs that match the prefix
          matching_cronjobs =
            cronjob_list["items"]
            |> Enum.filter(fn cronjob ->
              cronjob_name = cronjob["metadata"]["name"]
              String.starts_with?(cronjob_name, prefix)
            end)

          case matching_cronjobs do
            [] ->
              # No matches
              {:error,
               %{
                 reason: "NoMatchingCronJob",
                 message: "No CronJobs found matching pattern #{name}"
               }}

            [single_match] ->
              # Exactly one match - success
              resolved_name = single_match["metadata"]["name"]
              {:ok, single_match, resolved_name}

            multiple_matches ->
              # Multiple matches - error
              matched_names = Enum.map(multiple_matches, & &1["metadata"]["name"])
              names_string = Enum.join(matched_names, ", ")

              {:error,
               %{
                 reason: "MultipleMatchingCronJobs",
                 message: "Wildcard #{name} matched multiple CronJobs: #{names_string}"
               }}
          end

        {:error, reason} ->
          {:error,
           %{
             reason: "ListCronJobsError",
             message: "Error listing CronJobs: #{inspect(reason)}"
           }}
      end
    else
      # For exact name, use existing approach
      case get_cronjob(name, namespace) do
        {:ok, cronjob} ->
          # For non-wildcard, resolved name is the same as the original name
          {:ok, cronjob, name}

        {:error, reason} ->
          {:error,
           %{
             reason: "CronJobNotFound",
             message: "CronJob not found: #{inspect(reason)}"
           }}
      end
    end
  end

  def update_sleep_schedule(sleep_schedule) do
    Drowzee.K8s.SleepSchedule.update_sleep_schedule(sleep_schedule)
  end

  # Get deployments for a sleep schedule
  def get_deployments_for_schedule(sleep_schedule) do
    namespace = sleep_schedule["metadata"]["namespace"]
    deployment_names = get_in(sleep_schedule, ["spec", "deployments"]) || []

    deployment_names
    |> Enum.map(fn deployment ->
      name = deployment["name"]

      case get_deployment(name, namespace) do
        {:ok, deployment} -> deployment
        {:error, _} -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  # Get statefulsets for a sleep schedule
  def get_statefulsets_for_schedule(sleep_schedule) do
    namespace = sleep_schedule["metadata"]["namespace"]
    statefulset_names = get_in(sleep_schedule, ["spec", "statefulsets"]) || []

    statefulset_names
    |> Enum.map(fn statefulset ->
      name = statefulset["name"]

      case get_statefulset(name, namespace) do
        {:ok, statefulset} -> statefulset
        {:error, _} -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  # Get cronjobs for a sleep schedule
  def get_cronjobs_for_schedule(sleep_schedule) do
    namespace = sleep_schedule["metadata"]["namespace"]
    cronjob_name_infos = Drowzee.K8s.SleepSchedule.cronjob_names(sleep_schedule)

    # Check for cached resolved names
    resolved_names_map = get_resolved_wildcard_names(sleep_schedule)

    # Process each cronjob name
    {cronjobs, resolved_names_updates} =
      cronjob_name_infos
      |> Enum.reduce({[], %{}}, fn name_info, {cronjobs_acc, resolved_names_acc} ->
        original_name = name_info["name"]
        is_wildcard = name_info["is_wildcard"]

        # If it's a wildcard and we have a cached resolved name, try that first
        if is_wildcard && Map.has_key?(resolved_names_map, original_name) do
          cached_name = resolved_names_map[original_name]

          # Try to get the cronjob using the cached name
          case get_cronjob(cached_name, namespace) do
            {:ok, cronjob} ->
              # Cache hit - use the cached resolved name
              {[cronjob | cronjobs_acc], resolved_names_acc}

            {:error, _} ->
              # Cache miss - the cached cronjob no longer exists, try wildcard resolution
              case get_cronjob_with_wildcard(name_info, namespace) do
                {:ok, cronjob, resolved_name} ->
                  # Found a new match, update the cache
                  {[cronjob | cronjobs_acc],
                   Map.put(resolved_names_acc, original_name, resolved_name)}

                {:error, _} ->
                  # No match found, don't update cache
                  {cronjobs_acc, resolved_names_acc}
              end
          end
        else
          # No cached name or not a wildcard, do normal resolution
          case get_cronjob_with_wildcard(name_info, namespace) do
            {:ok, cronjob, resolved_name} ->
              # If it's a wildcard, store the resolved name
              new_resolved_names =
                if is_wildcard do
                  Map.put(resolved_names_acc, original_name, resolved_name)
                else
                  resolved_names_acc
                end

              {[cronjob | cronjobs_acc], new_resolved_names}

            {:error, _} ->
              {cronjobs_acc, resolved_names_acc}
          end
        end
      end)

    # If we have new resolved names, update the sleep schedule
    unless Enum.empty?(resolved_names_updates) do
      # Merge with existing resolved names
      updated_resolved_names = Map.merge(resolved_names_map, resolved_names_updates)

      # Update the sleep schedule with the new resolved names
      update_resolved_wildcard_names(sleep_schedule, updated_resolved_names)
    end

    cronjobs
  end

  # Get the resolved wildcard names from the sleep schedule annotations
  defp get_resolved_wildcard_names(sleep_schedule) do
    annotations = get_in(sleep_schedule, ["metadata", "annotations"]) || %{}
    resolved_names_json = Map.get(annotations, "drowzee.io/resolved-wildcard-names")

    if resolved_names_json do
      case Jason.decode(resolved_names_json) do
        {:ok, resolved_names} -> resolved_names
        _ -> %{}
      end
    else
      %{}
    end
  end

  # Update the resolved wildcard names annotation on the sleep schedule
  defp update_resolved_wildcard_names(sleep_schedule, resolved_names) do
    # Convert to JSON
    {:ok, resolved_names_json} = Jason.encode(resolved_names)

    # Update the annotation
    sleep_schedule =
      Drowzee.K8s.SleepSchedule.ensure_annotations(sleep_schedule)
      |> put_in(
        ["metadata", "annotations", "drowzee.io/resolved-wildcard-names"],
        resolved_names_json
      )

    # Update the sleep schedule in Kubernetes
    update_sleep_schedule(sleep_schedule)
  end
end
