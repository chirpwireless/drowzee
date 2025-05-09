defmodule Drowzee.SleepCheckerTest do
  @moduledoc false
  use ExUnit.Case, async: false

  test "parses a valid time in 12-hour format" do
    assert {:ok, %DateTime{}} = Drowzee.SleepChecker.parse_time("12:00am", "Australia/Sydney")
    assert {:ok, %DateTime{}} = Drowzee.SleepChecker.parse_time("10:45am", "Australia/Sydney")
    assert {:ok, %DateTime{}} = Drowzee.SleepChecker.parse_time("02:30pm", "Australia/Sydney")
  end
  
  test "parses a valid time in 24-hour format" do
    assert {:ok, dt} = Drowzee.SleepChecker.parse_time("00:00", "Australia/Sydney")
    assert dt.hour == 0
    assert dt.minute == 0
    
    assert {:ok, dt} = Drowzee.SleepChecker.parse_time("10:45", "Australia/Sydney")
    assert dt.hour == 10
    assert dt.minute == 45
    
    assert {:ok, dt} = Drowzee.SleepChecker.parse_time("14:30", "Australia/Sydney")
    assert dt.hour == 14
    assert dt.minute == 30
    
    assert {:ok, dt} = Drowzee.SleepChecker.parse_time("23:59", "Australia/Sydney")
    assert dt.hour == 23
    assert dt.minute == 59
  end

  test "fails to parse an invalid time" do
    assert {:error, "Expected `hour between 1 and 12` at line 1, column 1."} = Drowzee.SleepChecker.parse_time("00:01am", "Australia/Sydney")
    assert {:error, "Expected `hour between 1 and 12` at line 1, column 1."} = Drowzee.SleepChecker.parse_time("2:01am", "Australia/Sydney")
    assert {:error, "Expected `hour between 1 and 12` at line 1, column 1."} = Drowzee.SleepChecker.parse_time("13:00am", "Australia/Sydney")
    assert {:error, "Expected `minute` at line 1, column 4."} = Drowzee.SleepChecker.parse_time("12:65am", "Australia/Sydney")
  end

  test "returns true when it's naptime with 12-hour format" do
    # Very lazy way to write this test
    assert Drowzee.SleepChecker.naptime?("12:00am", "11:59pm", "Australia/Sydney")
  end

  test "returns false when it's not naptime with 12-hour format" do
    # Very lazy way to write this test
    assert !Drowzee.SleepChecker.naptime?("11:58pm", "11:59pm", "Australia/Sydney")
  end
  
  test "returns true when it's naptime with 24-hour format" do
    assert Drowzee.SleepChecker.naptime?("00:00", "23:59", "Australia/Sydney")
  end

  test "returns false when it's not naptime with 24-hour format" do
    assert !Drowzee.SleepChecker.naptime?("23:58", "23:59", "Australia/Sydney")
  end
  
  test "works with mixed formats" do
    # 12-hour sleep time, 24-hour wake time
    assert Drowzee.SleepChecker.naptime?("12:00am", "23:59", "Australia/Sydney")
    
    # 24-hour sleep time, 12-hour wake time
    assert !Drowzee.SleepChecker.naptime?("23:58", "11:59pm", "Australia/Sydney")
  end
end
