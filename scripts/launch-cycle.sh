#!/usr/bin/env bash
# launch-cycle.sh - The complete launch cycle in one command
# SUSPICIOUS Framework: spawn -> boot -> validate
#
# Idempotent: an existing READY/running instance is used, not re-created.
# Every line is logged to the terminal and to /tmp/launch-cycle.log.
#
# Usage: sudo ./scripts/launch-cycle.sh [instance-name]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE="${1:-child-fsv}"
LOG="/tmp/launch-cycle-$(date +%H%M%S).log"

main() {

step() { echo -e "\n===== $1 ====="; }

step "LAUNCH CYCLE: ${INSTANCE} — $(date)"

step "1/4 Boundary (apply-baseline - idempotent)"
bash "${SCRIPT_DIR}/apply-baseline.sh" || echo "NOTE: baseline reported failure - continuing (pool may hold state)"

step "2/4 Spawn (skips when the instance already exists)"
bash "${SCRIPT_DIR}/spawn-child-instance.sh" "${INSTANCE}" || {
    if [ ! -d "/sys/fs/multikernel/instances/${INSTANCE}" ]; then
        echo "ERROR: spawn failed and instance ${INSTANCE} does not exist. Aborting launch cycle."
        exit 1
    else
        echo "NOTE: spawn reported failure but instance exists - continuing to boot."
    fi
}

step "3/4 Boot (device handoff + boot + mktty capture)"
bash "${SCRIPT_DIR}/boot-instance.sh" "${INSTANCE}" 2>&1 || echo "NOTE: boot reported failure - inspect above"

step "4/4 Validation (FSV-1..5b)"
bash "${SCRIPT_DIR}/first-spawn-validate.sh" || true

step "CYCLE COMPLETE"
}

main "$@" 2>&1 | tee "${LOG}"
echo "Full output: ${LOG}"
