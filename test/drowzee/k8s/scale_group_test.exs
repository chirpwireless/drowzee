defmodule Drowzee.K8s.ScaleGroupTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Drowzee.K8s.SleepSchedule

  @schedule %{
    "apiVersion" => "drowzee.challengr.io/v1beta1",
    "kind" => "SleepSchedule",
    "metadata" => %{"name" => "test-schedule", "namespace" => "test-ns", "uid" => "sched-uid-123", "resourceVersion" => "1000", "generation" => 1},
    "spec" => %{
      "enabled" => true,
      "sleepTime" => "23:00",
      "wakeTime" => "08:00",
      "timezone" => "UTC",
      "dayOfWeek" => "*",
      "deployments" => [%{"name" => "dep-a"}],
      "statefulsets" => [%{"name" => "sts-a"}],
      "cronjobs" => [%{"name" => "cj-a"}]
    }
  }

  @names %{deployments: ["dep-a"], statefulsets: ["sts-a"], cronjobs: ["cj-a"]}

  defp deployment(name, replicas, annotations \\ %{}) do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{"name" => name, "namespace" => "test-ns", "uid" => "dep-uid-#{name}", "resourceVersion" => "1000", "annotations" => annotations},
      "spec" => %{"replicas" => replicas, "selector" => %{"matchLabels" => %{"app" => name}}},
      "status" => %{"replicas" => replicas, "readyReplicas" => replicas, "availableReplicas" => replicas}
    }
  end

  defp statefulset(name, replicas, annotations \\ %{}) do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "StatefulSet",
      "metadata" => %{"name" => name, "namespace" => "test-ns", "uid" => "sts-uid-#{name}", "resourceVersion" => "1000", "annotations" => annotations},
      "spec" => %{"replicas" => replicas, "selector" => %{"matchLabels" => %{"app" => name}}},
      "status" => %{"replicas" => replicas, "readyReplicas" => replicas}
    }
  end

  defp cronjob(name, suspend) do
    %{
      "apiVersion" => "batch/v1",
      "kind" => "CronJob",
      "metadata" => %{"name" => name, "namespace" => "test-ns", "uid" => "cj-uid-#{name}", "resourceVersion" => "1000", "annotations" => %{}},
      "spec" => %{"suspend" => suspend, "schedule" => "0 2 * * *", "jobTemplate" => %{"spec" => %{"template" => %{"spec" => %{"containers" => []}}}}}
    }
  end

  defp register_mock(get_responses) do
    K8s.Client.DynamicHTTPProvider.register(self(), fn method, url, body, _headers, _opts ->
      url_str = URI.to_string(url)

      case method do
        :get ->
          resource = Enum.find_value(get_responses, fn {pattern, res} ->
            if String.contains?(url_str, pattern), do: res
          end)

          if resource do
            {:ok, resource}
          else
            {:error, %K8s.Client.APIError{message: "not found", reason: "NotFound"}}
          end

        m when m in [:put, :patch, :post] ->
          {:ok, Jason.decode!(body)}

        _ ->
          {:ok, %{}}
      end
    end)
  end

  describe "scale_down_group/2" do
    test "scales down all resource types" do
      register_mock(%{
        "deployments/dep-a" => deployment("dep-a", 3),
        "statefulsets/sts-a" => statefulset("sts-a", 2),
        # Exact cronjob: get returns it, list not needed
        "cronjobs/cj-a" => cronjob("cj-a", false)
      })

      assert {:ok, results} = SleepSchedule.scale_down_group(@schedule, @names)
      assert length(results) == 3

      dep = Enum.find(results, &(&1["kind"] == "Deployment"))
      assert dep["spec"]["replicas"] == 0

      sts = Enum.find(results, &(&1["kind"] == "StatefulSet"))
      assert sts["spec"]["replicas"] == 0

      cj = Enum.find(results, &(&1["kind"] == "CronJob"))
      assert cj["spec"]["suspend"] == true
    end

    test "returns partial when some resources not found" do
      register_mock(%{
        "deployments/dep-a" => deployment("dep-a", 3)
        # statefulset and cronjob not registered → not found
      })

      names = %{deployments: ["dep-a"], statefulsets: ["sts-missing"], cronjobs: ["cj-missing"]}
      assert {:partial, ok_results, errors} = SleepSchedule.scale_down_group(@schedule, names)
      assert length(ok_results) == 1
      assert length(errors) == 2
    end

    test "returns ok with empty lists when no resources" do
      register_mock(%{})
      names = %{deployments: [], statefulsets: [], cronjobs: []}
      assert {:ok, []} = SleepSchedule.scale_down_group(@schedule, names)
    end
  end

  describe "scale_up_group/2" do
    test "scales up all resource types" do
      register_mock(%{
        "deployments/dep-a" => deployment("dep-a", 0, %{"drowzee.io/original-replicas" => "3"}),
        "statefulsets/sts-a" => statefulset("sts-a", 0, %{"drowzee.io/original-replicas" => "2"}),
        "cronjobs/cj-a" => cronjob("cj-a", true)
      })

      names = %{deployments: ["dep-a"], statefulsets: ["sts-a"], cronjobs: ["cj-a"]}
      assert {:ok, results} = SleepSchedule.scale_up_group(@schedule, names)
      assert length(results) == 3

      dep = Enum.find(results, &(&1["kind"] == "Deployment"))
      assert dep["spec"]["replicas"] == 3

      sts = Enum.find(results, &(&1["kind"] == "StatefulSet"))
      assert sts["spec"]["replicas"] == 2

      cj = Enum.find(results, &(&1["kind"] == "CronJob"))
      assert cj["spec"]["suspend"] == false
    end
  end
end
