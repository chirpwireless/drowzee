defmodule Drowzee.K8s.StatefulSet do
  require Logger

  def name(statefulset), do: statefulset["metadata"]["name"]

  def namespace(statefulset), do: statefulset["metadata"]["namespace"]

  def replicas(statefulset), do: statefulset["spec"]["replicas"] || 0

  def ready_replicas(statefulset), do: statefulset["status"]["readyReplicas"] || 0

  @doc """
  Always save (or update) the current replica count as an annotation on the statefulset.
  """
  def save_original_replicas(statefulset) do
    annotations = get_in(statefulset, ["metadata", "annotations"]) || %{}
    current = get_in(statefulset, ["spec", "replicas"]) || 0
    current_str = Integer.to_string(current)

    # Only save if:
    # - annotation is missing OR
    # - annotation value != current AND current > 0
    # This way, if someone changed the replica count while awake, you update it before sleep
    case Map.get(annotations, "drowzee.io/original-replicas") do
      nil when current > 0 ->
        put_in(
          statefulset,
          ["metadata", "annotations", "drowzee.io/original-replicas"],
          current_str
        )

      value when value != current_str and current > 0 ->
        put_in(
          statefulset,
          ["metadata", "annotations", "drowzee.io/original-replicas"],
          current_str
        )

      _ ->
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
  """
  def scale_down(%{"kind" => "StatefulSet"} = statefulset) do
    try do
      # Save the original replicas count
      statefulset = save_original_replicas(statefulset)

      # Scale down to 0
      case scale_statefulset(statefulset, 0) do
        {:ok, scaled_statefulset} ->
          {:ok, scaled_statefulset}

        {:error, reason} ->
          # Mark as failed with annotations
          failed_statefulset =
            put_in(statefulset, ["metadata", "annotations", "drowzee.io/scale-failed"], "true")

          failed_statefulset =
            put_in(
              failed_statefulset,
              ["metadata", "annotations", "drowzee.io/scale-error"],
              "Failed to scale: #{inspect(reason)}"
            )

          {:error, failed_statefulset,
           "Failed to scale down statefulset #{name(statefulset)}: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Error scaling down statefulset: #{inspect(e)}", name: name(statefulset))
        # Mark as failed with annotations
        failed_statefulset =
          put_in(statefulset, ["metadata", "annotations", "drowzee.io/scale-failed"], "true")

        failed_statefulset =
          put_in(
            failed_statefulset,
            ["metadata", "annotations", "drowzee.io/scale-error"],
            "Exception: #{inspect(e)}"
          )

        {:error, failed_statefulset,
         "Failed to scale down statefulset #{name(statefulset)}: #{inspect(e)}"}
    catch
      kind, reason ->
        Logger.error("Error scaling down statefulset: #{inspect(reason)}",
          name: name(statefulset)
        )

        # Mark as failed with annotations
        failed_statefulset =
          put_in(statefulset, ["metadata", "annotations", "drowzee.io/scale-failed"], "true")

        failed_statefulset =
          put_in(
            failed_statefulset,
            ["metadata", "annotations", "drowzee.io/scale-error"],
            "Caught #{kind}: #{inspect(reason)}"
          )

        {:error, failed_statefulset,
         "Failed to scale down statefulset #{name(statefulset)}: #{inspect(reason)}"}
    end
  end

  @doc """
  Scale up a StatefulSet to its original replica count (stored in annotations).
  Clears any error annotations after successful scaling.
  """
  def scale_up(%{"kind" => "StatefulSet"} = statefulset) do
    try do
      # Get the original replica count
      original = get_original_replicas(statefulset)

      # Scale up to original replicas
      case scale_statefulset(statefulset, original) do
        {:ok, scaled_statefulset} ->
          # Clear any error annotations and return the result
          Drowzee.K8s.ResourceUtils.clear_error_annotations(scaled_statefulset, :statefulset)

        {:error, reason} ->
          # Mark as failed with annotations
          failed_statefulset =
            put_in(statefulset, ["metadata", "annotations", "drowzee.io/scale-failed"], "true")

          failed_statefulset =
            put_in(
              failed_statefulset,
              ["metadata", "annotations", "drowzee.io/scale-error"],
              "Failed to scale: #{inspect(reason)}"
            )

          {:error, failed_statefulset,
           "Failed to scale up statefulset #{name(statefulset)}: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Error scaling up statefulset: #{inspect(e)}", name: name(statefulset))
        # Mark as failed with annotations
        failed_statefulset =
          put_in(statefulset, ["metadata", "annotations", "drowzee.io/scale-failed"], "true")

        failed_statefulset =
          put_in(
            failed_statefulset,
            ["metadata", "annotations", "drowzee.io/scale-error"],
            "Exception: #{inspect(e)}"
          )

        {:error, failed_statefulset,
         "Failed to scale up statefulset #{name(statefulset)}: #{inspect(e)}"}
    catch
      kind, reason ->
        Logger.error("Error scaling up statefulset: #{inspect(reason)}", name: name(statefulset))
        # Mark as failed with annotations
        failed_statefulset =
          put_in(statefulset, ["metadata", "annotations", "drowzee.io/scale-failed"], "true")

        failed_statefulset =
          put_in(
            failed_statefulset,
            ["metadata", "annotations", "drowzee.io/scale-error"],
            "Caught #{kind}: #{inspect(reason)}"
          )

        {:error, failed_statefulset,
         "Failed to scale up statefulset #{name(statefulset)}: #{inspect(reason)}"}
    end
  end
end
