defmodule Drowzee.K8s.CronJob do
  require Logger

  def name(cronjob), do: cronjob["metadata"]["name"]

  def namespace(cronjob), do: cronjob["metadata"]["namespace"]

  def suspend(cronjob), do: cronjob["spec"]["suspend"] || false

  @doc """
  Add the managed-by annotation to track which SleepSchedule manages this resource.
  """
  def add_managed_by_annotation(cronjob, sleep_schedule_key) do
    if sleep_schedule_key do
      annotations = get_in(cronjob, ["metadata", "annotations"]) || %{}
      updated_annotations = Map.put(annotations, "drowzee.io/managed-by", sleep_schedule_key)
      put_in(cronjob, ["metadata", "annotations"], updated_annotations)
    else
      cronjob
    end
  end

  @doc """
  Save the current suspension state as an annotation on the cronjob before suspending.
  This tracks the state before Drowzee modifies it, and should be called every time
  before suspend since users can change the state while the CronJob is awake.
  Also adds the managed-by annotation to track which SleepSchedule manages this resource.
  """
  def save_original_state(cronjob, sleep_schedule_key \\ nil) do
    current_suspend = get_in(cronjob, ["spec", "suspend"]) || false
    current_suspend_str = to_string(current_suspend)

    # Always update the annotation with the current state before suspend
    annotations = get_in(cronjob, ["metadata", "annotations"]) || %{}

    updated_annotations =
      annotations
      |> Map.put("drowzee.io/original-suspend", current_suspend_str)
      |> Map.put("drowzee.io/managed-by", sleep_schedule_key)

    put_in(cronjob, ["metadata", "annotations"], updated_annotations)
  end

  @doc """
  Get the original suspend state from the annotation, as boolean. Default to false if missing or invalid.
  """
  def get_original_state(cronjob) do
    annotations = get_in(cronjob, ["metadata", "annotations"]) || %{}

    case Map.get(annotations, "drowzee.io/original-suspend") do
      "true" -> true
      "false" -> false
      _ -> false  # Default to not suspended if annotation is missing or invalid
    end
  end

  @doc """
  Scale a cronjob by setting its suspend state, but only if it should be modified.
  For suspend operations: always suspend (save original state first if needed)
  For resume operations: only resume if the original state was not suspended
  Also adds managed-by annotation to track which SleepSchedule manages this resource.
  """
  def suspend(%{"kind" => "CronJob"} = cronjob, suspend, sleep_schedule_key \\ nil) do
    # First check if the CronJob is already in the desired state
    operation = if suspend, do: :suspend, else: :resume

    Logger.debug("CronJob suspend operation",
      name: name(cronjob),
      operation: operation,
      current_suspend: get_in(cronjob, ["spec", "suspend"]) || false
    )

    # Always save original state before suspend operations (not resume)
    cronjob = if suspend do
      Logger.debug("Saving original state before suspend", name: name(cronjob))
      save_original_state(cronjob, sleep_schedule_key)
    else
      cronjob
    end

    case Drowzee.K8s.ResourceUtils.check_resource_state(cronjob, operation) do
      {:already_in_desired_state, cronjob} ->
        if suspend do
          # CronJob already suspended, but we saved the original state above
          # Need to persist the annotation since no other update will happen
          case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(cronjob)) do
            {:ok, updated_cronjob} ->
              Logger.debug("Saved original state for already-suspended CronJob", name: name(cronjob))
              {:ok, updated_cronjob}
            {:error, reason} ->
              Logger.warning("Failed to save original state annotation: #{inspect(reason)}", name: name(cronjob))
              {:ok, cronjob}  # Return success even if annotation failed
          end
        else
          # Already in the desired state for resume, return success
          Logger.debug("CronJob already in desired state",
            name: name(cronjob),
            operation: operation
          )
          {:ok, cronjob}
        end

      {:needs_modification, cronjob} ->
        if suspend do
          # Original state already saved above, just do the suspend operation
          Logger.debug("Suspending CronJob", name: name(cronjob))
          do_suspend(cronjob, true)
        else
          # When resuming, check if the original state was suspended
          original_suspend = get_original_state(cronjob)

          Logger.debug("Resuming CronJob, checking original state",
            name: name(cronjob),
            original_suspend: original_suspend
          )

          if original_suspend do
            # The CronJob was originally suspended by the user, don't resume it
            Logger.info("CronJob was originally suspended by user, skipping resume",
              name: name(cronjob),
              original_suspend: original_suspend
            )
            {:ok, cronjob}
          else
            # The CronJob was originally not suspended, safe to resume
            Logger.debug("CronJob was not originally suspended, proceeding with resume",
              name: name(cronjob)
            )
            do_suspend(cronjob, false)
          end
        end
    end
  end

  # Internal function that actually performs the suspend/resume operation
  defp do_suspend(cronjob, suspend) do
    Logger.info("Setting cronjob suspend", name: name(cronjob), suspend: suspend)
    cronjob = put_in(cronjob["spec"]["suspend"], suspend)

    case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(cronjob)) do
      {:ok, cronjob} ->
        # Clear any previous failure annotations using the common utility function
        Drowzee.K8s.ResourceUtils.clear_error_annotations(cronjob, :cronjob)

      {:error, reason} ->
        Logger.error("Failed to suspend cronjob: #{inspect(reason)}",
          name: name(cronjob),
          suspend: suspend
        )

        # Create error message
        error_message =
          "Failed to #{(suspend && "suspend") || "unsuspend"}: #{inspect(reason)}"

        # Mark this specific resource as failed using centralized function
        # First ensure annotations exist
        cronjob_with_annotations = ensure_annotations(cronjob)

        case Drowzee.K8s.ResourceUtils.set_error_annotations(
               cronjob_with_annotations,
               :cronjob,
               error_message
             ) do
          {:ok, failed_cronjob} ->
            {:error, failed_cronjob,
             "Failed to #{(suspend && "suspend") || "unsuspend"} cronjob #{name(cronjob)}: #{inspect(reason)}"}

          {:error, _} ->
            # If updating annotations fails, still return the original error
            {:error, cronjob,
             "Failed to #{(suspend && "suspend") || "unsuspend"} cronjob #{name(cronjob)}: #{inspect(reason)}"}
        end
    end
  end

  # Helper to ensure annotations exist
  defp ensure_annotations(cronjob) do
    metadata = cronjob["metadata"] || %{}
    annotations = metadata["annotations"] || %{}

    cronjob
    |> put_in(["metadata"], metadata)
    |> put_in(["metadata", "annotations"], annotations)
  end
end
