defmodule Drowzee.ScheduleCoordinatorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Drowzee.ScheduleCoordinator

  @test_schedule %{
    "metadata" => %{"name" => "test", "namespace" => "test-ns"},
    "spec" => %{"deployments" => [%{"name" => "dep-a"}]}
  }

  @test_names %{deployments: ["dep-a"], statefulsets: [], cronjobs: []}

  setup do
    # Registry and DynamicSupervisor are started by Drowzee.Application
    # Just verify they're running
    true = Process.whereis(Drowzee.ScheduleRegistry) != nil
    true = Process.whereis(Drowzee.ScheduleSupervisor) != nil
    :ok
  end

  describe "lifecycle" do
    test "processes all operations and terminates" do
      test_pid = self()

      scale_executor = fn direction, _schedule, _names ->
        send(test_pid, {:scaled, direction})
        {:ok, []}
      end

      operations = [
        {:scale_group, :up, @test_schedule, @test_names},
        {:wait_ms, 10},
        {:scale_group, :up, @test_schedule, @test_names}
      ]

      {:ok, pid} =
        ScheduleCoordinator.start_or_enqueue(
          "test-ns",
          "lifecycle-test",
          operations,
          scale_executor: scale_executor
        )

      ref = Process.monitor(pid)

      assert_receive {:scaled, :up}, 1_000
      assert_receive {:scaled, :up}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "single operation terminates after completion" do
      test_pid = self()

      scale_executor = fn _dir, _schedule, _names ->
        send(test_pid, :scaled)
        {:ok, []}
      end

      operations = [{:scale_group, :down, @test_schedule, @test_names}]

      {:ok, pid} =
        ScheduleCoordinator.start_or_enqueue(
          "test-ns",
          "single-op-test",
          operations,
          scale_executor: scale_executor
        )

      ref = Process.monitor(pid)

      assert_receive :scaled, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
      assert reason in [:normal, :noproc]
    end
  end

  describe "idempotency" do
    test "start_or_enqueue returns already_running for active coordinator" do
      scale_executor = fn _dir, _schedule, _names ->
        # Slow operation to keep coordinator alive
        Process.sleep(500)
        {:ok, []}
      end

      operations = [{:scale_group, :up, @test_schedule, @test_names}]

      {:ok, pid} =
        ScheduleCoordinator.start_or_enqueue(
          "test-ns",
          "idempotent-test",
          operations,
          scale_executor: scale_executor
        )

      assert {:already_running, ^pid} =
               ScheduleCoordinator.start_or_enqueue(
                 "test-ns",
                 "idempotent-test",
                 [{:scale_group, :down, @test_schedule, @test_names}]
               )
    end
  end

  describe "wait_ms" do
    test "waits specified duration between operations" do
      test_pid = self()

      scale_executor = fn _dir, _schedule, _names ->
        send(test_pid, {:scaled, System.monotonic_time(:millisecond)})
        {:ok, []}
      end

      operations = [
        {:scale_group, :up, @test_schedule, @test_names},
        {:wait_ms, 100},
        {:scale_group, :up, @test_schedule, @test_names}
      ]

      {:ok, pid} =
        ScheduleCoordinator.start_or_enqueue(
          "test-ns",
          "wait-test",
          operations,
          scale_executor: scale_executor
        )

      ref = Process.monitor(pid)

      assert_receive {:scaled, t1}, 1_000
      assert_receive {:scaled, t2}, 1_000
      assert t2 - t1 >= 90
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end

  describe "wait_for_ready" do
    test "proceeds when readiness checker returns true" do
      test_pid = self()

      scale_executor = fn _dir, _schedule, _names ->
        send(test_pid, :scaled)
        {:ok, []}
      end

      readiness_checker = fn _dir, _schedule, _names ->
        send(test_pid, :readiness_checked)
        true
      end

      operations = [
        {:scale_group, :up, @test_schedule, @test_names},
        {:wait_for_ready, :up, @test_schedule, @test_names, 30_000},
        {:scale_group, :up, @test_schedule, @test_names}
      ]

      {:ok, pid} =
        ScheduleCoordinator.start_or_enqueue(
          "test-ns",
          "ready-test",
          operations,
          scale_executor: scale_executor,
          readiness_checker: readiness_checker
        )

      ref = Process.monitor(pid)

      assert_receive :scaled, 1_000
      assert_receive :readiness_checked, 1_000
      assert_receive :scaled, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
      assert reason in [:normal, :noproc]
    end

    @tag capture_log: true
    test "times out and proceeds after max_timeout_ms" do
      test_pid = self()

      scale_executor = fn _dir, _schedule, _names ->
        send(test_pid, :scaled)
        {:ok, []}
      end

      readiness_checker = fn _dir, _schedule, _names ->
        # Never ready
        false
      end

      operations = [
        {:scale_group, :up, @test_schedule, @test_names},
        {:wait_for_ready, :up, @test_schedule, @test_names, 50},
        {:scale_group, :up, @test_schedule, @test_names}
      ]

      {:ok, pid} =
        ScheduleCoordinator.start_or_enqueue(
          "test-ns",
          "timeout-test",
          operations,
          scale_executor: scale_executor,
          readiness_checker: readiness_checker,
          poll_interval: 10
        )

      ref = Process.monitor(pid)

      assert_receive :scaled, 1_000
      # After timeout, second scale should proceed
      assert_receive :scaled, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
      assert reason in [:normal, :noproc]
    end

    test "polls multiple times before becoming ready" do
      test_pid = self()
      counter = :counters.new(1, [:atomics])

      scale_executor = fn _dir, _schedule, _names ->
        send(test_pid, :scaled)
        {:ok, []}
      end

      readiness_checker = fn _dir, _schedule, _names ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        send(test_pid, {:poll, count})
        # Ready on 3rd poll
        count >= 2
      end

      operations = [
        {:scale_group, :up, @test_schedule, @test_names},
        {:wait_for_ready, :up, @test_schedule, @test_names, 60_000},
        {:scale_group, :up, @test_schedule, @test_names}
      ]

      {:ok, pid} =
        ScheduleCoordinator.start_or_enqueue(
          "test-ns",
          "multi-poll-test",
          operations,
          scale_executor: scale_executor,
          readiness_checker: readiness_checker
        )

      ref = Process.monitor(pid)

      assert_receive :scaled, 1_000
      assert_receive {:poll, 0}, 1_000
      assert_receive {:poll, 1}, 6_000
      assert_receive {:poll, 2}, 6_000
      assert_receive :scaled, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "scale_down direction works" do
      test_pid = self()

      scale_executor = fn dir, _schedule, _names ->
        send(test_pid, {:scaled, dir})
        {:ok, []}
      end

      readiness_checker = fn dir, _schedule, _names ->
        send(test_pid, {:readiness_check, dir})
        true
      end

      operations = [
        {:scale_group, :down, @test_schedule, @test_names},
        {:wait_for_ready, :down, @test_schedule, @test_names, 30_000},
        {:scale_group, :down, @test_schedule, @test_names}
      ]

      {:ok, pid} =
        ScheduleCoordinator.start_or_enqueue(
          "test-ns",
          "down-test",
          operations,
          scale_executor: scale_executor,
          readiness_checker: readiness_checker
        )

      ref = Process.monitor(pid)

      assert_receive {:scaled, :down}, 1_000
      assert_receive {:readiness_check, :down}, 1_000
      assert_receive {:scaled, :down}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
      assert reason in [:normal, :noproc]
    end
  end

  describe "crash recovery" do
    @tag capture_log: true
    test "coordinator is not restarted after crash (temporary)" do
      scale_executor = fn _dir, _schedule, _names ->
        raise "boom"
      end

      operations = [{:scale_group, :up, @test_schedule, @test_names}]

      {pid, ref} =
        capture_log(fn ->
          {:ok, pid} =
            ScheduleCoordinator.start_or_enqueue(
              "test-ns",
              "crash-test",
              operations,
              scale_executor: scale_executor
            )

          ref = Process.monitor(pid)
          send(self(), {:pid_ref, pid, ref})
          Process.sleep(200)
        end)
        |> then(fn _log ->
          receive do
            {:pid_ref, pid, ref} -> {pid, ref}
          end
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      # Coordinator should not be restarted
      Process.sleep(100)
      assert Registry.lookup(Drowzee.ScheduleRegistry, {"test-ns", "crash-test"}) == []
    end
  end
end
