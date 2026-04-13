defmodule Drowzee.K8s.StatefulSetTest do
  use ExUnit.Case, async: true

  alias Drowzee.K8s.StatefulSet

  defp build_statefulset(replicas, annotations \\ %{}) do
    %{
      "kind" => "StatefulSet",
      "metadata" => %{
        "name" => "test-sts",
        "namespace" => "test-ns",
        "annotations" => annotations
      },
      "spec" => %{"replicas" => replicas},
      "status" => %{"readyReplicas" => replicas}
    }
  end

  describe "name/1 and namespace/1" do
    test "extracts name and namespace" do
      sts = build_statefulset(3)
      assert StatefulSet.name(sts) == "test-sts"
      assert StatefulSet.namespace(sts) == "test-ns"
    end
  end

  describe "replicas/1 and ready_replicas/1" do
    test "returns replica counts" do
      sts = build_statefulset(3)
      assert StatefulSet.replicas(sts) == 3
      assert StatefulSet.ready_replicas(sts) == 3
    end

    test "defaults to 0 when missing" do
      sts = %{"metadata" => %{}, "spec" => %{}, "status" => %{}}
      assert StatefulSet.replicas(sts) == 0
      assert StatefulSet.ready_replicas(sts) == 0
    end
  end

  describe "save_original_replicas/2" do
    test "saves current replicas as annotation" do
      sts = build_statefulset(3)
      result = StatefulSet.save_original_replicas(sts, "ns/schedule")

      assert get_in(result, ["metadata", "annotations", "drowzee.io/original-replicas"]) == "3"
      assert get_in(result, ["metadata", "annotations", "drowzee.io/managed-by"]) == "ns/schedule"
    end

    test "updates when replicas changed and > 0" do
      sts = build_statefulset(5, %{"drowzee.io/original-replicas" => "3"})
      result = StatefulSet.save_original_replicas(sts, "ns/schedule")

      assert get_in(result, ["metadata", "annotations", "drowzee.io/original-replicas"]) == "5"
    end

    test "does not overwrite when replicas are 0" do
      sts = build_statefulset(0, %{"drowzee.io/original-replicas" => "3"})
      result = StatefulSet.save_original_replicas(sts, "ns/schedule")

      assert get_in(result, ["metadata", "annotations", "drowzee.io/original-replicas"]) == "3"
    end
  end

  describe "get_original_replicas/1" do
    test "returns annotated value" do
      sts = build_statefulset(0, %{"drowzee.io/original-replicas" => "5"})
      assert StatefulSet.get_original_replicas(sts) == 5
    end

    test "defaults to 1 when no annotation" do
      sts = build_statefulset(0)
      assert StatefulSet.get_original_replicas(sts) == 1
    end

    test "defaults to 1 for invalid annotation" do
      sts = build_statefulset(0, %{"drowzee.io/original-replicas" => "abc"})
      assert StatefulSet.get_original_replicas(sts) == 1
    end
  end
end
