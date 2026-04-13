defmodule Drowzee.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    operator_children =
      if Application.get_env(:drowzee, :start_operator, true) do
        [
          {Drowzee.Operator, conn: Drowzee.K8sConn.get!(), enable_leader_election: false},
          Bonny.PeriodicTask
        ]
      else
        []
      end

    children =
      [
        DrowzeeWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:drowzee, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Drowzee.PubSub}
      ] ++
        operator_children ++
        [
          # Per-schedule coordinator infrastructure
          {Registry, keys: :unique, name: Drowzee.ScheduleRegistry},
          {DynamicSupervisor, name: Drowzee.ScheduleSupervisor, strategy: :one_for_one},

          # Start to serve requests, typically the last entry
          DrowzeeWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Drowzee.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DrowzeeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
