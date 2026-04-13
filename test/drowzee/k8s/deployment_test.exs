defmodule Drowzee.K8s.DeploymentTest do
  use ExUnit.Case, async: true

  alias Drowzee.K8s.Deployment

  defp build_deployment(replicas, annotations \\ %{}) do
    %{
      "kind" => "Deployment",
      "metadata" => %{
        "name" => "test-dep",
        "namespace" => "test-ns",
        "annotations" => annotations
      },
      "spec" => %{"replicas" => replicas},
      "status" => %{"readyReplicas" => replicas}
    }
  end

  describe "name/1 and namespace/1" do
    test "extracts name and namespace" do
      dep = build_deployment(3)
      assert Deployment.name(dep) == "test-dep"
      assert Deployment.namespace(dep) == "test-ns"
    end
  end

  describe "replicas/1 and ready_replicas/1" do
    test "returns replica counts" do
      dep = build_deployment(3)
      assert Deployment.replicas(dep) == 3
      assert Deployment.ready_replicas(dep) == 3
    end

    test "defaults to 0 when missing" do
      dep = %{"metadata" => %{}, "spec" => %{}, "status" => %{}}
      assert Deployment.replicas(dep) == 0
      assert Deployment.ready_replicas(dep) == 0
    end
  end

  describe "save_original_replicas/2" do
    test "saves current replicas as annotation when no annotation exists" do
      dep = build_deployment(3)
      result = Deployment.save_original_replicas(dep, "ns/schedule")

      assert get_in(result, ["metadata", "annotations", "drowzee.io/original-replicas"]) == "3"
      assert get_in(result, ["metadata", "annotations", "drowzee.io/managed-by"]) == "ns/schedule"
    end

    test "updates annotation when replicas changed and > 0" do
      dep = build_deployment(5, %{"drowzee.io/original-replicas" => "3"})
      result = Deployment.save_original_replicas(dep, "ns/schedule")

      assert get_in(result, ["metadata", "annotations", "drowzee.io/original-replicas"]) == "5"
    end

    test "does not overwrite annotation when replicas are 0" do
      dep = build_deployment(0, %{"drowzee.io/original-replicas" => "3"})
      result = Deployment.save_original_replicas(dep, "ns/schedule")

      # Should not change — replicas are 0
      assert get_in(result, ["metadata", "annotations", "drowzee.io/original-replicas"]) == "3"
    end

    test "does not save when replicas are 0 and no annotation" do
      dep = build_deployment(0)
      result = Deployment.save_original_replicas(dep, "ns/schedule")

      assert get_in(result, ["metadata", "annotations", "drowzee.io/original-replicas"]) == nil
    end

    test "does not update when annotation matches current" do
      dep = build_deployment(3, %{"drowzee.io/original-replicas" => "3"})
      result = Deployment.save_original_replicas(dep, "ns/schedule")

      # Should not add managed-by since no update needed
      assert result == dep
    end
  end

  describe "get_original_replicas/1" do
    test "returns annotated value" do
      dep = build_deployment(0, %{"drowzee.io/original-replicas" => "5"})
      assert Deployment.get_original_replicas(dep) == 5
    end

    test "defaults to 1 when no annotation" do
      dep = build_deployment(0)
      assert Deployment.get_original_replicas(dep) == 1
    end

    test "defaults to 1 for invalid annotation" do
      dep = build_deployment(0, %{"drowzee.io/original-replicas" => "invalid"})
      assert Deployment.get_original_replicas(dep) == 1
    end
  end

  describe "add_managed_by_annotation/2" do
    test "adds managed-by annotation" do
      dep = build_deployment(3)
      result = Deployment.add_managed_by_annotation(dep, "ns/my-schedule")

      assert get_in(result, ["metadata", "annotations", "drowzee.io/managed-by"]) == "ns/my-schedule"
    end

    test "does nothing when key is nil" do
      dep = build_deployment(3)
      result = Deployment.add_managed_by_annotation(dep, nil)
      assert result == dep
    end
  end
end
