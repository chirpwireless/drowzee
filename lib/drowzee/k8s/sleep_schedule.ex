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

  def cronjob_names(sleep_schedule) do
    Logger.debug("CronJobs entries: #{inspect(sleep_schedule["spec"]["cronjobs"])}")

    (sleep_schedule["spec"]["cronjobs"] || [])
    |> Enum.map(& &1["name"])
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

    results =
      (deployment_names(sleep_schedule) || [])
      |> Stream.map(&Drowzee.K8s.get_deployment(&1, namespace))
      |> Enum.to_list()

    case Enum.all?(results, fn
           {:ok, _} -> true
           _ -> false
         end) do
      true ->
        {:ok, Enum.map(results, fn {:ok, deployment} -> deployment end)}

      false ->
        {:error,
         Enum.filter(results, fn
           {:error, _} -> true
           _ -> false
         end)
         |> Enum.map(fn {:error, error} -> error end)}
    end
  end

  @retry with: exponential_backoff(1000) |> Stream.take(2)
  def get_statefulsets(sleep_schedule) do
    namespace = namespace(sleep_schedule)

    results =
      (statefulset_names(sleep_schedule) || [])
      |> Stream.map(&Drowzee.K8s.get_statefulset(&1, namespace))
      |> Enum.to_list()

    case Enum.all?(results, fn
           {:ok, _} -> true
           _ -> false
         end) do
      true ->
        {:ok, Enum.map(results, fn {:ok, statefulset} -> statefulset end)}

      false ->
        {:error,
         Enum.filter(results, fn
           {:error, _} -> true
           _ -> false
         end)
         |> Enum.map(fn {:error, error} -> error end)}
    end
  end

  @retry with: exponential_backoff(1000) |> Stream.take(2)
  def get_cronjobs(sleep_schedule) do
    namespace = namespace(sleep_schedule)

    results =
      (cronjob_names(sleep_schedule) || [])
      |> Stream.map(&Drowzee.K8s.get_cronjob(&1, namespace))
      |> Enum.to_list()

    case Enum.all?(results, fn
           {:ok, _} -> true
           _ -> false
         end) do
      true ->
        {:ok, Enum.map(results, fn {:ok, cronjob} -> cronjob end)}

      false ->
        {:error,
         Enum.filter(results, fn
           {:error, _} -> true
           _ -> false
         end)
         |> Enum.map(fn {:error, error} -> error end)}
    end
  end

  def scale_down_deployments(sleep_schedule) do
    Logger.debug("Scaling down deployments...")

    case get_deployments(sleep_schedule) do
      {:ok, deployments} ->
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

                {:error, failed_deployment,
                 "Failed to scale down deployment #{name}: #{inspect(e)}"}
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
            {:error, _} -> true
            _ -> false
          end)

        if Enum.empty?(errors) do
          {:ok, results}
        else
          # Return both successful results and errors
          {:partial, results, errors}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def scale_down_statefulsets(sleep_schedule) do
    Logger.debug("Scaling down statefulsets...")

    case get_statefulsets(sleep_schedule) do
      {:ok, statefulsets} ->
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
            {:error, _} -> true
            _ -> false
          end)

        if Enum.empty?(errors) do
          {:ok, results}
        else
          # Return both successful results and errors
          {:partial, results, errors}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def suspend_cronjobs(sleep_schedule) do
    Logger.debug("Suspending cronjobs...")

    case get_cronjobs(sleep_schedule) do
      {:ok, cronjobs} ->
        results = Enum.map(cronjobs, &CronJob.suspend_cronjob(&1, true))
        {:ok, results}

      {:error, error} ->
        {:error, error}
    end
  end

  def scale_up_deployments(sleep_schedule) do
    Logger.debug("Scaling up deployments...")

    case get_deployments(sleep_schedule) do
      {:ok, deployments} ->
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

                {:error, failed_deployment,
                 "Failed to scale up deployment #{name}: #{inspect(e)}"}
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
            {:error, _} -> true
            _ -> false
          end)

        if Enum.empty?(errors) do
          {:ok, results}
        else
          # Return both successful results and errors
          {:partial, results, errors}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def scale_up_statefulsets(sleep_schedule) do
    Logger.debug("Scaling up statefulsets...")

    case get_statefulsets(sleep_schedule) do
      {:ok, statefulsets} ->
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

                {:error, failed_statefulset,
                 "Failed to scale up statefulset #{name}: #{inspect(e)}"}
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
            {:error, _} -> true
            _ -> false
          end)

        if Enum.empty?(errors) do
          {:ok, results}
        else
          # Return both successful results and errors
          {:partial, results, errors}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def resume_cronjobs(sleep_schedule) do
    Logger.debug("Resuming cronjobs...")

    case get_cronjobs(sleep_schedule) do
      {:ok, cronjobs} ->
        results = Enum.map(cronjobs, &CronJob.suspend_cronjob(&1, false))
        {:ok, results}

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
