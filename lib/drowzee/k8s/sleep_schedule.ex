defmodule Drowzee.K8s.SleepSchedule do
  use Retry.Annotation

  require Logger

  alias Drowzee.K8s.{Deployment, StatefulSet, CronJob, Ingress, Condition}

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

    # Separate successful and failed results
    {found, missing} =
      Enum.split_with(results, fn {_, result} -> match?({:ok, _}, result) end)

    found_cronjobs = Enum.map(found, fn {_, {:ok, cronjob}} -> cronjob end)

    missing_resources =
      Enum.map(missing, fn {name, {:error, reason}} ->
        %{
          "kind" => "CronJob",
          "name" => name,
          "namespace" => namespace,
          "error" => inspect(reason),
          "reason" => reason.reason,
          "message" => reason.message,
          "status" => "NotFound"
        }
      end)

    if Enum.empty?(missing_resources) do
      {:ok, found_cronjobs}
    else
      {:partial, found_cronjobs, missing_resources}
    end
  end

  def scale_down_deployments(sleep_schedule) do
    Logger.debug("Scaling down deployments...")

    case get_deployments(sleep_schedule) do
      {:ok, deployments} ->
        # All deployments found, proceed normally
        scale_found_deployments(deployments)

      {:partial, found_deployments, missing_resources} ->
        # Some deployments were not found
        Logger.warning("Some deployments were not found: #{inspect(missing_resources)}")

        # Scale the deployments that were found
        scaling_result = scale_found_deployments(found_deployments)

        # Create a combined result that includes both scaling results and missing resources
        case scaling_result do
          {:ok, results} ->
            # All found deployments scaled successfully, but we still have missing ones
            {:partial, results, missing_resources}

          {:partial, results, errors} ->
            # Some found deployments failed to scale and we have missing ones
            {:partial, results, errors ++ missing_resources}

          {:error, error} ->
            # Complete failure scaling found deployments
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # Helper function to scale deployments that were found
  defp scale_found_deployments(deployments) do
    results =
      Enum.map(deployments, fn deployment ->
        try do
          deployment = Deployment.save_original_replicas(deployment)

          case Deployment.scale_deployment(deployment, 0) do
            {:ok, scaled_deployment} ->
              {:ok, scaled_deployment}

            {:error, reason} ->
              name = deployment["metadata"]["name"]
              Logger.error("Error scaling down deployment: #{inspect(reason)}", name: name)
              # Mark this specific resource as failed
              failed_deployment =
                put_in(
                  deployment,
                  ["metadata", "annotations", "drowzee.io/scale-failed"],
                  "true"
                )

              failed_deployment =
                put_in(
                  failed_deployment,
                  ["metadata", "annotations", "drowzee.io/scale-error"],
                  "Failed to scale: #{inspect(reason)}"
                )

              {:error, failed_deployment,
               "Failed to scale down deployment #{name}: #{inspect(reason)}"}
          end
        rescue
          e ->
            name = deployment["metadata"]["name"]
            Logger.error("Error scaling down deployment: #{inspect(e)}", name: name)
            # Mark this specific resource as failed
            failed_deployment =
              put_in(
                deployment,
                ["metadata", "annotations", "drowzee.io/scale-failed"],
                "true"
              )

            failed_deployment =
              put_in(
                failed_deployment,
                ["metadata", "annotations", "drowzee.io/scale-error"],
                "Exception: #{inspect(e)}"
              )

            {:error, failed_deployment, "Failed to scale down deployment #{name}: #{inspect(e)}"}
        catch
          kind, reason ->
            name = deployment["metadata"]["name"]
            Logger.error("Error scaling down deployment: #{inspect(reason)}", name: name)
            # Mark this specific resource as failed
            failed_deployment =
              put_in(
                deployment,
                ["metadata", "annotations", "drowzee.io/scale-failed"],
                "true"
              )

            failed_deployment =
              put_in(
                failed_deployment,
                ["metadata", "annotations", "drowzee.io/scale-error"],
                "Caught #{kind}: #{inspect(reason)}"
              )

            {:error, failed_deployment,
             "Failed to scale down deployment #{name}: #{inspect(reason)}"}
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

  def scale_down_statefulsets(sleep_schedule) do
    Logger.debug("Scaling down statefulsets...")

    case get_statefulsets(sleep_schedule) do
      {:ok, statefulsets} ->
        # All statefulsets found, proceed normally
        scale_found_statefulsets(statefulsets)

      {:partial, found_statefulsets, missing_resources} ->
        # Some statefulsets were not found
        Logger.warning("Some statefulsets were not found: #{inspect(missing_resources)}")

        # Scale the statefulsets that were found
        scaling_result = scale_found_statefulsets(found_statefulsets)

        # Create a combined result that includes both scaling results and missing resources
        case scaling_result do
          {:ok, results} ->
            # All found statefulsets scaled successfully, but we still have missing ones
            {:partial, results, missing_resources}

          {:partial, results, errors} ->
            # Some found statefulsets failed to scale and we have missing ones
            {:partial, results, errors ++ missing_resources}

          {:error, error} ->
            # Complete failure scaling found statefulsets
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # Helper function to scale statefulsets that were found
  defp scale_found_statefulsets(statefulsets) do
    results =
      Enum.map(statefulsets, fn statefulset ->
        try do
          statefulset = StatefulSet.save_original_replicas(statefulset)

          case StatefulSet.scale_statefulset(statefulset, 0) do
            {:ok, scaled_statefulset} ->
              {:ok, scaled_statefulset}

            {:error, reason} ->
              name = statefulset["metadata"]["name"]
              Logger.error("Error scaling down statefulset: #{inspect(reason)}", name: name)
              # Mark this specific resource as failed
              failed_statefulset =
                put_in(
                  statefulset,
                  ["metadata", "annotations", "drowzee.io/scale-failed"],
                  "true"
                )

              failed_statefulset =
                put_in(
                  failed_statefulset,
                  ["metadata", "annotations", "drowzee.io/scale-error"],
                  "Failed to scale: #{inspect(reason)}"
                )

              {:error, failed_statefulset,
               "Failed to scale down statefulset #{name}: #{inspect(reason)}"}
          end
        rescue
          e ->
            name = statefulset["metadata"]["name"]
            Logger.error("Error scaling down statefulset: #{inspect(e)}", name: name)
            # Mark this specific resource as failed
            failed_statefulset =
              put_in(
                statefulset,
                ["metadata", "annotations", "drowzee.io/scale-failed"],
                "true"
              )

            failed_statefulset =
              put_in(
                failed_statefulset,
                ["metadata", "annotations", "drowzee.io/scale-error"],
                "Exception: #{inspect(e)}"
              )

            {:error, failed_statefulset,
             "Failed to scale down statefulset #{name}: #{inspect(e)}"}
        catch
          kind, reason ->
            name = statefulset["metadata"]["name"]
            Logger.error("Error scaling down statefulset: #{inspect(reason)}", name: name)
            # Mark this specific resource as failed
            failed_statefulset =
              put_in(
                statefulset,
                ["metadata", "annotations", "drowzee.io/scale-failed"],
                "true"
              )

            failed_statefulset =
              put_in(
                failed_statefulset,
                ["metadata", "annotations", "drowzee.io/scale-error"],
                "Caught #{kind}: #{inspect(reason)}"
              )

            {:error, failed_statefulset,
             "Failed to scale down statefulset #{name}: #{inspect(reason)}"}
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

    case get_cronjobs(sleep_schedule) do
      {:ok, cronjobs} ->
        # Process each cronjob and collect results
        scaling_result =
          Enum.reduce_while(cronjobs, {[], []}, fn cronjob, {successes, failures} ->
            case CronJob.suspend_cronjob(cronjob, true) do
              {:ok, suspended_cronjob} ->
                {:cont, {[suspended_cronjob | successes], failures}}

              {:error, failed_cronjob, error_msg} ->
                # Save the failed cronjob and continue with others
                {:cont, {successes, [{:error, failed_cronjob, error_msg} | failures]}}
            end
          end)

        case scaling_result do
          {successes, []} ->
            # All operations succeeded
            {:ok, successes}

          {successes, failures} ->
            # Some operations failed
            {:partial, successes, failures}
        end

      {:partial, found_cronjobs, missing_resources} ->
        # Some cronjobs were not found
        Logger.warning("Some cronjobs were not found: #{inspect(missing_resources)}")

        # Suspend the cronjobs that were found
        scaling_result =
          Enum.reduce_while(found_cronjobs, {[], []}, fn cronjob, {successes, failures} ->
            case CronJob.suspend_cronjob(cronjob, true) do
              {:ok, suspended_cronjob} ->
                {:cont, {[suspended_cronjob | successes], failures}}

              {:error, failed_cronjob, error_msg} ->
                # Save the failed cronjob and continue with others
                {:cont, {successes, [{:error, failed_cronjob, error_msg} | failures]}}
            end
          end)

        case scaling_result do
          {successes, []} ->
            # All found cronjobs were suspended successfully
            {:partial, successes, missing_resources}

          {successes, failures} ->
            # Some found cronjobs failed to suspend
            {:partial, successes, missing_resources ++ failures}
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
        scale_up_found_deployments(deployments)

      {:partial, found_deployments, missing_resources} ->
        # Some deployments were not found
        Logger.warning("Some deployments were not found: #{inspect(missing_resources)}")

        # Scale the deployments that were found
        scaling_result = scale_up_found_deployments(found_deployments)

        # Create a combined result that includes both scaling results and missing resources
        case scaling_result do
          {:ok, results} ->
            # All found deployments scaled successfully, but we still have missing ones
            {:partial, results, missing_resources}

          {:partial, results, errors} ->
            # Some found deployments failed to scale and we have missing ones
            {:partial, results, errors ++ missing_resources}

          {:error, error} ->
            # Complete failure scaling found deployments
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # Helper function to scale up deployments that were found
  defp scale_up_found_deployments(deployments) do
    results =
      Enum.map(deployments, fn deployment ->
        try do
          original = Deployment.get_original_replicas(deployment)

          case Deployment.scale_deployment(deployment, original) do
            {:ok, scaled_deployment} ->
              # Clear any previous failure annotations if they exist
              scaled_deployment =
                pop_in(scaled_deployment, [
                  "metadata",
                  "annotations",
                  "drowzee.io/scale-failed"
                ])
                |> elem(1)

              scaled_deployment =
                pop_in(scaled_deployment, [
                  "metadata",
                  "annotations",
                  "drowzee.io/scale-error"
                ])
                |> elem(1)

              {:ok, scaled_deployment}

            {:error, reason} ->
              name = deployment["metadata"]["name"]
              Logger.error("Error scaling up deployment: #{inspect(reason)}", name: name)
              # Mark this specific resource as failed
              failed_deployment =
                put_in(
                  deployment,
                  ["metadata", "annotations", "drowzee.io/scale-failed"],
                  "true"
                )

              failed_deployment =
                put_in(
                  failed_deployment,
                  ["metadata", "annotations", "drowzee.io/scale-error"],
                  "Failed to scale: #{inspect(reason)}"
                )

              {:error, failed_deployment,
               "Failed to scale up deployment #{name}: #{inspect(reason)}"}
          end
        rescue
          e ->
            name = deployment["metadata"]["name"]
            Logger.error("Error scaling up deployment: #{inspect(e)}", name: name)
            # Mark this specific resource as failed
            failed_deployment =
              put_in(
                deployment,
                ["metadata", "annotations", "drowzee.io/scale-failed"],
                "true"
              )

            failed_deployment =
              put_in(
                failed_deployment,
                ["metadata", "annotations", "drowzee.io/scale-error"],
                "Exception: #{inspect(e)}"
              )

            {:error, failed_deployment, "Failed to scale up deployment #{name}: #{inspect(e)}"}
        catch
          kind, reason ->
            name = deployment["metadata"]["name"]
            Logger.error("Error scaling up deployment: #{inspect(reason)}", name: name)
            # Mark this specific resource as failed
            failed_deployment =
              put_in(
                deployment,
                ["metadata", "annotations", "drowzee.io/scale-failed"],
                "true"
              )

            failed_deployment =
              put_in(
                failed_deployment,
                ["metadata", "annotations", "drowzee.io/scale-error"],
                "Caught #{kind}: #{inspect(reason)}"
              )

            {:error, failed_deployment,
             "Failed to scale up deployment #{name}: #{inspect(reason)}"}
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

  def scale_up_statefulsets(sleep_schedule) do
    Logger.debug("Scaling up statefulsets...")

    case get_statefulsets(sleep_schedule) do
      {:ok, statefulsets} ->
        # All statefulsets found, proceed normally
        scale_up_found_statefulsets(statefulsets)

      {:partial, found_statefulsets, missing_resources} ->
        # Some statefulsets were not found
        Logger.warning("Some statefulsets were not found: #{inspect(missing_resources)}")

        # Scale the statefulsets that were found
        scaling_result = scale_up_found_statefulsets(found_statefulsets)

        # Create a combined result that includes both scaling results and missing resources
        case scaling_result do
          {:ok, results} ->
            # All found statefulsets scaled successfully, but we still have missing ones
            {:partial, results, missing_resources}

          {:partial, results, errors} ->
            # Some found statefulsets failed to scale and we have missing ones
            {:partial, results, errors ++ missing_resources}

          {:error, error} ->
            # Complete failure scaling found statefulsets
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # Helper function to scale up statefulsets that were found
  defp scale_up_found_statefulsets(statefulsets) do
    results =
      Enum.map(statefulsets, fn statefulset ->
        try do
          original = StatefulSet.get_original_replicas(statefulset)

          case StatefulSet.scale_statefulset(statefulset, original) do
            {:ok, scaled_statefulset} ->
              # Clear any previous failure annotations if they exist
              scaled_statefulset =
                pop_in(scaled_statefulset, [
                  "metadata",
                  "annotations",
                  "drowzee.io/scale-failed"
                ])
                |> elem(1)

              scaled_statefulset =
                pop_in(scaled_statefulset, [
                  "metadata",
                  "annotations",
                  "drowzee.io/scale-error"
                ])
                |> elem(1)

              {:ok, scaled_statefulset}

            {:error, reason} ->
              name = statefulset["metadata"]["name"]
              Logger.error("Error scaling up statefulset: #{inspect(reason)}", name: name)
              # Mark this specific resource as failed
              failed_statefulset =
                put_in(
                  statefulset,
                  ["metadata", "annotations", "drowzee.io/scale-failed"],
                  "true"
                )

              failed_statefulset =
                put_in(
                  failed_statefulset,
                  ["metadata", "annotations", "drowzee.io/scale-error"],
                  "Failed to scale: #{inspect(reason)}"
                )

              {:error, failed_statefulset,
               "Failed to scale up statefulset #{name}: #{inspect(reason)}"}
          end
        rescue
          e ->
            name = statefulset["metadata"]["name"]
            Logger.error("Error scaling up statefulset: #{inspect(e)}", name: name)
            # Mark this specific resource as failed
            failed_statefulset =
              put_in(
                statefulset,
                ["metadata", "annotations", "drowzee.io/scale-failed"],
                "true"
              )

            failed_statefulset =
              put_in(
                failed_statefulset,
                ["metadata", "annotations", "drowzee.io/scale-error"],
                "Exception: #{inspect(e)}"
              )

            {:error, failed_statefulset, "Failed to scale up statefulset #{name}: #{inspect(e)}"}
        catch
          kind, reason ->
            name = statefulset["metadata"]["name"]
            Logger.error("Error scaling up statefulset: #{inspect(reason)}", name: name)
            # Mark this specific resource as failed
            failed_statefulset =
              put_in(
                statefulset,
                ["metadata", "annotations", "drowzee.io/scale-failed"],
                "true"
              )

            failed_statefulset =
              put_in(
                failed_statefulset,
                ["metadata", "annotations", "drowzee.io/scale-error"],
                "Caught #{kind}: #{inspect(reason)}"
              )

            {:error, failed_statefulset,
             "Failed to scale up statefulset #{name}: #{inspect(reason)}"}
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

  def resume_cronjobs(sleep_schedule) do
    Logger.debug("Resuming cronjobs...")

    case get_cronjobs(sleep_schedule) do
      {:ok, cronjobs} ->
        # Process each cronjob and collect results
        scaling_result =
          Enum.reduce_while(cronjobs, {[], []}, fn cronjob, {successes, failures} ->
            case CronJob.suspend_cronjob(cronjob, false) do
              {:ok, resumed_cronjob} ->
                {:cont, {[resumed_cronjob | successes], failures}}

              {:error, failed_cronjob, error_msg} ->
                # Save the failed cronjob and continue with others
                {:cont, {successes, [{:error, failed_cronjob, error_msg} | failures]}}
            end
          end)

        case scaling_result do
          {successes, []} ->
            # All operations succeeded
            {:ok, successes}

          {successes, failures} ->
            # Some operations failed
            {:partial, successes, failures}
        end

      {:partial, found_cronjobs, missing_resources} ->
        # Some cronjobs were not found
        Logger.warning("Some cronjobs were not found: #{inspect(missing_resources)}")

        # Resume the cronjobs that were found
        scaling_result =
          Enum.reduce_while(found_cronjobs, {[], []}, fn cronjob, {successes, failures} ->
            case CronJob.suspend_cronjob(cronjob, false) do
              {:ok, resumed_cronjob} ->
                {:cont, {[resumed_cronjob | successes], failures}}

              {:error, failed_cronjob, error_msg} ->
                # Save the failed cronjob and continue with others
                {:cont, {successes, [{:error, failed_cronjob, error_msg} | failures]}}
            end
          end)

        case scaling_result do
          {successes, []} ->
            # All found cronjobs were resumed successfully
            {:partial, successes, missing_resources}

          {successes, failures} ->
            # Some found cronjobs failed to resume
            {:partial, successes, missing_resources ++ failures}
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
end
