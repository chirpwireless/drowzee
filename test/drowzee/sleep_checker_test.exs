defmodule Drowzee.SleepCheckerTest do
  @moduledoc false
  use ExUnit.Case, async: false

  # parse_time is private, so we test it indirectly through naptime?
  # naptime? returns {:ok, bool}

  test "accepts 12-hour format times" do
    # 12:00am to 11:59pm covers almost the entire day — should always be naptime
    assert {:ok, true} = Drowzee.SleepChecker.naptime?("12:00am", "11:59pm", "UTC", "*")
  end

  test "accepts 24-hour format times" do
    # 00:00 to 23:59 covers the entire day — should always be naptime
    assert {:ok, true} = Drowzee.SleepChecker.naptime?("00:00", "23:59", "UTC", "*")
  end

  @tag capture_log: true
  test "returns false when sleep equals wake" do
    # Same time — logs warning and returns false
    assert {:ok, false} = Drowzee.SleepChecker.naptime?("12:00", "12:00", "UTC", "*")
  end

  test "returns naptime result based on current time" do
    # Build a window that is guaranteed to include now
    now = DateTime.utc_now()
    sleep_h = now.hour
    sleep_m = max(now.minute - 1, 0)
    wake_h = rem(now.hour + 1, 24)

    sleep_str = String.pad_leading("#{sleep_h}", 2, "0") <> ":" <> String.pad_leading("#{sleep_m}", 2, "0")
    wake_str = String.pad_leading("#{wake_h}", 2, "0") <> ":" <> String.pad_leading("#{now.minute}", 2, "0")

    assert {:ok, true} = Drowzee.SleepChecker.naptime?(sleep_str, wake_str, "UTC", "*")
  end

  test "works with mixed formats" do
    # 12-hour sleep time, 24-hour wake time — covers entire day
    assert {:ok, true} = Drowzee.SleepChecker.naptime?("12:00am", "23:59", "UTC", "*")
  end
end
