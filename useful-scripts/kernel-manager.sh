#!/usr/bin/env bash
# kernel-manager.sh - Multikernel Instance Manager
# SUSPICIOUS Framework: Kernel Lifecycle Management
#
# Manages multikernel instances:
# - List all instances
# - Start/stop instances
# - Monitor instance status
# - Backup/restore configurations
# - View resource allocation
#
# Usage: ./kernel-manager.sh [command] [options]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

MULTIKERNEL_SYSFS="/sys/fs/multikernel"
CONFIG_DIR="/etc/multikernel"
BACKUP_DIR="/var/backup/multikernel"

cleanup_on_error() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo -e "\n${RED}${BOLD}[ERROR] Kernel manager failed with exit code ${exit_code}${NC}"
    fi
    exit ${exit_code}
}

trap cleanup_on_error EXIT

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
║         K E R N E L   M A N A G E R                                 ║
║                                                                      ║
║         Multikernel Instance Management                              ║
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

# Function to list all instances
list_instances() {
    show_header "Kernel Instances"
    
    if [ ! -d "${MULTIKERNEL_SYSFS}/instances" ]; then
        echo -e "${YELLOW}No instances directory found${NC}"
        echo -e "${YELLOW}Is multikernel enabled?${NC}"
        return 1
    fi
    
    local count=0
    
    echo -e "${BOLD}Instance          Status      CPUs        Memory      Role${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────────${NC}"
    
    for instance_dir in "${MULTIKERNEL_SYSFS}/instances"/*/; do
        if [ -d "${instance_dir}" ]; then
            local name=$(basename "${instance_dir}")
            local status="unknown"
            local cpus="N/A"
            local memory="N/A"
            local role="N/A"
            
            [ -f "${instance_dir}/status" ] && status=$(cat "${instance_dir}/status" 2>/dev/null || echo "unknown")
            [ -f "${instance_dir}/cpus" ] && cpus=$(cat "${instance_dir}/cpus" 2>/dev/null || echo "N/A")
            [ -f "${instance_dir}/memory" ] && memory=$(cat "${instance_dir}/memory" 2>/dev/null || echo "N/A")
            
            # Get role from kernel command line if running
            if [ "${status}" = "running" ]; then
                role="running"
            fi
            
            # Color status
            local status_color="${NC}"
            case "${status}" in
                running) status_color="${GREEN}" ;;
                stopped) status_color="${YELLOW}" ;;
                error) status_color="${RED}" ;;
            esac
            
            printf "%-18s ${status_color}%-12s${NC} %-12s %-12s %s\n" "${name}" "${status}" "${cpus}" "${memory}" "${role}"
            count=$((count + 1))
        fi
    done
    
    echo
    echo -e "${BOLD}Total instances: ${count}${NC}"
    echo
}

# Function to show instance details
show_instance() {
    local instance_name="$1"
    
    show_header "Instance Details: ${instance_name}"
    
    local instance_dir="${MULTIKERNEL_SYSFS}/instances/${instance_name}"
    
    if [ ! -d "${instance_dir}" ]; then
        echo -e "${RED}Instance not found: ${instance_name}${NC}"
        return 1
    fi
    
    echo -e "${BOLD}Status:${NC}"
    local status="unknown"
    [ -f "${instance_dir}/status" ] && status=$(cat "${instance_dir}/status" 2>/dev/null || echo "unknown")
    echo "  Status: ${status}"
    
    echo -e "\n${BOLD}Resource Allocation:${NC}"
    local cpus="N/A"
    local memory="N/A"
    [ -f "${instance_dir}/cpus" ] && cpus=$(cat "${instance_dir}/cpus" 2>/dev/null || echo "N/A")
    [ -f "${instance_dir}/memory" ] && memory=$(cat "${instance_dir}/memory" 2>/dev/null || echo "N/A")
    echo "  CPUs:   ${cpus}"
    echo "  Memory: ${memory}"
    
    echo -e "\n${BOLD}Configuration:${NC}"
    if [ -f "${instance_dir}/config" ]; then
        cat "${instance_dir}/config" 2>/dev/null | head -20
        echo "  ..."
    else
        echo "  No configuration found"
    fi
    
    echo
}

# Function to start an instance
start_instance() {
    local instance_name="$1"
    
    show_header "Starting Instance: ${instance_name}"
    
    local instance_dir="${MULTIKERNEL_SYSFS}/instances/${instance_name}"
    
    if [ ! -d "${instance_dir}" ]; then
        echo -e "${RED}Instance not found: ${instance_name}${NC}"
        return 1
    fi
    
    local status="unknown"
    [ -f "${instance_dir}/status" ] && status=$(cat "${instance_dir}/status" 2>/dev/null || echo "unknown")
    
    if [ "${status}" = "running" ]; then
        echo -e "${YELLOW}Instance already running${NC}"
        return 0
    fi
    
    echo -e "${BLUE}Starting ${instance_name}...${NC}"
    
    if echo "boot" > "${instance_dir}/control" 2>/dev/null; then
        echo -e "${GREEN}✓ Start command sent${NC}"
        
        # Wait for startup
        echo -n "  Waiting for startup"
        for i in {1..30}; do
            local new_status="unknown"
            [ -f "${instance_dir}/status" ] && new_status=$(cat "${instance_dir}/status" 2>/dev/null || echo "unknown")
            
            if [ "${new_status}" = "running" ]; then
                echo " OK"
                echo -e "${GREEN}✓ Instance started successfully${NC}"
                return 0
            fi
            echo -n "."
            sleep 1
        done
        echo " TIMEOUT"
        echo -e "${YELLOW}Warning: Startup timeout - check instance status${NC}"
    else
        echo -e "${RED}Failed to send start command${NC}"
        return 1
    fi
    
    echo
}

# Function to stop an instance
stop_instance() {
    local instance_name="$1"
    
    show_header "Stopping Instance: ${instance_name}"
    
    local instance_dir="${MULTIKERNEL_SYSFS}/instances/${instance_name}"
    
    if [ ! -d "${instance_dir}" ]; then
        echo -e "${RED}Instance not found: ${instance_name}${NC}"
        return 1
    fi
    
    local status="unknown"
    [ -f "${instance_dir}/status" ] && status=$(cat "${instance_dir}/status" 2>/dev/null || echo "unknown")
    
    if [ "${status}" != "running" ]; then
        echo -e "${YELLOW}Instance not running${NC}"
        return 0
    fi
    
    echo -e "${BLUE}Stopping ${instance_name}...${NC}"
    
    # Try graceful shutdown first
    if echo "shutdown" > "${instance_dir}/control" 2>/dev/null; then
        echo -e "${GREEN}✓ Shutdown command sent${NC}"
        
        # Wait for shutdown
        echo -n "  Waiting for shutdown"
        for i in {1..30}; do
            local new_status="unknown"
            [ -f "${instance_dir}/status" ] && new_status=$(cat "${instance_dir}/status" 2>/dev/null || echo "unknown")
            
            if [ "${new_status}" != "running" ]; then
                echo " OK"
                echo -e "${GREEN}✓ Instance stopped${NC}"
                return 0
            fi
            echo -n "."
            sleep 1
        done
        echo " TIMEOUT"
        
        # Force shutdown if graceful failed
        echo -e "${YELLOW}Attempting force shutdown...${NC}"
        if echo "force-shutdown" > "${instance_dir}/control" 2>/dev/null; then
            sleep 2
            echo -e "${GREEN}✓ Force shutdown completed${NC}"
        fi
    else
        echo -e "${RED}Failed to send stop command${NC}"
        return 1
    fi
    
    echo
}

# Function to backup configurations
backup_configs() {
    show_header "Backing Up Configurations"
    
    mkdir -p "${BACKUP_DIR}"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/configs_${timestamp}.tar.gz"
    
    echo -e "${BLUE}Creating backup: ${backup_file}${NC}"
    
    # Backup multikernel configs
    if [ -d "${CONFIG_DIR}" ]; then
        tar -czf "${backup_file}" -C "$(dirname "${CONFIG_DIR}")" "$(basename "${CONFIG_DIR}")" 2>/dev/null
        echo -e "${GREEN}✓ Backup created: ${backup_file}${NC}"
    else
        echo -e "${YELLOW}No configuration directory found${NC}"
    fi
    
    # Also backup instance configs
    if [ -d "${MULTIKERNEL_SYSFS}/instances" ]; then
        local instance_backup="${BACKUP_DIR}/instances_${timestamp}.tar.gz"
        
        # Create temp directory for instance configs
        local temp_dir=$(mktemp -d)
        for instance_dir in "${MULTIKERNEL_SYSFS}/instances"/*/; do
            if [ -d "${instance_dir}" ] && [ -f "${instance_dir}/config" ]; then
                local name=$(basename "${instance_dir}")
                mkdir -p "${temp_dir}/${name}"
                cp "${instance_dir}/config" "${temp_dir}/${name}/"
            fi
        done
        
        tar -czf "${instance_backup}" -C "${temp_dir}" . 2>/dev/null
        rm -rf "${temp_dir}"
        
        echo -e "${GREEN}✓ Instance configs backed up: ${instance_backup}${NC}"
    fi
    
    echo
    echo -e "${BOLD}Backup location: ${BACKUP_DIR}${NC}"
    echo -e "${BOLD}List backups: ls -la ${BACKUP_DIR}${NC}"
    echo
}

# Function to restore configurations
restore_configs() {
    local backup_file="$1"
    
    show_header "Restoring Configurations"
    
    if [ ! -f "${backup_file}" ]; then
        echo -e "${RED}Backup file not found: ${backup_file}${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Restoring from: ${backup_file}${NC}"
    
    # Restore multikernel configs
    tar -xzf "${backup_file}" -C "$(dirname "${CONFIG_DIR}")" 2>/dev/null
    
    echo -e "${GREEN}✓ Configurations restored${NC}"
    echo -e "${YELLOW}Note: You may need to reload multikernel for changes to take effect${NC}"
    echo
}

# Function to monitor instances
monitor_instances() {
    show_header "Monitoring Instances (Ctrl+C to stop)"
    
    echo -e "${BOLD}Refreshing every 2 seconds...${NC}\n"
    
    while true; do
        clear
        show_banner
        echo -e "${BOLD}$(date)${NC}\n"
        
        list_instances
        
        # Show resource usage
        echo -e "${BOLD}System Resources:${NC}"
        echo "  CPU:    $(nproc) cores"
        echo "  Memory: $(free -h | awk '/^Mem:/ {print $2}') total"
        echo "  Load:   $(uptime | awk -F'load average:' '{print $2}')"
        echo
        
        sleep 2
    done
}

# Function to display menu
show_menu() {
    echo -e "${BOLD}Kernel Manager Commands:${NC}"
    echo
    echo -e "  ${GREEN}list${NC}                    List all instances"
    echo -e "  ${GREEN}status <instance>${NC}       Show instance details"
    echo -e "  ${GREEN}start <instance>${NC}        Start an instance"
    echo -e "  ${GREEN}stop <instance>${NC}         Stop an instance"
    echo -e "  ${GREEN}monitor${NC}                 Monitor instances in real-time"
    echo -e "  ${GREEN}backup${NC}                  Backup configurations"
    echo -e "  ${GREEN}restore <file>${NC}          Restore configurations"
    echo -e "  ${GREEN}help${NC}                    Show this help"
    echo -e "  ${GREEN}quit${NC}                    Exit"
    echo
}

# Function to display usage
show_usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 [command] [options]"
    echo
    echo -e "${BOLD}Commands:${NC}"
    echo "  list                    List all instances"
    echo "  status <instance>       Show instance details"
    echo "  start <instance>        Start an instance"
    echo "  stop <instance>         Stop an instance"
    echo "  monitor                 Monitor instances in real-time"
    echo "  backup                  Backup configurations"
    echo "  restore <file>          Restore configurations"
    echo "  interactive             Start interactive mode"
    echo "  help                    Show this help"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0 list                 # List all instances"
    echo "  $0 start child0         # Start child0 instance"
    echo "  $0 stop child0          # Stop child0 instance"
    echo "  $0 monitor              # Real-time monitoring"
    echo "  $0 interactive          # Interactive mode"
    echo
}

# Interactive mode
interactive_mode() {
    show_banner
    echo -e "${GREEN}Entering interactive mode (type 'help' for commands)${NC}\n"
    
    while true; do
        echo -ne "${BOLD}kernel-manager>${NC} "
        read -r cmd args
        
        case "${cmd}" in
            list|ls)
                list_instances
                ;;
            status|st)
                if [ -n "${args}" ]; then
                    show_instance "${args}"
                else
                    echo -e "${RED}Usage: status <instance>${NC}"
                fi
                ;;
            start)
                if [ -n "${args}" ]; then
                    start_instance "${args}"
                else
                    echo -e "${RED}Usage: start <instance>${NC}"
                fi
                ;;
            stop)
                if [ -n "${args}" ]; then
                    stop_instance "${args}"
                else
                    echo -e "${RED}Usage: stop <instance>${NC}"
                fi
                ;;
            monitor|mon)
                monitor_instances
                ;;
            backup)
                backup_configs
                ;;
            restore)
                if [ -n "${args}" ]; then
                    restore_configs "${args}"
                else
                    echo -e "${RED}Usage: restore <backup-file>${NC}"
                fi
                ;;
            help|h|\?)
                show_menu
                ;;
            quit|exit|q)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            "")
                # Empty input, do nothing
                ;;
            *)
                echo -e "${RED}Unknown command: ${cmd}${NC}"
                echo -e "Type 'help' for available commands"
                ;;
        esac
    done
}

# Main execution
main() {
    local command="${1:-help}"
    shift || true
    
    case "${command}" in
        list|ls)
            show_banner
            list_instances
            ;;
        status|st)
            show_banner
            if [ $# -gt 0 ]; then
                show_instance "$1"
            else
                echo -e "${RED}Usage: $0 status <instance>${NC}"
                exit 1
            fi
            ;;
        start)
            show_banner
            if [ $# -gt 0 ]; then
                start_instance "$1"
            else
                echo -e "${RED}Usage: $0 start <instance>${NC}"
                exit 1
            fi
            ;;
        stop)
            show_banner
            if [ $# -gt 0 ]; then
                stop_instance "$1"
            else
                echo -e "${RED}Usage: $0 stop <instance>${NC}"
                exit 1
            fi
            ;;
        monitor|mon)
            monitor_instances
            ;;
        backup)
            show_banner
            backup_configs
            ;;
        restore)
            show_banner
            if [ $# -gt 0 ]; then
                restore_configs "$1"
            else
                echo -e "${RED}Usage: $0 restore <backup-file>${NC}"
                exit 1
            fi
            ;;
        interactive|i)
            interactive_mode
            ;;
        help|h)
            show_banner
            show_usage
            ;;
        *)
            show_banner
            echo -e "${RED}Unknown command: ${command}${NC}"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
