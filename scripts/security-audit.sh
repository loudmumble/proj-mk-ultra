#!/usr/bin/env bash
# security-audit.sh - Run security audit on PROJ-MK-ULTRA
# SUSPICIOUS Framework: Utility Script
#
# Iterates all detection layer scripts and runs each in audit mode.
# Aggregates results for a single-pass security posture check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                    S U S P I C I O U S   S E C U R I T Y   A U D I T        ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo

echo "Running security audit..."
echo

# Detection monitors are read-only one-shot checks - safe to run for audit
for script in "${SCRIPT_DIR}/../detection/"*.sh; do
    if [ -x "${script}" ]; then
        echo "Running: $(basename "${script}")"
        bash "${script}" --audit 2>/dev/null || true
        echo
    fi
done

echo "Security audit complete."
