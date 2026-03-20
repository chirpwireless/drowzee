defmodule Drowzee.Operator do
  @moduledoc """
  Defines the operator.

  The operator resource defines custom resources, watch queries and their
  controllers and serves as the entry point to the watching and handling
  processes.
  """

  use Bonny.Operator, default_watch_namespace: "default"

  step(Bonny.Pluggable.Logger, level: :debug)
  step(:delegate_to_controller)
  step(Bonny.Pluggable.ApplyStatus)
  step(Bonny.Pluggable.ApplyDescendants)

  require Logger

  @impl Bonny.Operator
  def controllers(_wrong_namespace, _opts) do
    namespaces = Drowzee.Config.namespaces()
    # Note: To watch all namespaces set BONNY_POD_NAMESPACE to "__ALL__"
    Logger.info("Configuring SleepScheduleController controller with namespace(s): #{Enum.join(namespaces, ", ")}")

    # Base controllers for SleepSchedule resources
    sleep_schedule_controllers = if Enum.member?(namespaces, :all) do
      # If :all is in the list, watch all namespaces
      [
        %{
          query: K8s.Client.watch("drowzee.challengr.io/v1beta1", "SleepSchedule", namespace: :all),
          controller: Drowzee.Controller.SleepScheduleController
        }
      ]
    else
      # Otherwise watch the specific namespaces
      Enum.map(namespaces, fn namespace ->
        %{
          query: K8s.Client.watch("drowzee.challengr.io/v1beta1", "SleepSchedule", namespace: namespace),
          controller: Drowzee.Controller.SleepScheduleController
        }
      end)
    end

    # Resource watcher controllers for drift monitoring
    # These watch Deployments, StatefulSets, and CronJobs that have drowzee.io/managed-by annotation
    resource_watcher_controllers = if Enum.member?(namespaces, :all) do
      [
        # Watch Deployments for drift
        %{
          query: K8s.Client.watch("apps/v1", "Deployment", namespace: :all),
          controller: Drowzee.Controller.DeploymentWatcherController
        },
        # Watch StatefulSets for drift
        %{
          query: K8s.Client.watch("apps/v1", "StatefulSet", namespace: :all),
          controller: Drowzee.Controller.StatefulSetWatcherController
        },
        # Watch CronJobs for drift
        %{
          query: K8s.Client.watch("batch/v1", "CronJob", namespace: :all),
          controller: Drowzee.Controller.CronJobWatcherController
        }
      ]
    else
      # Watch specific namespaces for resource drift
      Enum.flat_map(namespaces, fn namespace ->
        [
          %{
            query: K8s.Client.watch("apps/v1", "Deployment", namespace: namespace),
            controller: Drowzee.Controller.DeploymentWatcherController
          },
          %{
            query: K8s.Client.watch("apps/v1", "StatefulSet", namespace: namespace),
            controller: Drowzee.Controller.StatefulSetWatcherController
          },
          %{
            query: K8s.Client.watch("batch/v1", "CronJob", namespace: namespace),
            controller: Drowzee.Controller.CronJobWatcherController
          }
        ]
      end)
    end

    # Combine all controllers
    sleep_schedule_controllers ++ resource_watcher_controllers
  end

  @impl Bonny.Operator
  def crds() do
    [
      %Bonny.API.CRD{
        names: %{
          kind: "SleepSchedule",
          singular: "sleepschedule",
          plural: "sleepschedules",
          shortNames: ["ss"]
        },
        group: "drowzee.challengr.io",
        versions: [Drowzee.API.V1Beta1.SleepSchedule],
        scope: :Namespaced
      }
    ]
  end
end
