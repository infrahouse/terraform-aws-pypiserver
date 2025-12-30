#!/bin/bash
#
# PyPI Server Diagnostic Data Collection Script
#
# This script collects comprehensive diagnostic data during performance incidents.
# It captures memory, CPU, I/O, network, and container metrics.
#
# Usage:
#   /opt/pypiserver/collect-diagnostics.sh
#
# Output:
#   Creates timestamped report in /var/log/pypiserver-diagnostics/
#

set -euo pipefail

# Configuration
DIAG_DIR="/var/log/pypiserver-diagnostics"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${DIAG_DIR}/diagnostics_${TIMESTAMP}.txt"

# Ensure diagnostic directory exists
mkdir -p "${DIAG_DIR}"

# Start report
{
    echo "=========================================="
    echo "PyPI Server Diagnostic Report"
    echo "=========================================="
    echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Hostname: $(hostname)"
    echo "Instance ID: $(ec2-metadata --instance-id | cut -d' ' -f2)"
    echo "Instance Type: $(ec2-metadata --instance-type | cut -d' ' -f2)"
    echo ""

    echo "=========================================="
    echo "Memory Status"
    echo "=========================================="
    free -h
    echo ""

    echo "Memory breakdown (MB):"
    free -m
    echo ""

    echo "Swap usage details:"
    swapon --show
    echo ""

    echo "Top 10 memory consumers:"
    ps aux --sort=-%mem | head -11
    echo ""

    echo "=========================================="
    echo "CPU Status"
    echo "=========================================="
    echo "Load average:"
    uptime
    echo ""

    echo "CPU utilization (5 samples, 1 second apart):"
    mpstat 1 5
    echo ""

    echo "Per-CPU statistics:"
    mpstat -P ALL 1 1
    echo ""

    echo "I/O wait statistics (5 samples):"
    iostat -x 1 5
    echo ""

    echo "Top 10 CPU consumers:"
    ps aux --sort=-%cpu | head -11
    echo ""

    echo "=========================================="
    echo "Disk I/O Status"
    echo "=========================================="
    echo "I/O statistics:"
    iostat -xz 1 3
    echo ""

    echo "Disk usage:"
    df -h
    echo ""

    echo "Inode usage:"
    df -i
    echo ""

    echo "=========================================="
    echo "EFS Mount Status"
    echo "=========================================="
    echo "EFS mount points:"
    mount | grep nfs4
    echo ""

    echo "EFS mount statistics:"
    if mountpoint -q /data/packages; then
        cat /proc/self/mountstats | grep -A50 "mounted on /data/packages" || echo "Mount stats not available"
    else
        echo "ERROR: /data/packages is not mounted!"
    fi
    echo ""

    echo "=========================================="
    echo "Network Status"
    echo "=========================================="
    echo "Network connections summary:"
    netstat -ant | awk '{print $6}' | sort | uniq -c | sort -rn
    echo ""

    echo "Established connections count:"
    netstat -ant | grep ESTABLISHED | wc -l
    echo ""

    echo "Network interface statistics:"
    ip -s link
    echo ""

    echo "=========================================="
    echo "Docker Container Status"
    echo "=========================================="
    echo "Running containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""

    echo "Container resource usage:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"
    echo ""

    echo "PyPI container details:"
    PYPI_CONTAINERS=$(docker ps --filter "name=pypiserver" --format "{{.ID}}")
    for container_id in $PYPI_CONTAINERS; do
        echo ""
        echo "Container: $container_id"
        echo "---"
        docker inspect "$container_id" | jq -r '.[0] | {
            Name: .Name,
            State: .State.Status,
            Memory: .HostConfig.Memory,
            RestartCount: .RestartCount,
            StartedAt: .State.StartedAt
        }'

        echo ""
        echo "Recent logs (last 50 lines):"
        docker logs --tail 50 "$container_id" 2>&1 | tail -50
    done
    echo ""

    echo "=========================================="
    echo "ECS Agent Status"
    echo "=========================================="
    echo "ECS agent metadata:"
    curl -s http://localhost:51678/v1/metadata 2>/dev/null | jq '.' || echo "ECS metadata not available"
    echo ""

    echo "ECS tasks:"
    curl -s http://localhost:51678/v1/tasks 2>/dev/null | jq '.' || echo "ECS tasks info not available"
    echo ""

    echo "=========================================="
    echo "System Logs (last 100 lines)"
    echo "=========================================="
    echo "Kernel messages (OOM, memory pressure):"
    dmesg -T | grep -iE 'oom|memory|kill' | tail -100 || echo "No OOM messages"
    echo ""

    echo "CloudWatch agent logs:"
    tail -100 /var/log/ecs/ecs-agent.log 2>/dev/null || echo "ECS agent logs not available"
    echo ""

    echo "=========================================="
    echo "Process Tree"
    echo "=========================================="
    pstree -p
    echo ""

    echo "=========================================="
    echo "Open File Descriptors"
    echo "=========================================="
    echo "File descriptor limits:"
    ulimit -a
    echo ""

    echo "Open file count by process:"
    lsof 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -20 || echo "lsof not available"
    echo ""

    echo "=========================================="
    echo "Systemd Services Status"
    echo "=========================================="
    systemctl list-units --type=service --state=running
    echo ""

    echo "=========================================="
    echo "End of Diagnostic Report"
    echo "=========================================="
    echo "Report saved to: ${REPORT_FILE}"
    echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

} > "${REPORT_FILE}" 2>&1

# Also save a compressed copy
gzip -c "${REPORT_FILE}" > "${REPORT_FILE}.gz"

# Clean up old reports (keep last 10)
cd "${DIAG_DIR}"
ls -t diagnostics_*.txt | tail -n +11 | xargs -r rm -f
ls -t diagnostics_*.txt.gz | tail -n +11 | xargs -r rm -f

echo "Diagnostic data collected successfully!"
echo "Report: ${REPORT_FILE}"
echo "Compressed: ${REPORT_FILE}.gz"
echo ""
echo "To view the report:"
echo "  cat ${REPORT_FILE}"
echo "  zcat ${REPORT_FILE}.gz"