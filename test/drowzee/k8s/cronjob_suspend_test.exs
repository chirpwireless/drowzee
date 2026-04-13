defmodule Drowzee.K8s.CronJobSuspendTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Drowzee.K8s.CronJob

  defp build_cronjob(name, suspend, annotations \\ %{}) do
    %{
      "apiVersion" => "batch/v1",
      "kind" => "CronJob",
      "metadata" => %{
        "name" => name,
        "namespace" => "test-ns",
        "annotations" => annotations
      },
      "spec" => %{"suspend" => suspend}
    }
  end

  defp register_mock do
    K8s.Client.DynamicHTTPProvider.register(self(), fn method, _url, body, _headers, _opts ->
      case method do
        m when m in [:put, :patch, :post] -> {:ok, Jason.decode!(body)}
        _ -> {:ok, %{}}
      end
    end)
  end

  describe "suspend/3 — suspending" do
    test "suspends an active cronjob and saves original state" do
      cj = build_cronjob("my-cj", false)
      register_mock()

      assert {:ok, result} = CronJob.suspend(cj, true, "ns/schedule")
      assert result["spec"]["suspend"] == true
      assert result["metadata"]["annotations"]["drowzee.io/original-suspend"] == "false"
      assert result["metadata"]["annotations"]["drowzee.io/managed-by"] == "ns/schedule"
    end

    test "handles already suspended cronjob" do
      cj = build_cronjob("my-cj", true)
      register_mock()

      assert {:ok, _result} = CronJob.suspend(cj, true)
    end
  end

  describe "suspend/3 — resuming" do
    test "resumes a suspended cronjob that was originally not suspended" do
      cj = build_cronjob("my-cj", true, %{"drowzee.io/original-suspend" => "false"})
      register_mock()

      assert {:ok, result} = CronJob.suspend(cj, false)
      assert result["spec"]["suspend"] == false
    end

    test "does not resume a cronjob that was originally suspended by user" do
      cj = build_cronjob("my-cj", true, %{"drowzee.io/original-suspend" => "true"})
      register_mock()

      assert {:ok, result} = CronJob.suspend(cj, false)
      # Should NOT change suspend state — was originally suspended
      assert result["spec"]["suspend"] == true
    end

    test "handles already resumed cronjob" do
      cj = build_cronjob("my-cj", false, %{"drowzee.io/original-suspend" => "false"})

      assert {:ok, _result} = CronJob.suspend(cj, false)
    end
  end
end
