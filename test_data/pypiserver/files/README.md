# Diagnostic Tools for PyPI Server Test Infrastructure

This directory contains tools for collecting diagnostic data from PyPI server EC2 instances during stress testing and performance troubleshooting.

## Files

- `collect-diagnostics.sh` - Comprehensive diagnostic data collection script

## Required Packages

### Core Diagnostic Tools

The following packages must be installed on EC2 instances for the diagnostic script to work:

1. **sysstat** - System performance monitoring tools
   - Provides: `mpstat`, `iostat`, `sar`, `pidstat`
   - Used for: CPU utilization, I/O statistics, performance history

2. **jq** - JSON processor
   - Used for: Parsing ECS metadata, Docker inspect output

3. **lsof** - List open files
   - Used for: Monitoring file descriptor usage

4. **psmisc** - Process management utilities
   - Provides: `pstree`
   - Used for: Visualizing process hierarchy

5. **net-tools** - Network utilities
   - Provides: `netstat`
   - Used for: Network connection monitoring

### Installation

All required tools are installed automatically via cloud-init when the test infrastructure is deployed. The installation command is:

```bash
yum install -y sysstat jq lsof psmisc net-tools
```

## Usage

### During Stress Tests

When running stress tests, you can collect diagnostics at any time:

```bash
# SSH or SSM into the EC2 instance
aws ssm start-session --target i-xxxxx

# Become root
sudo -i

# Run diagnostic collection
/opt/pypiserver/collect-diagnostics.sh
```

### What Gets Collected

The diagnostic script collects:

- **Memory status**: Usage, swap, top consumers
- **CPU status**: Load averages, utilization, I/O wait
- **Disk I/O**: I/O statistics, disk usage, inode usage
- **EFS mount status**: Mount points, NFS statistics
- **Network status**: Connection counts, interface statistics
- **Docker containers**: Resource usage, logs, inspect output
- **ECS agent status**: Metadata, task information
- **System logs**: Kernel messages, OOM events
- **Process tree**: Running processes and hierarchy
- **File descriptors**: Limits and usage

### Output

Reports are saved to `/var/log/pypiserver-diagnostics/` with timestamps:

```
/var/log/pypiserver-diagnostics/diagnostics_20251228_153045.txt
/var/log/pypiserver-diagnostics/diagnostics_20251228_153045.txt.gz
```

The script automatically keeps the last 10 reports and removes older ones.

### Viewing Reports

```bash
# View latest report
cat /var/log/pypiserver-diagnostics/diagnostics_*.txt | tail

# View compressed report
zcat /var/log/pypiserver-diagnostics/diagnostics_20251228_153045.txt.gz | less
```

## Integration with Test Infrastructure

The diagnostic script is deployed via the test terraform configuration in `test_data/pypiserver/main.tf`:

```hcl
module "pypiserver" {
  source = "../../"

  # Install diagnostic tools
  cloudinit_extra_commands = [
    "yum install -y sysstat jq lsof psmisc net-tools"
  ]

  # Deploy diagnostic script
  extra_files = [
    {
      content     = file("${path.module}/files/collect-diagnostics.sh")
      path        = "/opt/pypiserver/collect-diagnostics.sh"
      permissions = "755"
    }
  ]
}
```

## Troubleshooting

### "Command not found" errors

If the script reports missing commands, verify tools are installed:

```bash
command -v mpstat && echo "✓ sysstat installed"
command -v jq && echo "✓ jq installed"
command -v lsof && echo "✓ lsof installed"
command -v pstree && echo "✓ psmisc installed"
command -v netstat && echo "✓ net-tools installed"
```

If any are missing, install manually:
```bash
yum install -y sysstat jq lsof psmisc net-tools
```

### Permission denied

Ensure you're running as root:
```bash
sudo /opt/pypiserver/collect-diagnostics.sh
```