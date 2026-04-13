defmodule Drowzee.Test.K8sMock do
  @moduledoc """
  Helper for registering K8s DynamicHTTPProvider mocks in tests.

  Usage:
    setup do
      K8sMock.register(self(), fn method, url, body, _headers, _opts ->
        # return {:ok, response_map}
      end)
      :ok
    end
  """

  @doc """
  Registers a mock function for K8s HTTP requests.
  The function receives (method, url, body, headers, opts) and must return {:ok, map()}.
  """
  def register(pid, handler) when is_function(handler) do
    K8s.Client.DynamicHTTPProvider.register(pid, handler)
  end

  @doc """
  Creates a mock that echoes back the request body (for update/patch operations)
  and returns preset resources for get operations.
  """
  def register_echo(pid, get_resources \\ %{}) do
    register(pid, fn method, url, body, _headers, _opts ->
      url_str = URI.to_string(url)

      case method do
        :get ->
          # Match by URL path to return the right resource
          resource = find_resource(url_str, get_resources)
          if resource, do: {:ok, resource}, else: {:error, %K8s.Client.APIError{message: "not found", reason: "NotFound"}}

        m when m in [:put, :patch] ->
          # Echo back the body as the updated resource
          {:ok, Jason.decode!(body)}

        _ ->
          {:ok, %{}}
      end
    end)
  end

  defp find_resource(url_str, resources) do
    Enum.find_value(resources, fn {pattern, resource} ->
      if String.contains?(url_str, pattern), do: resource
    end)
  end
end
