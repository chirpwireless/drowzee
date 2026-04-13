defmodule Drowzee.K8s.ResourceUtilsTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Drowzee.K8s.ResourceUtils

  defp build_deployment(replicas, annotations \\ %{}) do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => "test-dep",
        "namespace" => "test-ns",
        "uid" => "dep-uid-123",
        "resourceVersion" => "1000",
        "annotations" => annotations
      },
      "spec" => %{"replicas" => replicas},
      "status" => %{"replicas" => replicas, "readyReplicas" => replicas}
    }
  end

  defp build_statefulset(replicas, annotations \\ %{}) do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "StatefulSet",
      "metadata" => %{
        "name" => "test-sts",
        "namespace" => "test-ns",
        "uid" => "sts-uid-123",
        "resourceVersion" => "1000",
        "annotations" => annotations
      },
      "spec" => %{"replicas" => replicas},
      "status" => %{"replicas" => replicas, "readyReplicas" => replicas}
    }
  end

  defp build_cronjob(suspend) do
    %{
      "apiVersion" => "batch/v1",
      "kind" => "CronJob",
      "metadata" => %{
        "name" => "test-cj",
        "namespace" => "test-ns",
        "uid" => "cj-uid-123",
        "resourceVersion" => "1000",
        "annotations" => %{}
      },
      "spec" => %{"suspend" => suspend, "schedule" => "0 2 * * *"}
    }
  end

  describe "check_resource_state/2 — Deployment" do
    test "already scaled down when replicas == 0" do
      dep = build_deployment(0)
      assert {:already_in_desired_state, ^dep} = ResourceUtils.check_resource_state(dep, :scale_down)
    end

    test "needs modification when replicas > 0 for scale_down" do
      dep = build_deployment(3)
      assert {:needs_modification, ^dep} = ResourceUtils.check_resource_state(dep, :scale_down)
    end

    test "already scaled up when replicas match original and > 0" do
      dep = build_deployment(3, %{"drowzee.io/original-replicas" => "3"})
      assert {:already_in_desired_state, ^dep} = ResourceUtils.check_resource_state(dep, :scale_up)
    end

    test "needs modification when replicas are 0 for scale_up" do
      dep = build_deployment(0, %{"drowzee.io/original-replicas" => "3"})
      assert {:needs_modification, ^dep} = ResourceUtils.check_resource_state(dep, :scale_up)
    end

    test "needs modification when replicas differ from original" do
      dep = build_deployment(1, %{"drowzee.io/original-replicas" => "3"})
      assert {:needs_modification, ^dep} = ResourceUtils.check_resource_state(dep, :scale_up)
    end
  end

  describe "check_resource_state/2 — StatefulSet" do
    test "already scaled down when replicas == 0" do
      sts = build_statefulset(0)
      assert {:already_in_desired_state, ^sts} = ResourceUtils.check_resource_state(sts, :scale_down)
    end

    test "needs modification when replicas > 0 for scale_down" do
      sts = build_statefulset(3)
      assert {:needs_modification, ^sts} = ResourceUtils.check_resource_state(sts, :scale_down)
    end

    test "already scaled up when replicas match original" do
      sts = build_statefulset(3, %{"drowzee.io/original-replicas" => "3"})
      assert {:already_in_desired_state, ^sts} = ResourceUtils.check_resource_state(sts, :scale_up)
    end

    test "needs modification when replicas are 0 for scale_up" do
      sts = build_statefulset(0, %{"drowzee.io/original-replicas" => "3"})
      assert {:needs_modification, ^sts} = ResourceUtils.check_resource_state(sts, :scale_up)
    end
  end

  describe "check_resource_state/2 — CronJob" do
    test "already suspended" do
      cj = build_cronjob(true)
      assert {:already_in_desired_state, ^cj} = ResourceUtils.check_resource_state(cj, :suspend)
    end

    test "needs modification to suspend" do
      cj = build_cronjob(false)
      assert {:needs_modification, ^cj} = ResourceUtils.check_resource_state(cj, :suspend)
    end

    test "already resumed" do
      cj = build_cronjob(false)
      assert {:already_in_desired_state, ^cj} = ResourceUtils.check_resource_state(cj, :resume)
    end

    test "needs modification to resume" do
      cj = build_cronjob(true)
      assert {:needs_modification, ^cj} = ResourceUtils.check_resource_state(cj, :resume)
    end
  end

  describe "check_resource_state/2 — unknown" do
    test "unknown kind defaults to needs_modification" do
      resource = %{"kind" => "Service", "metadata" => %{"name" => "svc", "namespace" => "ns"}}
      assert {:needs_modification, ^resource} = ResourceUtils.check_resource_state(resource, :scale_down)
    end
  end
end
