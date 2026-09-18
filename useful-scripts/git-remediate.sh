#!/usr/bin/env bash
# git-remediate.sh - Git Repository Remediation Tool
# SUSPICIOUS Framework: Code-Base Recovery
#
# Scans and remediates poisoned git repositories:
# - Command/prompt injection
# - Malicious hooks
# - Dangerous config directives
# - File attribute poisoning
# - Metadata corruption
#
# Usage: sudo ./git-remediate.sh [options] <repo-path>
#
# Based on research from:
# - git-malware-remediator
# - coldclone
# - git-protect
# - git-sentinel

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
QUARANTINE_DIR=".quarantine"
LOG_FILE="/var/log/git-remediate.log"
DRY_RUN=true
VERBOSE=false
FIX_MODE=false

# Counters
CRITICAL=0
HIGH=0
MEDIUM=0
LOW=0
INFO=0

# Logging
log_event() {
    local event="$1"
    local level="${2:-INFO}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $event" >> "${LOG_FILE}" 2>/dev/null || true
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
║         G I T   R E M E D I A T I O N   T O O L                     ║
║                                                                      ║
║         Scan and repair poisoned repositories                        ║
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
            CRITICAL=$((CRITICAL + 1))
            ;;
        HIGH)
            color="${RED}"
            symbol="!"
            HIGH=$((HIGH + 1))
            ;;
        MEDIUM)
            color="${YELLOW}"
            symbol="⚠"
            MEDIUM=$((MEDIUM + 1))
            ;;
        LOW)
            color="${YELLOW}"
            symbol="○"
            LOW=$((LOW + 1))
            ;;
        INFO)
            color="${BLUE}"
            symbol="·"
            INFO=$((INFO + 1))
            ;;
    esac
    
    echo -e "  ${color}${symbol} [${severity}] ${message}${NC}"
    if [ -n "${location}" ]; then
        echo -e "      ${color}Location: ${location}${NC}"
    fi
    
    log_event "[${severity}] ${message} at ${location}"
}

# Function to create quarantine directory
create_quarantine() {
    local repo_path="$1"
    local quarantine="${repo_path}/${QUARANTINE_DIR}"
    
    if [ ! -d "${quarantine}" ]; then
        mkdir -p "${quarantine}"
        echo "# Git Remediation Quarantine" > "${quarantine}/MANIFEST.txt"
        echo "# Created: $(date)" >> "${quarantine}/MANIFEST.txt"
        echo "# Repository: ${repo_path}" >> "${quarantine}/MANIFEST.txt"
        echo "" >> "${quarantine}/MANIFEST.txt"
    fi
    
    echo "${quarantine}"
}

# Function to quarantine a file
quarantine_file() {
    local file="$1"
    local quarantine="$2"
    local reason="$3"
    
    if [ -f "${file}" ]; then
        local basename=$(basename "${file}")
        local dir=$(dirname "${file}")
        local quarantine_path="${quarantine}/${basename}.$(date +%s)"
        
        if [ "${DRY_RUN}" = true ]; then
            echo -e "      ${YELLOW}[DRY-RUN] Would quarantine: ${file}${NC}"
        else
            mv "${file}" "${quarantine_path}"
            echo "QUARANTINED: ${file} -> ${quarantine_path}" >> "${quarantine}/MANIFEST.txt"
            echo "REASON: ${reason}" >> "${quarantine}/MANIFEST.txt"
            echo "" >> "${quarantine}/MANIFEST.txt"
            echo -e "      ${GREEN}[FIXED] Quarantined: ${file}${NC}"
        fi
    fi
}

# Function to scan git hooks
scan_hooks() {
    local repo_path="$1"
    local hooks_dir="${repo_path}/.git/hooks"
    
    show_header "Scanning Git Hooks"
    
    if [ ! -d "${hooks_dir}" ]; then
        echo -e "  ${YELLOW}No hooks directory found${NC}"
        return 0
    fi
    
    echo -e "${BOLD}Checking for malicious hooks...${NC}"
    echo
    
    # Check for non-sample hooks
    for hook in "${hooks_dir}"/*; do
        if [ -f "${hook}" ] && [[ ! "${hook}" =~ \.sample$ ]]; then
            local hook_name=$(basename "${hook}")
            local first_line=$(head -1 "${hook}" 2>/dev/null || echo "")
            
            # Check for suspicious shebangs
            if echo "${first_line}" | grep -E "^#!.*/(sh|bash|zsh|python|node|perl|ruby)" > /dev/null; then
                show_finding "CRITICAL" "Custom executable hook detected" "${hook}"
                
                # Check hook content for suspicious patterns
                if grep -qE "(curl|wget|eval|exec|base64|decode|http|https)" "${hook}" 2>/dev/null; then
                    show_finding "HIGH" "Hook contains network/execution patterns" "${hook}"
                fi
                
                if [ "${FIX_MODE}" = true ]; then
                    local quarantine=$(create_quarantine "${repo_path}")
                    quarantine_file "${hook}" "${quarantine}" "Custom executable hook"
                fi
            fi
        fi
    done
    
    # Check for hooks directory with suspicious content
    if [ -d "${hooks_dir}/.git" ]; then
        show_finding "CRITICAL" "Embedded .git directory in hooks" "${hooks_dir}/.git"
    fi
    
    echo
}

# Function to scan git config
scan_config() {
    local repo_path="$1"
    local config_file="${repo_path}/.git/config"
    
    show_header "Scanning Git Config"
    
    if [ ! -f "${config_file}" ]; then
        echo -e "  ${YELLOW}No .git/config found${NC}"
        return 0
    fi
    
    echo -e "${BOLD}Checking for dangerous config directives...${NC}"
    echo
    
    # Dangerous config keys
    local dangerous_keys=(
        "core.hooksPath"
        "core.fsmonitor"
        "core.editor"
        "core.pager"
        "include.path"
        "includeIf.*.path"
        "url.*.insteadOf"
        "http.proxy"
        "https.proxy"
    )
    
    for key in "${dangerous_keys[@]}"; do
        if grep -q "${key}" "${config_file}" 2>/dev/null; then
            local value=$(grep "${key}" "${config_file}" | head -1 | awk '{print $3}')
            show_finding "HIGH" "Dangerous config directive: ${key}" "${config_file}"
            echo -e "      ${YELLOW}Value: ${value}${NC}"
        fi
    done
    
    # Check for external hooks path
    if grep -q "hooksPath" "${config_file}" 2>/dev/null; then
        local hooks_path=$(grep "hooksPath" "${config_file}" | awk '{print $3}')
        if [ "${hooks_path}" != "${repo_path}/.git/hooks" ]; then
            show_finding "CRITICAL" "External hooks path configured" "${config_file}"
            echo -e "      ${RED}Path: ${hooks_path}${NC}"
        fi
    fi
    
    echo
}

# Function to scan for prompt injection
scan_prompt_injection() {
    local repo_path="$1"
    
    show_header "Scanning for Prompt Injection"
    
    echo -e "${BOLD}Checking for AI/agent manipulation patterns...${NC}"
    echo
    
    # Patterns that indicate prompt injection
    local patterns=(
        "ignore previous instructions"
        "ignore all previous"
        "you are now"
        "act as"
        "pretend to be"
        "disregard"
        "override"
        "system prompt"
        "ADMIN OVERRIDE"
        "SECRET INSTRUCTION"
        "hidden instruction"
        "do not tell"
        "never mention"
        "between you and me"
        "confidential"
        "trust me"
        "do not share"
    )
    
    # Scan text files
    find "${repo_path}" -type f \( -name "*.md" -o -name "*.txt" -o -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.sh" -o -name "*.yaml" -o -name "*.yml" -o -name "*.json" -o -name "*.toml" \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/${QUARANTINE_DIR}/*" 2>/dev/null | while read file; do
        for pattern in "${patterns[@]}"; do
            if grep -qi "${pattern}" "${file}" 2>/dev/null; then
                show_finding "HIGH" "Potential prompt injection: '${pattern}'" "${file}"
            fi
        done
        
        # Check for zero-width characters
        if grep -Pq '[\x{200B}-\x{200F}\x{FEFF}\x{2028}-\x{202F}]' "${file}" 2>/dev/null; then
            show_finding "HIGH" "Contains zero-width/invisible characters" "${file}"
        fi
        
        # Check for base64 encoded content
        if grep -qE "base64|atob|btoa|decode|encode" "${file}" 2>/dev/null; then
            local b64_count=$(grep -cE "base64|atob|btoa" "${file}" 2>/dev/null || echo "0")
            if [ "${b64_count}" -gt 2 ]; then
                show_finding "MEDIUM" "Multiple base64 references (${b64_count})" "${file}"
            fi
        fi
    done
    
    echo
}

# Function to scan for dangerous file patterns
scan_dangerous_files() {
    local repo_path="$1"
    
    show_header "Scanning for Dangerous Files"
    
    echo -e "${BOLD}Checking for malicious file patterns...${NC}"
    echo
    
    # Dangerous file patterns
    local dangerous_files=(
        ".env"
        ".env.local"
        ".env.production"
        ".env.development"
        "*.pem"
        "*.key"
        "*.p12"
        "*.pfx"
        "id_rsa"
        "id_ed25519"
        ".ssh/*"
        ".aws/*"
        ".config/*"
        "credentials"
        "secrets.*"
    )
    
    for pattern in "${dangerous_files[@]}"; do
        find "${repo_path}" -name "${pattern}" -not -path "*/.git/*" -not -path "*/${QUARANTINE_DIR}/*" 2>/dev/null | while read file; do
            # Check if file contains actual secrets
            if grep -qE "(password|secret|token|key|api_key|apikey)" "${file}" 2>/dev/null; then
                show_finding "CRITICAL" "Potential secrets file: ${pattern}" "${file}"
            else
                show_finding "MEDIUM" "Sensitive file pattern: ${pattern}" "${file}"
            fi
        done
    done
    
    # Check for executable scripts with suspicious content
    find "${repo_path}" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" -o -name "*.js" \) -not -path "*/.git/*" -not -path "*/${QUARANTINE_DIR}/*" -executable 2>/dev/null | while read file; do
        if grep -qE "(curl|wget).*\|.*sh|eval\s*\(|exec\s*\(" "${file}" 2>/dev/null; then
            show_finding "HIGH" "Executable with network/eval patterns" "${file}"
        fi
    done
    
    echo
}

# Function to scan for symlink attacks
scan_symlinks() {
    local repo_path="$1"
    
    show_header "Scanning for Symlink Attacks"
    
    echo -e "${BOLD}Checking for symlink-based attacks...${NC}"
    echo
    
    # Find symlinks that escape the repo
    find "${repo_path}" -type l -not -path "*/.git/*" 2>/dev/null | while read link; do
        local target=$(readlink -f "${link}" 2>/dev/null || echo "")
        
        if [ -n "${target}" ]; then
            # Check if target escapes the repo
            if [[ "${target}" != "${repo_path}"* ]]; then
                show_finding "CRITICAL" "Symlink escapes repository" "${link}"
                echo -e "      ${RED}Target: ${target}${NC}"
            fi
        fi
    done
    
    echo
}

# Function to scan for .gitattributes injection
scan_gitattributes() {
    local repo_path="$1"
    local gitattributes="${repo_path}/.gitattributes"
    
    show_header "Scanning .gitattributes"
    
    if [ ! -f "${gitattributes}" ]; then
        echo -e "  ${YELLOW}No .gitattributes found${NC}"
        return 0
    fi
    
    echo -e "${BOLD}Checking for dangerous filter/diff/merge drivers...${NC}"
    echo
    
    # Check for custom filter drivers
    if grep -qE "filter=" "${gitattributes}" 2>/dev/null; then
        show_finding "HIGH" "Custom filter driver configured" "${gitattributes}"
    fi
    
    # Check for custom diff drivers
    if grep -qE "diff=" "${gitattributes}" 2>/dev/null; then
        show_finding "MEDIUM" "Custom diff driver configured" "${gitattributes}"
    fi
    
    # Check for custom merge drivers
    if grep -qE "merge=" "${gitattributes}" 2>/dev/null; then
        show_finding "MEDIUM" "Custom merge driver configured" "${gitattributes}"
    fi
    
    echo
}

# Function to scan IDE configs
scan_ide_configs() {
    local repo_path="$1"
    
    show_header "Scanning IDE Configurations"
    
    echo -e "${BOLD}Checking for dangerous IDE settings...${NC}"
    echo
    
    # VS Code tasks.json with runOn: folderOpen
    local vscode_tasks="${repo_path}/.vscode/tasks.json"
    if [ -f "${vscode_tasks}" ]; then
        if grep -q "folderOpen" "${vscode_tasks}" 2>/dev/null; then
            show_finding "HIGH" "VS Code task with runOn: folderOpen" "${vscode_tasks}"
        fi
    fi
    
    # VS Code settings.json with dangerous overrides
    local vscode_settings="${repo_path}/.vscode/settings.json"
    if [ -f "${vscode_settings}" ]; then
        if grep -qE "(git.path|python|terminal)" "${vscode_settings}" 2>/dev/null; then
            show_finding "MEDIUM" "VS Code settings override detected" "${vscode_settings}"
        fi
    fi
    
    # Check for .envrc (direnv)
    local envrc="${repo_path}/.envrc"
    if [ -f "${envrc}" ]; then
        if grep -qE "(GIT_CONFIG|PATH|LD_PRELOAD)" "${envrc}" 2>/dev/null; then
            show_finding "HIGH" ".envrc with dangerous environment variables" "${envrc}"
        fi
    fi
    
    # Check for .devcontainer
    local devcontainer="${repo_path}/.devcontainer/devcontainer.json"
    if [ -f "${devcontainer}" ]; then
        if grep -qE "(postCreateCommand|postStartCommand|postAttachCommand)" "${devcontainer}" 2>/dev/null; then
            show_finding "MEDIUM" ".devcontainer with lifecycle commands" "${devcontainer}"
        fi
    fi
    
    echo
}

# Function to generate report
generate_report() {
    local repo_path="$1"
    
    show_header "Remediation Report"
    
    local total=$((CRITICAL + HIGH + MEDIUM + LOW + INFO))
    
    echo -e "${BOLD}Scan Results:${NC}"
    echo
    echo -e "  Total findings: ${total}"
    echo -e "  ${RED}Critical: ${CRITICAL}${NC}"
    echo -e "  ${RED}High: ${HIGH}${NC}"
    echo -e "  ${YELLOW}Medium: ${MEDIUM}${NC}"
    echo -e "  ${YELLOW}Low: ${LOW}${NC}"
    echo -e "  ${BLUE}Info: ${INFO}${NC}"
    echo
    
    # Overall verdict
    if [ "${CRITICAL}" -gt 0 ]; then
        echo -e "${RED}${BOLD}✗ VERDICT: DANGEROUS - DO NOT USE${NC}"
        echo -e "${RED}  This repository contains critical security issues.${NC}"
        echo -e "${RED}  Review quarantine directory before proceeding.${NC}"
    elif [ "${HIGH}" -gt 0 ]; then
        echo -e "${YELLOW}${BOLD}⚠ VERDICT: SUSPICIOUS - REVIEW REQUIRED${NC}"
        echo -e "${YELLOW}  This repository contains high-severity findings.${NC}"
        echo -e "${YELLOW}  Manual review recommended.${NC}"
    elif [ "${MEDIUM}" -gt 0 ]; then
        echo -e "${YELLOW}${BOLD}○ VERDICT: CAUTION${NC}"
        echo -e "${YELLOW}  Some concerning patterns detected.${NC}"
    else
        echo -e "${GREEN}${BOLD}✓ VERDICT: CLEAN${NC}"
        echo -e "${GREEN}  No significant security issues found.${NC}"
    fi
    
    echo
    
    # Quarantine info
    if [ -d "${repo_path}/${QUARANTINE_DIR}" ]; then
        echo -e "${BOLD}Quarantine Directory:${NC}"
        echo "  ${repo_path}/${QUARANTINE_DIR}"
        echo
        echo -e "${YELLOW}Review quarantined files before deletion:${NC}"
        echo "  cat ${repo_path}/${QUARANTINE_DIR}/MANIFEST.txt"
    fi
    
    echo
}

# Function to display usage
show_usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  sudo $0 [options] <repo-path>"
    echo
    echo -e "${BOLD}Options:${NC}"
    echo "  --scan          Scan only (default, no changes)"
    echo "  --fix           Apply fixes (quarantine malicious files)"
    echo "  --dry-run       Show what would be done (default)"
    echo "  --verbose       Show detailed output"
    echo "  --help          Show this help"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo "  sudo $0 /path/to/repo              # Scan repository"
    echo "  sudo $0 --fix /path/to/repo        # Scan and fix"
    echo "  sudo $0 --verbose /path/to/repo    # Detailed scan"
    echo
}

# Main execution
main() {
    local repo_path=""
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --scan)
                DRY_RUN=true
                FIX_MODE=false
                shift
                ;;
            --fix)
                DRY_RUN=false
                FIX_MODE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
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
                repo_path="$1"
                shift
                ;;
        esac
    done
    
    # Check for repo path
    if [ -z "${repo_path}" ]; then
        echo -e "${RED}${BOLD}[ERROR] Repository path required${NC}"
        show_usage
        exit 1
    fi
    
    # Validate repo path
    if [ ! -d "${repo_path}/.git" ]; then
        echo -e "${RED}${BOLD}[ERROR] Not a git repository: ${repo_path}${NC}"
        exit 1
    fi
    
    show_banner
    
    echo -e "${BOLD}Repository:${NC} ${repo_path}"
    echo -e "${BOLD}Mode:${NC} $([ "${FIX_MODE}" = true ] && echo "FIX" || echo "SCAN")"
    echo
    
    # Run all scans
    scan_hooks "${repo_path}"
    scan_config "${repo_path}"
    scan_prompt_injection "${repo_path}"
    scan_dangerous_files "${repo_path}"
    scan_symlinks "${repo_path}"
    scan_gitattributes "${repo_path}"
    scan_ide_configs "${repo_path}"
    
    # Generate report
    generate_report "${repo_path}"
    
    # Exit code based on severity
    if [ "${CRITICAL}" -gt 0 ]; then
        exit 2
    elif [ "${HIGH}" -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

# Run main function
main "$@"
