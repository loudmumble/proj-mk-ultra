#!/usr/bin/env bash
# enroll-mok.sh - Put the module-signing key into a trust chain the kernel honors
# SUSPICIOUS Framework: Prevention Layer support tool
#
# A generated signing key signs nothing the kernel will ACCEPT until the key
# is trusted. Two trust paths exist:
#
#   Path A - Secure Boot hosts (MOK machine-owner key):
#       1. This script exports the public key to DER.
#       2. `mokutil --import` registers it (prompts for a one-time password).
#       3. REBOOT: firmware performs MOK enrollment (type the password at the
#          blue MokManager screen - this is a deliberate physical act by
#          design; it is the machine owner vouching for the key).
#       4. Re-run this script: it verifies the key is now on the MOK list.
#
#   Path B - Non-Secure-Boot hosts (built-in trusted keyring):
#       Add CONFIG_SYSTEM_TRUSTED_KEYS="<path to key.pem>" to the kernel
#       config fragment and REBUILD the kernel - the key becomes part of the
#       built-in trusted keyring. build-multikernel.sh checks for the key at
#       build time and wires it automatically when present.
#
# Usage: sudo ./enroll-mok.sh [check|export|import]

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

KEYS_DIR="/etc/secureboot/keys"
KEY_PEM="${KEYS_DIR}/signing_key.pem"
KEY_DER="${KEYS_DIR}/signing_key.der"

say() { echo -e "  $1 $2"; }

check_root() {
    [ "$EUID" -eq 0 ] || { echo -e "${RED}[ERROR] run as root${NC}"; exit 1; }
}

sb_state() {
    if command -v mokutil &>/dev/null; then
        mokutil --sb-state 2>/dev/null | grep -i "SecureBoot enabled" > /dev/null && echo "enabled" || echo "disabled"
    else
        echo "mokutil-missing"
    fi
}

key_exists() { [ -f "${KEY_PEM}" ]; }

do_export() {
    if ! key_exists; then
        say "${RED}" "Signing key not found: ${KEY_PEM}"
        say "${YELLOW}" "Run enforce-module-signing.sh first (creates the key)"
        exit 1
    fi
    mkdir -p "${KEYS_DIR}"
    openssl x509 -in "${KEY_PEM}" -outform DER -out "${KEY_DER}"
    say "${GREEN}" "Public key exported: ${KEY_DER}"
}

do_import() {
    [ "$(sb_state)" = "enabled" ] || {
        say "${YELLOW}" "Secure Boot is not enabled - use Path B (built-in trusted keyring) instead."
        say "${BLUE}" "  Add to config fragment: CONFIG_SYSTEM_TRUSTED_KEYS=\"${KEY_PEM}\""
        say "${BLUE}" "  Then rebuild via pre-install/build-multikernel.sh"
        exit 0
    }
    command -v mokutil &>/dev/null || { say "${RED}" "mokutil not installed"; exit 1; }
    [ -f "${KEY_DER}" ] || do_export
    say "${BLUE}" "Importing ${KEY_DER} into MOK..."
    say "${YELLOW}" "  mokutil will prompt for a one-time password (you choose it)."
    say "${YELLOW}" "  REBOOT next - the blue MokManager screen asks for that password."
    mokutil --import "${KEY_DER}"
    say "${GREEN}" "Import queued. Reboot to complete enrollment."
}

do_check() {
    say "${BLUE}" "Secure Boot state: $(sb_state)"
    if [ "$(sb_state)" = "enabled" ]; then
        say "${BLUE}" "MOK listing (look for: SUSPICIOUS Framework Module Signing Key):"
        mokutil --list-enrolled 2>/dev/null | grep -i "SUSPICIOUS" > /dev/null \
            && say "${GREEN}" "  ✓ Signing key IS enrolled in MOK" \
            || say "${YELLOW}" "  ✗ Key NOT yet enrolled - run: $0 import && reboot"
    fi
    # Runtime truth: is a test module signed with our key accepted?
    if [ -f "${KEY_PEM}" ]; then
        say "${BLUE}" "Key present: ${KEY_PEM}"
    else
        say "${YELLOW}" "Key absent - run enforce-module-signing.sh"
    fi
    echo
    say "${BLUE}" "Non-SB path: CONFIG_SYSTEM_TRUSTED_KEYS=\"${KEY_PEM}\" in the config fragment + kernel rebuild"
}

case "${1:-check}" in
    export) check_root; do_export ;;
    import) check_root; do_import ;;
    check|"") do_check ;;
    *) echo "Usage: sudo $0 {check|export|import}"; exit 1 ;;
esac
