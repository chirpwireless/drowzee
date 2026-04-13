defmodule Drowzee.K8s.StatefulSetScaleTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Drowzee.K8s.StatefulSet

  defp build_statefulset(name, replicas, annotations \\ %{}) do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "StatefulSet",
      "metadata" => %{
        "name" => name,
        "namespace" => "test-ns",
        "annotations" => annotations
      },
      "spec" => %{"replicas" => replicas},
      "status" => %{"readyReplicas" => replicas}
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

  describe "scale_down/2" do
    test "scales statefulset from 3 to 0 and saves original replicas" do
      sts = build_statefulset("my-sts", 3)
      register_mock()

      assert {:ok, result} = StatefulSet.scale_down(sts, "ns/schedule")
      assert result["spec"]["replicas"] == 0
      assert result["metadata"]["annotations"]["drowzee.io/original-replicas"] == "3"
    end

    test "handles already scaled down statefulset" do
      sts = build_statefulset("my-sts", 0, %{"drowzee.io/original-replicas" => "3"})
      register_mock()

      assert {:ok, _result} = StatefulSet.scale_down(sts)
    end
  end

  describe "scale_up/2" do
    test "scales statefulset from 0 to original replicas" do
      sts = build_statefulset("my-sts", 0, %{"drowzee.io/original-replicas" => "3"})
      register_mock()

      assert {:ok, result} = StatefulSet.scale_up(sts, "ns/schedule")
      assert result["spec"]["replicas"] == 3
    end

    test "returns ok when already at original replicas" do
      sts = build_statefulset("my-sts", 3, %{"drowzee.io/original-replicas" => "3"})

      assert {:ok, ^sts} = StatefulSet.scale_up(sts)
    end

    test "defaults to 1 replica when no annotation" do
      sts = build_statefulset("my-sts", 0)
      register_mock()

      assert {:ok, result} = StatefulSet.scale_up(sts)
      assert result["spec"]["replicas"] == 1
    end
  end
end
