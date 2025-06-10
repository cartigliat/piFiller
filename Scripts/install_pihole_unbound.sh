#!/bin/bash

# Pi-hole and Unbound Installation Script for WSL
# Works in both systemd and non-systemd environments

set -e  # Exit on any error

# --- Configuration ---
SCRIPT_LOG="/var/log/pifill_install.log"
PIHOLE_SETUP_VARS="/etc/pihole/setupVars.conf"
UNBOUND_CONF_DIR="/etc/unbound/unbound.conf.d"
PIHOLE_UNBOUND_CONF="${UNBOUND_CONF_DIR}/pi-hole.conf"

# --- Helper Functions ---
log_message() {
    local msg="[INFO] $(date '+%Y-%m-%d %H:%M:%S'): $1"
    echo "$msg"
    echo "$msg" | sudo tee -a "$SCRIPT_LOG" > /dev/null
}

log_error() {
    local msg="[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $1"
    echo "$msg" >&2
    echo "$msg" | sudo tee -a "$SCRIPT_LOG" > /dev/null
}

# Detect if systemd is available and working
is_systemd_available() {
    # Check multiple conditions to ensure systemd is truly available
    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
        # Additional check: see if systemctl actually works
        if systemctl --version &>/dev/null 2>&1; then
            # Final check: can we actually query a service?
            if systemctl list-units &>/dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    return 1
}

# Start a service using systemd or fallback methods
start_service() {
    local service_name=$1
    local binary_path=$2
    local args=$3
    
    log_message "Starting service: $service_name"
    
    if is_systemd_available; then
        log_message "Using systemd to start $service_name"
        sudo systemctl enable "$service_name" 2>/dev/null || true
        sudo systemctl restart "$service_name"
        
        # Verify it started
        sleep 2
        if ! systemctl is-active --quiet "$service_name"; then
            log_message "systemd start failed, falling back to direct method"
            start_service_directly "$service_name" "$binary_path" "$args"
        fi
    else
        log_message "systemd not available, using direct service management for $service_name"
        start_service_directly "$service_name" "$binary_path" "$args"
    fi
}

# Start a service by running its binary directly
start_service_directly() {
    local service_name=$1
    local binary_path=$2
    local args=$3
    
    # Kill any existing process
    stop_service_directly "$service_name" "$binary_path"
    
    # Create log directory if needed
    sudo mkdir -p /var/log
    local log_file="/var/log/${service_name}-direct.log"
    
    # Start the service based on type
    case "$service_name" in
        "unbound")
            log_message "Starting Unbound directly..."
            sudo nohup $binary_path -d -c /etc/unbound/unbound.conf > "$log_file" 2>&1 &
            ;;
        "pihole-FTL")
            log_message "Starting Pi-hole FTL directly..."
            # Ensure required directories exist
            sudo mkdir -p /run/pihole /var/log/pihole
            sudo chown pihole:pihole /run/pihole /var/log/pihole 2>/dev/null || true
            sudo nohup $binary_path no-daemon > "$log_file" 2>&1 &
            ;;
        "lighttpd")
            log_message "Starting lighttpd directly..."
            sudo nohup $binary_path -D -f /etc/lighttpd/lighttpd.conf > "$log_file" 2>&1 &
            ;;
        *)
            log_message "Starting $service_name with generic method..."
            sudo nohup $binary_path $args > "$log_file" 2>&1 &
            ;;
    esac
    
    # Give it time to start
    sleep 3
    
    # Verify it started
    if pgrep -f "$binary_path" > /dev/null; then
        log_message "✓ $service_name started successfully (PID: $(pgrep -f "$binary_path" | head -1))"
    else
        log_error "✗ Failed to start $service_name"
        return 1
    fi
}

# Stop a service using systemd or direct methods
stop_service() {
    local service_name=$1
    local process_name=$2
    
    log_message "Stopping service: $service_name"
    
    if is_systemd_available; then
        sudo systemctl stop "$service_name" 2>/dev/null || true
        sudo systemctl disable "$service_name" 2>/dev/null || true
    else
        stop_service_directly "$service_name" "$process_name"
    fi
    
    sleep 2
}

# Stop a service directly by killing its process
stop_service_directly() {
    local service_name=$1
    local process_name=$2
    
    # Try multiple methods to ensure the process is stopped
    sudo pkill -f "$process_name" 2>/dev/null || true
    sudo killall "$process_name" 2>/dev/null || true
    
    # Also try the service command if available
    if command -v service &>/dev/null; then
        sudo service "$service_name" stop 2>/dev/null || true
    fi
    
    # Give processes time to exit
    sleep 1
    
    # Force kill if still running
    if pgrep -f "$process_name" > /dev/null; then
        sudo pkill -9 -f "$process_name" 2>/dev/null || true
        sleep 1
    fi
}

# Check if a service is running
is_service_running() {
    local service_name=$1
    local process_name=$2
    
    if is_systemd_available; then
        # Try systemd first
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            return 0
        fi
    fi
    
    # Fallback to process check
    if pgrep -f "$process_name" > /dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Get service status
get_service_status() {
    local service_name=$1
    local process_name=$2
    
    if is_service_running "$service_name" "$process_name"; then
        echo "active"
    else
        echo "inactive"
    fi
}

fix_wsl_dns_resolution() {
    log_message "Pre-installation: Verifying WSL DNS resolution..."
    
    # Test current internet connectivity
    if dig +short google.com &>/dev/null || nslookup google.com &>/dev/null 2>&1; then
        log_message "✓ WSL DNS resolution is working"
        return 0
    fi
    
    log_message "⚠ WSL DNS resolution failed, applying fix..."
    
    # Backup current resolv.conf
    if [[ -f "/etc/resolv.conf" ]]; then
        sudo cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%s) 2>/dev/null || true
    fi
    
    # Remove immutable flag if present
    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Write reliable DNS configuration
    sudo tee /etc/resolv.conf > /dev/null <<EOF
# Temporary DNS for installation
nameserver 8.8.8.8
nameserver 1.1.1.1
options edns0
EOF
    
    # Test again
    sleep 2
    if dig +short google.com &>/dev/null || nslookup google.com &>/dev/null 2>&1; then
        log_message "✓ WSL DNS resolution fixed successfully"
        return 0
    else
        log_error "✗ WSL DNS resolution still failing after fix attempt"
        return 1
    fi
}

check_prerequisites() {
    log_message "Checking prerequisites..."
    
    if ! grep -q microsoft /proc/version 2>/dev/null; then
        log_error "This script must be run in WSL (Windows Subsystem for Linux)"
        exit 1
    fi
    
    if ! ping -c 1 google.com &>/dev/null && ! nslookup google.com &>/dev/null 2>&1; then
        log_error "No internet connectivity. Please check your network connection."
        exit 1
    fi
    
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root. Run as regular user with sudo access."
        exit 1
    fi
    
    if ! sudo -n true 2>/dev/null; then
        log_message "Testing sudo access..."
        sudo true
    fi
    
    log_message "Prerequisites check passed"
}

setup_environment() {
    log_message "Setting up environment..."
    
    sudo mkdir -p /var/log
    sudo touch "$SCRIPT_LOG"
    sudo chmod 644 "$SCRIPT_LOG"
    
    export DEBIAN_FRONTEND=noninteractive
    export PIHOLE_SKIP_OS_CHECK=true
    
    log_message "Environment setup complete"
}

update_system() {
    log_message "Updating package lists..."
    sudo apt-get update -qq
    
    log_message "Installing essential dependencies..."
    sudo apt-get install -y \
        curl \
        wget \
        lsb-release \
        gnupg \
        dnsutils \
        jq \
        git \
        ca-certificates \
        procps \
        psmisc \
        net-tools \
        lsof
    
    log_message "Updating certificate store..."
    sudo update-ca-certificates --fresh
}

create_pihole_config() {
    log_message "Creating Pi-hole configuration..."
    
    WSL_IP=$(hostname -I | awk '{print $1}')
    if [[ -z "$WSL_IP" ]]; then
        WSL_IP="172.24.0.1"
        log_message "Using fallback IP: $WSL_IP"
    else
        log_message "Detected WSL IP: $WSL_IP"
    fi
    
    sudo mkdir -p /etc/pihole
    sudo tee "$PIHOLE_SETUP_VARS" > /dev/null <<EOF
WEBPASSWORD=
PIHOLE_INTERFACE=eth0
IPV4_ADDRESS=${WSL_IP}/24
IPV6_ADDRESS=
PIHOLE_DNS_1=127.0.0.1#5335
PIHOLE_DNS_2=
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=all
BLOCKING_ENABLED=true
DNSSEC=false
CONDITIONAL_FORWARDING=false
EOF
    
    log_message "Pi-hole configuration created"
}

install_pihole() {
    if pihole -v &>/dev/null; then
        log_message "Pi-hole is already installed. Updating configuration..."
        sudo pihole -r unattended
    else
        log_message "Installing Pi-hole..."
        
        curl -sSL https://install.pi-hole.net | sudo bash /dev/stdin --unattended
        
        if ! pihole -v &>/dev/null; then
            log_error "Pi-hole installation failed"
            exit 1
        fi
        
        log_message "Pi-hole installation completed"
    fi
}

install_unbound() {
    if command -v unbound &>/dev/null; then
        log_message "Unbound is already installed"
    else
        log_message "Installing Unbound..."
        sudo apt-get install -y unbound
    fi
    
    log_message "Configuring Unbound with standard DNS forwarding (Quad9)..."
    sudo mkdir -p "$UNBOUND_CONF_DIR"
    
    sudo tee "$PIHOLE_UNBOUND_CONF" > /dev/null <<'EOF'
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    prefer-ip6: no
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 1
    msg-cache-size: 50m
    rrset-cache-size: 100m
    hide-identity: yes
    hide-version: yes
    private-address: 192.168.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    access-control: 127.0.0.0/8 allow

forward-zone:
    name: "."
    forward-addr: 9.9.9.9
    forward-addr: 149.112.112.112
    forward-addr: 8.8.8.8
    forward-addr: 8.8.4.4
EOF
    
    log_message "Unbound configuration completed"
}

stabilize_wsl_networking() {
    log_message "Stabilizing WSL networking..."
    
    # Create /etc/wsl.conf to prevent WSL from managing resolv.conf
    log_message "Creating /etc/wsl.conf to disable DNS management..."
    sudo tee /etc/wsl.conf > /dev/null <<EOF
[network]
generateResolvConf = false
EOF
    log_message "/etc/wsl.conf created. A WSL restart may be required for full effect."

    # Write stable resolv.conf for current session
    log_message "Writing stable DNS configuration..."
    sudo tee "/etc/resolv.conf" > /dev/null <<EOF
# Generated by piFiller to ensure WSL connectivity
nameserver 8.8.8.8
nameserver 1.1.1.1
options edns0
EOF

    log_message "WSL networking stabilized"
}

fix_pihole_port() {
    log_message "Checking Pi-hole web server port configuration..."
    local PIHOLE_CONFIG_FILE="/etc/pihole/pihole.toml"

    if [[ -f "$PIHOLE_CONFIG_FILE" ]]; then
        if grep -q "port = 8080" "$PIHOLE_CONFIG_FILE"; then
            log_message "Correcting web server port from 8080 to 80..."
            sudo sed -i 's/port = 8080/port = 80/g' "$PIHOLE_CONFIG_FILE"
            log_message "Web server port corrected"
        else
            log_message "Web server port is already correct"
        fi
    fi
}

wait_for_unbound_ready() {
    log_message "Waiting for Unbound to become ready..."
    local timeout=30
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if dig @127.0.0.1 -p 5335 google.com +time=1 +tries=1 &>/dev/null; then
            log_message "✓ Unbound is responsive after ${elapsed} seconds"
            return 0
        fi
        
        log_message "Waiting for Unbound... (${elapsed}/${timeout}s)"
        sleep 1
        ((elapsed++))
    done
    
    log_error "✗ Unbound did not become responsive after ${timeout} seconds"
    return 1
}

configure_services() {
    log_message "Configuring and starting services..."
    log_message "systemd available: $(is_systemd_available && echo 'yes' || echo 'no')"

    # Fix the web server port before starting services
    fix_pihole_port
    
    # Configure Pi-hole to use Unbound
    sudo pihole -a -d 127.0.0.1#5335
    
    # Stop all services first
    stop_service "unbound" "unbound"
    stop_service "pihole-FTL" "pihole-FTL"
    stop_service "lighttpd" "lighttpd"
    
    # Start Unbound
    if [[ -f "/usr/sbin/unbound" ]]; then
        start_service "unbound" "/usr/sbin/unbound" "-d -c /etc/unbound/unbound.conf"
        
        # Wait for Unbound to become ready
        if ! wait_for_unbound_ready; then
            log_error "Unbound failed to start properly"
            # Try to get more diagnostic info
            sudo unbound-checkconf 2>&1 | tee -a "$SCRIPT_LOG"
            return 1
        fi
    else
        log_error "Unbound binary not found at /usr/sbin/unbound"
        return 1
    fi
    
    # Start Pi-hole FTL
    if [[ -f "/usr/bin/pihole-FTL" ]]; then
        start_service "pihole-FTL" "/usr/bin/pihole-FTL" "no-daemon"
        sleep 5
    else
        log_error "Pi-hole FTL binary not found at /usr/bin/pihole-FTL"
        return 1
    fi
    
    # Start lighttpd for web interface
    if [[ -f "/usr/sbin/lighttpd" ]]; then
        start_service "lighttpd" "/usr/sbin/lighttpd" "-D -f /etc/lighttpd/lighttpd.conf"
        sleep 3
    else
        log_message "lighttpd not found, web interface may not be available"
    fi
    
    log_message "Services configuration completed"
    return 0
}

verify_installation() {
    log_message "Verifying installation..."
    local failed=0
    
    # Check if Pi-hole command works
    if pihole status &>/dev/null; then
        log_message "✓ Pi-hole command is working"
    else
        log_error "✗ Pi-hole command is not working"
        ((failed++))
    fi
    
    # Check if Unbound is running
    if is_service_running "unbound" "unbound"; then
        log_message "✓ Unbound is running"
    else
        log_error "✗ Unbound is not running"
        ((failed++))
    fi
    
    # Check if Pi-hole FTL is running
    if is_service_running "pihole-FTL" "pihole-FTL"; then
        log_message "✓ Pi-hole FTL is running"
    else
        log_error "✗ Pi-hole FTL is not running"
        ((failed++))
    fi
    
    # Check if lighttpd is running
    if is_service_running "lighttpd" "lighttpd"; then
        log_message "✓ Lighttpd (web interface) is running"
    else
        log_message "⚠ Lighttpd is not running (web interface may not be available)"
    fi
    
    # Test DNS resolution through Unbound
    if dig @127.0.0.1 -p 5335 google.com +short &>/dev/null; then
        log_message "✓ Unbound DNS resolution working"
    else
        log_error "✗ Unbound DNS resolution failed"
        ((failed++))
    fi
    
    # Test DNS resolution through Pi-hole
    WSL_IP=$(hostname -I | awk '{print $1}')
    if dig @${WSL_IP} google.com +short &>/dev/null; then
        log_message "✓ Pi-hole DNS resolution working"
    else
        log_error "✗ Pi-hole DNS resolution failed"
        ((failed++))
    fi
    
    # Show current service status
    log_message "Current service status:"
    log_message "  - Unbound: $(get_service_status 'unbound' 'unbound')"
    log_message "  - Pi-hole FTL: $(get_service_status 'pihole-FTL' 'pihole-FTL')"
    log_message "  - Lighttpd: $(get_service_status 'lighttpd' 'lighttpd')"
    
    if [[ $failed -eq 0 ]]; then
        log_message "Installation verification completed successfully"
        return 0
    else
        log_error "Installation verification failed with $failed errors"
        return 1
    fi
}

# Create a comprehensive startup script for manual service management
create_startup_script() {
    log_message "Creating service management scripts..."
    
    # Main startup script
    sudo tee /usr/local/bin/start-pihole-services.sh > /dev/null <<'EOF'
#!/bin/bash
# Start Pi-hole and Unbound services
# Can be used manually or at system startup

echo "Starting Pi-hole services..."
echo "Time: $(date)"

# Function to check if a process is running
is_running() {
    pgrep -f "$1" > /dev/null 2>&1
}

# Function to start a service
start_service() {
    local name=$1
    local binary=$2
    local args=$3
    
    echo -n "Starting $name... "
    
    if is_running "$binary"; then
        echo "already running"
        return 0
    fi
    
    case "$name" in
        "Unbound")
            nohup $binary -d -c /etc/unbound/unbound.conf > /var/log/unbound-startup.log 2>&1 &
            ;;
        "Pi-hole FTL")
            mkdir -p /run/pihole /var/log/pihole
            chown pihole:pihole /run/pihole /var/log/pihole 2>/dev/null || true
            nohup $binary no-daemon > /var/log/pihole-FTL-startup.log 2>&1 &
            ;;
        "Lighttpd")
            nohup $binary -D -f /etc/lighttpd/lighttpd.conf > /var/log/lighttpd-startup.log 2>&1 &
            ;;
    esac
    
    sleep 2
    
    if is_running "$binary"; then
        echo "started (PID: $(pgrep -f "$binary" | head -1))"
        return 0
    else
        echo "failed"
        return 1
    fi
}

# Start services in order
start_service "Unbound" "/usr/sbin/unbound" ""
sleep 3

start_service "Pi-hole FTL" "/usr/bin/pihole-FTL" ""
sleep 3

start_service "Lighttpd" "/usr/sbin/lighttpd" ""

echo ""
echo "Service status:"
echo "  Unbound: $(is_running 'unbound' && echo 'running' || echo 'not running')"
echo "  Pi-hole FTL: $(is_running 'pihole-FTL' && echo 'running' || echo 'not running')"
echo "  Lighttpd: $(is_running 'lighttpd' && echo 'running' || echo 'not running')"

# Test DNS resolution
echo ""
echo "Testing DNS resolution:"
if dig @127.0.0.1 -p 5335 google.com +short > /dev/null 2>&1; then
    echo "  Unbound: working"
else
    echo "  Unbound: not working"
fi

WSL_IP=$(hostname -I | awk '{print $1}')
if dig @${WSL_IP} google.com +short > /dev/null 2>&1; then
    echo "  Pi-hole: working"
else
    echo "  Pi-hole: not working"
fi

echo ""
echo "Pi-hole services startup completed"
EOF
    
    # Stop script
    sudo tee /usr/local/bin/stop-pihole-services.sh > /dev/null <<'EOF'
#!/bin/bash
# Stop Pi-hole and Unbound services

echo "Stopping Pi-hole services..."

# Function to stop a service
stop_service() {
    local name=$1
    local process=$2
    
    echo -n "Stopping $name... "
    
    if pgrep -f "$process" > /dev/null; then
        pkill -f "$process" 2>/dev/null
        sleep 2
        
        # Force kill if still running
        if pgrep -f "$process" > /dev/null; then
            pkill -9 -f "$process" 2>/dev/null
            sleep 1
        fi
        
        echo "stopped"
    else
        echo "not running"
    fi
}

# Stop services
stop_service "Lighttpd" "lighttpd"
stop_service "Pi-hole FTL" "pihole-FTL"
stop_service "Unbound" "unbound"

echo "Pi-hole services stopped"
EOF
    
    # Restart script
    sudo tee /usr/local/bin/restart-pihole-services.sh > /dev/null <<'EOF'
#!/bin/bash
# Restart Pi-hole and Unbound services

echo "Restarting Pi-hole services..."
/usr/local/bin/stop-pihole-services.sh
sleep 2
/usr/local/bin/start-pihole-services.sh
EOF
    
    # Status script
    sudo tee /usr/local/bin/status-pihole-services.sh > /dev/null <<'EOF'
#!/bin/bash
# Check status of Pi-hole and Unbound services

echo "Pi-hole Services Status"
echo "======================="
echo ""

# Function to check service
check_service() {
    local name=$1
    local process=$2
    local port=$3
    
    echo -n "$name: "
    
    if pgrep -f "$process" > /dev/null; then
        echo -n "running (PID: $(pgrep -f "$process" | head -1))"
        
        if [[ -n "$port" ]]; then
            if netstat -ln 2>/dev/null | grep -q ":$port " || ss -ln 2>/dev/null | grep -q ":$port "; then
                echo " - listening on port $port"
            else
                echo " - NOT listening on port $port"
            fi
        else
            echo ""
        fi
    else
        echo "not running"
    fi
}

check_service "Unbound" "unbound" "5335"
check_service "Pi-hole FTL" "pihole-FTL" "53"
check_service "Lighttpd" "lighttpd" "80"

echo ""
echo "DNS Resolution Tests:"
echo "--------------------"

if dig @127.0.0.1 -p 5335 google.com +short > /dev/null 2>&1; then
    echo "Unbound (127.0.0.1:5335): working"
else
    echo "Unbound (127.0.0.1:5335): not working"
fi

WSL_IP=$(hostname -I | awk '{print $1}')
if dig @${WSL_IP} google.com +short > /dev/null 2>&1; then
    echo "Pi-hole ($WSL_IP:53): working"
else
    echo "Pi-hole ($WSL_IP:53): not working"
fi

echo ""
echo "Web Interface: http://$WSL_IP/admin"
EOF
    
    # Make all scripts executable
    sudo chmod +x /usr/local/bin/start-pihole-services.sh
    sudo chmod +x /usr/local/bin/stop-pihole-services.sh
    sudo chmod +x /usr/local/bin/restart-pihole-services.sh
    sudo chmod +x /usr/local/bin/status-pihole-services.sh
    
    log_message "Service management scripts created in /usr/local/bin/"
}

main() {
    log_message "=========================================="
    log_message "Starting Pi-hole and Unbound installation"
    log_message "=========================================="
    log_message "systemd available: $(is_systemd_available && echo 'yes' || echo 'no')"
    
    # Fix WSL DNS resolution before anything else
    fix_wsl_dns_resolution
    
    check_prerequisites
    setup_environment
    update_system
    create_pihole_config
    install_pihole
    install_unbound
    stabilize_wsl_networking
    
    # Configure and start services
    if ! configure_services; then
        log_error "Service configuration failed"
        exit 1
    fi
    
    create_startup_script
    
    if verify_installation; then
        log_message "=========================================="
        log_message "🎉 Installation completed successfully!"
        log_message "=========================================="
        echo ""
        echo "Pi-hole Web Interface: http://$(hostname -I | awk '{print $1}')/admin"
        echo "DNS Server: $(hostname -I | awk '{print $1}')"
        echo "Upstream DNS: Unbound (127.0.0.1:5335) → Quad9"
        echo ""
        echo "Service Management Commands:"
        echo "  Start:   sudo /usr/local/bin/start-pihole-services.sh"
        echo "  Stop:    sudo /usr/local/bin/stop-pihole-services.sh"
        echo "  Restart: sudo /usr/local/bin/restart-pihole-services.sh"
        echo "  Status:  sudo /usr/local/bin/status-pihole-services.sh"
        echo ""
        echo "Installation log: $SCRIPT_LOG"
        
        if ! is_systemd_available; then
            echo ""
            echo "⚠️  Note: systemd is not available in this WSL environment."
            echo "   Services have been started directly and may need manual restart after WSL restarts."
            echo "   Use the service management commands above to control services."
        fi
    else
        log_error "Installation verification failed. Check logs for details."
        echo ""
        echo "Troubleshooting commands:"
        echo "  View logs: sudo tail -50 $SCRIPT_LOG"
        echo "  Check status: sudo /usr/local/bin/status-pihole-services.sh"
        echo "  Restart services: sudo /usr/local/bin/restart-pihole-services.sh"
        exit 1
    fi
}

# Run main function
main "$@"