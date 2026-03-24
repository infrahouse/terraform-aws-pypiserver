# Upgrading

## ECS Module 7.6.0 to 7.12.0

Version 7.12.0 of the ECS module adds Terraform management of the Container Insights
CloudWatch log group (`/aws/ecs/containerinsights/<service_name>/performance`).

Previously, AWS created this log group implicitly with **1-day retention** when Container
Insights was enabled. Vanta flagged this as non-compliant with the ISO/SOC 365-day
retention requirement. The log group is now created by Terraform with the configured
retention (365 days by default).

### Importing the Existing Log Group

If you are upgrading an existing deployment where Container Insights is already enabled,
the log group already exists in AWS. You must import it into Terraform state before
applying, otherwise Terraform will fail trying to create a log group that already exists.

Add an `import` block to your root Terraform configuration (where you call this module):

```hcl
import {
  to = module.<your_module_name>.module.pypiserver.aws_cloudwatch_log_group.container_insights[0]
  id = "/aws/ecs/containerinsights/<service_name>/performance"
}
```

For example, if your module block is:

```hcl
module "pypi" {
  source  = "registry.infrahouse.com/infrahouse/pypiserver/aws"
  version = "..."
  # ...
}
```

and you use the default `service_name` (`"pypiserver"`), the import block would be:

```hcl
import {
  to = module.pypi.module.pypiserver.aws_cloudwatch_log_group.container_insights[0]
  id = "/aws/ecs/containerinsights/pypiserver/performance"
}
```

Replace `<service_name>` with the actual value of your `service_name` variable
if you customized it.

!!! note
    The `import` block is a one-time migration step. After a successful `terraform apply`,
    you can remove the `import` block from your configuration.

### Fresh Deployments

No action needed. Terraform will create and manage the log group automatically.
