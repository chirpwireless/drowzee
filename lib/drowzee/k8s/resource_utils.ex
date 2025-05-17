defmodule Drowzee.K8s.ResourceUtils do
  @moduledoc """
  Utility functions for working with Kubernetes resources.
  Provides common operations for handling resource annotations and other metadata.
  """

  require Logger

  @doc """
  Clears error annotations from a resource and persists the changes to Kubernetes.

  This function removes both the scale-failed and scale-error annotations
  (or suspend-failed and suspend-error for CronJobs) and then updates
  the resource in Kubernetes to ensure the changes are persisted.

  Returns `{:ok, updated_resource}` if successful or if the update fails but the
  original operation was successful.
  """
  def clear_error_annotations(resource, type) do
    # Determine which annotations to clear based on resource type
    {failed_annotation, error_annotation} =
      case type do
        :cronjob -> {"drowzee.io/suspend-failed", "drowzee.io/suspend-error"}
        _ -> {"drowzee.io/scale-failed", "drowzee.io/scale-error"}
      end

    # Get resource name for logging
    name = get_resource_name(resource)

    # Clear the annotations in memory
    resource =
      pop_in(resource, ["metadata", "annotations", failed_annotation])
      |> elem(1)

    resource =
      pop_in(resource, ["metadata", "annotations", error_annotation])
      |> elem(1)

    # Persist the changes to Kubernetes
    case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(resource)) do
      {:ok, updated_resource} ->
        Logger.info("Successfully cleared error annotations for #{type}", name: name)
        {:ok, updated_resource}

      {:error, update_error} ->
        Logger.warning("Failed to clear error annotations for #{type}: #{inspect(update_error)}",
          name: name
        )

        # Return success anyway since the original operation worked
        {:ok, resource}
    end
  end

  @doc """
  Sets error annotations on a resource and persists the changes to Kubernetes.

  This function adds both the scale-failed and scale-error annotations
  (or suspend-failed and suspend-error for CronJobs) with the provided error reason
  and then updates the resource in Kubernetes to ensure the changes are persisted.

  Returns `{:ok, updated_resource}` if the update is successful, or
  `{:error, reason}` if the update fails.
  """
  def set_error_annotations(resource, type, error_reason) do
    # Determine which annotations to set based on resource type
    {failed_annotation, error_annotation} =
      case type do
        :cronjob -> {"drowzee.io/suspend-failed", "drowzee.io/suspend-error"}
        _ -> {"drowzee.io/scale-failed", "drowzee.io/scale-error"}
      end

    # Get resource name for logging
    name = get_resource_name(resource)

    # Set the annotations in memory
    resource = put_in(resource, ["metadata", "annotations", failed_annotation], "true")

    resource =
      put_in(resource, ["metadata", "annotations", error_annotation], inspect(error_reason))

    # Log the error annotation being set
    Logger.warning("Setting error annotation for #{type}: #{inspect(error_reason)}", name: name)

    # Persist the changes to Kubernetes
    case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(resource)) do
      {:ok, updated_resource} ->
        Logger.info("Successfully persisted error annotations for #{type}", name: name)
        {:ok, updated_resource}

      {:error, update_error} ->
        Logger.error("Failed to persist error annotations for #{type}: #{inspect(update_error)}",
          name: name
        )

        {:error, update_error}
    end
  end

  # Helper to get resource name for logging
  defp get_resource_name(resource) do
    get_in(resource, ["metadata", "name"]) || "unknown"
  end

  @doc """
  Checks if a resource is already in the desired state before attempting to modify it.
  This prevents redundant operations and unnecessary API calls.

  For StatefulSets and Deployments:
  - When scaling down, checks if replicas are already 0
  - When scaling up, checks if replicas are already at the original count

  For CronJobs:
  - When suspending, checks if already suspended
  - When resuming, checks if already resumed

  Returns `{:already_in_desired_state, resource}` if the resource is already in the desired state,
  or `{:needs_modification, resource}` if it needs to be modified.
  """
  def check_resource_state(resource, operation) do
    resource_kind = resource["kind"]
    resource_name = get_resource_name(resource)
    namespace = resource["metadata"]["namespace"]

    case {resource_kind, operation} do
      {"StatefulSet", :scale_down} ->
        if resource["spec"]["replicas"] == 0 do
          Logger.info(
            "StatefulSet #{namespace}/#{resource_name} already scaled down to 0 replicas, skipping operation"
          )

          {:already_in_desired_state, resource}
        else
          {:needs_modification, resource}
        end

      {"StatefulSet", :scale_up} ->
        current_replicas = resource["spec"]["replicas"]
        original_replicas = Drowzee.K8s.StatefulSet.get_original_replicas(resource)

        if current_replicas == original_replicas and current_replicas > 0 do
          Logger.info(
            "StatefulSet #{namespace}/#{resource_name} already scaled up to #{original_replicas} replicas, skipping operation"
          )

          {:already_in_desired_state, resource}
        else
          {:needs_modification, resource}
        end

      {"Deployment", :scale_down} ->
        if resource["spec"]["replicas"] == 0 do
          Logger.info(
            "Deployment #{namespace}/#{resource_name} already scaled down to 0 replicas, skipping operation"
          )

          {:already_in_desired_state, resource}
        else
          {:needs_modification, resource}
        end

      {"Deployment", :scale_up} ->
        current_replicas = resource["spec"]["replicas"]
        original_replicas = Drowzee.K8s.Deployment.get_original_replicas(resource)

        if current_replicas == original_replicas and current_replicas > 0 do
          Logger.info(
            "Deployment #{namespace}/#{resource_name} already scaled up to #{original_replicas} replicas, skipping operation"
          )

          {:already_in_desired_state, resource}
        else
          {:needs_modification, resource}
        end

      {"CronJob", :suspend} ->
        if resource["spec"]["suspend"] do
          Logger.info(
            "CronJob #{namespace}/#{resource_name} already suspended, skipping operation"
          )

          {:already_in_desired_state, resource}
        else
          {:needs_modification, resource}
        end

      {"CronJob", :resume} ->
        if not resource["spec"]["suspend"] do
          Logger.info("CronJob #{namespace}/#{resource_name} already resumed, skipping operation")
          {:already_in_desired_state, resource}
        else
          {:needs_modification, resource}
        end

      _ ->
        # For unknown resource types or operations, always proceed with the operation
        {:needs_modification, resource}
    end
  end
end
