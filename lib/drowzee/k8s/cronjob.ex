defmodule Drowzee.K8s.CronJob do
  require Logger

  def name(cronjob), do: cronjob["metadata"]["name"]

  def namespace(cronjob), do: cronjob["metadata"]["namespace"]

  def suspend(cronjob), do: cronjob["spec"]["suspend"] || false

  # Main implementation for suspending a CronJob
  def suspend_cronjob(cronjob, suspend) when is_map(cronjob) do
    # Ensure the cronjob has a kind field
    cronjob = Map.put_new(cronjob, "kind", "CronJob")

    Logger.info("Setting cronjob suspend",
      name: get_in(cronjob, ["metadata", "name"]),
      suspend: suspend,
      kind: cronjob["kind"]
    )

    # Ensure the spec field exists
    cronjob = Map.put_new(cronjob, "spec", %{})
    cronjob = put_in(cronjob["spec"]["suspend"], suspend)

    case K8s.Client.run(Drowzee.K8s.conn(), K8s.Client.update(cronjob)) do
      {:ok, cronjob} ->
        # Clear any previous failure annotations if they exist
        cronjob =
          pop_in(cronjob, [
            "metadata",
            "annotations",
            "drowzee.io/suspend-failed"
          ])
          |> elem(1)

        cronjob =
          pop_in(cronjob, [
            "metadata",
            "annotations",
            "drowzee.io/suspend-error"
          ])
          |> elem(1)

        {:ok, cronjob}

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

  # Fallback clause for non-map CronJobs
  def suspend_cronjob(cronjob, _suspend) do
    type =
      cond do
        is_list(cronjob) -> "list"
        is_binary(cronjob) -> "binary"
        is_atom(cronjob) -> "atom"
        is_number(cronjob) -> "number"
        true -> "unknown"
      end

    Logger.error("Invalid CronJob format - not a map",
      cronjob_type: type,
      cronjob_inspect: inspect(cronjob)
    )

    {:error, %{"kind" => "CronJob", "metadata" => %{"name" => "unknown"}},
     "Invalid CronJob format: expected a map"}
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
