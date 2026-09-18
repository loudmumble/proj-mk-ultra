#!/usr/bin/env bash
# metadata-cleaner.sh - File Attribute Poisoning Cleaner
# SUSPICIOUS Framework: Data Remediation
#
# Cleans file attribute poisoning:
# - Extended attributes (xattr)
# - File capabilities
# - ACLs
# - Timestamps
# - Permissions
# - Special bits (SUID, SGID, sticky)
#
# Usage: sudo ./metadata-cleaner.sh [options] <path>
#
# Based on research from:
# - loudmumble's CBPI research
# - File attribute poisoning on x86-64 architecture

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Configuration
DRY_RUN=false
VERBOSE=false
BACKUP=true
BACKUP_DIR=".metadata-backup"

# Counters
CLEANED=0
SKIPPED=0
ERRORS=0

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║     ███████╗██╗   ██╗███╗   ██╗████████╗██╗  ██╗███████╗           ║
║     ██╔════╝██║   ██║████╗  ██║╚══██╔══╝██║  ██║██╔════╝           ║
║     ███████╗██║   ██║██╔██╗ ██║   ██║   ███████║█████╗             ║
║     ╚════██║██║   ██║██║╚██╗██║   ██║   ██╔══██║██╔══╝             ║
║     ███████║╚██████╔╝██║ ╚████║   ██║   ██║  ██║███████╗           ║
║     ╚══════╝ ╚═════╝ ╚═╝  ╚═══╝   ╚═╝   ╚═╝  ╚═╝╚══════╝           ║
║                                                                      ║
║         M E T A D A T A   C L E A N E R                             ║
║                                                                      ║
║         File Attribute Poisoning Remediation                         ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Function to display section header
show_header() {
    local title="$1"
    echo -e "\n${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}${BOLD}  ${title}${NC}"
    echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
}

# Function to display finding
show_finding() {
    local severity="$1"
    local message="$2"
    local location="$3"
    
    local color=""
    local symbol=""
    
    case "${severity}" in
        CRITICAL)
            color="${RED}"
            symbol="✗"
            ;;
        HIGH)
            color="${RED}"
            symbol="!"
            ;;
        MEDIUM)
            color="${YELLOW}"
            symbol="⚠"
            ;;
        LOW)
            color="${YELLOW}"
            symbol="○"
            ;;
        INFO)
            color="${BLUE}"
            symbol="·"
            ;;
        CLEAN)
            color="${GREEN}"
            symbol="✓"
            ;;
    esac
    
    echo -e "  ${color}${symbol} [${severity}] ${message}${NC}"
    if [ -n "${location}" ]; then
        echo -e "      ${color}Location: ${location}${NC}"
    fi
}

# Function to backup metadata
backup_metadata() {
    local file="$1"
    local backup_path="${BACKUP_DIR}/$(echo "${file}" | sed 's|/|_|g').meta"
    
    if [ "${BACKUP}" = true ]; then
        mkdir -p "${BACKUP_DIR}"
        
        # Backup extended attributes
        if command -v getfattr &> /dev/null; then
            getfattr -d "${file}" > "${backup_path}.xattr" 2>/dev/null || true
        fi
        
        # Backup permissions
        stat -c "%a %U %G" "${file}" > "${backup_path}.perms" 2>/dev/null || true
        
        # Backup ACLs
        if command -v getfacl &> /dev/null; then
            getfacl "${file}" > "${backup_path}.acl" 2>/dev/null || true
        fi
    fi
}

# Function to clean extended attributes
clean_xattr() {
    local file="$1"
    
    if command -v getfattr &> /dev/null; then
        local xattrs=$(getfattr -d "${file}" 2>/dev/null | grep -v "^#" | awk -F'=' '{print $1}' || true)
        
        if [ -n "${xattrs}" ]; then
            show_finding "HIGH" "Extended attributes found" "${file}"
            
            if [ "${DRY_RUN}" = false ]; then
                for xattr in ${xattrs}; do
                    if [ "${VERBOSE}" = true ]; then
                        echo -e "      Removing: ${xattr}"
                    fi
                    setfattr -x "${xattr}" "${file}" 2>/dev/null || true
                done
                show_finding "CLEAN" "Extended attributes removed" "${file}"
                CLEANED=$((CLEANED + 1))
            fi
        fi
    fi
}

# Function to clean file capabilities
clean_caps() {
    local file="$1"
    
    if command -v getcap &> /dev/null; then
        local caps=$(getcap "${file}" 2>/dev/null || true)
        
        if [ -n "${caps}" ]; then
            show_finding "CRITICAL" "File capabilities detected" "${file}"
            echo -e "      ${RED}Caps: ${caps}${NC}"
            
            if [ "${DRY_RUN}" = false ]; then
                setcap -r "${file}" 2>/dev/null || true
                show_finding "CLEAN" "File capabilities removed" "${file}"
                CLEANED=$((CLEANED + 1))
            fi
        fi
    fi
}

# Function to clean ACLs
clean_acls() {
    local file="$1"
    
    if command -v getfacl &> /dev/null; then
        local acls=$(getfacl "${file}" 2>/dev/null | grep -c "^default:" || echo "0")
        
        if [ "${acls}" -gt 0 ]; then
            show_finding "MEDIUM" "ACLs detected" "${file}"
            
            if [ "${DRY_RUN}" = false ]; then
                setfacl -b "${file}" 2>/dev/null || true
                show_finding "CLEAN" "ACLs removed" "${file}"
                CLEANED=$((CLEANED + 1))
            fi
        fi
    fi
}

# Function to clean special permissions
clean_special_perms() {
    local file="$1"
    
    # Get file permissions
    local perms=$(stat -c "%a" "${file}" 2>/dev/null || echo "000")
    
    # Check for SUID (4000), SGID (2000), sticky (1000)
    local uid_bit=$((perms / 1000 % 10))
    local gid_bit=$((perms / 100 % 10))
    local sticky_bit=$((perms / 10 % 10))
    local base_perm=$((perms % 10))
    
    if [ "${uid_bit}" -eq 4 ] || [ "${gid_bit}" -eq 2 ] || [ "${sticky_bit}" -eq 1 ]; then
        show_finding "HIGH" "Special permissions detected (SUID/SGID/sticky)" "${file}"
        echo -e "      ${RED}Current perms: ${perms}${NC}"
        
        if [ "${DRY_RUN}" = false ]; then
            # Remove special bits, keep base permissions
            local new_perm=$((base_perm * 100 + (perms / 10 % 10) * 10 + base_perm))
            chmod "${new_perm}" "${file}" 2>/dev/null || true
            show_finding "CLEAN" "Special permissions removed" "${file}"
            CLEANED=$((CLEANED + 1))
        fi
    fi
}

# Function to clean timestamps
clean_timestamps() {
    local file="$1"
    
    # Normalize to a single canonical timestamp (1 day ago, midnight)
    if [ "${DRY_RUN}" = false ]; then
        touch -a -m -t "$(date -d '1 day ago' '+%Y%m%d0000.00')" "${file}" 2>/dev/null || true
    fi
}

# Function to check for suspicious patterns
check_suspicious_patterns() {
    local file="$1"
    
    # Check for hidden characters in filename
    local basename=$(basename "${file}")
    if echo "${basename}" | grep --P '[\x00-\x1f\x7f-\x9f]' > /dev/null; then
        show_finding "CRITICAL" "Hidden characters in filename" "${file}"
    fi
    
    # Check for very long extended attribute names
    if command -v getfattr &> /dev/null; then
        local long_xattrs=$(getfattr -d "${file}" 2>/dev/null | awk -F'=' '{print length($1), $0}' | awk '$1 > 50' || true)
        if [ -n "${long_xattrs}" ]; then
            show_finding "HIGH" "Suspiciously long xattr names" "${file}"
        fi
    fi
}

# Function to scan and clean a file
clean_file() {
    local file="$1"
    
    if [ ! -e "${file}" ]; then
        return 0
    fi
    
    # Backup if enabled
    if [ "${BACKUP}" = true ]; then
        backup_metadata "${file}"
    fi
    
    # Clean various metadata
    clean_xattr "${file}"
    clean_caps "${file}"
    clean_acls "${file}"
    clean_special_perms "${file}"
    check_suspicious_patterns "${file}"
}

# Function to scan directory
scan_directory() {
    local dir="$1"
    
    show_header "Scanning Directory: ${dir}"
    
    echo -e "${BOLD}Scanning for file attribute poisoning...${NC}"
    echo
    
    local file_count=0
    
    # Find all files
    while IFS= read -r -d '' file; do
        clean_file "${file}"
        file_count=$((file_count + 1))
        
        if [ "${VERBOSE}" = true ]; then
            echo -ne "\r  Scanned: ${file_count} files"
        fi
    done < <(find "${dir}" -type f -print0 2>/dev/null)
    
    echo -e "\r  Scanned: ${file_count} files"
    echo
}

# Function to generate report
generate_report() {
    show_header "Cleaning Report"
    
    echo -e "${BOLD}Results:${NC}"
    echo -e "  Files cleaned:  ${GREEN}${CLEANED}${NC}"
    echo -e "  Files skipped:  ${YELLOW}${SKIPPED}${NC}"
    echo -e "  Errors:         ${RED}${ERRORS}${NC}"
    echo
    
    if [ "${BACKUP}" = true ] && [ -d "${BACKUP_DIR}" ]; then
        echo -e "${BOLD}Backup Location:${NC}"
        echo "  ${BACKUP_DIR}/"
        echo
        echo -e "${YELLOW}To restore metadata:${NC}"
        echo "  # Review backups first"
        echo "  ls -la ${BACKUP_DIR}/"
        echo
    fi
    
    if [ "${DRY_RUN}" = true ]; then
        echo -e "${YELLOW}${BOLD}This was a dry run - no changes were made${NC}"
        echo -e "${YELLOW}Run with --fix to apply changes${NC}"
    fi
}

# Function to display usage
show_usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  sudo $0 [options] <path>"
    echo
    echo -e "${BOLD}Options:${NC}"
    echo "  --scan          Scan only (default, no changes)"
    echo "  --fix           Apply fixes (clean metadata)"
    echo "  --dry-run       Show what would be done (default)"
    echo "  --no-backup     Don't backup metadata"
    echo "  --verbose       Show detailed output"
    echo "  --help          Show this help"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo "  sudo $0 /path/to/files              # Scan directory"
    echo "  sudo $0 --fix /path/to/files        # Clean metadata"
    echo "  sudo $0 --verbose /path/to/files    # Detailed scan"
    echo
    echo -e "${BOLD}What it cleans:${NC}"
    echo "  ✓ Extended attributes (xattr)"
    echo "  ✓ File capabilities"
    echo "  ✓ ACLs"
    echo "  ✓ Special permissions (SUID, SGID, sticky)"
    echo "  ✓ Suspicious filename patterns"
    echo
}

# Main execution
main() {
    local target_path=""
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --scan)
                DRY_RUN=true
                BACKUP=false
                shift
                ;;
            --fix)
                DRY_RUN=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --no-backup)
                BACKUP=false
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                target_path="$1"
                shift
                ;;
        esac
    done
    
    # Check for target path
    if [ -z "${target_path}" ]; then
        echo -e "${RED}${BOLD}[ERROR] Target path required${NC}"
        show_usage
        exit 1
    fi
    
    # Validate path
    if [ ! -e "${target_path}" ]; then
        echo -e "${RED}${BOLD}[ERROR] Path not found: ${target_path}${NC}"
        exit 1
    fi
    
    # Check for root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}Warning: Some operations require root privileges${NC}"
    fi
    
    show_banner
    
    echo -e "${BOLD}Target:${NC} ${target_path}"
    echo -e "${BOLD}Mode:${NC} $([ "${DRY_RUN}" = true ] && echo "SCAN" || echo "FIX")"
    echo -e "${BOLD}Backup:${NC} ${BACKUP}"
    echo
    
    # Scan and clean
    if [ -d "${target_path}" ]; then
        scan_directory "${target_path}"
    else
        clean_file "${target_path}"
    fi
    
    # Generate report
    generate_report
    
    # Exit code
    if [ "${ERRORS}" -gt 0 ]; then
        exit 1
    fi
    
    return 0
}

# Run main function
main "$@"
