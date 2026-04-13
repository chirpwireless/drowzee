defmodule Drowzee.K8s.CronJobTest do
  use ExUnit.Case, async: true

  alias Drowzee.K8s.CronJob

  defp build_cronjob(suspend, annotations \\ %{}) do
    %{
      "apiVersion" => "batch/v1",
      "kind" => "CronJob",
      "metadata" => %{
        "name" => "test-cj",
        "namespace" => "test-ns",
        "uid" => "cj-uid-123",
        "resourceVersion" => "1000",
        "annotations" => annotations
      },
      "spec" => %{
        "suspend" => suspend,
        "schedule" => "0 2 * * *",
        "jobTemplate" => %{"spec" => %{"template" => %{"spec" => %{"containers" => []}}}}
      }
    }
  end

  describe "name/1 and namespace/1" do
    test "extracts name and namespace" do
      cj = build_cronjob(false)
      assert CronJob.name(cj) == "test-cj"
      assert CronJob.namespace(cj) == "test-ns"
    end
  end

  describe "suspend/1" do
    test "returns suspend state" do
      assert CronJob.suspend(build_cronjob(true)) == true
      assert CronJob.suspend(build_cronjob(false)) == false
    end

    test "defaults to false when missing" do
      cj = %{"metadata" => %{}, "spec" => %{}}
      assert CronJob.suspend(cj) == false
    end
  end

  describe "save_original_state/2" do
    test "saves current suspend state as annotation" do
      cj = build_cronjob(false)
      result = CronJob.save_original_state(cj, "ns/schedule")

      assert get_in(result, ["metadata", "annotations", "drowzee.io/original-suspend"]) == "false"
      assert get_in(result, ["metadata", "annotations", "drowzee.io/managed-by"]) == "ns/schedule"
    end

    test "saves true when currently suspended" do
      cj = build_cronjob(true)
      result = CronJob.save_original_state(cj, "ns/schedule")

      assert get_in(result, ["metadata", "annotations", "drowzee.io/original-suspend"]) == "true"
    end
  end

  describe "get_original_state/1" do
    test "returns true when annotation is true" do
      cj = build_cronjob(true, %{"drowzee.io/original-suspend" => "true"})
      assert CronJob.get_original_state(cj) == true
    end

    test "returns false when annotation is false" do
      cj = build_cronjob(true, %{"drowzee.io/original-suspend" => "false"})
      assert CronJob.get_original_state(cj) == false
    end

    test "defaults to false when no annotation" do
      cj = build_cronjob(true)
      assert CronJob.get_original_state(cj) == false
    end
  end

  describe "add_managed_by_annotation/2" do
    test "adds managed-by annotation" do
      cj = build_cronjob(false)
      result = CronJob.add_managed_by_annotation(cj, "ns/my-schedule")

      assert get_in(result, ["metadata", "annotations", "drowzee.io/managed-by"]) == "ns/my-schedule"
    end

    test "does nothing when key is nil" do
      cj = build_cronjob(false)
      result = CronJob.add_managed_by_annotation(cj, nil)
      assert result == cj
    end
  end
end
