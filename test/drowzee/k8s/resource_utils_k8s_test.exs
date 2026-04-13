defmodule Drowzee.K8s.ResourceUtilsK8sTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Drowzee.K8s.ResourceUtils

  defp register_mock do
    K8s.Client.DynamicHTTPProvider.register(self(), fn method, _url, body, _headers, _opts ->
      case method do
        m when m in [:put, :patch, :post] -> {:ok, Jason.decode!(body)}
        _ -> {:ok, %{}}
      end
    end)
  end

  defp build_deployment(annotations \\ %{}) do
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
      "spec" => %{"replicas" => 3},
      "status" => %{"replicas" => 3, "readyReplicas" => 3}
    }
  end

  describe "set_error_annotations/3" do
    test "sets scale-failed and scale-error for deployment" do
      dep = build_deployment()
      register_mock()

      assert {:ok, result} = ResourceUtils.set_error_annotations(dep, :deployment, "something broke")
      assert result["metadata"]["annotations"]["drowzee.io/scale-failed"] == "true"
      assert result["metadata"]["annotations"]["drowzee.io/scale-error"] =~ "something broke"
    end

    test "sets suspend-failed and suspend-error for cronjob" do
      cj = %{
        "apiVersion" => "batch/v1",
        "kind" => "CronJob",
        "metadata" => %{"name" => "test-cj", "namespace" => "test-ns", "uid" => "cj-uid-123", "resourceVersion" => "1000", "annotations" => %{}},
        "spec" => %{"suspend" => false, "schedule" => "0 2 * * *"}
      }
      register_mock()

      assert {:ok, result} = ResourceUtils.set_error_annotations(cj, :cronjob, "suspend failed")
      assert result["metadata"]["annotations"]["drowzee.io/suspend-failed"] == "true"
      assert result["metadata"]["annotations"]["drowzee.io/suspend-error"] =~ "suspend failed"
    end
  end

  describe "clear_error_annotations/2" do
    test "removes scale error annotations for deployment" do
      dep = build_deployment(%{
        "drowzee.io/scale-failed" => "true",
        "drowzee.io/scale-error" => "something broke"
      })
      register_mock()

      assert {:ok, result} = ResourceUtils.clear_error_annotations(dep, :deployment)
      refute Map.has_key?(result["metadata"]["annotations"], "drowzee.io/scale-failed")
      refute Map.has_key?(result["metadata"]["annotations"], "drowzee.io/scale-error")
    end
  end
end
