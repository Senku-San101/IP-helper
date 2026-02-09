#!/bin/bash
# IP Command Helper with Persistence
# Save as: ip-helper.sh

# ==================== CONFIGURATION & GLOBALS ====================
CONFIG_FILE="/etc/network/interfaces.d/ip-helper-persistent"
BACKUP_DIR="/etc/network/interfaces.d/backups"
LOG_FILE="/tmp/ip-command-helper.log"
declare -A INTERFACE_CONFIGS
SELECTED_INTERFACE=""
COMMAND_PREVIEW=""

# ==================== INITIALIZATION ====================
initialize() {
    # Create necessary directories
    mkdir -p "$(dirname "$CONFIG_FILE")" "$BACKUP_DIR" 2>/dev/null || true
    touch "$LOG_FILE"
    
    # Load existing persistent configurations
    load_persistent_configs
    
    # Check for root privileges
    if [ "$EUID" -ne 0 ]; then
        echo "Warning: Some commands require sudo. Using 'sudo' where needed."
        SUDO_CMD="sudo"
    else
        SUDO_CMD=""
    fi
}

# ==================== PERSISTENCE FUNCTIONS ====================
load_persistent_configs() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "Loading persistent configurations from $CONFIG_FILE"
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
    
    case $os_type in
        "debian")
            save_to_debian_config "$interface" "$config_type" "$value"
            ;;
        "redhat")
            save_to_redhat_config "$interface" "$config_type" "$value"
            ;;
        *)
            echo "✗ Unsupported OS for automatic persistence."
            save_to_custom_config "$interface" "$config_type" "$value"
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        log_action "SAVED_PERSISTENT: $config_type for $interface: $value"
        echo "✓ Configuration saved persistently for $os_type"
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
        echo "# $interface:$config_type:$value:$(date)"
    } | sudo tee -a "$CONFIG_FILE" > /dev/null
    
    log_action "SAVED_CUSTOM: $config_type for $interface: $value"
    echo "✓ Configuration saved to custom file"
}

apply_persistent_configs() {
    local os_type=$(detect_os_network_config)
    echo "Applying persistent configurations for $os_type..."
    
    case $os_type in
        "debian")
            sudo systemctl restart networking 2>/dev/null || sudo /etc/init.d/networking restart
            echo "✓ Restarted Debian networking service"
            ;;
        "redhat")
            sudo systemctl restart network 2>/dev/null || sudo service network restart
            echo "✓ Restarted Red Hat network service"
            ;;
        *)
            echo "! Could not apply configs: Unknown OS"
            ;;
    esac
}

# ==================== UTILITY FUNCTIONS ====================
log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

validate_interface() {
    local interface_name="${1%%@*}"
    
    if ! ip link show "$interface_name" &>/dev/null; then
        echo "ERROR: Interface '$interface_name' does not exist."
        return 1
    fi
    return 0
}

show_current_state() {
    local interface_name="${SELECTED_INTERFACE%%@*}"
    
    echo ""
    echo "========================================="
    echo "CURRENT STATE for $interface_name"
    echo "========================================="
    ip -brief addr show dev "$interface_name" 2>/dev/null || echo "Interface not found"
    ip -brief link show dev "$interface_name" 2>/dev/null || echo "Interface not found"
    echo "========================================="
    echo ""
}

execute_with_preview() {
    echo ""
    echo "Command to execute:"
    echo "  $COMMAND_PREVIEW"
    echo ""
    
    read -p "Execute this command? (y/N): " confirm
    case $confirm in
        [yY]|[yY][eE][sS])
            echo "Executing: $COMMAND_PREVIEW"
            eval "$SUDO_CMD $COMMAND_PREVIEW"
            if [ $? -eq 0 ]; then
                echo "✓ Command executed successfully."
                log_action "EXECUTED: $COMMAND_PREVIEW"
                
                read -p "Save this change persistently? (y/N): " save_confirm
                if [[ "$save_confirm" =~ ^[Yy]$ ]]; then
                    local config_type=""
                    local config_value=""
                    
                    if [[ "$COMMAND_PREVIEW" == *"addr add"* ]]; then
                        config_type="IP"
                        config_value=$(echo "$COMMAND_PREVIEW" | grep -o 'addr add [^ ]*' | cut -d' ' -f3)
                    elif [[ "$COMMAND_PREVIEW" == *"link add"* && "$COMMAND_PREVIEW" == *"vlan"* ]]; then
                        config_type="VLAN"
                        config_value=$(echo "$COMMAND_PREVIEW" | grep -o 'name [^ ]*' | cut -d' ' -f2)
                    elif [[ "$COMMAND_PREVIEW" == *"link set"* && "$COMMAND_PREVIEW" == *"mtu"* ]]; then
                        config_type="MTU"
                        config_value=$(echo "$COMMAND_PREVIEW" | grep -o 'mtu [^ ]*' | cut -d' ' -f2)
                    fi
                    
                    if [ -n "$config_type" ] && [ -n "$config_value" ]; then
                        save_to_persistent "$SELECTED_INTERFACE" "$config_type" "$config_value"
                    fi
                fi
            else
                echo "✗ Command failed with error."
            fi
            ;;
        *)
            echo "Command cancelled."
            ;;
    esac
    read -p "Press Enter to continue..."
}

# ==================== INTERFACE SELECTION ====================
select_interface() {
    clear
    echo "========================================"
    echo "    IP COMMAND HELPER - Select Interface"
    echo "========================================"
    echo ""
    
    declare -a interfaces_display
    declare -a interfaces_clean
    local count=1
    
    echo "Available network interfaces:"
    while read -r line; do
        full_iface=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $3}')
        
        interfaces_display[$count]="$full_iface"
        clean_iface="${full_iface%%@*}"
        interfaces_clean[$count]="$clean_iface"
        
        echo "  $count. $clean_iface ($state)"
        ((count++))
    done < <(ip -brief link show)
    
    echo ""
    echo "  $count. Apply persistent configurations"
    echo "  $((count+1)). Exit program"
    echo ""
    
    local total_options=$((count+1))
    read -p "Select option (1-$total_options): " choice
    
    if [ "$choice" -eq "$count" ]; then
        apply_persistent_configs
        read -p "Press Enter to continue..."
        return 2
    elif [ "$choice" -eq "$total_options" ]; then
        echo "Exiting. Goodbye!"
        exit 0
    elif [ "$choice" -ge 1 ] && [ "$choice" -lt "$count" ]; then
        SELECTED_INTERFACE="${interfaces_clean[$choice]}"
        echo "Selected interface: ${interfaces_display[$choice]}"
        return 0
    else
        echo "Invalid selection!"
        read -p "Press Enter to continue..."
        return 1
    fi
}

# ==================== MODULE MENUS ====================
module_link() {
    while true; do
        clear
        echo "=== LINK MODULE (Layer 2) ==="
        echo "Interface: $SELECTED_INTERFACE"
        show_current_state
        echo ""
        echo "1. Bring interface UP"
        echo "2. Bring interface DOWN"
        echo "3. Set MTU"
        echo "4. Change MAC address"
        echo "5. Set promiscuous mode"
        echo "6. Create VLAN subinterface"
        echo "7. Create bridge"
        echo "8. Add interface to bridge"
        echo "9. Create bond interface"
        echo "10. Show detailed link info"
        echo "11. Delete virtual interface"
        echo "0. Back to interface selection"
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
                read -p "Enter MTU value (68-9000): " mtu_value
                if [[ "$mtu_value" =~ ^[0-9]+$ ]] && [ "$mtu_value" -ge 68 ] && [ "$mtu_value" -le 9000 ]; then
                    COMMAND_PREVIEW="ip link set dev $SELECTED_INTERFACE mtu $mtu_value"
                    execute_with_preview
                else
                    echo "Invalid MTU value."
                    read -p "Press Enter to continue..."
                fi
                ;;
            4)
                read -p "Enter new MAC address (format: aa:bb:cc:dd:ee:ff): " mac_addr
                if [[ "$mac_addr" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                    COMMAND_PREVIEW="ip link set dev $SELECTED_INTERFACE address $mac_addr"
                    execute_with_preview
                else
                    echo "Invalid MAC address format."
                    read -p "Press Enter to continue..."
                fi
                ;;
            5)
                echo "1. Enable promiscuous mode"
                echo "2. Disable promiscuous mode"
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
                read -p "Enter VLAN interface name (e.g., ${SELECTED_INTERFACE}.100): " vlan_name
                if [[ "$vlan_id" =~ ^[0-9]+$ ]] && [ "$vlan_id" -ge 1 ] && [ "$vlan_id" -le 4094 ]; then
                    COMMAND_PREVIEW="ip link add link $SELECTED_INTERFACE name $vlan_name type vlan id $vlan_id"
                    execute_with_preview
                    
                    if [ $? -eq 0 ]; then
                        read -p "Bring up the VLAN interface and add IP? (y/N): " vlan_setup
                        if [[ "$vlan_setup" =~ ^[Yy]$ ]]; then
                            $SUDO_CMD ip link set dev "$vlan_name" up
                            read -p "Enter IP address for VLAN (e.g., 192.168.100.1/24): " vlan_ip
                            if [[ "$vlan_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                                $SUDO_CMD ip addr add "$vlan_ip" dev "$vlan_name"
                                echo "VLAN interface configured."
                            fi
                        fi
                    fi
                else
                    echo "Invalid VLAN ID."
                    read -p "Press Enter to continue..."
                fi
                ;;
            7)
                read -p "Enter bridge name (e.g., br0): " bridge_name
                COMMAND_PREVIEW="ip link add name $bridge_name type bridge"
                execute_with_preview
                if [ $? -eq 0 ]; then
                    $SUDO_CMD ip link set dev "$bridge_name" up
                fi
                ;;
            8)
                read -p "Enter bridge name to add to: " bridge_name
                if ip link show type bridge | grep -q "$bridge_name"; then
                    COMMAND_PREVIEW="ip link set dev $SELECTED_INTERFACE master $bridge_name"
                    execute_with_preview
                else
                    echo "Bridge $bridge_name not found."
                    read -p "Press Enter to continue..."
                fi
                ;;
            9)
                read -p "Enter bond name (e.g., bond0): " bond_name
                read -p "Enter bond mode (balance-rr, active-backup, etc.): " bond_mode
                COMMAND_PREVIEW="ip link add name $bond_name type bond mode $bond_mode"
                execute_with_preview
                ;;
            10)
                echo ""
                ip -details link show dev "$SELECTED_INTERFACE"
                read -p "Press Enter to continue..."
                ;;
            11)
                echo "Virtual interfaces detected:"
                ip -brief link show | grep -E "\.|@" | awk '{print $1}' | while read iface; do
                    clean_iface="${iface%%@*}"
                    state=$(ip -brief link show dev "$clean_iface" 2>/dev/null | awk '{print $3}')
                    echo "  $clean_iface ($state)"
                done
                read -p "Enter the exact name of the interface to DELETE: " iface_to_delete
                if [[ -n "$iface_to_delete" ]]; then
                    read -p "ARE YOU SURE? (type 'DELETE' to confirm): " confirm
                    if [[ "$confirm" == "DELETE" ]]; then
                        $SUDO_CMD ip link set dev "$iface_to_delete" down 2>/dev/null
                        COMMAND_PREVIEW="ip link delete dev $iface_to_delete"
                        execute_with_preview
                        local os_type=$(detect_os_network_config)
                        if [[ "$os_type" == "redhat" ]]; then
                            sudo rm -f "/etc/sysconfig/network-scripts/ifcfg-${iface_to_delete}" 2>/dev/null
                            echo "Removed Red Hat config file."
                        fi
                    else
                        echo "Deletion cancelled."
                    fi
                fi
                ;;
            0)
                return
                ;;
            *)
                echo "Invalid option."
                sleep 1
                ;;
        esac
    done
}

module_address() {
    while true; do
        clear
        echo "=== ADDRESS MODULE (Layer 3 - IP) ==="
        echo "Interface: $SELECTED_INTERFACE"
        show_current_state
        echo "1. Add IP address"
        echo "2. Delete IP address"
        echo "3. Flush all IP addresses"
        echo "4. Show all IP addresses"
        echo "0. Back to interface selection"
        echo ""
        
        read -p "Select operation: " choice
        
        case $choice in
            1)
                read -p "Enter IP address with CIDR (e.g., 192.168.1.10/24): " ip_cidr
                if [[ "$ip_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                    COMMAND_PREVIEW="ip addr add $ip_cidr dev $SELECTED_INTERFACE"
                    execute_with_preview
                else
                    echo "Invalid IP/CIDR format."
                    read -p "Press Enter to continue..."
                fi
                ;;
            2)
                echo "Current IP addresses on $SELECTED_INTERFACE:"
                ip addr show dev "$SELECTED_INTERFACE" 2>/dev/null | grep -E "inet\s" | awk '{print "  "$2}' || echo "  No IP addresses found"
                echo ""
                read -p "Enter IP to delete (with CIDR): " ip_cidr
                if [ -n "$ip_cidr" ]; then
                    COMMAND_PREVIEW="ip addr del $ip_cidr dev $SELECTED_INTERFACE"
                    execute_with_preview
                fi
                ;;
            3)
                read -p "Are you sure you want to flush ALL IPs from $SELECTED_INTERFACE? (yes/no): " confirm_flush
                if [[ "$confirm_flush" == "yes" ]]; then
                    COMMAND_PREVIEW="ip addr flush dev $SELECTED_INTERFACE"
                    execute_with_preview
                fi
                ;;
            4)
                echo ""
                ip addr show dev "$SELECTED_INTERFACE" 2>/dev/null || echo "Interface not found"
                read -p "Press Enter to continue..."
                ;;
            0)
                return
                ;;
            *)
                echo "Invalid option."
                sleep 1
                ;;
        esac
    done
}

module_route() {
    while true; do
        clear
        echo "=== ROUTING MODULE ==="
        echo "1. Show routing table"
        echo "2. Add route"
        echo "3. Delete route"
        echo "4. Add default gateway"
        echo "5. Flush routing table"
        echo "0. Back to interface selection"
        echo ""
        
        read -p "Select operation: " choice
        
        case $choice in
            1)
                echo ""
                ip route show
                read -p "Press Enter to continue..."
                ;;
            2)
                read -p "Enter destination network (e.g., 10.0.0.0/24): " dest_net
                read -p "Enter gateway (or 'dev <interface>' for direct): " gateway
                COMMAND_PREVIEW="ip route add $dest_net via $gateway"
                execute_with_preview
                ;;
            3)
                read -p "Enter route to delete (e.g., 10.0.0.0/24): " route_to_delete
                COMMAND_PREVIEW="ip route del $route_to_delete"
                execute_with_preview
                ;;
            4)
                read -p "Enter default gateway IP: " default_gw
                COMMAND_PREVIEW="ip route add default via $default_gw"
                execute_with_preview
                ;;
            5)
                read -p "Are you sure you want to flush the routing table? (yes/no): " confirm_flush
                if [[ "$confirm_flush" == "yes" ]]; then
                    COMMAND_PREVIEW="ip route flush table main"
                    execute_with_preview
                fi
                ;;
            0)
                return
                ;;
            *)
                echo "Invalid option."
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
            echo "========================================"
            echo "    Configuration for: $SELECTED_INTERFACE"
            echo "========================================"
            show_current_state
            echo "Select module to configure:"
            echo "1. LINK Configuration (Layer 2)"
            echo "2. ADDRESS Configuration (IP Addresses)"
            echo "3. ROUTE Configuration"
            echo "4. NEIGHBOR Configuration (ARP)"
            echo "5. RULE Configuration (Policy Routing)"
            echo "0. Back to interface selection"
            echo ""
            
            read -p "Select module: " module_choice
            
            case $module_choice in
                1) module_link ;;
                2) module_address ;;
                3) module_route ;;
                4) 
                    echo "Neighbor module not yet implemented"
                    read -p "Press Enter to continue..."
                    ;;
                5) 
                    echo "Rule module not yet implemented"
                    read -p "Press Enter to continue..."
                    ;;
                0)
                    break
                    ;;
                *)
                    echo "Invalid option."
                    sleep 1
                    ;;
            esac
        done
    done
}

# ==================== SCRIPT START ====================
trap 'echo -e "\nSaving configurations before exit..."; save_to_persistent "SYSTEM" "EXIT" "User interrupted"; exit 0' INT TERM

main
