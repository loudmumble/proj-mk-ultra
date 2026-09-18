#!/usr/bin/env bash
# system-monitor.sh - Monitor PROJ-MK-ULTRA system
# SUSPICIOUS Framework: Utility Script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                    S U S P I C I O U S   S Y S T E M   M O N I T O R        ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo

# Show system status
echo "System Status:"
echo "  Kernel: $(uname -r)"
echo "  Hostname: $(hostname)"
echo "  Uptime: $(uptime -p)"
echo

# Show multikernel status
if [ -d /sys/fs/multikernel ]; then
    echo "Multikernel Status:"
    ls /sys/fs/multikernel/instances/ 2>/dev/null || echo "  No instances running"
else
    echo "Multikernel: Not mounted"
fi
echo

# Show disk usage
echo "Disk Usage:"
df -h / /data 2>/dev/null || df -h /
echo

# Show memory usage
echo "Memory Usage:"
free -h
echo

echo "Monitor complete."
