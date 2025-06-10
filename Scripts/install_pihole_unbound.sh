#!/bin/bash

# Pi-hole and Unbound Installation Script for WSL
# Designed for unattended installation with proper error handling

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

check_prerequisites() {
    log_message "Checking prerequisites..."
    
    if ! grep -q microsoft /proc/version 2>/dev/null; then
        log_error "This script must be run in WSL (Windows Subsystem for Linux)"
        exit 1
    fi
    
    if ! ping -c 1 google.com &>/dev/null; then
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
        systemd \
        git \
        ca-certificates
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
    
    log_message "Configuring Unbound to use Quad9 as a forwarding resolver..."
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
    forward-tls-upstream: yes
    forward-addr: 9.9.9.9@853#dns.quad9.net
    forward-addr: 149.112.112.112@853#dns.quad9.net
EOF
    
    log_message "Unbound configuration completed"
}

stabilize_wsl_networking() {
    log_message "Stabilizing WSL networking by preventing auto-generation of resolv.conf..."
    
    # Create /etc/wsl.conf to prevent WSL from managing resolv.conf
    log_message "Creating /etc/wsl.conf to disable DNS management..."
    sudo tee /etc/wsl.conf > /dev/null <<EOF
[network]
generateResolvConf = false
EOF
    log_message "/etc/wsl.conf created. A WSL restart is required for this to take full effect."

    # Write the correct resolv.conf for the current session
    log_message "Writing new DNS configuration to /etc/resolv.conf for current session..."
    sudo tee "/etc/resolv.conf" > /dev/null <<EOF
# Generated by piFiller to ensure WSL connectivity
nameserver 8.8.8.8
nameserver 1.1.1.1
options edns0
EOF

    log_message "WSL networking stabilized for the current session."
}

fix_pihole_port() {
    log_message "Checking and correcting Pi-hole web server port..."
    local PIHOLE_CONFIG_FILE="/etc/pihole/pihole.toml"

    if [[ -f "$PIHOLE_CONFIG_FILE" ]]; then
        if grep -q "port = 8080" "$PIHOLE_CONFIG_FILE"; then
            log_message "Incorrect port 8080 found. Correcting to port 80..."
            sudo sed -i 's/port = 8080/port = 80/g' "$PIHOLE_CONFIG_FILE"
            log_message "Pi-hole web server port has been corrected."
        else
            log_message "Pi-hole web server port is already correct. No changes needed."
        fi
    else
        log_message "Pi-hole v6 config file not found at $PIHOLE_CONFIG_FILE. Skipping port fix."
    fi
}

configure_services() {
    log_message "Configuring and starting services..."

    # Fix the web server port before starting services
    fix_pihole_port
    
    # Configure Pi-hole to use Unbound
    sudo pihole -a -d 127.0.0.1#5335
    
    # Enable and start Unbound
    sudo systemctl enable unbound
    sudo systemctl restart unbound
    
    # Wait for Unbound to become responsive before starting Pi-hole
    log_message "Waiting for Unbound to be ready..."
    local unbound_ready=false
    for i in {1..20}; do
        if dig @127.0.0.1 -p 5335 google.com +time=1 +tries=1 &>/dev/null; then
            log_message "Unbound is responsive after $i seconds."
            unbound_ready=true
            break
        fi
        log_message "Waiting for Unbound... attempt $i of 20."
        sleep 1
    done

    if [ "$unbound_ready" = false ]; then
        log_error "Unbound did not become responsive after 20 seconds. Pi-hole may fail to start."
    fi
    
    # Restart Pi-hole FTL now that Unbound is ready
    log_message "Restarting Pi-hole FTL..."
    sudo systemctl enable pihole-FTL
    sudo systemctl restart pihole-FTL
    
    sleep 3
    
    log_message "Services configured and started"
}

verify_installation() {
    log_message "Verifying installation..."
    
    if pihole status &>/dev/null; then
        log_message "? Pi-hole is running"
    else
        log_error "? Pi-hole is not running"
        return 1
    fi
    
    if sudo systemctl is-active unbound &>/dev/null; then
        log_message "? Unbound is running"
    else
        log_error "? Unbound is not running"
        return 1
    fi
    
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

main() {
    log_message "Starting Pi-hole and Unbound installation..."
    
    check_prerequisites
    setup_environment
    update_system
    create_pihole_config
    install_pihole
    install_unbound
    stabilize_wsl_networking
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

main "$@"