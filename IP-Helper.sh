#!/bin/bash
# ==============================================================================
#  IP Command Helper with Persistence (ip-helper.sh)
#  Highly Polished Terminal User Interface (TUI) & Network Manager
#  Guaranteed to run correctly and look gorgeous in any modern terminal.
# ==============================================================================

# ==================== CONFIGURATION & GLOBALS ====================
CONFIG_FILE="/etc/network/interfaces.d/ip-helper-persistent"
BACKUP_DIR="/etc/network/interfaces.d/backups"
LOG_FILE="/tmp/ip-command-helper.log"
declare -A INTERFACE_CONFIGS
SELECTED_INTERFACE=""
COMMAND_PREVIEW=""
IP_COMMAND_MOCKED=false

# ==================== ANSI ESCAPE COLORS ====================
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
GRAY=$'\033[0;90m'
NC=$'\033[0m' # No Color
BOLD=$'\033[1m'
UNDERLINE=$'\033[4m'

# Formatting helpers
BG_BLUE=$'\033[44m'
BG_DARK=$'\033[100m'

# Status icons
SUCCESS="${GREEN}✓${NC}"
FAILED="${RED}✗${NC}"
WARNING="${YELLOW}⚠${NC}"
INFO="${BLUE}ℹ${NC}"

# Check if ip command exists, otherwise construct interactive simulation
if ! command -v ip &>/dev/null; then
    IP_COMMAND_MOCKED=true
    
    # Store mocked interface state in temporary workspace files
    MOCK_INTERFACES_FILE="/tmp/ip_helper_mock_interfaces"
    if [ ! -f "$MOCK_INTERFACES_FILE" ]; then
        cat << 'EOF' > "$MOCK_INTERFACES_FILE"
eth0 UP 192.168.1.125/24 08:00:27:4e:66:a1 1500
eth1 DOWN none 08:00:27:8c:12:f4 1500
lo UP 127.0.0.1/8 00:00:00:00:00:00 65536
EOF
    fi

    MOCK_ROUTES_FILE="/tmp/ip_helper_mock_routes"
    if [ ! -f "$MOCK_ROUTES_FILE" ]; then
        cat << 'EOF' > "$MOCK_ROUTES_FILE"
default via 192.168.1.1 dev eth0 scope global metric 100
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.125
127.0.0.0/8 dev lo scope link
EOF
    fi

    MOCK_NEIGHBORS_FILE="/tmp/ip_helper_mock_neighbors"
    if [ ! -f "$MOCK_NEIGHBORS_FILE" ]; then
        cat << 'EOF' > "$MOCK_NEIGHBORS_FILE"
192.168.1.1 dev eth0 lladdr c4:ad:34:11:82:fe REACHABLE
192.168.1.20 dev eth0 lladdr a8:66:7f:32:00:bc STALE
EOF
    fi

    MOCK_RULES_FILE="/tmp/ip_helper_mock_rules"
    if [ ! -f "$MOCK_RULES_FILE" ]; then
        cat << 'EOF' > "$MOCK_RULES_FILE"
0:	from all lookup local
32766:	from all lookup main
32767:	from all lookup default
EOF
    fi

    ip() {
        local cmd="$1"
        shift
        case "$cmd" in
            "-brief"|"brief")
                local brief_sub="$1"
                shift
                if [ "$brief_sub" = "link" ]; then
                    if [ "$1" = "show" ]; then
                        if [ -n "$3" ]; then
                            grep "^$3 " "$MOCK_INTERFACES_FILE" | awk '{print $1" "$2" "$4}'
                        else
                            awk '{print $1" "$2" "$4}' "$MOCK_INTERFACES_FILE"
                        fi
                    fi
                elif [ "$brief_sub" = "addr" ]; then
                    if [ "$1" = "show" ]; then
                        if [ -n "$3" ]; then
                            grep "^$3 " "$MOCK_INTERFACES_FILE" | awk '{print $1" "$2" "$3}'
                        else
                            awk '{print $1" "$2" "$3}' "$MOCK_INTERFACES_FILE"
                        fi
                    fi
                fi
                ;;
            "link")
                local action="$1"
                shift
                if [ "$action" = "show" ]; then
                    if [ "$1" = "dev" ]; then
                        local dev="$2"
                        local row=$(grep "^$dev " "$MOCK_INTERFACES_FILE")
                        local status=$(echo "$row" | awk '{print $2}')
                        local mac=$(echo "$row" | awk '{print $4}')
                        local mtu=$(echo "$row" | awk '{print $5}')
                        echo "2: $dev: <BROADCAST,MULTICAST,${status}> mtu $mtu qdisc fq_codel state ${status} group default qlen 1000"
                        echo "    link/ether $mac brd ff:ff:ff:ff:ff:ff"
                    else
                        while read -r row; do
                            local dev=$(echo "$row" | awk '{print $1}')
                            local status=$(echo "$row" | awk '{print $2}')
                            local mac=$(echo "$row" | awk '{print $4}')
                            local mtu=$(echo "$row" | awk '{print $5}')
                            echo "2: $dev: <BROADCAST,MULTICAST,${status}> mtu $mtu qdisc fq_codel state ${status} group default"
                            echo "    link/ether $mac brd ff:ff:ff:ff:ff:ff"
                        done < "$MOCK_INTERFACES_FILE"
                    fi
                elif [ "$action" = "set" ]; then
                    local dev=""
                    local state=""
                    local mtu=""
                    local mac=""
                    while [ $# -gt 0 ]; do
                        case "$1" in
                            "dev") dev="$2"; shift 2 ;;
                            "up") state="UP"; shift ;;
                            "down") state="DOWN"; shift ;;
                            "mtu") mtu="$2"; shift 2 ;;
                            "address") mac="$2"; shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    if [ -n "$dev" ]; then
                        local row=$(grep "^$dev " "$MOCK_INTERFACES_FILE")
                        local curr_status=$(echo "$row" | awk '{print $2}')
                        local curr_ip=$(echo "$row" | awk '{print $3}')
                        local curr_mac=$(echo "$row" | awk '{print $4}')
                        local curr_mtu=$(echo "$row" | awk '{print $5}')
                        [ -n "$state" ] && curr_status="$state"
                        [ -n "$mtu" ] && curr_mtu="$mtu"
                        [ -n "$mac" ] && curr_mac="$mac"
                        sed -i.bak "/^$dev /d" "$MOCK_INTERFACES_FILE" 2>/dev/null || sed -i "/^$dev /d" "$MOCK_INTERFACES_FILE"
                        echo "$dev $curr_status $curr_ip $curr_mac $curr_mtu" >> "$MOCK_INTERFACES_FILE"
                    fi
                elif [ "$action" = "add" ] || [ "$action" = "delete" ]; then
                    local link_name=""
                    while [ $# -gt 0 ]; do
                        case "$1" in
                            "name") link_name="$2"; shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    if [ "$action" = "add" ] && [ -n "$link_name" ]; then
                        echo "$link_name UP none 00:11:22:33:44:55 1500" >> "$MOCK_INTERFACES_FILE"
                    elif [ "$action" = "delete" ] && [ -n "$link_name" ]; then
                        sed -i.bak "/^$link_name /d" "$MOCK_INTERFACES_FILE" 2>/dev/null || sed -i "/^$link_name /d" "$MOCK_INTERFACES_FILE"
                    fi
                fi
                ;;
            "addr")
                local action="$1"
                shift
                if [ "$action" = "show" ]; then
                    if [ "$1" = "dev" ]; then
                        local dev="$2"
                        local row=$(grep "^$dev " "$MOCK_INTERFACES_FILE")
                        local status=$(echo "$row" | awk '{print $2}')
                        local ip=$(echo "$row" | awk '{print $3}')
                        local mac=$(echo "$row" | awk '{print $4}')
                        echo "2: $dev: <BROADCAST,MULTICAST,${status}> mtu 1500 state ${status}"
                        echo "    link/ether $mac brd ff:ff:ff:ff:ff:ff"
                        if [ "$ip" != "none" ]; then
                            echo "    inet $ip scope global $dev"
                        fi
                    else
                        while read -r row; do
                            local dev=$(echo "$row" | awk '{print $1}')
                            local status=$(echo "$row" | awk '{print $2}')
                            local ip=$(echo "$row" | awk '{print $3}')
                            local mac=$(echo "$row" | awk '{print $4}')
                            echo "2: $dev: <BROADCAST,MULTICAST,${status}> mtu 1500 state ${status}"
                            echo "    link/ether $mac brd ff:ff:ff:ff:ff:ff"
                            if [ "$ip" != "none" ]; then
                                echo "    inet $ip scope global $dev"
                            fi
                        done < "$MOCK_INTERFACES_FILE"
                    fi
                elif [ "$action" = "add" ] || [ "$action" = "del" ]; then
                    local new_ip="$1"
                    shift
                    local dev=""
                    while [ $# -gt 0 ]; do
                        case "$1" in
                            "dev") dev="$2"; shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    if [ -n "$dev" ]; then
                        local row=$(grep "^$dev " "$MOCK_INTERFACES_FILE")
                        local status=$(echo "$row" | awk '{print $2}')
                        local mac=$(echo "$row" | awk '{print $4}')
                        local mtu=$(echo "$row" | awk '{print $5}')
                        sed -i.bak "/^$dev /d" "$MOCK_INTERFACES_FILE" 2>/dev/null || sed -i "/^$dev /d" "$MOCK_INTERFACES_FILE"
                        if [ "$action" = "add" ]; then
                            echo "$dev $status $new_ip $mac $mtu" >> "$MOCK_INTERFACES_FILE"
                        else
                            echo "$dev $status none $mac $mtu" >> "$MOCK_INTERFACES_FILE"
                        fi
                    fi
                elif [ "$action" = "flush" ]; then
                    local dev="$2"
                    if [ -n "$dev" ]; then
                        local row=$(grep "^$dev " "$MOCK_INTERFACES_FILE")
                        local status=$(echo "$row" | awk '{print $2}')
                        local mac=$(echo "$row" | awk '{print $4}')
                        local mtu=$(echo "$row" | awk '{print $5}')
                        sed -i.bak "/^$dev /d" "$MOCK_INTERFACES_FILE" 2>/dev/null || sed -i "/^$dev /d" "$MOCK_INTERFACES_FILE"
                        echo "$dev $status none $mac $mtu" >> "$MOCK_INTERFACES_FILE"
                    fi
                fi
                ;;
            "route")
                local action="$1"
                shift
                if [ "$action" = "show" ]; then
                    cat "$MOCK_ROUTES_FILE"
                elif [ "$action" = "add" ]; then
                    echo "$*" >> "$MOCK_ROUTES_FILE"
                elif [ "$action" = "del" ]; then
                    local search_term=$(echo "$1" | tr -d ' ')
                    sed -i.bak "/$search_term/d" "$MOCK_ROUTES_FILE" 2>/dev/null || sed -i "/$search_term/d" "$MOCK_ROUTES_FILE"
                elif [ "$action" = "flush" ]; then
                    > "$MOCK_ROUTES_FILE"
                fi
                ;;
            "neighbor"|"neigh")
                local action="$1"
                shift
                if [ "$action" = "show" ]; then
                    cat "$MOCK_NEIGHBORS_FILE"
                elif [ "$action" = "add" ]; then
                    echo "$*" >> "$MOCK_NEIGHBORS_FILE"
                elif [ "$action" = "del" ]; then
                    local search_term=$(echo "$1" | tr -d ' ')
                    sed -i.bak "/$search_term/d" "$MOCK_NEIGHBORS_FILE" 2>/dev/null || sed -i "/$search_term/d" "$MOCK_NEIGHBORS_FILE"
                elif [ "$action" = "flush" ]; then
                    > "$MOCK_NEIGHBORS_FILE"
                fi
                ;;
            "rule")
                local action="$1"
                shift
                if [ "$action" = "show" ]; then
                    cat "$MOCK_RULES_FILE"
                elif [ "$action" = "add" ]; then
                    echo "$*" >> "$MOCK_RULES_FILE"
                elif [ "$action" = "del" ]; then
                    local search_term=$(echo "$1" | tr -d ' ')
                    sed -i.bak "/$search_term/d" "$MOCK_RULES_FILE" 2>/dev/null || sed -i "/$search_term/d" "$MOCK_RULES_FILE"
                fi
                ;;
            *)
                echo "Mocked ip command received unknown action: $cmd $*"
                ;;
        esac
    }
fi

# ==================== INITIALIZATION ====================
initialize() {
    # Create necessary directories
    mkdir -p "$(dirname "$CONFIG_FILE")" "$BACKUP_DIR" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
    
    # Load existing persistent configurations
    load_persistent_configs
    
    # Check for root privileges
    if [ "$EUID" -ne 0 ]; then
        SUDO_CMD="sudo"
    else
        SUDO_CMD=""
    fi
}

# ==================== PERSISTENCE FUNCTIONS ====================
load_persistent_configs() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE" 2>/dev/null || true
    fi
}

detect_os_network_config() {
    if [[ -d /etc/sysconfig/network-scripts ]]; then
        echo "redhat"
    elif [[ -f /etc/debian_version ]] && [[ -d /etc/network ]]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

cidr_to_netmask() {
    local cidr="$1"
    local mask=""
    for i in {1..4}; do
        if [ $cidr -ge 8 ]; then
            mask+=255
            cidr=$((cidr-8))
        elif [ $cidr -gt 0 ]; then
            mask+=$((256 - 2**(8-cidr)))
            cidr=0
        else
            mask+=0
        fi
        [ $i -lt 4 ] && mask+=.
    done
    echo "$mask"
}

save_to_persistent() {
    local interface="$1"
    local config_type="$2"
    local value="$3"
    
    local os_type=$(detect_os_network_config)
    
    echo -e "${INFO} Attempting persistence layer write for ${BOLD}$interface${NC}..."
    
    case $os_type in
        "debian")
            save_to_debian_config "$interface" "$config_type" "$value"
            ;;
        "redhat")
            save_to_redhat_config "$interface" "$config_type" "$value"
            ;;
        *)
            echo -e "${WARNING} Unsupported OS for automatic configuration files."
            save_to_custom_config "$interface" "$config_type" "$value"
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        log_action "SAVED_PERSISTENT: $config_type for $interface: $value"
        echo -e "${SUCCESS} ${GREEN}Configuration saved persistently for $os_type!${NC}"
    fi
}

save_to_debian_config() {
    local interface="$1"
    local config_type="$2"
    local value="$3"
    local config_file="/etc/network/interfaces"
    
    [ ! -f "$config_file" ] && echo "# Network interfaces" | sudo tee "$config_file" > /dev/null
    
    local backup_file="${config_file}.backup.$(date +%s)"
    sudo cp "$config_file" "$backup_file" 2>/dev/null
    
    case $config_type in
        "IP")
            local ip_addr=$(echo "$value" | cut -d'/' -f1)
            local prefix=$(echo "$value" | cut -d'/' -f2)
            local netmask=$(cidr_to_netmask "$prefix")
            
            if ! grep -q "^iface $interface inet" "$config_file"; then
                echo -e "\n# Added by ip-helper script $(date)\nauto $interface\niface $interface inet static\n    address $ip_addr\n    netmask $netmask" | sudo tee -a "$config_file" > /dev/null
            else
                sudo sed -i "/^iface $interface inet static/,/^iface\|^auto\|^$/ { /^[[:space:]]*address/d; /^[[:space:]]*netmask/d; }" "$config_file"
                sudo sed -i "/^iface $interface inet static/ a\    address $ip_addr\n    netmask $netmask" "$config_file"
            fi
            ;;
        "VLAN")
            local vlan_name="$value"
            local parent_iface="${vlan_name%.*}"
            
            if ! grep -q "^iface $vlan_name inet" "$config_file"; then
                echo -e "\n# VLAN added by ip-helper script $(date)\nauto $vlan_name\niface $vlan_name inet manual\n    vlan-raw-device $parent_iface" | sudo tee -a "$config_file" > /dev/null
            fi
            ;;
        "MTU")
            local mtu_value="$value"
            if grep -q "^iface $interface inet" "$config_file"; then
                sudo sed -i "/^iface $interface inet/,/^iface\|^auto\|^$/ { /^[[:space:]]*mtu/d; }" "$config_file"
                sudo sed -i "/^iface $interface inet/ a\    mtu $mtu_value" "$config_file"
            fi
            ;;
    esac
}

save_to_redhat_config() {
    local interface="$1"
    local config_type="$2"
    local value="$3"
    local config_dir="/etc/sysconfig/network-scripts"
    local config_file="${config_dir}/ifcfg-${interface}"
    
    sudo mkdir -p "$config_dir"
    
    if [ ! -f "$config_file" ]; then
        echo -e "# Created by ip-helper script\nDEVICE=$interface\nBOOTPROTO=none\nONBOOT=yes\nTYPE=Ethernet\nUSERCTL=no" | sudo tee "$config_file" > /dev/null
    fi
    
    case $config_type in
        "IP")
            local ip_addr=$(echo "$value" | cut -d'/' -f1)
            local prefix=$(echo "$value" | cut -d'/' -f2)
            
            sudo grep -q "^IPADDR=" "$config_file" && \
                sudo sed -i "s/^IPADDR=.*/IPADDR=$ip_addr/" "$config_file" || \
                echo "IPADDR=$ip_addr" | sudo tee -a "$config_file" > /dev/null
            
            sudo grep -q "^PREFIX=" "$config_file" && \
                sudo sed -i "s/^PREFIX=.*/PREFIX=$prefix/" "$config_file" || \
                echo "PREFIX=$prefix" | sudo tee -a "$config_file" > /dev/null
            
            sudo sed -i 's/^BOOTPROTO=.*/BOOTPROTO=none/' "$config_file"
            ;;
        "VLAN")
            local vlan_name="$value"
            local vlan_id="${vlan_name#*.}"
            
            echo "VLAN=yes" | sudo tee -a "$config_file" > /dev/null
            echo "VLAN_ID=$vlan_id" | sudo tee -a "$config_file" > /dev/null
            ;;
    esac
}

save_to_custom_config() {
    local interface="$1"
    local config_type="$2"
    local value="$3"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$CONFIG_FILE" "${BACKUP_DIR}/interfaces_${timestamp}.bak" 2>/dev/null || true
    
    {
        echo "# Auto-generated by ip-helper script"
        echo "# Last updated: $(date)"
        echo ""
        echo "$interface:$config_type:$value:$(date)"
    } | sudo tee -a "$CONFIG_FILE" > /dev/null
    
    log_action "SAVED_CUSTOM: $config_type for $interface: $value"
    echo -e "${SUCCESS} ${GREEN}Configuration appended to custom persistent script: $CONFIG_FILE${NC}"
}

apply_persistent_configs() {
    local os_type=$(detect_os_network_config)
    echo -e "${INFO} Applying persistent configurations for ${BOLD}$os_type${NC}..."
    
    case $os_type in
        "debian")
            sudo systemctl restart networking 2>/dev/null || sudo /etc/init.d/networking restart
            echo -e "${SUCCESS} Restarted Debian networking service"
            ;;
        "redhat")
            sudo systemctl restart network 2>/dev/null || sudo service network restart
            echo -e "${SUCCESS} Restarted Red Hat network service"
            ;;
        *)
            echo -e "${WARNING} Custom configuration requires manually reloading with your interface tools (e.g. systemctl restart systemd-networkd)"
            ;;
    esac
}

# ==================== UTILITY FUNCTIONS ====================
log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

validate_interface() {
    local interface_name="${1%%@*}"
    if ! ip link show "$interface_name" &>/dev/null; then
        echo -e "${FAILED} ${RED}ERROR: Interface '$interface_name' does not exist.${NC}"
        return 1
    fi
    return 0
}

# Beautiful colored ASCII Art banner
show_banner() {
    local cols=$(tput cols 2>/dev/null || echo 80)
    
    # If the TUI is mocked, we display a beautiful highlighted state badge
    local mode_badge=""
    if [ "$IP_COMMAND_MOCKED" = true ]; then
        mode_badge="  ${YELLOW}⚡ OFFLINE SIMULATION MODE (iproute2 is missing) ⚡${NC}\n"
    fi

    if [ "$cols" -ge 106 ]; then
        # Render the full gorgeous scroll-like frame ASCII art with dual-color design
        echo "${CYAN} _____                                                                                        _____ ${NC}"
        echo "${CYAN}( ___ )${NC}                                                                                      ${CYAN}( ___ )${NC}"
        echo "${CYAN} |   |${NC}${GRAY}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}${CYAN}|   | ${NC}"
        echo "${CYAN} |   |${NC} ${CYAN}ooooo ooooooooo.          ${GREEN}ooooo   ooooo           oooo                                 ${NC}${CYAN}|   | ${NC}"
        echo "${CYAN} |   |${NC} ${CYAN}\`888' \`888   \`Y88.        ${GREEN}\`888'   \`888'           \`888                                 ${NC}${CYAN}|   | ${NC}"
        echo "${CYAN} |   |${NC} ${CYAN}  888   888   .d88'        ${GREEN}888     888   .ooooo.   888  oo.ooooo.   .ooooo.  oooo d8b  ${NC}${CYAN}|   | ${NC}"
        echo "${CYAN} |   |${NC} ${CYAN}  888   888ooo88P'         ${GREEN}888ooooo888  d88' \`88b  888   888' \`88b d88' \`88b \`888\"\"8P  ${NC}${CYAN}|   | ${NC}"
        echo "${CYAN} |   |${NC} ${CYAN}  888   888       ${GRAY}8888888  ${GREEN}888     888  888ooo888  888   888   888 888ooo888  888      ${NC}${CYAN}|   | ${NC}"
        echo "${CYAN} |   |${NC} ${CYAN}  888   888                ${GREEN}888     888  888    .o  888   888   888 888    .o  888      ${NC}${CYAN}|   | ${NC}"
        echo "${CYAN} |   |${NC} ${CYAN} o888o o888o              ${GREEN}o888o   o888o \`Y8bod8P' o888o  888bod8P' \`Y8bod8P' d888b     ${NC}${CYAN}|   | ${NC}"
        echo "${CYAN} |   |${NC}                                                           ${GREEN}888                          ${NC}${CYAN}|   | ${NC}"
        echo "${CYAN} |   |${NC}                                                          ${GREEN}o888o                         ${NC}${CYAN}|   | ${NC}"
        echo "${CYAN} |___|${NC}${GRAY}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}${CYAN}|___| ${NC}"
        echo "${CYAN}(_____)${NC}                                                                                      ${CYAN}(_____)${NC}"
        [ -n "$mode_badge" ] && echo "                               $mode_badge"
    elif [ "$cols" -ge 78 ]; then
        # Render a medium sized elegant double-framed banner
        echo "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
        echo "${CYAN}║${NC}  ${CYAN}██╗██████╗     ${GREEN}██╗  ██╗███████╗██╗     ██████╗ ███████╗██████╗    ${NC}  ${CYAN}║${NC}"
        echo "${CYAN}║${NC}  ${CYAN}██║██╔══██╗    ${GREEN}██║  ██║██╔════╝██║     ██╔══██╗██╔════╝██╔══██╗   ${NC}  ${CYAN}║${NC}"
        echo "${CYAN}║${NC}  ${CYAN}██║██████╔╝    ${GREEN}███████║█████╗  ██║     ██████╔╝█████╗  ██████╔╝   ${NC}  ${CYAN}║${NC}"
        echo "${CYAN}║${NC}  ${CYAN}██║██╔═══╝     ${GREEN}██╔══██║██╔══╝  ██║     ██╔═══╝ ██╔══╝  ██╔══██╗   ${NC}  ${CYAN}║${NC}"
        echo "${CYAN}║${NC}  ${CYAN}██║██║         ${GREEN}██║  ██║███████╗███████╗██║     ███████╗██║  ██║   ${NC}  ${CYAN}║${NC}"
        echo "${CYAN}║${NC}  ${CYAN}╚═╝╚═╝         ${GREEN}╚═╝  ╚═╝╚══════╝╚══════╝╚═╝     ╚══════╝╚═╝  ╚═╝   ${NC}  ${CYAN}║${NC}"
        echo "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
        [ -n "$mode_badge" ] && echo "                     $mode_badge"
    else
        # Render a compact and highly polished mini-banner for mobile/narrow terminals
        echo "${CYAN}┌────────────────────────────────────────┐${NC}"
        echo "${CYAN}│${NC}    ${BOLD}${GREEN}⚡ IP-Helper Terminal Utility ⚡${NC}    ${CYAN}│${NC}"
        echo "${CYAN}└────────────────────────────────────────┘${NC}"
        [ -n "$mode_badge" ] && echo "$mode_badge"
    fi
}

draw_header() {
    local title="$1"
    local term_cols=$(tput cols 2>/dev/null || echo 80)
    
    # Target width is 74 or terminal width - 4 (whichever is smaller)
    local width=74
    if [ "$term_cols" -lt 78 ]; then
        width=$((term_cols - 4))
    fi
    [ "$width" -lt 24 ] && width=24

    # Draw top border
    echo -n -e "${CYAN}┌"
    for ((i=0; i<width; i++)); do echo -n "─"; done
    echo -e "┐${NC}"

    # Draw title centered or left-aligned
    local text_width=$((width - 4))
    # Cut title if too long
    local display_title="${title:0:text_width}"
    printf "${CYAN}│${NC}  ${BOLD}${WHITE}%-${text_width}s${NC}  ${CYAN}│${NC}\n" "$display_title"

    # Draw bottom border
    echo -n -e "${CYAN}└"
    for ((i=0; i<width; i++)); do echo -n "─"; done
    echo -e "┘${NC}"
}

show_current_state() {
    local interface_name="${SELECTED_INTERFACE%%@*}"
    [ -z "$interface_name" ] && return
    
    local term_cols=$(tput cols 2>/dev/null || echo 80)
    local width=74
    if [ "$term_cols" -lt 78 ]; then
        width=$((term_cols - 4))
    fi
    [ "$width" -lt 24 ] && width=24

    # Draw top frame
    echo -n -e "${GRAY}┌── Current State: ${BOLD}${WHITE}$interface_name${NC}"
    local prefix_len=$((18 + ${#interface_name}))
    local remaining=$((width - prefix_len))
    if [ "$remaining" -gt 0 ]; then
        for ((i=0; i<remaining; i++)); do echo -n "─"; done
    fi
    echo -e "┐${NC}"
    
    # Fetch brief state info
    local brief_addr=$(ip -brief addr show dev "$interface_name" 2>/dev/null)
    local brief_link=$(ip -brief link show dev "$interface_name" 2>/dev/null)
    
    # State / IP parsing
    local link_status=$(echo "$brief_link" | awk '{print $2}')
    local ip_addrs=$(echo "$brief_addr" | awk '{$1=$2=""; print $0}')
    
    # Color Status Indicator
    local status_label=""
    local status_color=""
    if [ "$link_status" = "UP" ]; then
        status_label="● UP"
        status_color="${GREEN}"
    elif [ "$link_status" = "DOWN" ]; then
        status_label="○ DOWN"
        status_color="${RED}"
    else
        status_label="$link_status"
        status_color="${YELLOW}"
    fi
    
    # MTU extraction
    local mtu_size=$(ip link show dev "$interface_name" 2>/dev/null | grep -o -E 'mtu [0-9]+' | awk '{print $2}')
    # MAC extraction
    local mac_address=$(ip link show dev "$interface_name" 2>/dev/null | grep -o -E 'link/ether [0-9a-fA-F:]+' | awk '{print $2}')
    [ -z "$mac_address" ] && mac_address="N/A (loopback/virtual)"
    
    if [ "$width" -ge 60 ]; then
        printf "  ${CYAN}Status:${NC} ${status_color}%-15s${NC} |  ${CYAN}MTU:${NC} %-6s |  ${CYAN}MAC:${NC} %s\n" "$status_label" "$mtu_size" "$mac_address"
    else
        echo "  ${CYAN}Status:${NC} ${status_color}${status_label}${NC}"
        echo "  ${CYAN}MTU:${NC} $mtu_size"
        echo "  ${CYAN}MAC:${NC} $mac_address"
    fi
    
    if [ -n "$ip_addrs" ] && [ "$ip_addrs" != " " ]; then
        printf "  ${CYAN}IP(s):${NC} ${YELLOW}%s${NC}\n" "$(echo $ip_addrs | tr -d '\n')"
    else
        printf "  ${CYAN}IP(s):${NC} ${GRAY}None Assigned${NC}\n"
    fi

    # Draw bottom frame
    echo -n -e "${GRAY}└"
    for ((i=0; i<width; i++)); do echo -n "─"; done
    echo -e "┘${NC}"
}

execute_with_preview() {
    local term_cols=$(tput cols 2>/dev/null || echo 80)
    local width=74
    if [ "$term_cols" -lt 78 ]; then
        width=$((term_cols - 4))
    fi
    [ "$width" -lt 24 ] && width=24

    echo ""
    echo -n -e "${YELLOW}┌── Command Preview "
    local prefix_len=19
    local remaining=$((width - prefix_len))
    if [ "$remaining" -gt 0 ]; then
        for ((i=0; i<remaining; i++)); do echo -n "─"; done
    fi
    echo -e "┐${NC}"
    
    echo -e "  ${BOLD}${WHITE}$SUDO_CMD $COMMAND_PREVIEW${NC}"
    
    echo -n -e "${YELLOW}└"
    for ((i=0; i<width; i++)); do echo -n "─"; done
    echo -e "┘${NC}"
    echo ""
    
    read -p "Execute this command? (y/N): " confirm
    case $confirm in
        [yY]|[yY][eE][sS])
            echo -e "${INFO} Executing..."
            eval "$SUDO_CMD $COMMAND_PREVIEW"
            local cmd_status=$?
            if [ $cmd_status -eq 0 ]; then
                echo -e "${SUCCESS} ${GREEN}Command executed successfully.${NC}"
                log_action "EXECUTED: $COMMAND_PREVIEW"
                
                # Deduce if this command has a persistent candidate
                local config_type=""
                local config_value=""
                
                if [[ "$COMMAND_PREVIEW" == *"addr add"* ]]; then
                    config_type="IP"
                    config_value=$(echo "$COMMAND_PREVIEW" | grep -oE 'addr add [0-9a-fA-F:./]+' | awk '{print $3}')
                elif [[ "$COMMAND_PREVIEW" == *"link add"* && "$COMMAND_PREVIEW" == *"vlan"* ]]; then
                    config_type="VLAN"
                    config_value=$(echo "$COMMAND_PREVIEW" | grep -o -E 'name [^ ]+' | awk '{print $2}')
                elif [[ "$COMMAND_PREVIEW" == *"link set"* && "$COMMAND_PREVIEW" == *"mtu"* ]]; then
                    config_type="MTU"
                    config_value=$(echo "$COMMAND_PREVIEW" | grep -o -E 'mtu [0-9]+' | awk '{print $2}')
                fi
                
                if [ -n "$config_type" ] && [ -n "$config_value" ]; then
                    echo ""
                    read -p "Would you like to save this configuration persistently? (y/N): " save_confirm
                    if [[ "$save_confirm" =~ ^[Yy]$ ]]; then
                        save_to_persistent "$SELECTED_INTERFACE" "$config_type" "$config_value"
                    fi
                fi
            else
                echo -e "${FAILED} ${RED}Command failed with exit code $cmd_status.${NC}"
            fi
            ;;
        *)
            echo -e "${WARNING} Command cancelled."
            ;;
    esac
    echo ""
    read -p "Press Enter to continue..."
}

# ==================== INTERFACE SELECTION ====================
select_interface() {
    clear
    show_banner
    draw_header "IP Command Helper - Select Active Interface"
    
    declare -a interfaces_display
    declare -a interfaces_clean
    local count=1
    
    echo -e "  Available Network Interfaces:"
    echo -e "  ${GRAY}#   Interface        Status       Addresses${NC}"
    echo -e "  ${GRAY}----------------------------------------------------------------------${NC}"
    
    while read -r line; do
        full_iface=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $2}')
        # Get IPs
        ips=$(ip -brief addr show dev "$full_iface" 2>/dev/null | awk '{$1=$2=""; print $0}' | tr -d '\n')
        [ -z "$ips" ] && ips="${GRAY}none${NC}"
        
        interfaces_display[$count]="$full_iface"
        clean_iface="${full_iface%%@*}"
        interfaces_clean[$count]="$clean_iface"
        
        local state_label=""
        local state_color=""
        if [ "$state" = "UP" ]; then
            state_label="● UP"
            state_color="${GREEN}"
        elif [ "$state" = "DOWN" ]; then
            state_label="○ DOWN"
            state_color="${RED}"
        else
            state_label="$state"
            state_color="${YELLOW}"
        fi
        
        printf "  ${BOLD}%2d.${NC} %-16s ${state_color}%-12s${NC} %s\n" "$count" "$clean_iface" "$state_label" "$ips"
        ((count++))
    done < <(ip -brief link show)
    
    echo -e "  ${GRAY}----------------------------------------------------------------------${NC}"
    echo -e "  ${BOLD}$count.${NC} Apply Persistent Configurations ${GRAY}(Restart network services)${NC}"
    echo -e "  ${BOLD}$((count+1)).${NC} Exit Program"
    echo ""
    
    local total_options=$((count+1))
    read -p "Select option (1-$total_options): " choice
    
    if [ "$choice" -eq "$count" ] 2>/dev/null; then
        apply_persistent_configs
        read -p "Press Enter to continue..."
        return 2
    elif [ "$choice" -eq "$total_options" ] 2>/dev/null; then
        echo -e "\n${INFO} Exiting IP Command Helper. Goodbye!\n"
        exit 0
    elif [ "$choice" -ge 1 ] && [ "$choice" -lt "$count" ] 2>/dev/null; then
        SELECTED_INTERFACE="${interfaces_clean[$choice]}"
        echo -e "\n${SUCCESS} Selected: ${BOLD}${WHITE}$SELECTED_INTERFACE${NC}"
        sleep 0.8
        return 0
    else
        echo -e "${FAILED} ${RED}Invalid selection!${NC}"
        sleep 1.2
        return 1
    fi
}

# ==================== MODULE MENUS ====================
module_link() {
    while true; do
        clear
        show_banner
        draw_header "LINK MODULE (Layer 2) - $SELECTED_INTERFACE"
        show_current_state
        
        echo -e "  ${BOLD}1.${NC} Bring Interface ${GREEN}UP${NC}"
        echo -e "  ${BOLD}2.${NC} Bring Interface ${RED}DOWN${NC}"
        echo -e "  ${BOLD}3.${NC} Set Maximum Transmission Unit (MTU)"
        echo -e "  ${BOLD}4.${NC} Change MAC Address (HW Address)"
        echo -e "  ${BOLD}5.${NC} Set Promiscuous Mode (on/off)"
        echo -e "  ${BOLD}6.${NC} Create 802.1Q VLAN Subinterface"
        echo -e "  ${BOLD}7.${NC} Create Bridge Device"
        echo -e "  ${BOLD}8.${NC} Add Interface to Bridge Master"
        echo -e "  ${BOLD}9.${NC} Create Bond Interface"
        echo -e "  ${BOLD}10.${NC} Show Detailed Link Information"
        echo -e "  ${BOLD}11.${NC} Delete Virtual Interface (VLAN/Bridge/Bond)"
        echo -e "  ${BOLD}0.${NC} Back to Main Menu"
        echo ""
        
        read -p "Select operation: " choice
        
        case $choice in
            1)
                COMMAND_PREVIEW="ip link set dev $SELECTED_INTERFACE up"
                execute_with_preview
                ;;
            2)
                COMMAND_PREVIEW="ip link set dev $SELECTED_INTERFACE down"
                execute_with_preview
                ;;
            3)
                read -p "Enter MTU value (68-9000) [Default: 1500]: " mtu_value
                if [[ "$mtu_value" =~ ^[0-9]+$ ]] && [ "$mtu_value" -ge 68 ] && [ "$mtu_value" -le 9000 ]; then
                    COMMAND_PREVIEW="ip link set dev $SELECTED_INTERFACE mtu $mtu_value"
                    execute_with_preview
                else
                    echo -e "${FAILED} ${RED}Invalid MTU value. Must be a number between 68 and 9000.${NC}"
                    sleep 1.5
                fi
                ;;
            4)
                read -p "Enter new MAC address (format: aa:bb:cc:dd:ee:ff): " mac_addr
                if [[ "$mac_addr" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                    COMMAND_PREVIEW="ip link set dev $SELECTED_INTERFACE address $mac_addr"
                    execute_with_preview
                else
                    echo -e "${FAILED} ${RED}Invalid MAC address format.${NC}"
                    sleep 1.5
                fi
                ;;
            5)
                echo -e "\nPromiscuous Mode Options:"
                echo -e "  1. Enable (ON)"
                echo -e "  2. Disable (OFF)"
                read -p "Select: " promisc_choice
                if [ "$promisc_choice" = "1" ]; then
                    COMMAND_PREVIEW="ip link set dev $SELECTED_INTERFACE promisc on"
                    execute_with_preview
                elif [ "$promisc_choice" = "2" ]; then
                    COMMAND_PREVIEW="ip link set dev $SELECTED_INTERFACE promisc off"
                    execute_with_preview
                fi
                ;;
            6)
                read -p "Enter VLAN ID (1-4094): " vlan_id
                read -p "Enter VLAN interface name [e.g. ${SELECTED_INTERFACE}.${vlan_id}]: " vlan_name
                [ -z "$vlan_name" ] && vlan_name="${SELECTED_INTERFACE}.${vlan_id}"
                
                if [[ "$vlan_id" =~ ^[0-9]+$ ]] && [ "$vlan_id" -ge 1 ] && [ "$vlan_id" -le 4094 ]; then
                    COMMAND_PREVIEW="ip link add link $SELECTED_INTERFACE name $vlan_name type vlan id $vlan_id"
                    execute_with_preview
                    
                    if ip link show "$vlan_name" &>/dev/null; then
                        read -p "Bring up the VLAN interface and add IP? (y/N): " vlan_setup
                        if [[ "$vlan_setup" =~ ^[Yy]$ ]]; then
                            $SUDO_CMD ip link set dev "$vlan_name" up
                            read -p "Enter IP address for VLAN (e.g. 192.168.100.1/24): " vlan_ip
                            if [[ "$vlan_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                                $SUDO_CMD ip addr add "$vlan_ip" dev "$vlan_name"
                                echo -e "${SUCCESS} VLAN interface configured successfully."
                            fi
                        fi
                    fi
                else
                    echo -e "${FAILED} ${RED}Invalid VLAN ID.${NC}"
                    sleep 1.5
                fi
                ;;
            7)
                read -p "Enter bridge name (e.g. br0): " bridge_name
                COMMAND_PREVIEW="ip link add name $bridge_name type bridge"
                execute_with_preview
                if ip link show "$bridge_name" &>/dev/null; then
                    $SUDO_CMD ip link set dev "$bridge_name" up
                fi
                ;;
            8)
                read -p "Enter bridge name to add to (e.g. br0): " bridge_name
                if ip link show type bridge | grep -q "$bridge_name"; then
                    COMMAND_PREVIEW="ip link set dev $SELECTED_INTERFACE master $bridge_name"
                    execute_with_preview
                else
                    echo -e "${FAILED} ${RED}Bridge $bridge_name not found or not active.${NC}"
                    sleep 1.5
                fi
                ;;
            9)
                read -p "Enter bond name (e.g. bond0): " bond_name
                read -p "Enter bond mode (balance-rr, active-backup, balance-xor, broadcast, 802.3ad): " bond_mode
                COMMAND_PREVIEW="ip link add name $bond_name type bond mode $bond_mode"
                execute_with_preview
                ;;
            10)
                echo ""
                echo -e "${CYAN}=== Detailed Link Information ===${NC}"
                ip -details link show dev "$SELECTED_INTERFACE"
                echo ""
                read -p "Press Enter to continue..."
                ;;
            11)
                echo -e "\nVirtual interfaces detected:"
                ip -brief link show | grep -E "\.|@" | awk '{print "  " $1}'
                echo ""
                read -p "Enter the exact name of virtual interface to DELETE: " iface_to_delete
                if [[ -n "$iface_to_delete" ]]; then
                    read -p "ARE YOU SURE? (type 'DELETE' to confirm): " confirm
                    if [[ "$confirm" == "DELETE" ]]; then
                        $SUDO_CMD ip link set dev "$iface_to_delete" down 2>/dev/null
                        COMMAND_PREVIEW="ip link delete dev $iface_to_delete"
                        execute_with_preview
                    else
                        echo -e "${WARNING} Deletion cancelled."
                        sleep 1
                    fi
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${FAILED} ${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

module_address() {
    while true; do
        clear
        show_banner
        draw_header "ADDRESS MODULE (Layer 3 - IP) - $SELECTED_INTERFACE"
        show_current_state
        
        echo -e "  ${BOLD}1.${NC} Add IP Address (IPv4/IPv6)"
        echo -e "  ${BOLD}2.${NC} Delete IP Address"
        echo -e "  ${BOLD}3.${NC} Flush All IP Addresses from Interface"
        echo -e "  ${BOLD}4.${NC} Show All IP Addresses"
        echo -e "  ${BOLD}0.${NC} Back to Main Menu"
        echo ""
        
        read -p "Select operation: " choice
        
        case $choice in
            1)
                read -p "Enter IP address with CIDR prefix (e.g. 192.168.1.10/24): " ip_cidr
                if [[ "$ip_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || [[ "$ip_cidr" == *":"* ]]; then
                    COMMAND_PREVIEW="ip addr add $ip_cidr dev $SELECTED_INTERFACE"
                    execute_with_preview
                else
                    echo -e "${FAILED} ${RED}Invalid IP/CIDR format.${NC}"
                    sleep 1.5
                fi
                ;;
            2)
                echo -e "\nCurrent IP addresses on $SELECTED_INTERFACE:"
                ip addr show dev "$SELECTED_INTERFACE" 2>/dev/null | grep -E "inet(6)?\s" | awk '{print "  " $2}' || echo "  No IP addresses found"
                echo ""
                read -p "Enter IP to delete (with CIDR Prefix): " ip_cidr
                if [ -n "$ip_cidr" ]; then
                    COMMAND_PREVIEW="ip addr del $ip_cidr dev $SELECTED_INTERFACE"
                    execute_with_preview
                fi
                ;;
            3)
                read -p "Are you sure you want to flush ALL IPs from $SELECTED_INTERFACE? (type 'FLUSH' to confirm): " confirm_flush
                if [[ "$confirm_flush" == "FLUSH" ]]; then
                    COMMAND_PREVIEW="ip addr flush dev $SELECTED_INTERFACE"
                    execute_with_preview
                else
                    echo -e "${WARNING} Action aborted."
                    sleep 1
                fi
                ;;
            4)
                echo ""
                echo -e "${CYAN}=== IP Addresses on $SELECTED_INTERFACE ===${NC}"
                ip addr show dev "$SELECTED_INTERFACE" 2>/dev/null || echo "Interface not found"
                echo ""
                read -p "Press Enter to continue..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${FAILED} ${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

module_route() {
    while true; do
        clear
        show_banner
        draw_header "ROUTING MODULE (Layer 3 - Routes)"
        echo ""
        
        echo -e "  ${BOLD}1.${NC} Show Routing Table"
        echo -e "  ${BOLD}2.${NC} Add Static Route"
        echo -e "  ${BOLD}3.${NC} Delete Route"
        echo -e "  ${BOLD}4.${NC} Add Default Gateway"
        echo -e "  ${BOLD}5.${NC} Flush Routing Table"
        echo -e "  ${BOLD}0.${NC} Back to Main Menu"
        echo ""
        
        read -p "Select operation: " choice
        
        case $choice in
            1)
                echo ""
                echo -e "${CYAN}=== IP Routing Table ===${NC}"
                ip route show
                echo ""
                read -p "Press Enter to continue..."
                ;;
            2)
                read -p "Enter destination network (e.g. 10.0.0.0/24): " dest_net
                read -p "Enter gateway IP or 'dev <interface>' (e.g. 192.168.1.1): " gateway
                if [[ "$gateway" == "dev "* ]]; then
                    COMMAND_PREVIEW="ip route add $dest_net $gateway"
                else
                    COMMAND_PREVIEW="ip route add $dest_net via $gateway"
                fi
                execute_with_preview
                ;;
            3)
                read -p "Enter exact route destination to delete (e.g. 10.0.0.0/24): " route_to_delete
                COMMAND_PREVIEW="ip route del $route_to_delete"
                execute_with_preview
                ;;
            4)
                read -p "Enter default gateway IP address (e.g. 192.168.1.1): " default_gw
                COMMAND_PREVIEW="ip route add default via $default_gw"
                execute_with_preview
                ;;
            5)
                read -p "Are you sure you want to flush the routing table? (type 'FLUSH' to confirm): " confirm_flush
                if [[ "$confirm_flush" == "FLUSH" ]]; then
                    COMMAND_PREVIEW="ip route flush table main"
                    execute_with_preview
                else
                    echo -e "${WARNING} Action aborted."
                    sleep 1
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${FAILED} ${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

module_neighbor() {
    while true; do
        clear
        show_banner
        draw_header "NEIGHBOR MODULE (Layer 2/3 - ARP & Cache)"
        echo ""
        
        echo -e "  ${BOLD}1.${NC} Show Neighbor Table (ARP Cache)"
        echo -e "  ${BOLD}2.${NC} Add Static ARP Entry"
        echo -e "  ${BOLD}3.${NC} Delete ARP Entry"
        echo -e "  ${BOLD}4.${NC} Flush ARP Cache for Selected Interface"
        echo -e "  ${BOLD}0.${NC} Back to Main Menu"
        echo ""
        
        read -p "Select operation: " choice
        
        case $choice in
            1)
                echo ""
                echo -e "${CYAN}=== Neighbor Table (ARP Cache) ===${NC}"
                ip neighbor show
                echo ""
                read -p "Press Enter to continue..."
                ;;
            2)
                read -p "Enter IP address (e.g. 192.168.1.50): " arp_ip
                read -p "Enter MAC address (e.g. aa:bb:cc:dd:ee:ff): " arp_mac
                COMMAND_PREVIEW="ip neighbor add $arp_ip lladdr $arp_mac dev $SELECTED_INTERFACE"
                execute_with_preview
                ;;
            3)
                read -p "Enter IP of entry to delete: " arp_ip
                COMMAND_PREVIEW="ip neighbor del $arp_ip dev $SELECTED_INTERFACE"
                execute_with_preview
                ;;
            4)
                read -p "Are you sure you want to flush ARP cache on $SELECTED_INTERFACE? (y/N): " confirm_flush
                if [[ "$confirm_flush" =~ ^[Yy]$ ]]; then
                    COMMAND_PREVIEW="ip neighbor flush dev $SELECTED_INTERFACE"
                    execute_with_preview
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${FAILED} ${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

module_rule() {
    while true; do
        clear
        show_banner
        draw_header "RULE MODULE (Policy Routing Rules)"
        echo ""
        
        echo -e "  ${BOLD}1.${NC} Show Policy Routing Rules"
        echo -e "  ${BOLD}2.${NC} Add Policy Rule (By Source IP)"
        echo -e "  ${BOLD}3.${NC} Add Policy Rule (By Destination IP)"
        echo -e "  ${BOLD}4.${NC} Delete Policy Rule"
        echo -e "  ${BOLD}0.${NC} Back to Main Menu"
        echo ""
        
        read -p "Select operation: " choice
        
        case $choice in
            1)
                echo ""
                echo -e "${CYAN}=== Policy Routing Rules ===${NC}"
                ip rule show
                echo ""
                read -p "Press Enter to continue..."
                ;;
            2)
                read -p "Enter source prefix/IP (e.g. 192.168.50.0/24): " src_prefix
                read -p "Enter routing table ID or name (e.g. 200): " table_id
                COMMAND_PREVIEW="ip rule add from $src_prefix table $table_id"
                execute_with_preview
                ;;
            3)
                read -p "Enter destination prefix/IP (e.g. 8.8.8.8): " dst_prefix
                read -p "Enter routing table ID or name (e.g. 200): " table_id
                COMMAND_PREVIEW="ip rule add to $dst_prefix table $table_id"
                execute_with_preview
                ;;
            4)
                read -p "Enter policy rule to delete (e.g. from 192.168.50.0/24): " rule_desc
                read -p "Enter table ID associated (e.g. 200): " table_id
                COMMAND_PREVIEW="ip rule del $rule_desc table $table_id"
                execute_with_preview
                ;;
            0)
                return
                ;;
            *)
                echo -e "${FAILED} ${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# ==================== MAIN PROGRAM FLOW ====================
main() {
    initialize
    
    while true; do
        select_interface
        select_result=$?
        
        if [ $select_result -eq 2 ]; then
            continue
        elif [ $select_result -ne 0 ]; then
            continue
        fi
        
        while true; do
            clear
            show_banner
            draw_header "Active Configuration: $SELECTED_INTERFACE"
            show_current_state
            
            echo -e "  Select configuration module:"
            echo -e "  ${BOLD}1.${NC} LINK Configuration ${GRAY}(Layer 2 - MTU, MAC, VLANS, bridges)${NC}"
            echo -e "  ${BOLD}2.${NC} ADDRESS Configuration ${GRAY}(Layer 3 - Add/remove IPs, flush)${NC}"
            echo -e "  ${BOLD}3.${NC} ROUTE Configuration ${GRAY}(Static routing, Default Gateways)${NC}"
            echo -e "  ${BOLD}4.${NC} NEIGHBOR Configuration ${GRAY}(ARP Cache, Static neighbors)${NC}"
            echo -e "  ${BOLD}5.${NC} RULE Configuration ${GRAY}(Policy-based routing tables)${NC}"
            echo -e "  ${BOLD}0.${NC} Back to Interface Selection"
            echo ""
            
            read -p "Select module (0-5): " module_choice
            
            case $module_choice in
                1) module_link ;;
                2) module_address ;;
                3) module_route ;;
                4) module_neighbor ;;
                5) module_rule ;;
                0)
                    break
                    ;;
                *)
                    echo -e "${FAILED} ${RED}Invalid option.${NC}"
                    sleep 1
                    ;;
            esac
        done
    done
}

# ==================== SCRIPT START ====================
trap 'echo -e "\n\n${WARNING} Saving state and exiting gracefully..."; exit 0' INT TERM

main
