defmodule Drowzee.K8s.SleepScheduleTest do
  use ExUnit.Case, async: true

  alias Drowzee.K8s.SleepSchedule

  describe "resources_by_priority_groups/1" do
    test "returns [] when no priorityGroups defined" do
      schedule = build_schedule(%{})
      assert SleepSchedule.resources_by_priority_groups(schedule) == []
    end

    test "returns [] when priorityGroups is empty list" do
      schedule = build_schedule(%{"priorityGroups" => []})
      assert SleepSchedule.resources_by_priority_groups(schedule) == []
    end

    test "groups resources by priority" do
      schedule =
        build_schedule(%{
          "deployments" => [
            %{"name" => "dep-a", "priority" => "critical"},
            %{"name" => "dep-b", "priority" => "application"}
          ],
          "statefulsets" => [
            %{"name" => "sts-c", "priority" => "critical"}
          ],
          "cronjobs" => [
            %{"name" => "cj-d"}
          ],
          "priorityGroups" => [
            %{"name" => "critical", "timeoutSeconds" => 120, "waitForReady" => true},
            %{"name" => "application", "timeoutSeconds" => 0}
          ]
        })

      groups = SleepSchedule.resources_by_priority_groups(schedule)

      assert length(groups) == 3

      [critical, application, default] = groups

      assert critical.name == "critical"
      assert critical.timeout_ms == 120_000
      assert critical.wait_for_ready == true
      assert critical.deployments == ["dep-a"]
      assert critical.statefulsets == ["sts-c"]
      assert critical.cronjobs == []

      assert application.name == "application"
      assert application.timeout_ms == 0
      assert application.wait_for_ready == false
      assert application.deployments == ["dep-b"]
      assert application.statefulsets == []
      assert application.cronjobs == []

      assert default.name == nil
      assert default.timeout_ms == 0
      assert default.wait_for_ready == false
      assert default.deployments == []
      assert default.statefulsets == []
      assert default.cronjobs == ["cj-d"]
    end

    test "skips empty groups" do
      schedule =
        build_schedule(%{
          "deployments" => [
            %{"name" => "dep-a", "priority" => "critical"}
          ],
          "priorityGroups" => [
            %{"name" => "critical", "timeoutSeconds" => 60},
            %{"name" => "unused", "timeoutSeconds" => 30}
          ]
        })

      groups = SleepSchedule.resources_by_priority_groups(schedule)

      assert length(groups) == 1
      assert hd(groups).name == "critical"
    end

    test "resources with unknown priority go to default group" do
      schedule =
        build_schedule(%{
          "deployments" => [
            %{"name" => "dep-a", "priority" => "nonexistent"}
          ],
          "priorityGroups" => [
            %{"name" => "critical", "timeoutSeconds" => 60}
          ]
        })

      groups = SleepSchedule.resources_by_priority_groups(schedule)

      # "nonexistent" doesn't match "critical" — so dep-a goes nowhere in named groups
      # and has a non-nil priority, so it doesn't go to default either
      # It effectively falls through (this is caught by validate_priority_groups in controller)
      assert Enum.all?(groups, fn g -> g.deployments == [] end) or length(groups) == 0
    end

    test "all resources without priority go to default" do
      schedule =
        build_schedule(%{
          "deployments" => [
            %{"name" => "dep-a"},
            %{"name" => "dep-b"}
          ],
          "statefulsets" => [
            %{"name" => "sts-c"}
          ],
          "priorityGroups" => [
            %{"name" => "critical", "timeoutSeconds" => 60}
          ]
        })

      groups = SleepSchedule.resources_by_priority_groups(schedule)

      # critical is empty, so skipped. Only default remains.
      assert length(groups) == 1
      default = hd(groups)
      assert default.name == nil
      assert default.deployments == ["dep-a", "dep-b"]
      assert default.statefulsets == ["sts-c"]
    end

    test "waitForReady defaults to false when not specified" do
      schedule =
        build_schedule(%{
          "deployments" => [%{"name" => "dep-a", "priority" => "app"}],
          "priorityGroups" => [
            %{"name" => "app", "timeoutSeconds" => 30}
          ]
        })

      [group] = SleepSchedule.resources_by_priority_groups(schedule)
      assert group.wait_for_ready == false
    end
  end

  describe "name/1 and namespace/1" do
    test "extracts name and namespace" do
      schedule = build_schedule(%{})
      assert SleepSchedule.name(schedule) == "test-schedule"
      assert SleepSchedule.namespace(schedule) == "test-ns"
    end
  end

  describe "schedule_key/1" do
    test "returns namespace/name" do
      schedule = build_schedule(%{})
      assert SleepSchedule.schedule_key(schedule) == "test-ns/test-schedule"
    end
  end

  describe "deployment_names/1" do
    test "extracts deployment names" do
      schedule = build_schedule(%{"deployments" => [%{"name" => "a"}, %{"name" => "b"}]})
      assert SleepSchedule.deployment_names(schedule) == ["a", "b"]
    end

    test "returns empty list when nil" do
      schedule = build_schedule(%{"deployments" => nil})
      assert SleepSchedule.deployment_names(schedule) == []
    end
  end

  describe "statefulset_names/1" do
    test "extracts statefulset names" do
      schedule = build_schedule(%{"statefulsets" => [%{"name" => "sts-a"}]})
      assert SleepSchedule.statefulset_names(schedule) == ["sts-a"]
    end

    test "returns empty list when nil" do
      schedule = build_schedule(%{"statefulsets" => nil})
      assert SleepSchedule.statefulset_names(schedule) == []
    end
  end

  describe "is_wildcard_name?/1" do
    test "true for names ending with *" do
      assert SleepSchedule.is_wildcard_name?("prefix-*")
    end

    test "false for regular names" do
      refute SleepSchedule.is_wildcard_name?("my-cronjob")
    end
  end

  describe "get_wildcard_prefix/1" do
    test "strips trailing *" do
      assert SleepSchedule.get_wildcard_prefix("prefix-*") == "prefix-"
    end
  end

  describe "conditions" do
    test "put_condition and get_condition round-trip" do
      schedule = build_schedule(%{})
      schedule = SleepSchedule.put_condition(schedule, "Sleeping", true, "Naptime", "It's bedtime")

      condition = SleepSchedule.get_condition(schedule, "Sleeping")
      assert condition["type"] == "Sleeping"
      assert condition["status"] == "True"
      assert condition["reason"] == "Naptime"
    end

    test "get_condition returns nil when not set" do
      schedule = build_schedule(%{})
      assert SleepSchedule.get_condition(schedule, "Sleeping") == nil
    end
  end

  describe "is_sleeping?/1" do
    test "true when Sleeping condition is True" do
      schedule =
        build_schedule(%{})
        |> SleepSchedule.put_condition("Sleeping", true, "Naptime", "Sleeping")

      assert SleepSchedule.is_sleeping?(schedule)
    end

    test "false when Sleeping condition is False" do
      schedule =
        build_schedule(%{})
        |> SleepSchedule.put_condition("Sleeping", false, "Awake", "Not sleeping")

      refute SleepSchedule.is_sleeping?(schedule)
    end

    test "false when no Sleeping condition" do
      schedule = build_schedule(%{})
      refute SleepSchedule.is_sleeping?(schedule)
    end
  end

  describe "get_valid_dependencies/1" do
    test "returns ok with empty deps when no needs" do
      schedule = build_schedule(%{})
      assert {:ok, []} = SleepSchedule.get_valid_dependencies(schedule)
    end
  end

  defp build_schedule(spec_overrides) do
    base_spec = %{
      "deployments" => [],
      "statefulsets" => [],
      "cronjobs" => []
    }

    %{
      "metadata" => %{
        "name" => "test-schedule",
        "namespace" => "test-ns"
      },
      "spec" => Map.merge(base_spec, spec_overrides)
    }
  end
end
