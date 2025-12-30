resource "aws_cloudwatch_dashboard" "pypiserver" {
  count          = var.enable_cloudwatch_dashboard ? 1 : 0
  dashboard_name = var.service_name

  dashboard_body = jsonencode(
    {
      widgets = [
        # Row 1: ECS Service Overview
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
          y      = 0
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
          y      = 0
        },

        # Row 2: ALB Metrics
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
          y      = 6
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
          y      = 6
        },

        # Row 3: ALB Additional Metrics
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
          y      = 12
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
          y      = 12
        },

        # Row 4: EFS Metrics
        {
          type = "metric"
          properties = {
            metrics = [
              ["AWS/EFS", "BurstCreditBalance", "FileSystemId",
              aws_efs_file_system.packages-enc.id, { stat = "Average" }]
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
          y      = 18
        },
        {
          type = "metric"
          properties = {
            metrics = [
              ["AWS/EFS", "PercentIOLimit", "FileSystemId", aws_efs_file_system.packages-enc.id, { stat = "Average" }]
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
          y      = 18
        },

        # Row 5: EFS Additional Metrics
        {
          type = "metric"
          properties = {
            metrics = [
              ["AWS/EFS", "ClientConnections", "FileSystemId", aws_efs_file_system.packages-enc.id, { stat = "Sum", label = "Client Connections" }]
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
          y      = 24
        },
        {
          type = "metric"
          properties = {
            metrics = [
              ["AWS/EFS", "DataReadIOBytes", "FileSystemId", aws_efs_file_system.packages-enc.id, { stat = "Sum", label = "Read Bytes" }],
              [".", "DataWriteIOBytes", ".", ".", { stat = "Sum", label = "Write Bytes" }],
              [".", "MetadataIOBytes", ".", ".", { stat = "Sum", label = "Metadata Bytes" }]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "EFS - I/O Operations (Bytes)"
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
          y      = 24
        },

        # Row 6: Container Insights
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
                { stat = "Average", label = "CPU Utilized" }
              ]
            ]
            view    = "timeSeries"
            stacked = false
            region  = data.aws_region.current.name
            title   = "Container Insights - CPU Utilized (vCPU)"
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
          y      = 30
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
                { stat = "Average", label = "Memory Utilized (MB)" }
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
          }
          width  = 12
          height = 6
          x      = 12
          y      = 30
        }
      ]
    }
  )
}

# Local variables for extracting resource names from ARNs
locals {
  # # Extract load balancer name from ARN
  # # Format: arn:aws:elasticloadbalancing:region:account-id:loadbalancer/app/name/id
  # load_balancer_name = try(
  #   join("/", slice(split("/", module.service_network_lb.load_balancer_arn), 1, 4)),
  #   ""
  # )
  #
  # # Extract target group name from ARN
  # # Format: arn:aws:elasticloadbalancing:region:account-id:targetgroup/name/id
  # target_group_name = try(
  #   join("/", slice(split("/", module.service_network_lb.target_group_arn), 1, 3)),
  #   ""
  # )
}
