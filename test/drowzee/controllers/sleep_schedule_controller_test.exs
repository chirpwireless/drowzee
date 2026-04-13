defmodule Drowzee.Controller.SleepScheduleControllerTest do
  @moduledoc false
  use ExUnit.Case, async: false
  use Bonny.Axn.Test

  alias Drowzee.Controller.SleepScheduleController

  @sleep_schedule_resource %{
    "apiVersion" => "drowzee.challengr.io/v1beta1",
    "kind" => "SleepSchedule",
    "metadata" => %{
      "name" => "test-schedule",
      "namespace" => "default",
      "uid" => "test-uid",
      "generation" => 1
    },
    "spec" => %{
      "enabled" => true,
      "sleepTime" => "23:00",
      "wakeTime" => "08:00",
      "timezone" => "UTC",
      "deployments" => [%{"name" => "test-dep"}]
    }
  }

  test "add is handled and returns axn" do
    axn = axn(:add, resource: @sleep_schedule_resource)
    result = SleepScheduleController.call(axn, [])
    assert is_struct(result, Bonny.Axn)
  end

  test "modify is handled and returns axn" do
    axn = axn(:modify, resource: @sleep_schedule_resource)
    result = SleepScheduleController.call(axn, [])
    assert is_struct(result, Bonny.Axn)
  end

  test "reconcile is handled and returns axn" do
    axn = axn(:reconcile, resource: @sleep_schedule_resource)
    result = SleepScheduleController.call(axn, [])
    assert is_struct(result, Bonny.Axn)
  end

  test "delete is handled and returns axn" do
    axn = axn(:delete, resource: @sleep_schedule_resource)
    result = SleepScheduleController.call(axn, [])
    assert is_struct(result, Bonny.Axn)
  end
end
