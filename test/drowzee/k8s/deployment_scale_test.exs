defmodule Drowzee.K8s.DeploymentScaleTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Drowzee.K8s.Deployment

  defp build_deployment(name, replicas, annotations \\ %{}) do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => name,
        "namespace" => "test-ns",
        "annotations" => annotations
      },
      "spec" => %{"replicas" => replicas},
      "status" => %{"readyReplicas" => replicas}
    }
  end

  defp register_mock(responses \\ %{}) do
    K8s.Client.DynamicHTTPProvider.register(self(), fn method, url, body, _headers, _opts ->
      url_str = URI.to_string(url)

      case method do
        :get ->
          resource = Enum.find_value(responses, fn {pattern, res} ->
            if String.contains?(url_str, pattern), do: res
          end)
          if resource, do: {:ok, resource}, else: {:error, %K8s.Client.APIError{message: "not found", reason: "NotFound"}}

        m when m in [:put, :patch, :post] ->
          {:ok, Jason.decode!(body)}

        _ ->
          {:ok, %{}}
      end
    end)
  end

  describe "scale_down/2" do
    test "scales deployment from 3 to 0 and saves original replicas" do
      dep = build_deployment("my-dep", 3)
      register_mock()

      assert {:ok, result} = Deployment.scale_down(dep, "ns/schedule")
      assert result["spec"]["replicas"] == 0
      assert result["metadata"]["annotations"]["drowzee.io/original-replicas"] == "3"
      assert result["metadata"]["annotations"]["drowzee.io/managed-by"] == "ns/schedule"
    end

    test "handles already scaled down deployment" do
      dep = build_deployment("my-dep", 0, %{"drowzee.io/original-replicas" => "3"})
      register_mock()

      assert {:ok, _result} = Deployment.scale_down(dep)
    end
  end

  describe "scale_up/2" do
    test "scales deployment from 0 to original replicas" do
      dep = build_deployment("my-dep", 0, %{"drowzee.io/original-replicas" => "3"})
      register_mock()

      assert {:ok, result} = Deployment.scale_up(dep, "ns/schedule")
      assert result["spec"]["replicas"] == 3
    end

    test "returns ok when already at original replicas" do
      dep = build_deployment("my-dep", 3, %{"drowzee.io/original-replicas" => "3"})

      assert {:ok, ^dep} = Deployment.scale_up(dep)
    end

    test "defaults to 1 replica when no annotation" do
      dep = build_deployment("my-dep", 0)
      register_mock()

      assert {:ok, result} = Deployment.scale_up(dep)
      assert result["spec"]["replicas"] == 1
    end
  end

  describe "scale_deployment/2" do
    test "sets replicas and updates via K8s API" do
      dep = build_deployment("my-dep", 3)
      register_mock()

      assert {:ok, result} = Deployment.scale_deployment(dep, 5)
      assert result["spec"]["replicas"] == 5
    end
  end
end
