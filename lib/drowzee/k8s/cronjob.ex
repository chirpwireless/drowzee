defmodule Drowzee.K8s.CronJob do
  require Logger

  def name(cronjob), do: cronjob["metadata"]["name"]

  def namespace(cronjob), do: cronjob["metadata"]["namespace"]

  def suspend(cronjob), do: cronjob["spec"]["suspend"] || false

  # Main implementation for suspending a CronJob
  def suspend_cronjob(%{"kind" => "CronJob"} = cronjob, suspend) do
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
        error_message = "Failed to #{(suspend && "suspend") || "unsuspend"}: #{inspect(reason)}"
        
        # Mark this specific resource as failed using centralized function
        # First ensure annotations exist
        cronjob_with_annotations = ensure_annotations(cronjob)
        
        case Drowzee.K8s.ResourceUtils.set_error_annotations(cronjob_with_annotations, :cronjob, error_message) do
          {:ok, failed_cronjob} ->
            {:error, failed_cronjob, "Failed to #{(suspend && "suspend") || "unsuspend"} cronjob #{name(cronjob)}: #{inspect(reason)}"}
          
          {:error, _} ->
            # If updating annotations fails, still return the original error
            {:error, cronjob, "Failed to #{(suspend && "suspend") || "unsuspend"} cronjob #{name(cronjob)}: #{inspect(reason)}"}
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
