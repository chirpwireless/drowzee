defmodule Drowzee.K8s.SleepSchedule do
  use Retry.Annotation

  require Logger

  alias Drowzee.K8s.{CronJob, Ingress, Condition}

  def name(sleep_schedule) do
    sleep_schedule["metadata"]["name"]
  end

  def namespace(sleep_schedule) do
    sleep_schedule["metadata"]["namespace"]
  end

  def deployment_names(sleep_schedule) do
    Logger.debug("Deployment entries: #{inspect(sleep_schedule["spec"]["deployments"])}")

    (sleep_schedule["spec"]["deployments"] || [])
    |> Enum.map(& &1["name"])
  end

  def statefulset_names(sleep_schedule) do
    Logger.debug("Statefulsets entries: #{inspect(sleep_schedule["spec"]["statefulsets"])}")

    (sleep_schedule["spec"]["statefulsets"] || [])
    |> Enum.map(& &1["name"])
  end

  # Helper function to check if a name contains a wildcard (suffix only)
  def is_wildcard_name?(name) do
    String.ends_with?(name, "*")
  end

  # Helper function to get the prefix from a wildcard name
  def get_wildcard_prefix(name) do
    String.replace_suffix(name, "*", "")
  end

  # Ensure that the sleep schedule has an annotations field
  def ensure_annotations(sleep_schedule) do
    metadata = sleep_schedule["metadata"] || %{}
    annotations = metadata["annotations"] || %{}

    sleep_schedule
    |> put_in(["metadata"], metadata)
    |> put_in(["metadata", "annotations"], annotations)
  end

  def cronjob_names(sleep_schedule) do
    Logger.debug("CronJobs entries: #{inspect(sleep_schedule["spec"]["cronjobs"])}")

    (sleep_schedule["spec"]["cronjobs"] || [])
    |> Enum.map(fn entry ->
      name = entry["name"]

      %{
        "name" => name,
        "is_wildcard" => is_wildcard_name?(name)
      }
    end)
  end

  def needs(sleep_schedule) do
    Logger.debug("Needs entries: #{inspect(sleep_schedule["spec"]["needs"])}")
    sleep_schedule["spec"]["needs"] || []
  end

  def has_needs?(sleep_schedule) do
    needs = needs(sleep_schedule)
    not Enum.empty?(needs)
  end

  def ingress_name(sleep_schedule) do
    sleep_schedule["spec"]["ingressName"]
  end

  def get_condition(sleep_schedule, type) do
    (sleep_schedule["status"]["conditions"] || [])
    |> Enum.filter(&(&1["type"] == type))
    |> List.first()
  end

  def put_condition(sleep_schedule, type, status, reason \\ nil, message \\ nil) do
    sleep_schedule = Map.put(sleep_schedule, "status", sleep_schedule["status"] || %{})

    new_conditions =
      (sleep_schedule["status"]["conditions"] || [])
      |> Enum.filter(&(&1["type"] != type))
      |> List.insert_at(-1, Condition.new(type, status, reason, message))

    put_in(sleep_schedule, ["status", "conditions"], new_conditions)
  end

  def is_sleeping?(sleep_schedule) do
    (get_condition(sleep_schedule, "Sleeping") || %{})["status"] == "True"
  end

  def get_ingress(sleep_schedule) do
    case ingress_name(sleep_schedule) do
      nil ->
        {:error, :ingress_name_not_set}

      "" ->
        {:error, :ingress_name_not_set}

      ingress_name ->
        namespace = namespace(sleep_schedule)
        Logger.debug("Fetching ingress", name: ingress_name)

        K8s.Client.get("networking.k8s.io/v1", :ingress, name: ingress_name, namespace: namespace)
        |> K8s.Client.put_conn(Drowzee.K8s.conn())
        |> K8s.Client.run()
    end
  end

  @retry with: exponential_backoff(1000) |> Stream.take(2)
  def get_deployments(sleep_schedule) do
    namespace = namespace(sleep_schedule)
    deployment_names = deployment_names(sleep_schedule) || []

    results =
      deployment_names
      |> Stream.map(fn name -> {name, Drowzee.K8s.get_deployment(name, namespace)} end)
      |> Enum.to_list()

    # Separate successful and failed results
    {found, missing} =
      Enum.split_with(results, fn {_, result} -> match?({:ok, _}, result) end)

    found_deployments = Enum.map(found, fn {_, {:ok, deployment}} -> deployment end)

    missing_resources =
      Enum.map(missing, fn {name, {:error, reason}} ->
        %{
          "kind" => "Deployment",
          "name" => name,
          "namespace" => namespace,
          "error" => inspect(reason),
          "status" => "NotFound"
        }
      end)

    if Enum.empty?(missing_resources) do
      {:ok, found_deployments}
    else
      {:partial, found_deployments, missing_resources}
    end
  end

  @retry with: exponential_backoff(1000) |> Stream.take(2)
  def get_statefulsets(sleep_schedule) do
    namespace = namespace(sleep_schedule)
    statefulset_names = statefulset_names(sleep_schedule) || []

    results =
      statefulset_names
      |> Stream.map(fn name -> {name, Drowzee.K8s.get_statefulset(name, namespace)} end)
      |> Enum.to_list()

    # Separate successful and failed results
    {found, missing} =
      Enum.split_with(results, fn {_, result} -> match?({:ok, _}, result) end)

    found_statefulsets = Enum.map(found, fn {_, {:ok, statefulset}} -> statefulset end)

    missing_resources =
      Enum.map(missing, fn {name, {:error, reason}} ->
        %{
          "kind" => "StatefulSet",
          "name" => name,
          "namespace" => namespace,
          "error" => inspect(reason),
          "status" => "NotFound"
        }
      end)

    if Enum.empty?(missing_resources) do
      {:ok, found_statefulsets}
    else
      {:partial, found_statefulsets, missing_resources}
    end
  end

  @retry with: exponential_backoff(1000) |> Stream.take(2)
  def get_cronjobs(sleep_schedule) do
    namespace = namespace(sleep_schedule)
    cronjob_name_infos = cronjob_names(sleep_schedule) || []

    results =
      cronjob_name_infos
      |> Stream.map(fn name_info ->
        {name_info["name"], Drowzee.K8s.get_cronjob_with_wildcard(name_info, namespace)}
      end)
      |> Enum.to_list()

    # Process each result to handle both tuple formats
    {found_cronjobs, missing_resources} =
      Enum.reduce(results, {[], []}, fn {name, result}, {found_acc, missing_acc} ->
        case result do
          {:ok, cronjob} ->
            {[cronjob | found_acc], missing_acc}

          {:ok, cronjob, _resolved_name} ->
            {[cronjob | found_acc], missing_acc}

          {:error, reason} ->
            missing_resource = %{
              "kind" => "CronJob",
              "name" => name,
              "namespace" => namespace,
              "error" => inspect(reason),
              "reason" => reason.reason,
              "message" => reason.message,
              "status" => "NotFound"
            }

            {found_acc, [missing_resource | missing_acc]}
        end
      end)

    if Enum.empty?(missing_resources) do
      {:ok, found_cronjobs}
    else
      {:partial, found_cronjobs, missing_resources}
    end
  end

  # Helper function to scale resources using a module function
  defp scale_resource_with_module(resources, scale_func) do
    results =
      Enum.map(resources, fn resource ->
        try do
          case scale_func.(resource) do
            {:ok, scaled_resource} ->
              {:ok, scaled_resource}

            {:error, failed_resource, error_msg} ->
              {:error, failed_resource, error_msg}
          end
        rescue
          e ->
            name = resource["metadata"]["name"]
            Logger.error("Error scaling resource: #{inspect(e)}", name: name)
            {:error, resource, "Exception during scaling: #{inspect(e)}"}
        catch
          kind, reason ->
            name = resource["metadata"]["name"]
            Logger.error("Error scaling resource: #{inspect(reason)}", name: name)
            {:error, resource, "Caught #{kind} during scaling: #{inspect(reason)}"}
        end
      end)

    # Check if any operations failed
    errors =
      Enum.filter(results, fn
        {:error, _, _} -> true
        _ -> false
      end)

    if Enum.empty?(errors) do
      {:ok, results}
    else
      # Return both successful results and errors
      {:partial, results, errors}
    end
  end

  def scale_down_deployments(sleep_schedule) do
    Logger.debug("Scaling down deployments...")

    case get_deployments(sleep_schedule) do
      {:ok, deployments} ->
        # All deployments found, proceed normally
        scale_resource_with_module(deployments, &Drowzee.K8s.Deployment.scale_down/1)

      {:partial, found_deployments, missing_resources} ->
        # Some deployments were not found
        Logger.warning("Some deployments were not found: #{inspect(missing_resources)}")

        # Scale the deployments that were found
        scaling_result =
          scale_resource_with_module(found_deployments, &Drowzee.K8s.Deployment.scale_down/1)

        # Create a combined result that includes both scaling results and missing resources
        case scaling_result do
          {:ok, results} ->
            # All found deployments scaled successfully, but we still have missing ones
            {:partial, results, missing_resources}

          {:partial, results, errors} ->
            # Some found deployments failed to scale and we have missing ones
            {:partial, results, errors ++ missing_resources}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def scale_down_statefulsets(sleep_schedule) do
    Logger.debug("Scaling down statefulsets...")

    case get_statefulsets(sleep_schedule) do
      {:ok, statefulsets} ->
        # All statefulsets found, proceed normally
        scale_resource_with_module(statefulsets, &Drowzee.K8s.StatefulSet.scale_down/1)

      {:partial, found_statefulsets, missing_resources} ->
        # Some statefulsets were not found
        Logger.warning("Some statefulsets were not found: #{inspect(missing_resources)}")

        # Scale the statefulsets that were found
        scaling_result =
          scale_resource_with_module(found_statefulsets, &Drowzee.K8s.StatefulSet.scale_down/1)

        # Create a combined result that includes both scaling results and missing resources
        case scaling_result do
          {:ok, results} ->
            # All found statefulsets scaled successfully, but we still have missing ones
            {:partial, results, missing_resources}

          {:partial, results, errors} ->
            # Some found statefulsets failed to scale and we have missing ones
            {:partial, results, errors ++ missing_resources}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def scale_up_deployments(sleep_schedule) do
    Logger.debug("Scaling up deployments...")

    case get_deployments(sleep_schedule) do
      {:ok, deployments} ->
        # All deployments found, proceed normally
        scale_resource_with_module(deployments, &Drowzee.K8s.Deployment.scale_up/1)

      {:partial, found_deployments, missing_resources} ->
        # Some deployments were not found
        Logger.warning("Some deployments were not found: #{inspect(missing_resources)}")

        # Scale the deployments that were found
        scaling_result =
          scale_resource_with_module(found_deployments, &Drowzee.K8s.Deployment.scale_up/1)

        # Create a combined result that includes both scaling results and missing resources
        case scaling_result do
          {:ok, results} ->
            # All found deployments scaled successfully, but we still have missing ones
            {:partial, results, missing_resources}

          {:partial, results, errors} ->
            # Some found deployments failed to scale and we have missing ones
            {:partial, results, errors ++ missing_resources}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def scale_up_statefulsets(sleep_schedule) do
    Logger.debug("Scaling up statefulsets...")

    case get_statefulsets(sleep_schedule) do
      {:ok, statefulsets} ->
        # All statefulsets found, proceed normally
        scale_resource_with_module(statefulsets, &Drowzee.K8s.StatefulSet.scale_up/1)

      {:partial, found_statefulsets, missing_resources} ->
        # Some statefulsets were not found
        Logger.warning("Some statefulsets were not found: #{inspect(missing_resources)}")

        # Scale the statefulsets that were found
        scaling_result =
          scale_resource_with_module(found_statefulsets, &Drowzee.K8s.StatefulSet.scale_up/1)

        # Create a combined result that includes both scaling results and missing resources
        case scaling_result do
          {:ok, results} ->
            # All found statefulsets scaled successfully, but we still have missing ones
            {:partial, results, missing_resources}

          {:partial, results, errors} ->
            # Some found statefulsets failed to scale and we have missing ones
            {:partial, results, errors ++ missing_resources}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # Helper function to process cronjobs using a module function
  defp process_cronjobs_with_module(resources, operation_func) do
    results =
      Enum.map(resources, fn resource ->
        try do
          case operation_func.(resource) do
            {:ok, processed_resource} ->
              {:ok, processed_resource}

            {:error, failed_resource, error_msg} ->
              {:error, failed_resource, error_msg}
          end
        rescue
          e ->
            name = resource["metadata"]["name"]
            Logger.error("Error processing cronjob: #{inspect(e)}", name: name)
            {:error, resource, "Exception during processing: #{inspect(e)}"}
        catch
          kind, reason ->
            name = resource["metadata"]["name"]
            Logger.error("Error processing cronjob: #{inspect(reason)}", name: name)
            {:error, resource, "Caught #{kind} during processing: #{inspect(reason)}"}
        end
      end)

    # Check if any operations failed
    errors =
      Enum.filter(results, fn
        {:error, _, _} -> true
        _ -> false
      end)

    if Enum.empty?(errors) do
      {:ok, results}
    else
      # Return both successful results and errors
      {:partial, results, errors}
    end
  end

  def suspend_cronjobs(sleep_schedule) do
    Logger.debug("Suspending cronjobs...")

    # Create a function that suspends a cronjob
    suspend_func = fn cronjob -> CronJob.suspend(cronjob, true) end

    case get_cronjobs(sleep_schedule) do
      {:ok, cronjobs} ->
        # All cronjobs found, proceed normally
        process_cronjobs_with_module(cronjobs, suspend_func)

      {:partial, found_cronjobs, missing_resources} ->
        # Some cronjobs were not found
        Logger.warning("Some cronjobs were not found: #{inspect(missing_resources)}")

        # Process the cronjobs that were found
        scaling_result = process_cronjobs_with_module(found_cronjobs, suspend_func)

        # Create a combined result that includes both scaling results and missing resources
        case scaling_result do
          {:ok, results} ->
            # All found cronjobs processed successfully, but we still have missing ones
            {:partial, results, missing_resources}

          {:partial, results, errors} ->
            # Some found cronjobs failed to process and we have missing ones
            {:partial, results, errors ++ missing_resources}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def resume_cronjobs(sleep_schedule) do
    Logger.debug("Resuming cronjobs...")

    # Create a function that resumes a cronjob
    resume_func = fn cronjob -> CronJob.suspend(cronjob, false) end

    case get_cronjobs(sleep_schedule) do
      {:ok, cronjobs} ->
        # All cronjobs found, proceed normally
        process_cronjobs_with_module(cronjobs, resume_func)

      {:partial, found_cronjobs, missing_resources} ->
        # Some cronjobs were not found
        Logger.warning("Some cronjobs were not found: #{inspect(missing_resources)}")

        # Process the cronjobs that were found
        scaling_result = process_cronjobs_with_module(found_cronjobs, resume_func)

        # Create a combined result that includes both scaling results and missing resources
        case scaling_result do
          {:ok, results} ->
            # All found cronjobs processed successfully, but we still have missing ones
            {:partial, results, missing_resources}

          {:partial, results, errors} ->
            # Some found cronjobs failed to process and we have missing ones
            {:partial, results, errors ++ missing_resources}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def put_ingress_to_sleep(sleep_schedule) do
    with {:ok, ingress} <- get_ingress(sleep_schedule),
         {:ok, drowzee_ingress} <- Drowzee.K8s.get_drowzee_ingress(),
         {:ok, updated_ingress} <-
           Ingress.add_redirect_annotation(ingress, sleep_schedule, drowzee_ingress),
         {:ok, _} <- K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(updated_ingress)) do
      {:ok, updated_ingress}
    else
      {:error, error} ->
        {:error, error}
    end
  end

  def wake_up_ingress(sleep_schedule) do
    with {:ok, ingress} <- get_ingress(sleep_schedule),
         {:ok, updated_ingress} <- Ingress.remove_redirect_annotation(ingress),
         {:ok, _} <- K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(updated_ingress)) do
      {:ok, updated_ingress}
    else
      {:error, error} ->
        {:error, error}
    end
  end

  def update_sleep_schedule(sleep_schedule) do
    require Logger

    Logger.info(
      "Updating SleepSchedule #{sleep_schedule["metadata"]["name"]} in namespace #{sleep_schedule["metadata"]["namespace"]}"
    )

    result = K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(sleep_schedule))
    Logger.debug("Update result: #{inspect(result)}")
    result
  end

  def update_heartbeat(sleep_schedule) do
    Logger.debug("Update heartbeat...")
    heartbeat = get_condition(sleep_schedule, "Heartbeat") || %{"status" => "False"}

    put_condition(
      sleep_schedule,
      "Heartbeat",
      if(heartbeat["status"] == "True", do: "False", else: "True"),
      "StayingAlive",
      "Triggers events from transition monitor"
    )
    |> Drowzee.K8s.decrement_observed_generation()
    |> Bonny.Resource.apply_status(Drowzee.K8s.conn())
  end

  @doc """
  Fetch and validate dependency schedules for manual wake-up.
  Returns {:ok, valid_schedules} or {:error, reason}.
  Only schedules without their own 'needs' can be dependencies.
  """
  def get_valid_dependencies(sleep_schedule) do
    dependencies = needs(sleep_schedule)

    if Enum.empty?(dependencies) do
      {:ok, []}
    else
      Logger.debug("Fetching #{length(dependencies)} dependency schedules",
        schedule: name(sleep_schedule)
      )

      results =
        dependencies
        |> Enum.map(&fetch_and_validate_dependency/1)
        |> Enum.split_with(fn {status, _} -> status == :ok end)

      case results do
        {valid_deps, []} ->
          # All dependencies are valid
          schedules = Enum.map(valid_deps, fn {:ok, schedule} -> schedule end)
          {:ok, schedules}

        {valid_deps, invalid_deps} ->
          # Some dependencies are invalid, log warnings but continue with valid ones
          Enum.each(invalid_deps, fn {:error, reason} ->
            Logger.warning("Invalid dependency: #{reason}", schedule: name(sleep_schedule))
          end)

          schedules = Enum.map(valid_deps, fn {:ok, schedule} -> schedule end)
          {:ok, schedules}
      end
    end
  end

  defp fetch_and_validate_dependency(need) do
    dep_name = need["name"]
    dep_namespace = need["namespace"]

    case Drowzee.K8s.get_sleep_schedule(dep_name, dep_namespace) do
      {:ok, dep_schedule} ->
        if has_needs?(dep_schedule) do
          {:error, "#{dep_namespace}/#{dep_name} has its own dependencies (nested dependencies not allowed)"}
        else
          {:ok, dep_schedule}
        end

      {:error, reason} ->
        {:error, "#{dep_namespace}/#{dep_name} not found: #{inspect(reason)}"}
    end
  end
end
