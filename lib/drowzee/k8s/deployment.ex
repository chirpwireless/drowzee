defmodule Drowzee.K8s.Deployment do
  require Logger

  def name(deployment), do: deployment["metadata"]["name"]

  def namespace(deployment), do: deployment["metadata"]["namespace"]

  def replicas(deployment), do: deployment["spec"]["replicas"] || 0

  def ready_replicas(deployment), do: deployment["status"]["readyReplicas"] || 0

  @doc """
  Add the managed-by annotation to track which SleepSchedule manages this resource.
  """
  def add_managed_by_annotation(deployment, sleep_schedule_key) do
    if sleep_schedule_key do
      annotations = get_in(deployment, ["metadata", "annotations"]) || %{}
      updated_annotations = Map.put(annotations, "drowzee.io/managed-by", sleep_schedule_key)
      put_in(deployment, ["metadata", "annotations"], updated_annotations)
    else
      deployment
    end
  end

  @doc """
  Always save (or update) the current replica count as an annotation on the deployment.
  Also adds the managed-by annotation to track which SleepSchedule manages this resource.
  """
  def save_original_replicas(deployment, sleep_schedule_key \\ nil) do
    annotations = get_in(deployment, ["metadata", "annotations"]) || %{}
    current = get_in(deployment, ["spec", "replicas"]) || 0
    current_str = Integer.to_string(current)

    original_annotation = Map.get(annotations, "drowzee.io/original-replicas")

    # Only save if:
    # - annotation is missing OR
    # - annotation value != current AND current > 0
    # This way, if someone changed the replica count while awake, you update it before sleep
    should_save = case original_annotation do
      nil when current > 0 -> true
      value when value != current_str and current > 0 -> true
      _ -> false
    end

    if should_save do
      annotations =
        annotations
        |> Map.put("drowzee.io/original-replicas", current_str)
        |> Map.put("drowzee.io/managed-by", sleep_schedule_key)

      put_in(deployment, ["metadata", "annotations"], annotations)
    else
      deployment
    end
  end

  @doc """
  Get the original replicas count from the annotation, as integer. Default to 1 if missing or invalid.
  """
  def get_original_replicas(deployment) do
    annotations = get_in(deployment, ["metadata", "annotations"]) || %{}

    case Map.get(annotations, "drowzee.io/original-replicas") do
      nil ->
        1

      value ->
        case Integer.parse(value) do
          {count, _} -> count
          :error -> 1
        end
    end
  end

  def scale_deployment(%{"kind" => "Deployment"} = deployment, replicas) do
    Logger.info("Scaling deployment", name: name(deployment), replicas: replicas)
    deployment = put_in(deployment["spec"]["replicas"], replicas)

    case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(deployment)) do
      {:ok, deployment} ->
        {:ok, deployment}

      {:error, reason} ->
        Logger.error("Failed to scale deployment: #{inspect(reason)}",
          name: name(deployment),
          replicas: replicas
        )

        {:error, reason}
    end
  end

  @doc """
  Scale down a Deployment to 0 replicas.
  Saves the original replica count as an annotation before scaling down.
  """
  def scale_down(%{"kind" => "Deployment"} = deployment, sleep_schedule_key \\ nil) do
    try do
      # Always save original replicas before scale down operations
      deployment = save_original_replicas(deployment, sleep_schedule_key)

      # Then check if the Deployment is already scaled down
      case Drowzee.K8s.ResourceUtils.check_resource_state(deployment, :scale_down) do
        {:already_in_desired_state, deployment} ->
          # Already scaled down, but we saved the original replicas above
          # Need to persist the annotation since no other update will happen
          case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(deployment)) do
            {:ok, updated_deployment} ->
              Logger.debug("Saved original replicas for already-scaled-down Deployment", name: name(deployment))
              {:ok, updated_deployment}
            {:error, reason} ->
              Logger.warning("Failed to save original replicas annotation: #{inspect(reason)}", name: name(deployment))
              {:ok, deployment}  # Return success even if annotation failed
          end

        {:needs_modification, deployment} ->
          # Original replicas already saved above, just do the scale operation
          # Scale down to 0
          case scale_deployment(deployment, 0) do
            {:ok, scaled_deployment} ->
              {:ok, scaled_deployment}

            {:error, reason} ->
              # Mark as failed with annotations using centralized function
              case Drowzee.K8s.ResourceUtils.set_error_annotations(
                     deployment,
                     :deployment,
                     "Failed to scale: #{inspect(reason)}"
                   ) do
                {:ok, failed_deployment} ->
                  {:error, failed_deployment,
                   "Failed to scale down deployment #{name(deployment)}: #{inspect(reason)}"}

                {:error, _} ->
                  # If updating annotations fails, still return the original error
                  {:error, deployment,
                   "Failed to scale down deployment #{name(deployment)}: #{inspect(reason)}"}
              end
          end
      end
    rescue
      e ->
        Logger.error("Error scaling down deployment: #{inspect(e)}", name: name(deployment))
        # Mark as failed with annotations using centralized function
        case Drowzee.K8s.ResourceUtils.set_error_annotations(
               deployment,
               :deployment,
               "Exception: #{inspect(e)}"
             ) do
          {:ok, failed_deployment} ->
            {:error, failed_deployment,
             "Failed to scale down deployment #{name(deployment)}: #{inspect(e)}"}

          {:error, _} ->
            # If updating annotations fails, still return the original error
            {:error, deployment,
             "Failed to scale down deployment #{name(deployment)}: #{inspect(e)}"}
        end
    catch
      kind, reason ->
        Logger.error("Error scaling down deployment: #{inspect(reason)}", name: name(deployment))
        # Mark as failed with annotations using centralized function
        case Drowzee.K8s.ResourceUtils.set_error_annotations(
               deployment,
               :deployment,
               "Caught #{kind}: #{inspect(reason)}"
             ) do
          {:ok, failed_deployment} ->
            {:error, failed_deployment,
             "Failed to scale down deployment #{name(deployment)}: #{inspect(reason)}"}

          {:error, _} ->
            # If updating annotations fails, still return the original error
            {:error, deployment,
             "Failed to scale down deployment #{name(deployment)}: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Scale up a Deployment to its original replica count.
  Gets the original replica count from the annotation and scales up to that value.
  Clears any error annotations after successful scaling.
  Also adds managed-by annotation to track which SleepSchedule manages this resource.
  """
  def scale_up(%{"kind" => "Deployment"} = deployment, sleep_schedule_key \\ nil) do
    try do
      # First check if the Deployment is already scaled up
      case Drowzee.K8s.ResourceUtils.check_resource_state(deployment, :scale_up) do
        {:already_in_desired_state, deployment} ->
          # Already scaled up, return success
          {:ok, deployment}

        {:needs_modification, deployment} ->
          # Add managed-by annotation before scaling up
          deployment = add_managed_by_annotation(deployment, sleep_schedule_key)

          # Get the original replica count
          original = get_original_replicas(deployment)

          # Scale up to original replicas
          case scale_deployment(deployment, original) do
            {:ok, scaled_deployment} ->
              # Clear any error annotations and return the result
              Drowzee.K8s.ResourceUtils.clear_error_annotations(scaled_deployment, :deployment)

            {:error, reason} ->
              # Mark as failed with annotations using centralized function
              case Drowzee.K8s.ResourceUtils.set_error_annotations(
                     deployment,
                     :deployment,
                     "Failed to scale: #{inspect(reason)}"
                   ) do
                {:ok, failed_deployment} ->
                  {:error, failed_deployment,
                   "Failed to scale up deployment #{name(deployment)}: #{inspect(reason)}"}

                {:error, _} ->
                  # If updating annotations fails, still return the original error
                  {:error, deployment,
                   "Failed to scale up deployment #{name(deployment)}: #{inspect(reason)}"}
              end
          end
      end
    rescue
      e ->
        Logger.error("Error scaling up deployment: #{inspect(e)}", name: name(deployment))
        # Mark as failed with annotations using centralized function
        case Drowzee.K8s.ResourceUtils.set_error_annotations(
               deployment,
               :deployment,
               "Exception: #{inspect(e)}"
             ) do
          {:ok, failed_deployment} ->
            {:error, failed_deployment,
             "Failed to scale up deployment #{name(deployment)}: #{inspect(e)}"}

          {:error, _} ->
            # If updating annotations fails, still return the original error
            {:error, deployment,
             "Failed to scale up deployment #{name(deployment)}: #{inspect(e)}"}
        end
    catch
      kind, reason ->
        Logger.error("Error scaling up deployment: #{inspect(reason)}", name: name(deployment))
        # Mark as failed with annotations using centralized function
        case Drowzee.K8s.ResourceUtils.set_error_annotations(
               deployment,
               :deployment,
               "Caught #{kind}: #{inspect(reason)}"
             ) do
          {:ok, failed_deployment} ->
            {:error, failed_deployment,
             "Failed to scale up deployment #{name(deployment)}: #{inspect(reason)}"}

          {:error, _} ->
            # If updating annotations fails, still return the original error
            {:error, deployment,
             "Failed to scale up deployment #{name(deployment)}: #{inspect(reason)}"}
        end
    end
  end
end
