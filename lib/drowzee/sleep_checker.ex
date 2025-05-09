defmodule Drowzee.SleepChecker do
  require Logger

  # Define the function head with default value
  def naptime?(sleep_time, wake_time, timezone, day_of_week \\ "*")

  def naptime?(_sleep_time, nil, _timezone, _day_of_week) do
    # If wake_time is nil, always consider it naptime (always sleeping)
    Logger.debug("Wake time is not defined, resources will remain scaled down/suspended indefinitely")
    {:ok, true}
  end

  def naptime?(sleep_time, "", timezone, day_of_week) do
    # Empty string wake_time is treated the same as nil
    naptime?(sleep_time, nil, timezone, day_of_week)
  end

  def naptime?(sleep_time, wake_time, timezone, day_of_week) do
    now = DateTime.now!(timezone)
    today_date = DateTime.to_date(now)

    # Check if schedule is active today based on day of week
    is_active_today = day_of_week_matches?(now, day_of_week)

    if not is_active_today do
      # If today is not an active day, do nothing (maintain current state)
      dow_num = Date.day_of_week(today_date)
      dow_name = Timex.day_name(dow_num)
      Logger.debug("Today (#{dow_num}/#{dow_name}) is not in day of week expression '#{day_of_week}', maintaining current state")
      {:ok, :inactive_day}
    else
      with {:ok, sleep_datetime} <- parse_time(sleep_time, today_date, timezone),
           {:ok, wake_datetime} <- parse_time(wake_time, today_date, timezone) do
        Logger.debug("Sleep time: #{format(sleep_datetime, "{h24}:{m}:{s}")}, Wake time: #{format(wake_datetime, "{h24}:{m}:{s}")}, Now: #{format(now)}")
        result = case DateTime.compare(sleep_datetime, wake_datetime) do
            :gt ->
              DateTime.compare(now, sleep_datetime) in [:eq, :gt] or DateTime.compare(now, wake_datetime) == :lt
            :lt ->
              DateTime.compare(now, sleep_datetime) in [:eq, :gt] and DateTime.compare(now, wake_datetime) == :lt
            :eq ->
              Logger.warning("Sleep time and wake time cannot be the same!")
              false
          end
        {:ok, result}
      else
        {:error, error} -> {:error, error}
      end
    end
  end

  # Check if the current day of week matches the cron-like expression
  # Examples:
  # "*" - all days (default)
  # "1-5" - Monday to Friday
  # "0,6" - Sunday and Saturday
  # "MON-FRI" - Monday to Friday
  # "SUN,SAT" - Sunday and Saturday
  defp day_of_week_matches?(_now, nil), do: true
  defp day_of_week_matches?(_now, ""), do: true
  defp day_of_week_matches?(_now, "*"), do: true
  defp day_of_week_matches?(now, day_of_week) do
    # Convert Elixir's Date.day_of_week (1-7, Monday is 1) to Crontab's format (0-6, Sunday is 0)
    dow_num = Date.day_of_week(now)
    cron_dow = if dow_num == 7, do: 0, else: dow_num
    
    # Log the current day for debugging
    Logger.debug("Current day: #{now.day}, dow_num: #{dow_num}, cron_dow: #{cron_dow}")
    
    # Handle text-based day of week expressions (MON, TUE, etc.)
    day_of_week = cond do
      # If it's already a numeric expression, keep it as is
      String.match?(day_of_week, ~r/^[0-9,\-*]+$/) -> 
        day_of_week
      # Otherwise, convert text days to numbers
      true ->
        day_of_week
        |> String.upcase()
        |> String.replace("SUN", "0")
        |> String.replace("MON", "1")
        |> String.replace("TUE", "2")
        |> String.replace("WED", "3")
        |> String.replace("THU", "4")
        |> String.replace("FRI", "5")
        |> String.replace("SAT", "6")
    end
    
    Logger.debug("Checking if day #{cron_dow} matches expression: #{day_of_week}")
    
    # Create a full cron expression with the day of week part
    # The format is: minute hour day month day_of_week
    cron_expression = "* * * * #{day_of_week}"

    # Parse the cron expression and check if it matches the current day
    case Crontab.CronExpression.Parser.parse(cron_expression) do
      {:ok, cron_expression} ->
        # Create a NaiveDateTime struct for matching (required by Crontab.DateChecker.matches_date?)
        naive_datetime = NaiveDateTime.new!(now.year, now.month, now.day, 0, 0, 0)

        # Check if the current day of week matches the expression
        # We only care about the day of week part, not the full date match
        Crontab.DateChecker.matches_date?(cron_expression, naive_datetime)

      {:error, error} ->
        # Log the error and default to true (all days) for invalid expressions
        Logger.error("Invalid cron expression for day of week: #{day_of_week}. Error: #{inspect(error)}")
        true
    end
  end

  defp parse_time(time_str, date, timezone) do
    case Timex.parse(time_str, "%-I:%M%p", :strftime) do
      {:ok, time} ->
        datetime = DateTime.new!(date, Time.new!(time.hour, time.minute, 0), timezone)
        {:ok, datetime}
      {:error, error} ->
        {:error, error}
    end
  end

  defp format(datetime, format \\ "{YYYY}-{0M}-{0D} {h24}:{m}:{s}") do
    case Timex.format(datetime, format) do
      {:ok, formatted} ->
        formatted
      {:error, error} ->
        raise "Invalid format: #{inspect(error)}"
    end
  end
end
