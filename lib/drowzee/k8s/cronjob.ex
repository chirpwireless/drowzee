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

        # Mark this specific resource as failed
        failed_cronjob =
          ensure_annotations(cronjob)
          |> put_in(
            ["metadata", "annotations", "drowzee.io/suspend-failed"],
            "true"
          )

        failed_cronjob =
          put_in(
            failed_cronjob,
            ["metadata", "annotations", "drowzee.io/suspend-error"],
            "Failed to #{(suspend && "suspend") || "unsuspend"}: #{inspect(reason)}"
          )

        {:error, failed_cronjob,
         "Failed to #{(suspend && "suspend") || "unsuspend"} cronjob #{name(cronjob)}: #{inspect(reason)}"}
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
