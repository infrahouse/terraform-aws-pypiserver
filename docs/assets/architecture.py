#!/usr/bin/env python3
"""
Generate architecture diagram for terraform-aws-pypiserver module.

Requirements:
    pip install diagrams

Usage:
    cd docs/assets
    python architecture.py

Output:
    architecture.png (in current directory)
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECS, EC2
from diagrams.aws.network import ALB, Route53
from diagrams.aws.management import Cloudwatch
from diagrams.aws.security import ACM, SecretsManager
from diagrams.aws.storage import EFS
from diagrams.aws.general import Users

fontsize = "16"

graph_attr = {
    "splines": "spline",
    "nodesep": "1.5",
    "ranksep": "1.5",
    "fontsize": fontsize,
    "fontname": "Roboto",
    "dpi": "200",
}

node_attr = {
    "fontname": "Roboto",
    "fontsize": fontsize,
}

edge_attr = {
    "fontname": "Roboto",
    "fontsize": fontsize,
}

with Diagram(
    "PyPI Server Architecture",
    filename="architecture",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
    outformat="png",
):
    users = Users("\npip / twine")
    dns = Route53("\nRoute 53\nDNS")
    cert = ACM("\nACM\nCertificate")

    with Cluster("VPC"):
        with Cluster("Public Subnets"):
            lb = ALB("\nApplication\nLoad Balancer")

        with Cluster("Private Subnets"):
            with Cluster("Auto Scaling Group"):
                ec2_instances = [
                    EC2("\nEC2 Instance\n(ECS Agent)"),
                    EC2("\nEC2 Instance\n(ECS Agent)"),
                ]

            with Cluster("ECS Cluster"):
                ecs_tasks = ECS("\nPyPI Server\nContainers")

            efs = EFS("\nEFS\n(Encrypted)\nPackage Storage")

    secrets = SecretsManager("\nSecrets Manager\nCredentials")
    cloudwatch = Cloudwatch("\nCloudWatch\nAlarms +\nDashboard")

    # User traffic flow
    users >> dns >> lb
    cert - Edge(style="dashed", label="TLS") - lb
    lb >> ec2_instances
    ec2_instances[0] - ecs_tasks
    ec2_instances[1] - ecs_tasks

    # EFS mount (NFS)
    ecs_tasks >> Edge(label="NFS") >> efs

    # Secrets Manager
    ecs_tasks >> Edge(style="dashed", label="auth") >> secrets

    # Monitoring
    ecs_tasks >> Edge(style="dashed", label="metrics") >> cloudwatch
    efs >> Edge(style="dashed", label="alarms") >> cloudwatch
