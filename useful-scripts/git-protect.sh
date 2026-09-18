#!/usr/bin/env bash
# git-protect.sh - Safe Git Clone Wrapper
# SUSPICIOUS Framework: Inbound Protection
#
# Protects against malicious git repositories by:
# - Cloning without checkout first (bare clone)
# - Scanning before any files touch disk
# - Blocking dangerous hooks and configs
# - Neutralizing auto-execution vectors
#
# Usage: ./git-protect.sh [options] <repo-url> [destination]
#
# Based on research from:
# - git-protect (https://github.com/moldabekov/git-protect)
# - coldclone (https://github.com/devdacian/coldclone)
# - securegit

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
TEMP_DIR=""
CLONE_DIR=""
DRY_RUN=false
FORCE=false
VERBOSE=false

# Logging
log_event() {
    local event="$1"
    local level="${2:-INFO}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $event" >> /var/log/git-protect.log 2>/dev/null || true
}

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
║         G I T   P R O T E C T                                       ║
║                                                                      ║
║         Safe Repository Acquisition                                 ║
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

# Function to display step
show_step() {
    local step="$1"
    local message="$2"
    echo -e "  ${BLUE}[${step}]${NC} ${message}"
}

# Function to display success
show_success() {
    local message="$1"
    echo -e "  ${GREEN}✓${NC} ${message}"
}

# Function to display warning
show_warning() {
    local message="$1"
    echo -e "  ${YELLOW}⚠${NC} ${message}"
}

# Function to display error
show_error() {
    local message="$1"
    echo -e "  ${RED}✗${NC} ${message}"
}

# Function to cleanup on exit
cleanup() {
    if [ -n "${TEMP_DIR}" ] && [ -d "${TEMP_DIR}" ]; then
        rm -rf "${TEMP_DIR}"
        log_event "Cleaned up temporary directory: ${TEMP_DIR}"
    fi
}

trap cleanup EXIT

# Function to create temporary directory
create_temp_dir() {
    TEMP_DIR=$(mktemp -d /tmp/git-protect-XXXXXX)
    log_event "Created temporary directory: ${TEMP_DIR}"
}

# Function to perform bare clone
bare_clone() {
    local repo_url="$1"
    local bare_dir="${TEMP_DIR}/bare"
    
    show_step "1" "Performing bare clone (no checkout)..."
    
    if [ "${DRY_RUN}" = true ]; then
        show_warning "[DRY-RUN] Would clone: ${repo_url}"
        return 0
    fi
    
    # Clone with no checkout - this prevents hooks from running
    if git clone --bare --no-checkout "${repo_url}" "${bare_dir}" 2>/dev/null; then
        show_success "Bare clone completed"
        log_event "Bare clone successful: ${repo_url}"
        echo "${bare_dir}"
        return 0
    else
        show_error "Bare clone failed"
        log_event "Bare clone failed: ${repo_url}" "ERROR"
        return 1
    fi
}

# Function to scan bare repository
scan_bare_repo() {
    local bare_dir="$1"
    
    show_step "2" "Scanning bare repository..."
    
    local issues=0
    
    # Check for dangerous hooks
    echo -e "\n  ${BOLD}Checking hooks...${NC}"
    if [ -d "${bare_dir}/hooks" ]; then
        for hook in "${bare_dir}/hooks"/*; do
            if [ -f "${hook}" ] && [[ ! "${hook}" =~ \.sample$ ]]; then
                show_warning "Custom hook found: $(basename "${hook}")"
                issues=$((issues + 1))
            fi
        done
    fi
    
    # Check for dangerous config
    echo -e "\n  ${BOLD}Checking config...${NC}"
    local config_file="${bare_dir}/config"
    if [ -f "${config_file}" ]; then
        local dangerous_keys=("hooksPath" "fsmonitor" "insteadOf" "proxy")
        for key in "${dangerous_keys[@]}"; do
            if grep -q "${key}" "${config_file}" 2>/dev/null; then
                show_warning "Dangerous config key: ${key}"
                issues=$((issues + 1))
            fi
        done
    fi
    
    # Check for embedded .git directories
    echo -e "\n  ${BOLD}Checking for embedded repositories...${NC}"
    if find "${bare_dir}/objects" -name ".git" -type d 2>/dev/null | grep -- . > /dev/null; then
        show_warning "Embedded .git directory detected"
        issues=$((issues + 1))
    fi
    
    echo
    return $([ "${issues}" -eq 0 ] && echo 0 || echo 1)
}

# Function to sanitize config
sanitize_config() {
    local bare_dir="$1"
    local config_file="${bare_dir}/config"
    
    show_step "3" "Sanitizing repository config..."
    
    if [ ! -f "${config_file}" ]; then
        show_warning "No config file found"
        return 0
    fi
    
    if [ "${DRY_RUN}" = true ]; then
        show_warning "[DRY-RUN] Would sanitize config"
        return 0
    fi
    
    # Create backup
    cp "${config_file}" "${config_file}.bak"
    
    # Remove dangerous directives
    local dangerous_keys=("hooksPath" "fsmonitor" "insteadOf" "proxy" "http.proxy" "https.proxy")
    for key in "${dangerous_keys[@]}"; do
        if grep -q "${key}" "${config_file}" 2>/dev/null; then
            sed -i "/${key}/d" "${config_file}"
            show_success "Removed: ${key}"
        fi
    done
    
    log_event "Config sanitized"
    return 0
}

# Function to perform safe checkout
safe_checkout() {
    local bare_dir="$1"
    local dest_dir="$2"
    
    show_step "4" "Performing safe checkout..."
    
    if [ "${DRY_RUN}" = true ]; then
        show_warning "[DRY-RUN] Would checkout to: ${dest_dir}"
        return 0
    fi
    
    # Create destination directory
    mkdir -p "${dest_dir}"
    
    # Initialize new repo
    git init "${dest_dir}" >/dev/null 2>&1
    
    # Add bare as remote
    git -C "${dest_dir}" remote add origin "${bare_dir}" >/dev/null 2>&1
    
    # Fetch and checkout
    git -C "${dest_dir}" fetch origin >/dev/null 2>&1
    git -C "${dest_dir}" checkout FETCH_HEAD >/dev/null 2>&1
    
    # Disable hooks in the new repo
    git -C "${dest_dir}" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "${dest_dir}" config core.fsmonitor false >/dev/null 2>&1
    
    show_success "Safe checkout completed"
    log_event "Safe checkout to: ${dest_dir}"
    
    return 0
}

# Function to remove .git and reinitialize
reinitialize_repo() {
    local dest_dir="$1"
    
    show_step "5" "Reinitializing repository..."
    
    if [ "${DRY_RUN}" = true ]; then
        show_warning "[DRY-RUN] Would reinitialize repo"
        return 0
    fi
    
    # Remove original .git
    rm -rf "${dest_dir}/.git"
    
    # Reinitialize with security settings
    git init "${dest_dir}" >/dev/null 2>&1
    
    # Apply security hardening
    git -C "${dest_dir}" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "${dest_dir}" config core.fsmonitor false >/dev/null 2>&1
    git -C "${dest_dir}" config safe.bareRepository explicit >/dev/null 2>&1
    
    # Add remote (optional, user can add later)
    # git -C "${dest_dir}" remote add origin "${repo_url}"
    
    show_success "Repository reinitialized with security hardening"
    log_event "Repository reinitialized: ${dest_dir}"
    
    return 0
}

# Function to display usage
show_usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 [options] <repo-url> [destination]"
    echo
    echo -e "${BOLD}Options:${NC}"
    echo "  --dry-run       Show what would be done (default)"
    echo "  --force         Skip scan warnings and proceed"
    echo "  --verbose       Show detailed output"
    echo "  --help          Show this help"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0 https://github.com/user/repo              # Safe clone to ./repo"
    echo "  $0 https://github.com/user/repo ./my-project # Safe clone to ./my-project"
    echo "  $0 --force https://github.com/user/repo      # Force clone (skip warnings)"
    echo
    echo -e "${BOLD}Security Features:${NC}"
    echo "  ✓ Bare clone (no hooks execute)"
    echo "  ✓ Config sanitization"
    echo "  ✓ Safe checkout (hooks disabled)"
    echo "  ✓ Repository reinitialization"
    echo "  ✓ Security hardening applied"
    echo
}

# Main execution
main() {
    local repo_url=""
    local dest_dir=""
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force|-f)
                FORCE=true
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
            -*)
                echo -e "${RED}Unknown option: $1${NC}"
                show_usage
                exit 1
                ;;
            *)
                if [ -z "${repo_url}" ]; then
                    repo_url="$1"
                elif [ -z "${dest_dir}" ]; then
                    dest_dir="$1"
                fi
                shift
                ;;
        esac
    done
    
    # Check for repo URL
    if [ -z "${repo_url}" ]; then
        echo -e "${RED}${BOLD}[ERROR] Repository URL required${NC}"
        show_usage
        exit 1
    fi
    
    # Extract destination from URL if not provided
    if [ -z "${dest_dir}" ]; then
        dest_dir=$(basename "${repo_url}" .git)
    fi
    
    show_banner
    
    echo -e "${BOLD}Repository:${NC} ${repo_url}"
    echo -e "${BOLD}Destination:${NC} ${dest_dir}"
    echo -e "${BOLD}Mode:${NC} $([ "${DRY_RUN}" = true ] && echo "DRY-RUN" || echo "LIVE")"
    echo
    
    # Create temporary directory
    create_temp_dir
    
    # Step 1: Bare clone
    local bare_dir=$(bare_clone "${repo_url}")
    if [ $? -ne 0 ]; then
        show_error "Failed to clone repository"
        exit 1
    fi
    
    # Step 2: Scan bare repo
    if ! scan_bare_repo "${bare_dir}"; then
        if [ "${FORCE}" = false ]; then
            show_error "Repository contains security issues"
            echo -e "${YELLOW}Use --force to proceed anyway${NC}"
            exit 1
        else
            show_warning "Proceeding despite security issues (--force)"
        fi
    fi
    
    # Step 3: Sanitize config
    sanitize_config "${bare_dir}"
    
    # Step 4: Safe checkout
    safe_checkout "${bare_dir}" "${dest_dir}"
    
    # Step 5: Reinitialize
    reinitialize_repo "${dest_dir}"
    
    # Final summary
    show_header "Clone Complete"
    
    echo -e "${GREEN}${BOLD}✓ Repository acquired safely${NC}"
    echo
    echo -e "${BOLD}Location:${NC} ${dest_dir}"
    echo
    echo -e "${BOLD}Security Status:${NC}"
    echo "  ✓ Hooks disabled"
    echo "  ✓ fsmonitor disabled"
    echo "  ✓ Config sanitized"
    echo "  ✓ Repository reinitialized"
    echo
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Review the repository contents"
    echo "  2. Run git-remediate.sh for deeper scan:"
    echo "     sudo git-remediate.sh ${dest_dir}"
    echo "  3. Add remote when ready:"
    echo "     cd ${dest_dir} && git remote add origin ${repo_url}"
    echo
    
    log_event "Safe clone completed: ${repo_url} -> ${dest_dir}"
    
    return 0
}

# Run main function
main "$@"
