#!/bin/bash

# Pi-hole and Unbound Installation Script for WSL
# Designed for unattended installation with proper error handling

set -e  # Exit on any error

# --- Configuration ---
SCRIPT_LOG="/var/log/pifill_install.log"
PIHOLE_SETUP_VARS="/etc/pihole/setupVars.conf"
UNBOUND_CONF_DIR="/etc/unbound/unbound.conf.d"
PIHOLE_UNBOUND_CONF="${UNBOUND_CONF_DIR}/pi-hole.conf"
ROOT_HINTS_FILE="/var/lib/unbound/root.hints"

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

check_prerequisites() {
    log_message "Checking prerequisites..."
    
    # Check if running in WSL
    if ! grep -q microsoft /proc/version 2>/dev/null; then
        log_error "This script must be run in WSL (Windows Subsystem for Linux)"
        exit 1
    fi
    
    # Check internet connectivity
    if ! ping -c 1 google.com &>/dev/null; then
        log_error "No internet connectivity. Please check your network connection."
        exit 1
    fi
    
    # Check if running as root or with sudo access
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root. Run as regular user with sudo access."
        exit 1
    fi
    
    if ! sudo -n true 2>/dev/null; then
        log_message "Testing sudo access..."
        sudo true  # This will prompt for password if needed
    fi
    
    log_message "Prerequisites check passed"
}

setup_environment() {
    log_message "Setting up environment..."
    
    # Create log directory
    sudo mkdir -p /var/log
    sudo touch "$SCRIPT_LOG"
    sudo chmod 644 "$SCRIPT_LOG"
    
    # Set environment variables for unattended Pi-hole installation
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
        systemd \
        git \
        ca-certificates
}

create_pihole_config() {
    log_message "Creating Pi-hole configuration..."
    
    # Get WSL IP address for Pi-hole
    WSL_IP=$(hostname -I | awk '{print $1}')
    if [[ -z "$WSL_IP" ]]; then
        WSL_IP="172.24.0.1"  # Fallback to your detected IP
        log_message "Using fallback IP: $WSL_IP"
    else
        log_message "Detected WSL IP: $WSL_IP"
    fi
    
    # Create setupVars.conf for unattended installation
    sudo mkdir -p /etc/pihole
    sudo tee "$PIHOLE_SETUP_VARS" > /dev/null <<EOF
# Pi-hole Setup Variables (Unattended Installation)
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
DNSMASQ_LISTENING=single
BLOCKING_ENABLED=true
DNSSEC=false
CONDITIONAL_FORWARDING=false
EOF
    
    log_message "Pi-hole configuration created"
}

install_pihole() {
    if pihole -v &>/dev/null; then
        log_message "Pi-hole is already installed. Updating configuration..."
        sudo pihole -r unattended  # Reconfigure with current settings
    else
        log_message "Installing Pi-hole..."
        
        # Download and run Pi-hole installer
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
    
    # Configure Unbound
    log_message "Configuring Unbound for Pi-hole..."
    sudo mkdir -p "$UNBOUND_CONF_DIR"
    
    sudo tee "$PIHOLE_UNBOUND_CONF" > /dev/null <<'EOF'
server:
    # Basic configuration
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    prefer-ip6: no
    
    # Root hints
    root-hints: "/var/lib/unbound/root.hints"
    
    # Security settings
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    harden-large-queries: yes
    harden-short-bufsize: yes
    
    # Performance settings
    edns-buffer-size: 1472
    prefetch: yes
    num-threads: 1
    msg-cache-size: 50m
    rrset-cache-size: 100m
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    
    # Privacy settings
    hide-identity: yes
    hide-version: yes
    
    # Access control
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
EOF
    
    # Download root hints
    log_message "Downloading root hints..."
    sudo mkdir -p /var/lib/unbound
    sudo curl -s -o "$ROOT_HINTS_FILE" https://www.internic.net/domain/named.cache
    
    log_message "Unbound configuration completed"
}

configure_services() {
    log_message "Configuring and starting services..."
    
    # Configure Pi-hole to use Unbound
    sudo pihole -a -d 127.0.0.1#5335
    
    # Enable and start Unbound
    sudo systemctl enable unbound
    sudo systemctl restart unbound
    
    # Wait for Unbound to start
    sleep 2
    
    # Test Unbound
    if dig @127.0.0.1 -p 5335 google.com +short &>/dev/null; then
        log_message "Unbound is working correctly"
    else
        log_error "Unbound test failed"
    fi
    
    # Restart Pi-hole FTL
    sudo systemctl enable pihole-FTL
    sudo systemctl restart pihole-FTL
    
    # Wait for Pi-hole to start
    sleep 3
    
    log_message "Services configured and started"
}

verify_installation() {
    log_message "Verifying installation..."
    
    # Check Pi-hole status
    if pihole status &>/dev/null; then
        log_message "? Pi-hole is running"
    else
        log_error "? Pi-hole is not running"
        return 1
    fi
    
    # Check Unbound status
    if sudo systemctl is-active unbound &>/dev/null; then
        log_message "? Unbound is running"
    else
        log_error "? Unbound is not running"
        return 1
    fi
    
    # Test DNS resolution through Pi-hole
    WSL_IP=$(hostname -I | awk '{print $1}')
    if dig @${WSL_IP} google.com +short &>/dev/null; then
        log_message "? Pi-hole DNS resolution working"
    else
        log_error "? Pi-hole DNS resolution failed"
        return 1
    fi
    
    log_message "Installation verification completed successfully"
    return 0
}

# --- Main Installation Process ---
main() {
    log_message "Starting Pi-hole and Unbound installation..."
    
    check_prerequisites
    setup_environment
    update_system
    create_pihole_config
    install_pihole
    install_unbound
    configure_services
    
    if verify_installation; then
        log_message "?? Installation completed successfully!"
        echo ""
        echo "Pi-hole Web Interface: http://$(hostname -I | awk '{print $1}')/admin"
        echo "DNS Server: $(hostname -I | awk '{print $1}')"
        echo "Upstream DNS: Unbound (127.0.0.1:5335)"
        echo ""
        echo "Installation log: $SCRIPT_LOG"
    else
        log_error "Installation verification failed. Check logs for details."
        exit 1
    fi
}

# Run main function
main "$@"