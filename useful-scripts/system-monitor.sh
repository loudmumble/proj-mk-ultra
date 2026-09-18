#!/usr/bin/env bash
# system-monitor.sh - Real-time System Monitor
# SUSPICIOUS Framework: System Visibility
#
# Provides real-time monitoring of:
# - CPU/Memory/Disk usage
# - Network connections
# - Process activity
# - Kernel instance status
# - Security events
#
# Usage: ./system-monitor.sh [options]

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
MULTIKERNEL_SYSFS="/sys/fs/multikernel"
REFRESH_INTERVAL=2
SHOW_PROCESSES=true
SHOW_NETWORK=true
SHOW_KERNEL=true

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
║         S Y S T E M   M O N I T O R                                 ║
║                                                                      ║
║         Real-time System Visibility                                  ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Function to get CPU usage
get_cpu_usage() {
    local cpu_info=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo "${cpu_info:-0}"
}

# Function to get memory usage
get_memory_usage() {
    free -m | awk '/^Mem:/ {printf "%.1f%%", $3/$2 * 100}'
}

# Function to get disk usage
get_disk_usage() {
    df -h / | awk 'NR==2 {print $5}'
}

# Function to get load average
get_load_average() {
    uptime | awk -F'load average:' '{print $2}' | xargs
}

# Function to draw progress bar
draw_bar() {
    local value=$1
    local width=$2
    local filled=$((value * width / 100))
    local empty=$((width - filled))
    
    printf "["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "]"
}

# Function to display CPU section
show_cpu() {
    echo -e "${BOLD}CPU:${NC}"
    
    local cpu_usage=$(get_cpu_usage)
    local cpu_int=${cpu_usage%.*}
    
    local color="${GREEN}"
    [ "${cpu_int}" -gt 70 ] && color="${YELLOW}"
    [ "${cpu_int}" -gt 90 ] && color="${RED}"
    
    echo -e "  Usage: ${color}$(draw_bar ${cpu_int} 30)${NC} ${cpu_usage}%"
    echo -e "  Cores: $(nproc)"
    echo -e "  Load:  $(get_load_average)"
    echo
}

# Function to display memory section
show_memory() {
    echo -e "${BOLD}Memory:${NC}"
    
    local mem_info=$(free -m | awk '/^Mem:/ {print $2, $3, $4}')
    local total=$(echo ${mem_info} | awk '{print $1}')
    local used=$(echo ${mem_info} | awk '{print $2}')
    local free=$(echo ${mem_info} | awk '{print $3}')
    
    local usage_percent=$((used * 100 / total))
    
    local color="${GREEN}"
    [ "${usage_percent}" -gt 70 ] && color="${YELLOW}"
    [ "${usage_percent}" -gt 90 ] && color="${RED}"
    
    echo -e "  Usage:  ${color}$(draw_bar ${usage_percent} 30)${NC} ${usage_percent}%"
    echo -e "  Total:  ${total}MB"
    echo -e "  Used:   ${used}MB"
    echo -e "  Free:   ${free}MB"
    echo
}

# Function to display disk section
show_disk() {
    echo -e "${BOLD}Disk:${NC}"
    
    df -h / | awk 'NR==2 {
        printf "  Usage: "
        gsub(/%/, "", $5)
        if ($5 > 90) printf "\033[0;31m"
        else if ($5 > 70) printf "\033[1;33m"
        else printf "\033[0;32m"
        printf "[%s", ""
        for (i=0; i<$5/5; i++) printf "█"
        for (i=$5/5; i<20; i++) printf "░"
        printf "]\033[0m %s\n", $5 "%"
        printf "  Total: %s\n", $2
        printf "  Used:  %s\n", $3
        printf "  Free:  %s\n", $4
    }'
    echo
}

# Function to display network section
show_network() {
    if [ "${SHOW_NETWORK}" = false ]; then
        return 0
    fi
    
    echo -e "${BOLD}Network:${NC}"
    
    # Active connections
    local connections=$(ss -tn 2>/dev/null | grep -c "ESTAB" || echo "0")
    echo -e "  Active connections: ${connections}"
    
    # Listen ports
    local listening=$(ss -tl 2>/dev/null | grep -c "LISTEN" || echo "0")
    echo -e "  Listening ports:   ${listening}"
    
    # Show recent connections
    echo -e "  ${BLUE}Recent connections:${NC}"
    ss -tn 2>/dev/null | head -5 | awk '{
        if (NF >= 5) {
            printf "    %-20s -> %-20s %s\n", $4, $5, $1
        }
    }' || true
    
    echo
}

# Function to display kernel instances
show_kernel_instances() {
    if [ "${SHOW_KERNEL}" = false ]; then
        return 0
    fi
    
    echo -e "${BOLD}Kernel Instances:${NC}"
    
    if [ ! -d "${MULTIKERNEL_SYSFS}/instances" ]; then
        echo -e "  ${YELLOW}No multikernel instances found${NC}"
        echo
        return 0
    fi
    
    for instance_dir in "${MULTIKERNEL_SYSFS}/instances"/*/; do
        if [ -d "${instance_dir}" ]; then
            local name=$(basename "${instance_dir}")
            local status="unknown"
            local cpus="N/A"
            local memory="N/A"
            
            [ -f "${instance_dir}/status" ] && status=$(cat "${instance_dir}/status" 2>/dev/null || echo "unknown")
            [ -f "${instance_dir}/cpus" ] && cpus=$(cat "${instance_dir}/cpus" 2>/dev/null || echo "N/A")
            [ -f "${instance_dir}/memory" ] && memory=$(cat "${instance_dir}/memory" 2>/dev/null || echo "N/A")
            
            local status_color="${NC}"
            case "${status}" in
                running) status_color="${GREEN}" ;;
                stopped) status_color="${YELLOW}" ;;
                error) status_color="${RED}" ;;
            esac
            
            echo -e "  ${name}: ${status_color}${status}${NC} (CPUs: ${cpus}, Mem: ${memory})"
        fi
    done
    
    echo
}

# Function to display top processes
show_processes() {
    if [ "${SHOW_PROCESSES}" = false ]; then
        return 0
    fi
    
    echo -e "${BOLD}Top Processes (by CPU):${NC}"
    
    ps aux --sort=-%cpu 2>/dev/null | head -6 | awk 'NR==1 {
        printf "  %-8s %-6s %-6s %-10s %s\n", "USER", "%CPU", "%MEM", "RSS", "COMMAND"
    } NR>1 {
        printf "  %-8s %-6s %-6s %-10s %s\n", $1, $3, $4, $6, $11
    }' || true
    
    echo
}

# Function to display security events
show_security() {
    echo -e "${BOLD}Security:${NC}"
    
    # Check for suspicious processes
    local suspicious=0
    
    # Check for crypto miners
    if pgrep -f "(xmrig|cryptonight|stratum)" > /dev/null 2>&1; then
        echo -e "  ${RED}⚠ Potential crypto miner detected!${NC}"
        suspicious=$((suspicious + 1))
    fi
    
    # Check for reverse shells
    if pgrep -f "(nc -e|ncat|socat.*exec)" > /dev/null 2>&1; then
        echo -e "  ${RED}⚠ Potential reverse shell detected!${NC}"
        suspicious=$((suspicious + 1))
    fi
    
    # Check for unauthorized root processes
    local root_procs=$(ps aux 2>/dev/null | awk '$1=="root" && $11 !~ /^(\/sbin|\/usr\/sbin|\/bin|\/usr\/bin)/' | wc -l || echo "0")
    if [ "${root_procs}" -gt 5 ]; then
        echo -e "  ${YELLOW}⚠ Unusual number of root processes: ${root_procs}${NC}"
    fi
    
    if [ "${suspicious}" -eq 0 ]; then
        echo -e "  ${GREEN}✓ No obvious threats detected${NC}"
    fi
    
    # Check taint status
    if [ -f "/proc/sys/kernel/tainted" ]; then
        local taint=$(cat /proc/sys/kernel/tainted)
        if [ "${taint}" != "0" ]; then
            echo -e "  ${YELLOW}⚠ Kernel tainted: ${taint}${NC}"
        fi
    fi
    
    echo
}

# Function to display header
show_header() {
    echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${NC}"
}

# Function to display timestamp
show_timestamp() {
    echo -e "${BLUE}$(date '+%Y-%m-%d %H:%M:%S')${NC} | Refresh: ${REFRESH_INTERVAL}s | Press Ctrl+C to exit"
}

# Main monitoring loop
monitor_loop() {
    while true; do
        clear
        show_banner
        show_timestamp
        echo
        
        show_cpu
        show_memory
        show_disk
        show_network
        show_kernel_instances
        show_processes
        show_security
        
        sleep "${REFRESH_INTERVAL}"
    done
}

# Function to display usage
show_usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 [options]"
    echo
    echo -e "${BOLD}Options:${NC}"
    echo "  --no-processes     Hide process list"
    echo "  --no-network       Hide network info"
    echo "  --no-kernel        Hide kernel instances"
    echo "  --interval <sec>   Set refresh interval (default: 2)"
    echo "  --help             Show this help"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                          # Full monitoring"
    echo "  $0 --no-processes           # Hide processes"
    echo "  $0 --interval 5             # Refresh every 5 seconds"
    echo
}

# Main execution
main() {
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-processes)
                SHOW_PROCESSES=false
                shift
                ;;
            --no-network)
                SHOW_NETWORK=false
                shift
                ;;
            --no-kernel)
                SHOW_KERNEL=false
                shift
                ;;
            --interval)
                REFRESH_INTERVAL="$2"
                shift 2
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Check if running as root (for some features)
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}Note: Some features require root privileges${NC}"
    fi
    
    # Start monitoring
    monitor_loop
}

# Run main function
main "$@"
