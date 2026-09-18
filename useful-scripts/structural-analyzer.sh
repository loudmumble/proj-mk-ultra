#!/usr/bin/env bash
# structural-analyzer.sh - Structural Vulnerability Detector
# SUSPICIOUS Framework: Deep Code Analysis
#
# Detects "syntactically correct but structurally vulnerable" code:
# - Taint analysis (data flow from untrusted → dangerous sinks)
# - Semantic analysis (logic flaws, timing issues)
# - Prompt injection detection
# - Race condition patterns
# - Logic flow vulnerabilities
#
# Usage: ./structural-analyzer.sh [options] <path>
#
# Requires: opengrep (optional but recommended), codeql (optional but powerful)
#
# NOTE: Pattern-based analysis will NEVER catch everything. New attack
# vectors emerge constantly. This is a first-pass filter, not a complete
# security audit. Manual review is always required for sensitive code.
#
# Based on research from:
# - OpenGrep taint mode (cross-function analysis)
# - CodeQL semantic analysis
# - CPGHunter (LLM-guided taint analysis)
# - loudmumble's CBPI research on structural vulnerabilities

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
VERBOSE=false
OUTPUT_DIR=".structural-analysis"
OPENGREP_ENABLED=false
CODEQL_ENABLED=false

# Counters
CRITICAL=0
HIGH=0
MEDIUM=0
LOW=0
INFO=0

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
║         S T R U C T U R A L   A N A L Y Z E R                       ║
║                                                                      ║
║         Deep Code Vulnerability Detection                            ║
║         "Syntactically correct, structurally vulnerable"             ║
║                                                                      ║
║         Powered by OpenGrep (LGPL 2.1)                              ║
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
    local details="${4:-}"
    
    local color=""
    local symbol=""
    
    case "${severity}" in
        CRITICAL)
            color="${RED}"
            symbol="✗"
            CRITICAL=$((CRITICAL + 1)) || true
            ;;
        HIGH)
            color="${RED}"
            symbol="!"
            HIGH=$((HIGH + 1)) || true
            ;;
        MEDIUM)
            color="${YELLOW}"
            symbol="⚠"
            MEDIUM=$((MEDIUM + 1)) || true
            ;;
        LOW)
            color="${YELLOW}"
            symbol="○"
            LOW=$((LOW + 1)) || true
            ;;
        INFO)
            color="${BLUE}"
            symbol="·"
            INFO=$((INFO + 1)) || true
            ;;
    esac
    
    echo -e "  ${color}${symbol} [${severity}] ${message}${NC}"
    if [ -n "${location}" ]; then
        echo -e "      ${color}Location: ${location}${NC}"
    fi
    if [ -n "${details}" ]; then
        echo -e "      ${color}Details: ${details}${NC}"
    fi
}

# Function to check for tools
check_tools() {
    show_header "Checking Available Tools"
    
    # Check for opengrep
    echo -n "[*] OpenGrep: "
    if command -v opengrep &> /dev/null; then
        echo -e "${GREEN}INSTALLED${NC}"
        OPENGREP_ENABLED=true
        local version=$(opengrep --version 2>/dev/null | head -1 || echo "unknown")
        echo -e "  Version: ${version}"
    else
        echo -e "${YELLOW}NOT INSTALLED${NC}"
        echo -e "  ${YELLOW}Install from: https://github.com/opengrep/opengrep/releases${NC}"
        echo -e "  ${YELLOW}Or: pip install opengrep${NC}"
        echo -e "  ${YELLOW}Binary (recommended): curl -sSL https://github.com/opengrep/opengrep/releases/latest/download/opengrep-x86_64-linux -o /usr/local/bin/opengrep && chmod +x /usr/local/bin/opengrep${NC}"
    fi
    
    # Check for codeql
    echo -n "[*] CodeQL: "
    if command -v codeql &> /dev/null; then
        echo -e "${GREEN}INSTALLED${NC}"
        CODEQL_ENABLED=true
    else
        echo -e "${YELLOW}NOT INSTALLED${NC}"
        echo -e "  ${YELLOW}Install: https://github.com/github/codeql-cli-binaries${NC}"
    fi
    
    # Check for basic tools
    echo -n "[*] grep/ripgrep: "
    if command -v rg &> /dev/null; then
        echo -e "${GREEN}ripgrep${NC}"
    elif command -v grep &> /dev/null; then
        echo -e "${GREEN}grep${NC}"
    else
        echo -e "${RED}NOT FOUND${NC}"
    fi
    
    echo
    
    if [ "${OPENGREP_ENABLED}" = false ] && [ "${CODEQL_ENABLED}" = false ]; then
        echo -e "${YELLOW}${BOLD}Warning: No advanced analysis tools installed${NC}"
        echo -e "${YELLOW}Running pattern-based analysis only (limited)${NC}"
        echo -e "${YELLOW}For full analysis, install opengrep or codeql${NC}"
    fi
    
    echo
}

# Function to run opengrep analysis
run_opengrep() {
    local target_path="$1"
    
    if [ "${OPENGREP_ENABLED}" = false ]; then
        return 0
    fi
    
    show_header "Running OpenGrep Taint Analysis"
    
    echo -e "${BOLD}Running OpenGrep with cross-function taint analysis...${NC}"
    echo
    
    local output_file="${OUTPUT_DIR}/opengrep-results.json"
    local sarif_file="${OUTPUT_DIR}/opengrep-results.sarif"
    
    # Run opengrep with taint mode (cross-function analysis)
    echo -e "${CYAN}  Mode: Cross-function taint (--taint-intrafile)${NC}"
    echo -e "${CYAN}  Rules: security-audit + owasp-top-ten${NC}"
    echo
    
    if opengrep \
        --config auto \
        --config p/security-audit \
        --config p/owasp-top-ten \
        --taint-intrafile \
        --json \
        --output "${output_file}" \
        "${target_path}" 2>/dev/null; then
        
        echo -e "${GREEN}✓ OpenGrep analysis completed${NC}"
        
        # Parse results
        local findings=$(cat "${output_file}" | jq -r '.results | length' 2>/dev/null || echo "0")
        echo -e "  Findings: ${findings}"
        
        # Extract critical findings
        if [ "${findings}" -gt 0 ]; then
            echo
            echo -e "${BOLD}  Critical/High findings:${NC}"
            cat "${output_file}" | jq -r '.results[] | select(.extra.severity == "ERROR") | "\(.check_id): \(.path):\(.start.line)"' 2>/dev/null | head -20 | while read line; do
                show_finding "HIGH" "OpenGrep: ${line}" ""
            done
        fi
        
        # Also generate SARIF for downstream tools
        opengrep \
            --config auto \
            --config p/security-audit \
            --taint-intrafile \
            --sarif \
            --output "${sarif_file}" \
            "${target_path}" 2>/dev/null || true
        
    else
        echo -e "${YELLOW}⚠ OpenGrep analysis failed or timed out${NC}"
    fi
    
    echo
}

# Function to run CodeQL analysis
run_codeql() {
    local target_path="$1"
    
    if [ "${CODEQL_ENABLED}" = false ]; then
        return 0
    fi
    
    show_header "Running CodeQL Semantic Analysis"
    
    echo -e "${BOLD}Running CodeQL deep analysis...${NC}"
    echo
    
    local db_path="${OUTPUT_DIR}/codeql-db"
    local results_file="${OUTPUT_DIR}/codeql-results.sarif"
    
    # Create database
    echo -n "  Creating CodeQL database: "
    if codeql database create \
        --language=javascript-typescript,python \
        --source-root="${target_path}" \
        "${db_path}" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}FAILED${NC}"
        return 1
    fi
    
    # Run analysis
    echo -n "  Running analysis: "
    if codeql database analyze \
        --format=sarif-latest \
        --output="${results_file}" \
        "${db_path}" \
        javascriptecurity-extended \
        pythonsecurity-extended 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        
        # Parse results
        local findings=$(cat "${results_file}" | jq -r '.runs[0].results | length' 2>/dev/null || echo "0")
        echo -e "  Findings: ${findings}"
    else
        echo -e "${YELLOW}FAILED${NC}"
    fi
    
    echo
}

# Function to detect taint patterns (manual analysis - fallback)
detect_taint_patterns_manual() {
    local target_path="$1"
    
    show_header "Detecting Taint Patterns (Manual Fallback)"
    
    echo -e "${BOLD}Scanning for data flow vulnerabilities (pattern-based)...${NC}"
    echo
    
    # Define taint sources (untrusted input)
    local sources=(
        "req\.body"
        "req\.params"
        "req\.query"
        "request\.GET"
        "request\.POST"
        "request\.form"
        "input\("
        "raw_input\("
        "sys\.argv"
        "ARGV"
        "ENV\["
        "process\.env"
        "getenv\("
        "os\.environ"
        "request\.headers"
        "request\.cookies"
    )
    
    # Define taint sinks (dangerous operations)
    local sinks=(
        "eval\("
        "exec\("
        "system\("
        "passthru\("
        "shell_exec\("
        "popen\("
        "proc_open\("
        "execfile\("
        "__import__\("
        "subprocess\.call"
        "subprocess\.Popen"
        "os\.system"
        "os\.popen"
        "child_process\.exec"
        "child_process\.spawn"
        "innerHTML\s*="
        "document\.write\("
        "sql\.execute"
        "cursor\.execute"
        "query\("
        "raw_query\("
        "interpolate"
        "format\("
        "f\""
        "f'"
        "${"
        "concatenation"
    )
    
    # Scan for sources
    echo -e "${BOLD}Taint Sources (untrusted input):${NC}"
    for source in "${sources[@]}"; do
        local count
        if command -v rg &> /dev/null; then
            count=$(rg -c "${source}" "${target_path}" --type py --type js --type ts 2>/dev/null | wc -l || echo "0")
        else
            count=$(grep -r "${source}" "${target_path}" --include="*.py" --include="*.js" --include="*.ts" --include="*.go" --include="*.java" --include="*.rb" 2>/dev/null | wc -l || echo "0")
        fi
        if [ "${count}" -gt 0 ]; then
            echo -e "  ${YELLOW}Found ${count} instances: ${source}${NC}"
        fi
    done
    echo
    
    # Scan for sinks
    echo -e "${BOLD}Taint Sinks (dangerous operations):${NC}"
    for sink in "${sinks[@]}"; do
        local count
        if command -v rg &> /dev/null; then
            count=$(rg -c "${sink}" "${target_path}" --type py --type js --type ts 2>/dev/null | wc -l || echo "0")
        else
            count=$(grep -r "${sink}" "${target_path}" --include="*.py" --include="*.js" --include="*.ts" --include="*.go" --include="*.java" --include="*.rb" 2>/dev/null | wc -l || echo "0")
        fi
        if [ "${count}" -gt 0 ]; then
            echo -e "  ${RED}Found ${count} instances: ${sink}${NC}"
        fi
    done
    echo
    
    # Check for unsanitized flows
    echo -e "${BOLD}Checking for unsanitized flows...${NC}"
    
    # Simple heuristic: if source and sink exist in same file without sanitizer
    find "${target_path}" -type f \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.go" -o -name "*.java" \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null | while read file; do
        local has_source=false
        local has_sink=false
        local has_sanitizer=false
        
        # Check for sources
        for source in "${sources[@]}"; do
            if grep -q "${source}" "${file}" 2>/dev/null; then
                has_source=true
                break
            fi
        done
        
        # Check for sinks
        for sink in "${sinks[@]}"; do
            if grep -q "${sink}" "${file}" 2>/dev/null; then
                has_sink=true
                break
            fi
        done
        
        # Check for sanitizers
        local sanitizers=(
            "sanitize"
            "escape"
            "encode"
            "parameterize"
            "validate"
            "clean"
            "whitelist"
            "allowlist"
        )
        
        for sanitizer in "${sanitizers[@]}"; do
            if grep -qi "${sanitizer}" "${file}" 2>/dev/null; then
                has_sanitizer=true
                break
            fi
        done
        
        # Report if source + sink without sanitizer
        if [ "${has_source}" = true ] && [ "${has_sink}" = true ] && [ "${has_sanitizer}" = false ]; then
            show_finding "HIGH" "Potential unsanitized taint flow" "${file}" "Source and sink found without obvious sanitizer"
        fi
    done
    
    echo
}

# Function to detect prompt injection
detect_prompt_injection() {
    local target_path="$1"
    
    show_header "Detecting Prompt Injection"
    
    echo -e "${BOLD}Scanning for AI/agent manipulation patterns...${NC}"
    echo
    
    # Prompt injection patterns
    local patterns=(
        "ignore previous"
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
        "new instructions"
        "forget everything"
        "reset your"
        "clear your"
        "new task"
        "urgent:"
        "important:"
        "priority:"
        "confidential:"
        "classified:"
        "secret:"
    )
    
    # Scan files
    find "${target_path}" -type f \( -name "*.md" -o -name "*.txt" -o -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.yaml" -o -name "*.yml" -o -name "*.json" -o -name "*.toml" -o -name "*.cfg" \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null | while read file; do
        for pattern in "${patterns[@]}"; do
            if grep -qi "${pattern}" "${file}" 2>/dev/null; then
                show_finding "HIGH" "Potential prompt injection: '${pattern}'" "${file}"
            fi
        done
        
        # Check for hidden characters (zero-width spaces, etc.)
        if grep -Pq '[\x{200B}-\x{200F}\x{FEFF}\x{2028}-\x{202F}]' "${file}" 2>/dev/null; then
            show_finding "HIGH" "Contains zero-width/invisible characters" "${file}"
        fi
        
        # Check for base64 encoded content
        if grep -qE "base64|atob|btoa" "${file}" 2>/dev/null; then
            local b64_count=$(grep -cE "base64|atob|btoa" "${file}" 2>/dev/null || echo "0")
            if [ "${b64_count}" -gt 2 ]; then
                show_finding "MEDIUM" "Multiple base64 references (${b64_count})" "${file}"
            fi
        fi
    done
    
    echo
}

# Function to detect race conditions
detect_race_conditions() {
    local target_path="$1"
    
    show_header "Detecting Race Conditions"
    
    echo -e "${BOLD}Scanning for timing/race condition patterns...${NC}"
    echo
    
    # Race condition patterns
    local patterns=(
        "TOCTOU"
        "time\.sleep"
        "setTimeout"
        "setInterval"
        "Thread\.sleep"
        "await\s+delay"
        "check\s+then\s+act"
        "if.*exists.*then"
        "if.*file.*exists"
        "if.*permission.*granted"
    )
    
    find "${target_path}" -type f \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.go" -o -name "*.java" \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null | while read file; do
        for pattern in "${patterns[@]}"; do
            if grep -qiE "${pattern}" "${file}" 2>/dev/null; then
                show_finding "MEDIUM" "Potential race condition pattern: '${pattern}'" "${file}"
            fi
        done
    done
    
    echo
}

# Function to detect logic flaws
detect_logic_flaws() {
    local target_path="$1"
    
    show_header "Detecting Logic Flaws"
    
    echo -e "${BOLD}Scanning for common logic vulnerabilities...${NC}"
    echo
    
    # Logic flaw patterns
    local patterns=(
        "if.*==.*true"
        "if.*==.*false"
        "if.*!=.*null"
        "if.*!=.*undefined"
        "if.*length.*>.*0"
        "if.*\.exists"
        "if.*\.isPresent"
        "try.*catch.*{.*}"
        "except.*:"
        "return.*if.*else"
    )
    
    find "${target_path}" -type f \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.go" -o -name "*.java" \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null | while read file; do
        for pattern in "${patterns[@]}"; do
            if grep -qiE "${pattern}" "${file}" 2>/dev/null; then
                show_finding "LOW" "Potential logic pattern: '${pattern}'" "${file}"
            fi
        done
    done
    
    echo
}

# Function to detect structural vulnerabilities
detect_structural_vulnerabilities() {
    local target_path="$1"
    
    show_header "Detecting Structural Vulnerabilities"
    
    echo -e "${BOLD}Scanning for code structure issues...${NC}"
    echo
    
    # Check for deeply nested code
    echo -e "${BOLD}Deep nesting (complexity indicator):${NC}"
    find "${target_path}" -type f \( -name "*.py" -o -name "*.js" -o -name "*.ts" \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null | while read file; do
        local max_depth
        if command -v rg &> /dev/null; then
            max_depth=$(rg -c "^\t+" "${file}" 2>/dev/null | head -1 || echo "0")
        else
            max_depth=$(awk '{n=gsub(/\t/,"&"); if(n>max) max=n} END{print max}' "${file}" 2>/dev/null || echo "0")
        fi
        if [ "${max_depth}" -gt 6 ]; then
            show_finding "MEDIUM" "Deeply nested code (depth: ${max_depth})" "${file}"
        fi
    done
    echo
    
    # Check for long functions
    echo -e "${BOLD}Long functions (complexity indicator):${NC}"
    find "${target_path}" -type f \( -name "*.py" -o -name "*.js" -o -name "*.ts" \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null | while read file; do
        local total_lines
        total_lines=$(wc -l < "${file}" 2>/dev/null || echo "0")
        
        if [ "${total_lines}" -gt 500 ]; then
            show_finding "MEDIUM" "Large file (${total_lines} lines)" "${file}"
        fi
    done
    echo
    
    # Check for code duplication indicators
    echo -e "${BOLD}Potential code duplication:${NC}"
    find "${target_path}" -type f \( -name "*.py" -o -name "*.js" -o -name "*.ts" \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null | while read file; do
        # Check for copy-paste patterns
        local dup_indicators
        dup_indicators=$(grep -cE "(TODO|FIXME|HACK|XXX|COPYPASTE)" "${file}" 2>/dev/null || echo "0")
        if [ "${dup_indicators}" -gt 2 ]; then
            show_finding "LOW" "Multiple TODO/FIXME markers (${dup_indicators})" "${file}"
        fi
    done
    
    echo
}

# Function to generate report
generate_report() {
    local target_path="$1"
    
    show_header "Analysis Report"
    
    local total=$((CRITICAL + HIGH + MEDIUM + LOW + INFO))
    
    echo -e "${BOLD}Analysis Results:${NC}"
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
        echo -e "${RED}${BOLD}✗ VERDICT: STRUCTURALLY VULNERABLE${NC}"
        echo -e "${RED}  This codebase contains critical structural vulnerabilities.${NC}"
        echo -e "${RED}  Recommend: Do not use until remediated.${NC}"
    elif [ "${HIGH}" -gt 0 ]; then
        echo -e "${YELLOW}${BOLD}⚠ VERDICT: POTENTIALLY VULNERABLE${NC}"
        echo -e "${YELLOW}  This codebase has high-severity structural issues.${NC}"
        echo -e "${YELLOW}  Recommend: Manual review required.${NC}"
    elif [ "${MEDIUM}" -gt 0 ]; then
        echo -e "${YELLOW}${BOLD}○ VERDICT: NEEDS REVIEW${NC}"
        echo -e "${YELLOW}  Some structural concerns detected.${NC}"
    else
        echo -e "${GREEN}${BOLD}✓ VERDICT: STRUCTURALLY SOUND${NC}"
        echo -e "${GREEN}  No obvious structural vulnerabilities found.${NC}"
    fi
    
    echo
    
    # Limitations disclaimer
    echo -e "${YELLOW}${BOLD}IMPORTANT LIMITATIONS:${NC}"
    echo -e "${YELLOW}  This analysis is pattern-based and will NOT catch:${NC}"
    echo -e "${YELLOW}  - Novel attack vectors not in rule sets${NC}"
    echo -e "${YELLOW}  - Context-dependent vulnerabilities${NC}"
    echo -e "${YELLOW}  - Business logic flaws${NC}"
    echo -e "${YELLOW}  - Zero-day exploits${NC}"
    echo -e "${YELLOW}  - Subtle timing attacks${NC}"
    echo -e "${YELLOW}  Always pair with manual security review.${NC}"
    echo
    
    # Output files
    if [ -d "${OUTPUT_DIR}" ]; then
        echo -e "${BOLD}Output Files:${NC}"
        ls -la "${OUTPUT_DIR}/" 2>/dev/null || true
        echo
    fi
    
    # Recommendations
    echo -e "${BOLD}Recommendations:${NC}"
    echo
    if [ "${CRITICAL}" -gt 0 ] || [ "${HIGH}" -gt 0 ]; then
        echo "  1. Run OpenGrep with custom rules for your domain"
        echo "  2. Manual security review required"
        echo "  3. Consider rewriting vulnerable sections"
        echo "  4. Add comprehensive tests"
        echo "  5. Run CodeQL for deeper semantic analysis"
    elif [ "${MEDIUM}" -gt 0 ]; then
        echo "  1. Review flagged patterns"
        echo "  2. Add input validation/sanitization"
        echo "  3. Consider adding tests for edge cases"
        echo "  4. Run with --opengrep for taint analysis"
    else
        echo "  1. Continue monitoring"
        echo "  2. Add security tests to prevent regression"
        echo "  3. Consider adding custom OpenGrep rules"
    fi
    
    echo
}

# Function to display usage
show_usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 [options] <path>"
    echo
    echo -e "${BOLD}Options:${NC}"
    echo "  --scan          Scan only (default)"
    echo "  --opengrep      Run OpenGrep taint analysis (if installed)"
    echo "  --codeql        Run CodeQL analysis (if installed)"
    echo "  --all           Run all available analyses"
    echo "  --verbose       Show detailed output"
    echo "  --help          Show this help"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0 /path/to/code                    # Pattern-based analysis"
    echo "  $0 --opengrep /path/to/code         # Add OpenGrep taint analysis"
    echo "  $0 --all /path/to/code              # Run all analyses"
    echo
    echo -e "${BOLD}What it detects:${NC}"
    echo "  ✓ Taint flows (untrusted → dangerous sinks)"
    echo "  ✓ Prompt injection patterns"
    echo "  ✓ Race condition patterns"
    echo "  ✓ Logic flaw indicators"
    echo "  ✓ Structural complexity issues"
    echo "  ✓ Code duplication indicators"
    echo
    echo -e "${BOLD}Installation:${NC}"
    echo "  OpenGrep (recommended):"
    echo "    curl -sSL https://github.com/opengrep/opengrep/releases/latest/download/opengrep-x86_64-linux -o /usr/local/bin/opengrep"
    echo "    chmod +x /usr/local/bin/opengrep"
    echo
    echo -e "${BOLD}For loudmumble's GitLab remediation:${NC}"
    echo "  1. Clone repos safely: ./git-protect.sh <url>"
    echo "  2. Run this analyzer: $0 --all <repo-path>"
    echo "  3. Review findings manually"
    echo "  4. Remediate with: ./git-remediate.sh --fix <repo-path>"
    echo
}

# Main execution
main() {
    local target_path=""
    local run_opengrep=false
    local run_codeql=false
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --scan)
                shift
                ;;
            --opengrep)
                run_opengrep=true
                shift
                ;;
            --codeql)
                run_codeql=true
                shift
                ;;
            --all)
                run_opengrep=true
                run_codeql=true
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
    
    show_banner
    
    echo -e "${BOLD}Target:${NC} ${target_path}"
    echo -e "${BOLD}Mode:${NC} $([ "${run_opengrep}" = true ] || [ "${run_codeql}" = true ] && echo "Full Analysis" || echo "Pattern-Based")"
    echo
    
    # Create output directory
    mkdir -p "${OUTPUT_DIR}"
    
    # Check tools
    check_tools
    
    # Run analyses
    if [ "${run_opengrep}" = true ]; then
        run_opengrep "${target_path}"
    fi
    
    if [ "${run_codeql}" = true ]; then
        run_codeql "${target_path}"
    fi
    
    # Always run pattern-based analysis (fallback when no tools installed)
    detect_taint_patterns_manual "${target_path}"
    detect_prompt_injection "${target_path}"
    detect_race_conditions "${target_path}"
    detect_logic_flaws "${target_path}"
    detect_structural_vulnerabilities "${target_path}"
    
    # Generate report
    generate_report "${target_path}"
    
    # Exit code
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
