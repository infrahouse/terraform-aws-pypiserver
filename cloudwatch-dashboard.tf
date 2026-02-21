resource "aws_cloudwatch_dashboard" "pypiserver" {
  count          = var.enable_cloudwatch_dashboard ? 1 : 0
  dashboard_name = var.service_name

  dashboard_body = jsonencode(
    {
      widgets = flatten([
        # === ECS Section ===
        {
          type = "text"
          properties = {
            markdown = join("", [
              "## ECS — Containers running pypiserver\n",
              "**CPU & Memory Utilization** — Percentage of ",
              "*reserved* resources actually used by containers. ",
              "If CPU stays above 80%, containers are struggling ",
              "to serve requests fast enough — consider adding ",
              "more tasks or bigger instances. ",
              "If Memory stays high, containers may get ",
              "OOM-killed (restarted).\n\n",
              "**Task Count** — How many pypiserver containers ",
              "are running. ",
              "'Desired' is what ECS wants, 'Running' is what's ",
              "actually up, 'Pending' means waiting for an EC2 ",
              "instance with free capacity. ",
              "Persistent 'Pending' tasks means the cluster is ",
              "out of room — ASG needs to scale up.\n\n",
              "**Container Insights** — Average **per-task** ",
              "CPU (in CPU units, where 1024 = 1 vCPU) and ",
              "memory (in MB). ",
              "The red line is each container's reservation. ",
              "If you see 12 tasks and CPU utilized = 3.7, ",
              "it means each task uses ~3.7 CPU units out of ",
              "640 reserved — massively over-provisioned. ",
              "Multiply by task count for cluster total ",
              "(e.g. 12 tasks x 3.7 = 44 units total).",
            ])
          }
          width  = 24
          height = 4
          x      = 0
          y      = 0
        },

        # Row 1: ECS Service Utilization
        {
          type = "metric"
          properties = {
            metrics = [
              [
                "AWS/ECS",
                "CPUUtilization",
                "ServiceName",
                module.pypiserver.service_name,
                "ClusterName",
                module.pypiserver.cluster_name,
                {
                  stat = "Average", label = "CPU Average"
                }
              ],
              [
                "...", { stat = "Maximum", label = "CPU Maximum" }
              ],
              [
                ".", "MemoryUtilization", ".", ".", ".", ".", { stat = "Average", label = "Memory Average" }
              ],
              [
                "...", { stat = "Maximum", label = "Memory Maximum" }
              ]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "ECS Service - CPU & Memory Utilization"
            period  = 300
            yAxis = {
              left = {
                min = 0
                max = 100
              }
            }
          }
          width  = 12
          height = 6
          x      = 0
          y      = 4
        },
        {
          type = "metric"
          properties = {
            metrics = [
              [
                "ECS/ContainerInsights",
                "DesiredTaskCount",
                "ServiceName",
                module.pypiserver.service_name,
                "ClusterName",
                module.pypiserver.cluster_name,
                { stat = "Average", label = "Desired" }
              ],
              [
                ".",
                "RunningTaskCount",
                ".",
                ".",
                ".",
                ".",
                { stat = "Average", label = "Running" }
              ],
              [
                ".",
                "PendingTaskCount",
                ".",
                ".",
                ".",
                ".",
                { stat = "Average", label = "Pending" }
              ]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "ECS Service - Task Count (requires Container Insights)"
            period  = 300
            yAxis = {
              left = {
                min = 0
              }
            }
          }
          width  = 12
          height = 6
          x      = 12
          y      = 4
        },

        # Row 2: Container Insights
        {
          type = "metric"
          properties = {
            metrics = [
              [
                "ECS/ContainerInsights",
                "CpuUtilized",
                "ServiceName",
                module.pypiserver.service_name,
                "ClusterName",
                module.pypiserver.cluster_name,
                { stat = "Average", label = "Average per task" }
              ],
              [
                "...", { stat = "Maximum", label = "Busiest task" }
              ]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "Container Insights - CPU Utilized (units, 1024 = 1 vCPU)"
            period  = 300
            yAxis = {
              left = {
                min = 0
              }
            }
            annotations = {
              horizontal = [
                {
                  label = "Container CPU reservation (${local.container_cpu} units)"
                  value = local.container_cpu
                  color = "#d62728"
                }
              ]
            }
          }
          width  = 12
          height = 6
          x      = 0
          y      = 10
        },
        {
          type = "metric"
          properties = {
            metrics = [
              [
                "ECS/ContainerInsights",
                "MemoryUtilized",
                "ServiceName",
                module.pypiserver.service_name,
                "ClusterName",
                module.pypiserver.cluster_name,
                { stat = "Average", label = "Average per task (MB)" }
              ],
              [
                "...", { stat = "Maximum", label = "Busiest task (MB)" }
              ]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "Container Insights - Memory Utilized (MB)"
            period  = 300
            yAxis = {
              left = {
                min = 0
              }
            }
            annotations = {
              horizontal = [
                {
                  label = "Soft limit (${local.container_memory_reservation_actual} MB)"
                  value = local.container_memory_reservation_actual
                  color = "#ff9900"
                },
                {
                  label = "Hard limit (${var.container_memory} MB) - OOM kill"
                  value = var.container_memory
                  color = "#d62728"
                }
              ]
            }
          }
          width  = 12
          height = 6
          x      = 12
          y      = 10
        },

        # === ALB Section ===
        {
          type = "text"
          properties = {
            markdown = join("", [
              "## ALB — Load balancer in front of pypiserver\n",
              "**Response Time** — How long `pip install` ",
              "requests take from the ALB's perspective. ",
              "p50 is the median, p99 is the slowest 1%. ",
              "Spikes usually mean EFS is slow (directory ",
              "scans for `--backend simple-dir`) or ",
              "containers are overloaded.\n\n",
              "**Request Count & HTTP Codes** — Traffic ",
              "volume and errors. ",
              "2xx = successful package downloads/uploads. ",
              "4xx = auth failures or missing packages ",
              "(usually normal). ",
              "5xx = pypiserver crashed or timed out ",
              "(investigate immediately).\n\n",
              "**Connections** — How many TCP connections ",
              "are open to the ALB. ",
              "**Target Health** — How many containers the ",
              "ALB considers healthy. ",
              "If 'Unhealthy' is non-zero, containers are ",
              "failing health checks — check ECS events ",
              "and container logs.",
            ])
          }
          width  = 24
          height = 4
          x      = 0
          y      = 16
        },

        # Row 3: ALB Response & Request Metrics
        {
          type = "metric"
          properties = {
            metrics = [
              ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer",
                module.pypiserver.load_balancer_arn_suffix,
                { stat = "p50", label = "p50" }
              ],
              ["...", { stat = "p95", label = "p95" }],
              ["...", { stat = "p99", label = "p99" }],
              ["...", { stat = "Average", label = "Average" }]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "ALB - Target Response Time (seconds)"
            period  = 300
            yAxis = {
              left = {
                min = 0
              }
            }
            annotations = {
              horizontal = [
                {
                  label = "2s target (normal)"
                  value = 2
                  fill  = "below"
                  color = "#2ca02c"
                },
                {
                  label = "15s target (burst)"
                  value = 15
                  fill  = "above"
                  color = "#d62728"
                }
              ]
            }
          }
          width  = 12
          height = 6
          x      = 0
          y      = 20
        },
        {
          type = "metric"
          properties = {
            metrics = [
              [
                "AWS/ApplicationELB", "RequestCount",
                "LoadBalancer", module.pypiserver.load_balancer_arn_suffix,
                {
                  stat = "Sum", label = "Total Requests"
                }
              ],
              [".", "HTTPCode_Target_2XX_Count", ".", ".", { stat = "Sum", label = "2xx Success" }],
              [".", "HTTPCode_Target_4XX_Count", ".", ".", { stat = "Sum", label = "4xx Client Error" }],
              [".", "HTTPCode_Target_5XX_Count", ".", ".", { stat = "Sum", label = "5xx Server Error" }]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "ALB - Request Count & HTTP Status Codes"
            period  = 300
            yAxis = {
              left = {
                min = 0
              }
            }
          }
          width  = 12
          height = 6
          x      = 12
          y      = 20
        },

        # Row 4: ALB Connection & Health Metrics
        {
          type = "metric"
          properties = {
            metrics = [
              [
                "AWS/ApplicationELB", "ActiveConnectionCount",
                "LoadBalancer", module.pypiserver.load_balancer_arn_suffix,
                { stat = "Sum", label = "Active Connections" }
              ],
              [".", "NewConnectionCount", ".", ".", { stat = "Sum", label = "New Connections" }],
              [".", "ProcessedBytes", ".", ".", { stat = "Sum", label = "Processed Bytes" }]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "ALB - Connection Metrics"
            period  = 300
            yAxis = {
              left = {
                min = 0
              }
            }
          }
          width  = 12
          height = 6
          x      = 0
          y      = 26
        },
        {
          type = "metric"
          properties = {
            metrics = [
              [
                "AWS/ApplicationELB", "HealthyHostCount",
                "TargetGroup", module.pypiserver.target_group_arn_suffix,
                "LoadBalancer", module.pypiserver.load_balancer_arn_suffix,
                {
                  stat = "Average", label = "Healthy Targets"
                }
              ],
              [".", "UnHealthyHostCount", ".", ".", ".", ".", { stat = "Average", label = "Unhealthy Targets" }]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "ALB - Target Health"
            period  = 300
            yAxis = {
              left = {
                min = 0
              }
            }
          }
          width  = 12
          height = 6
          x      = 12
          y      = 26
        },

        # === EFS Section ===
        {
          type = "text"
          properties = {
            markdown = join("", [
              "## EFS — Shared filesystem storing packages\n",
              "All pypiserver containers share one EFS volume. ",
              "Every `pip install` triggers a directory scan ",
              "on EFS (`--backend simple-dir`), so EFS ",
              "performance directly affects response times.",
              "\n\n",
              "**Throughput Utilization** — How close EFS is ",
              "to its I/O limit. Above 80% means requests ",
              "may start queuing.\n\n",
              "**Client Connections** — Number of NFS mounts ",
              "(one per EC2 instance, not per container). ",
              "Should match the number of instances in the ",
              "ASG.\n\n",
              "**I/O Operations** — Breakdown of read, write,",
              " and metadata bytes. ",
              "For pypiserver, MetadataIOBytes (directory ",
              "listings, stat calls) is usually the dominant ",
              "component. ",
              "High metadata I/O with slow response times ",
              "means the package directory is large or ",
              "workers are contending.",
            ])
          }
          width  = 24
          height = 4
          x      = 0
          y      = 32
        },

        # Row 5: EFS Throughput Metrics
        # Burst credit panel only shown when using bursting throughput mode
        var.efs_throughput_mode == "bursting" ? [
          {
            type = "metric"
            properties = {
              metrics = [
                ["AWS/EFS", "BurstCreditBalance", "FileSystemId",
                local.efs_id, { stat = "Average" }]
              ]
              view    = "timeSeries"
              stacked = false
              region  = data.aws_region.current.name
              title   = "EFS - Burst Credit Balance"
              period  = 300
              yAxis = {
                left = {
                  min = 0
                }
              }
              annotations = {
                horizontal = [
                  {
                    label = "Low threshold (1 TB)"
                    value = 1000000000000
                    fill  = "below"
                    color = "#d62728"
                  }
                ]
              }
            }
            width  = 12
            height = 6
            x      = 0
            y      = 36
          }
        ] : [],
        {
          type = "metric"
          properties = {
            metrics = [
              ["AWS/EFS", "PercentIOLimit", "FileSystemId", local.efs_id, { stat = "Average" }]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "EFS - Throughput Utilization (%)"
            period  = 300
            yAxis = {
              left = {
                min = 0
                max = 100
              }
            }
            annotations = {
              horizontal = [
                {
                  label = "High threshold (80%)"
                  value = 80
                  fill  = "above"
                  color = "#d62728"
                }
              ]
            }
          }
          width  = 12
          height = 6
          x      = 12
          y      = 36
        },

        # Row 6: EFS I/O Metrics
        {
          type = "metric"
          properties = {
            metrics = [
              [
                "AWS/EFS", "ClientConnections",
                "FileSystemId", local.efs_id,
                { stat = "Sum", label = "Client Connections" }
              ]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "EFS - Client Connections"
            period  = 300
            yAxis = {
              left = {
                min = 0
              }
            }
          }
          width  = 12
          height = 6
          x      = 0
          y      = 42
        },
        {
          type = "metric"
          properties = {
            metrics = [
              ["AWS/EFS", "DataReadIOBytes", "FileSystemId", local.efs_id, { stat = "Sum", label = "Read Bytes" }],
              [".", "DataWriteIOBytes", ".", ".", { stat = "Sum", label = "Write Bytes" }],
              [".", "MetadataIOBytes", ".", ".", { stat = "Sum", label = "Metadata Bytes" }]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "EFS - I/O Bytes (per 5-min interval)"
            period  = 300
            yAxis = {
              left = {
                min = 0
              }
            }
          }
          width  = 12
          height = 6
          x      = 12
          y      = 42
        }
      ])
    }
  )
}

locals {
  efs_id = aws_efs_file_system.packages-enc.id
}
