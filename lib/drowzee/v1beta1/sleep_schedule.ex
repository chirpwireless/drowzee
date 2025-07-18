defmodule Drowzee.API.V1Beta1.SleepSchedule do
  @moduledoc """
  Drowzee: SleepSchedule CRD V1Beta1 version.

  Modify the `manifest/0` function in order to override the defaults,
  e.g. to define an openAPIV3 schema, add subresources or additional
  printer columns:

  ```
  def manifest() do
    struct!(
      defaults(),
      name: "v1beta1",
      schema: %{
        openAPIV3Schema: %{
          type: :object,
          properties: %{
            spec: %{
              type: :object,
              properties: %{
                foos: %{type: :integer}
              }
            },
            status: %{
              ...
            }
          }
        }
      },
      additionalPrinterColumns: [
        %{name: "foos", type: :integer, description: "Number of foos", jsonPath: ".spec.foos"}
      ],
      subresources: %{
        status: %{}
      }
    )
  end
  ```
  """
  use Bonny.API.Version,
    hub: true

  def manifest() do
    defaults()
    |> struct!(
      name: "v1beta1",
      schema: %{
        openAPIV3Schema: %{
          type: :object,
          properties: %{
            spec: %{
              type: :object,
              required: [:sleepTime, :wakeTime, :timezone, :deployments],
              properties: %{
                enabled: %{
                  type: :boolean,
                  description: "Whether the schedule is enabled",
                  default: true
                },
                deployments: %{
                  type: :array,
                  description: "The deployments that will be slept/woken.",
                  items: %{
                    type: :object,
                    required: [:name],
                    properties: %{
                      name: %{type: :string}
                    }
                  }
                },
                statefulsets: %{
                  type: :array,
                  description: "The statefulsets that will be slept/woken.",
                  items: %{
                    type: :object,
                    required: [:name],
                    properties: %{
                      name: %{type: :string}
                    }
                  }
                },
                cronjobs: %{
                  type: :array,
                  description: "The cronjobs that will be suspended/resumed.",
                  items: %{
                    type: :object,
                    required: [:name],
                    properties: %{
                      name: %{type: :string}
                    }
                  }
                },
                needs: %{
                  type: :array,
                  description: "List of other SleepSchedules that this schedule depends on. Dependencies will be woken up first during manual wake-up operations.",
                  items: %{
                    type: :object,
                    required: [:name, :namespace],
                    properties: %{
                      name: %{
                        type: :string,
                        description: "Name of the dependency SleepSchedule"
                      },
                      namespace: %{
                        type: :string,
                        description: "Namespace of the dependency SleepSchedule"
                      }
                    }
                  }
                },
                ingressName: %{
                  type: :string,
                  description: "The ingress that will be slept/woken."
                },
                sleepTime: %{
                  type: :string,
                  description: "The time that the deployment will start sleeping (format: HH:MM for 24h or H:MMam/pm for 12h)"
                },
                wakeTime: %{
                  type: :string,
                  description: "The time that the deployment will wake up (format: HH:MM for 24h or H:MMam/pm for 12h)"
                },
                onDemand: %{
                  type: :boolean,
                  description: "If true, the schedule will not automatically wake up at wakeTime but will still auto-sleep at sleepTime. Manual overrides are still auto-removed at scheduled times. If false (default), schedule works normally with auto-wake and auto-sleep.",
                  default: false
                },
                dayOfWeek: %{
                  description: "The day of the week that the deployment will start sleeping",
                  type: :string
                },
                timezone: %{
                  description: "The timezone that the input times are based in",
                  type: :string
                }
              }
            }
          }
        }
      },
      additionalPrinterColumns: [
        %{name: "Enabled", type: :boolean, description: "Enabled", jsonPath: ".spec.enabled"},
        %{name: "SleepTime", type: :string, description: "Starts Sleeping", jsonPath: ".spec.sleepTime"},
        %{name: "WakeTime", type: :string, description: "Wakes Up", jsonPath: ".spec.wakeTime"},
        %{name: "Timezone", type: :string, description: "Timezone", jsonPath: ".spec.timezone"},
        %{name: "Deployments", type: :string, description: "Deployments", jsonPath: ".spec.deployments[*].name"},
        %{name: "Statefulsets", type: :string, description: "Statefulsets", jsonPath: ".spec.statefulsets[*].name"},
        %{name: "Cronjobs", type: :string, description: "CronJobs", jsonPath: ".spec.cronjobs[*].name"},
        %{name: "Needs", type: :string, description: "Dependencies", jsonPath: ".spec.needs[*].name"},
        %{name: "OnDemand", type: :string, description: "On Demand", jsonPath: ".spec.onDemand"},
        %{name: "Sleeping?", type: :string, description: "Current Status", jsonPath: ".status.conditions[?(@.type == \"Sleeping\")].status"},
        %{name: "Transitioning?", type: :string, description: "Status Change In Progress", jsonPath: ".status.conditions[?(@.type == \"Transitioning\")].status"},
        %{name: "ManualOverride?", type: :string, description: "Status overridden by user", jsonPath: ".status.conditions[?(@.type == \"ManualOverride\")].status"}
      ]
    )
    |> add_observed_generation_status()
    |> add_hosts_status()
    |> add_conditions()
  end

  defp add_hosts_status(version) do
    version
    |> put_in([Access.key(:subresources, %{}), :status], %{})
    |> put_in(
      [
        Access.key(:schema, %{}),
        Access.key(:openAPIV3Schema, %{type: :object}),
        Access.key(:properties, %{}),
        Access.key(:status, %{type: :object, properties: %{}}),
        Access.key(:properties, %{}),
        :hosts
      ],
      %{type: :array, items: %{type: :string}}
    )
  end
end
