#!/usr/bin/env bash
# kernel-pin.sh - Manage the multikernel kernel pin across the repo
# The pin is a COMMIT REFERENCE (not a path binding) recorded in
# build-multikernel.sh and pre-install.sh. This tool reads, sets, and
# verifies it — so changing the pin is one command, not a hunt.
#
# Usage:
#   kernel-pin.sh get              # show the current pin
#   kernel-pin.sh set <commit>     # re-pin the repo to a new commit
#   kernel-pin.sh verify [srcdir]  # check a clone matches the pin

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGETS=("${REPO_ROOT}/pre-install/build-multikernel.sh" "${REPO_ROOT}/1_pre-install.sh")

current_pin() {
    grep -m1 '^PINNED_COMMIT=' "${TARGETS[0]}" | cut -d'"' -f2
}

cmd_get() {
    echo "Current pin: $(current_pin)"
}

cmd_set() {
    local new="${1:-}"
    [ -n "${new}" ] || { echo "Usage: $0 set <commit>"; exit 1; }
    # Validate format loosely (short or full sha)
    [[ "${new}" =~ ^[0-9a-f]{7,40}$ ]] || { echo -e "${RED}Not a commit hash: ${new}${NC}"; exit 1; }
    
    local old; old=$(current_pin)
    for target in "${TARGETS[@]}"; do
        [ -f "${target}" ] || { echo -e "${YELLOW}skip (missing): ${target}${NC}"; continue; }
        sed -i "s|^PINNED_COMMIT=.*|PINNED_COMMIT=\"${new}\"|" "${target}"
    done
    echo -e "${GREEN}Pin updated: ${old} -> ${new}${NC}"
    echo "Next: update the pin note in docs/BUILD-MULTIKERNEL.md, then rebuild:"
    echo "  sudo ./pre-install/build-multikernel.sh"
}

cmd_verify() {
    local src="${1:-/opt/multikernel/linux}"
    local pin; pin=$(current_pin)
    [ -d "${src}/.git" ] || { echo -e "${RED}No clone at ${src}${NC}"; exit 1; }
    local head; head=$(git -C "${src}" rev-parse --short HEAD 2>/dev/null || echo "none")
    if [ "${head}" = "${pin:0:${#head}}" ] || [ "${pin}" = "${head}" ]; then
        echo -e "${GREEN}Clone ${src} matches pin ${pin}${NC}"
    else
        echo -e "${YELLOW}Clone ${src} is at ${head}, pin is ${pin} — checkout: git -C ${src} checkout ${pin}${NC}"
        exit 1
    fi
}

case "${1:-get}" in
    get)    cmd_get ;;
    set)    shift || true; cmd_set "${1:-}" ;;
    verify) shift || true; cmd_verify "${1:-}" ;;
    *) echo "Usage: $0 {get|set <commit>|verify [srcdir]}"; exit 1 ;;
esac
