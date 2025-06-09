#!/bin/bash

# Pi-hole Statistics Script
# Returns: STATUS,QUERIES_TODAY,QUERIES_BLOCKED,PERCENT_BLOCKED
# Example: Active,1234,567,45.9

set -e

# Default output for errors
DEFAULT_OUTPUT="Inactive,0,0,0.0"

# Function to log debug info
debug_log() {
    echo "[DEBUG] $1" >&2
}

# Function to validate and clean numeric values
clean_number() {
    local value="$1"
    # Remove any non-numeric characters except decimal point
    cleaned=$(echo "$value" | sed 's/[^0-9.]//g')
    # If empty after cleaning, return 0
    echo "${cleaned:-0}"
}

# Method 1: Try Pi-hole API via HTTP
get_stats_via_api() {
    debug_log "Trying Pi-hole API method..."
    
    local wsl_ip=$(hostname -I | awk '{print $1}')
    if [[ -z "$wsl_ip" ]]; then
        debug_log "Could not determine WSL IP"
        return 1
    fi
    
    # Try to get stats from Pi-hole API
    local api_response
    if api_response=$(curl -s --connect-timeout 3 "http://${wsl_ip}/admin/api.php?summary" 2>/dev/null); then
        debug_log "API response received: $api_response"
        
        # Parse JSON response
        local queries_today=$(echo "$api_response" | jq -r '.dns_queries_today // "0"' 2>/dev/null)
        local blocked_today=$(echo "$api_response" | jq -r '.ads_blocked_today // "0"' 2>/dev/null)
        local percent_blocked=$(echo "$api_response" | jq -r '.ads_percentage_today // "0.0"' 2>/dev/null)
        local status=$(echo "$api_response" | jq -r '.status // "disabled"' 2>/dev/null)
        
        # Convert status
        local current_status="Inactive"
        if [[ "$status" == "enabled" ]]; then
            current_status="Active"
        fi
        
        # Clean and validate numbers
        queries_today=$(clean_number "$queries_today")
        blocked_today=$(clean_number "$blocked_today")
        percent_blocked=$(clean_number "$percent_blocked")
        
        echo "${current_status},${queries_today},${blocked_today},${percent_blocked}"
        return 0
    fi
    
    debug_log "API method failed"
    return 1
}

# Method 2: Try Pi-hole command line tool
get_stats_via_command() {
    debug_log "Trying Pi-hole command method..."
    
    if ! command -v pihole &>/dev/null; then
        debug_log "Pi-hole command not found"
        return 1
    fi
    
    # Try the chronometer command for real-time stats
    local pihole_output
    if pihole_output=$(timeout 5 pihole -c -e 2>/dev/null); then
        debug_log "Pi-hole command output: $pihole_output"
        
        # Parse comma-separated output
        # Format: domains_being_blocked,dns_queries_today,ads_blocked_today,ads_percentage_today,...,status
        local queries_today=$(echo "$pihole_output" | cut -d',' -f2)
        local blocked_today=$(echo "$pihole_output" | cut -d',' -f3)
        local percent_blocked=$(echo "$pihole_output" | cut -d',' -f4)
        local status=$(echo "$pihole_output" | rev | cut -d',' -f1 | rev)
        
        # Convert status
        local current_status="Inactive"
        if [[ "$status" == "enabled" ]]; then
            current_status="Active"
        fi
        
        # Clean and validate numbers
        queries_today=$(clean_number "$queries_today")
        blocked_today=$(clean_number "$blocked_today")
        percent_blocked=$(clean_number "$percent_blocked")
        
        echo "${current_status},${queries_today},${blocked_today},${percent_blocked}"
        return 0
    fi
    
    debug_log "Pi-hole command method failed"
    return 1
}

# Method 3: Check service status only
get_status_only() {
    debug_log "Trying service status method..."
    
    local current_status="Inactive"
    
    # Check if Pi-hole FTL service is running
    if systemctl is-active pihole-FTL &>/dev/null; then
        current_status="Active"
        debug_log "Pi-hole FTL service is active"
    elif pgrep pihole-FTL &>/dev/null; then
        current_status="Active"
        debug_log "Pi-hole FTL process is running"
    else
        debug_log "Pi-hole FTL is not running"
    fi
    
    echo "${current_status},0,0,0.0"
    return 0
}

# Method 4: Check if Pi-hole is installed at all
check_pihole_installation() {
    debug_log "Checking Pi-hole installation..."
    
    # Check if Pi-hole directories exist
    if [[ -d "/etc/pihole" ]] && [[ -f "/usr/local/bin/pihole" ]]; then
        debug_log "Pi-hole appears to be installed"
        return 0
    else
        debug_log "Pi-hole does not appear to be installed"
        return 1
    fi
}

# Main function
main() {
    debug_log "Starting Pi-hole stats collection..."
    
    # First, check if Pi-hole is even installed
    if ! check_pihole_installation; then
        debug_log "Pi-hole not installed, returning default output"
        echo "$DEFAULT_OUTPUT"
        exit 0
    fi
    
    # Try methods in order of preference
    
    # Method 1: API (fastest and most reliable)
    if get_stats_via_api; then
        debug_log "Successfully got stats via API"
        exit 0
    fi
    
    # Method 2: Command line
    if get_stats_via_command; then
        debug_log "Successfully got stats via command"
        exit 0
    fi
    
    # Method 3: Service status only
    if get_status_only; then
        debug_log "Got basic status info"
        exit 0
    fi
    
    # If all methods fail
    debug_log "All methods failed, returning default output"
    echo "$DEFAULT_OUTPUT"
    exit 0
}

# Run main function
main "$@"