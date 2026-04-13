defmodule Drowzee.K8s.WildcardCronJobTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  defp cronjob(name) do
    %{
      "apiVersion" => "batch/v1",
      "kind" => "CronJob",
      "metadata" => %{
        "name" => name,
        "namespace" => "test-ns",
        "uid" => "cj-uid-#{name}",
        "resourceVersion" => "1000",
        "annotations" => %{}
      },
      "spec" => %{
        "suspend" => false,
        "schedule" => "0 2 * * *",
        "jobTemplate" => %{"spec" => %{"template" => %{"spec" => %{"containers" => []}}}}
      }
    }
  end

  defp register_mock(list_items, get_responses \\ %{}) do
    K8s.Client.DynamicHTTPProvider.register(self(), fn method, url, _body, _headers, _opts ->
      url_str = URI.to_string(url)

      case method do
        :get ->
          # Distinguish list vs get by checking if URL path ends with /cronjobs (list)
          # or /cronjobs/<name> (get)
          is_list = Regex.match?(~r"/cronjobs/?$", url.path || "")

          if is_list do
            {:ok, %{"items" => list_items}}
          else
            resource = Enum.find_value(get_responses, fn {pattern, res} ->
              if String.contains?(url_str, pattern), do: res
            end)

            if resource do
              {:ok, resource}
            else
              {:error, %K8s.Client.APIError{message: "not found", reason: "NotFound"}}
            end
          end

        _ ->
          {:ok, %{}}
      end
    end)
  end

  describe "get_cronjob_with_wildcard/2 — exact name" do
    test "returns cronjob for exact name match" do
      cj = cronjob("my-job")
      register_mock([], %{"cronjobs/my-job" => cj})

      name_info = %{"name" => "my-job", "is_wildcard" => false}
      assert {:ok, ^cj, "my-job"} = Drowzee.K8s.get_cronjob_with_wildcard(name_info, "test-ns")
    end

    test "returns error for missing exact name" do
      register_mock([])

      name_info = %{"name" => "missing-job", "is_wildcard" => false}
      assert {:error, %{reason: "CronJobNotFound"}} =
        Drowzee.K8s.get_cronjob_with_wildcard(name_info, "test-ns")
    end
  end

  describe "get_cronjob_with_wildcard/2 — wildcard" do
    test "resolves wildcard to single matching cronjob" do
      cj = cronjob("backup-daily-abc123")
      register_mock(
        [cj],
        %{"cronjobs/backup-daily-abc123" => cj}
      )

      name_info = %{"name" => "backup-daily-*", "is_wildcard" => true}
      assert {:ok, ^cj, "backup-daily-abc123"} =
        Drowzee.K8s.get_cronjob_with_wildcard(name_info, "test-ns")
    end

    test "returns error when no cronjobs match wildcard" do
      register_mock([cronjob("other-job")])

      name_info = %{"name" => "backup-*", "is_wildcard" => true}
      assert {:error, %{reason: "NoMatchingCronJob"}} =
        Drowzee.K8s.get_cronjob_with_wildcard(name_info, "test-ns")
    end

    test "returns error when multiple cronjobs match wildcard" do
      register_mock([
        cronjob("backup-daily-1"),
        cronjob("backup-daily-2")
      ])

      name_info = %{"name" => "backup-daily-*", "is_wildcard" => true}
      assert {:error, %{reason: "MultipleMatchingCronJobs"}} =
        Drowzee.K8s.get_cronjob_with_wildcard(name_info, "test-ns")
    end

    test "filters only matching prefix" do
      cj_match = cronjob("data-sync-abc")
      register_mock(
        [cronjob("other-job"), cj_match],
        %{"cronjobs/data-sync-abc" => cj_match}
      )

      name_info = %{"name" => "data-sync-*", "is_wildcard" => true}
      assert {:ok, ^cj_match, "data-sync-abc"} =
        Drowzee.K8s.get_cronjob_with_wildcard(name_info, "test-ns")
    end
  end
end
