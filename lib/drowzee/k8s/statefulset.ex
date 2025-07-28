defmodule Drowzee.K8s.StatefulSet do
  require Logger

  def name(statefulset), do: statefulset["metadata"]["name"]

  def namespace(statefulset), do: statefulset["metadata"]["namespace"]

  def replicas(statefulset), do: statefulset["spec"]["replicas"] || 0

  def ready_replicas(statefulset), do: statefulset["status"]["readyReplicas"] || 0

  @doc """
  Add the managed-by annotation to track which SleepSchedule manages this resource.
  """
  defp add_managed_by_annotation(statefulset, sleep_schedule_key) do
    if sleep_schedule_key do
      annotations = get_in(statefulset, ["metadata", "annotations"]) || %{}
      annotations = Map.put(annotations, "drowzee.io/managed-by", sleep_schedule_key)
      put_in(statefulset, ["metadata", "annotations"], annotations)
    else
      statefulset
    end
  end

  @doc """
  Always save (or update) the current replica count as an annotation on the statefulset.
  """
  def save_original_replicas(statefulset, sleep_schedule_key) do
    annotations = get_in(statefulset, ["metadata", "annotations"]) || %{}
    current = get_in(statefulset, ["spec", "replicas"]) || 0
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

      put_in(statefulset, ["metadata", "annotations"], annotations)
    else
      statefulset
    end
  end

  @doc """
  Get the original replicas count from the annotation, as integer. Default to 1 if missing or invalid.
  """
  def get_original_replicas(statefulset) do
    annotations = get_in(statefulset, ["metadata", "annotations"]) || %{}

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

  def scale_statefulset(%{"kind" => "StatefulSet"} = statefulset, replicas) do
    Logger.info("Scaling statefulset", name: name(statefulset), replicas: replicas)
    statefulset = put_in(statefulset["spec"]["replicas"], replicas)

    case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(statefulset)) do
      {:ok, statefulset} ->
        {:ok, statefulset}

      {:error, reason} ->
        Logger.error("Failed to scale statefulset: #{inspect(reason)}",
          name: name(statefulset),
          replicas: replicas
        )

        {:error, reason}
    end
  end

  @doc """
  Scale down a StatefulSet to 0 replicas.
  Saves the original replica count as an annotation before scaling down.
  Also adds managed-by annotation to track which SleepSchedule manages this resource.
  """
  def scale_down(%{"kind" => "StatefulSet"} = statefulset, sleep_schedule_key \\ nil) do
    try do
      # Always save original replicas before scale down operations
      statefulset = save_original_replicas(statefulset, sleep_schedule_key)

      # Then check if the StatefulSet is already scaled down
      case Drowzee.K8s.ResourceUtils.check_resource_state(statefulset, :scale_down) do
        {:already_in_desired_state, statefulset} ->
          # Already scaled down, but we saved the original replicas above
          # Need to persist the annotation since no other update will happen
          case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(statefulset)) do
            {:ok, updated_statefulset} ->
              Logger.debug("Saved original replicas for already-scaled-down StatefulSet", name: name(statefulset))
              {:ok, updated_statefulset}
            {:error, reason} ->
              Logger.warning("Failed to save original replicas annotation: #{inspect(reason)}", name: name(statefulset))
              {:ok, statefulset}  # Return success even if annotation failed
          end

        {:needs_modification, statefulset} ->
          # Original replicas already saved above, just do the scale operation
          # Scale down to 0
          case scale_statefulset(statefulset, 0) do
            {:ok, scaled_statefulset} ->
              {:ok, scaled_statefulset}

            {:error, reason} ->
              # Mark as failed with annotations using centralized function
              case Drowzee.K8s.ResourceUtils.set_error_annotations(
                     statefulset,
                     :statefulset,
                     "Failed to scale: #{inspect(reason)}"
                   ) do
                {:ok, failed_statefulset} ->
                  {:error, failed_statefulset,
                   "Failed to scale down statefulset #{name(statefulset)}: #{inspect(reason)}"}

                {:error, _} ->
                  # If updating annotations fails, still return the original error
                  {:error, statefulset,
                   "Failed to scale down statefulset #{name(statefulset)}: #{inspect(reason)}"}
              end
          end
      end
    rescue
      e ->
        Logger.error("Error scaling down statefulset: #{inspect(e)}", name: name(statefulset))
        # Mark as failed with annotations using centralized function
        case Drowzee.K8s.ResourceUtils.set_error_annotations(
               statefulset,
               :statefulset,
               "Exception: #{inspect(e)}"
             ) do
          {:ok, failed_statefulset} ->
            {:error, failed_statefulset,
             "Failed to scale down statefulset #{name(statefulset)}: #{inspect(e)}"}

          {:error, _} ->
            # If updating annotations fails, still return the original error
            {:error, statefulset,
             "Failed to scale down statefulset #{name(statefulset)}: #{inspect(e)}"}
        end
    catch
      kind, reason ->
        Logger.error("Error scaling down statefulset: #{inspect(reason)}", name: name(statefulset))
        # Mark as failed with annotations using centralized function
        case Drowzee.K8s.ResourceUtils.set_error_annotations(
               statefulset,
               :statefulset,
               "Caught #{kind}: #{inspect(reason)}"
             ) do
          {:ok, failed_statefulset} ->
            {:error, failed_statefulset,
             "Failed to scale down statefulset #{name(statefulset)}: #{inspect(reason)}"}

          {:error, _} ->
            # If updating annotations fails, still return the original error
            {:error, statefulset,
             "Failed to scale down statefulset #{name(statefulset)}: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Scale up a StatefulSet to its original replica count.
  Gets the original replica count from the annotation and scales up to that value.
  Clears any error annotations after successful scaling.
  Also adds managed-by annotation to track which SleepSchedule manages this resource.
  """
  def scale_up(%{"kind" => "StatefulSet"} = statefulset, sleep_schedule_key \\ nil) do
    try do
      # First check if the StatefulSet is already scaled up
      case Drowzee.K8s.ResourceUtils.check_resource_state(statefulset, :scale_up) do
        {:already_in_desired_state, statefulset} ->
          # Already scaled up, return success
          {:ok, statefulset}

        {:needs_modification, statefulset} ->
          # Add managed-by annotation before scaling up
          statefulset = add_managed_by_annotation(statefulset, sleep_schedule_key)

          # Get the original replica count
          original = get_original_replicas(statefulset)

          # Scale up to original replicas
          case scale_statefulset(statefulset, original) do
            {:ok, scaled_statefulset} ->
              # Clear any error annotations and return the result
              Drowzee.K8s.ResourceUtils.clear_error_annotations(scaled_statefulset, :statefulset)

            {:error, reason} ->
              # Mark as failed with annotations using centralized function
              case Drowzee.K8s.ResourceUtils.set_error_annotations(
                     statefulset,
                     :statefulset,
                     "Failed to scale: #{inspect(reason)}"
                   ) do
                {:ok, failed_statefulset} ->
                  {:error, failed_statefulset,
                   "Failed to scale up statefulset #{name(statefulset)}: #{inspect(reason)}"}

                {:error, _} ->
                  # If updating annotations fails, still return the original error
                  {:error, statefulset,
                   "Failed to scale up statefulset #{name(statefulset)}: #{inspect(reason)}"}
              end
          end
      end
    rescue
      e ->
        Logger.error("Error scaling up statefulset: #{inspect(e)}", name: name(statefulset))
        # Mark as failed with annotations using centralized function
        case Drowzee.K8s.ResourceUtils.set_error_annotations(
               statefulset,
               :statefulset,
               "Exception: #{inspect(e)}"
             ) do
          {:ok, failed_statefulset} ->
            {:error, failed_statefulset,
             "Failed to scale up statefulset #{name(statefulset)}: #{inspect(e)}"}

          {:error, _} ->
            # If updating annotations fails, still return the original error
            {:error, statefulset,
             "Failed to scale up statefulset #{name(statefulset)}: #{inspect(e)}"}
        end
    catch
      kind, reason ->
        Logger.error("Error scaling up statefulset: #{inspect(reason)}", name: name(statefulset))
        # Mark as failed with annotations using centralized function
        case Drowzee.K8s.ResourceUtils.set_error_annotations(
               statefulset,
               :statefulset,
               "Caught #{kind}: #{inspect(reason)}"
             ) do
          {:ok, failed_statefulset} ->
            {:error, failed_statefulset,
             "Failed to scale up statefulset #{name(statefulset)}: #{inspect(reason)}"}

          {:error, _} ->
            # If updating annotations fails, still return the original error
            {:error, statefulset,
             "Failed to scale up statefulset #{name(statefulset)}: #{inspect(reason)}"}
        end
    end
  end
end
