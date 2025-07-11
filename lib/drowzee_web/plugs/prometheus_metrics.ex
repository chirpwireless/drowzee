defmodule DrowzeeWeb.Plugs.PrometheusMetrics do
  @moduledoc """
  Plug for exposing Prometheus metrics at /metrics endpoint.
  """

  import Plug.Conn
  use Prometheus.Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.request_path do
      "/metrics" ->
        # Serve Prometheus metrics
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, Prometheus.Format.Text.format())
        |> halt()
      _ ->
        # Continue with the next plug
        conn
    end
  end
end
