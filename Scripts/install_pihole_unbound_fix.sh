#!/bin/bash

# Fixed Pi-hole and Unbound Installation Script for WSL
# Ensures proper network binding and Quad9 forwarding

set -e

# Configuration
SCRIPT_LOG="/tmp/pifill_install.log"
WSL_IP=$(hostname -I | awk '{print $1}')

# Helper Functions
log_message() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$SCRIPT_LOG"
}

# Step 1: Install Pi-hole with proper network configuration
install_pihole() {
    log_message "Installing Pi-hole with network binding to $WSL_IP..."
    
    # Create pre-configuration for Pi-hole
    sudo mkdir -p /etc/pihole
    
    # Create setupVars.conf for unattended installation
    sudo tee /etc/pihole/setupVars.conf > /dev/null <<EOF
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
PIHOLE_SKIP_OS_CHECK=true
EOF
    
    # Download and install Pi-hole
    curl -sSL https://install.pi-hole.net | sudo bash /dev/stdin --unattended
    
    log_message "Pi-hole installed"
}

# Step 2: Configure Pi-hole for all interfaces
configure_pihole_network() {
    log_message "Configuring Pi-hole network binding..."
    
    # For Pi-hole v6 (uses pihole.toml)
    if [[ -f "/etc/pihole/pihole.toml" ]]; then
        sudo cp /etc/pihole/pihole.toml /etc/pihole/pihole.toml.backup
        
        # Create new configuration that listens on all interfaces
        sudo tee /etc/pihole/pihole.toml > /dev/null <<EOF
[files]
  gravity = "/etc/pihole/gravity.db"
  macvendor = "/etc/pihole/macvendor.db"

[dns]
  upstreams = ["127.0.0.1#5335"]
  interface = "all"
  bind = "0.0.0.0"
  port = 53
  ipv6 = false
  bogusPriv = true
  dnssec = false
  listeningMode = "all"
  queryLogging = true
  domainNeeded = true
  expandHosts = true

[webserver]
  port = 80
  bind = "0.0.0.0"
  ipv6 = false

[dhcp]
  active = false
  ipv6 = false

[api]
  key = ""

[misc]
  etc_pihole_dnsmasq = "/etc/dnsmasq.d/01-pihole.conf"
EOF
    fi
    
    # Configure dnsmasq to listen on all interfaces
    if [[ -f "/etc/dnsmasq.d/01-pihole.conf" ]]; then
        # Remove IPv6 servers
        sudo sed -i '/server=.*:.*#/d' /etc/dnsmasq.d/01-pihole.conf
        
        # Ensure correct upstream
        if ! grep -q "server=127.0.0.1#5335" /etc/dnsmasq.d/01-pihole.conf; then
            echo "server=127.0.0.1#5335" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
        fi
        
        # Ensure listening on all interfaces
        if ! grep -q "interface=" /etc/dnsmasq.d/01-pihole.conf; then
            echo "interface=eth0" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
            echo "bind-interfaces" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
            echo "listen-address=0.0.0.0" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
        fi
    fi
    
    log_message "Pi-hole network configuration complete"
}

# Step 3: Install and configure Unbound with Quad9 forwarding
install_configure_unbound() {
    log_message "Installing Unbound with Quad9 forwarding..."
    
    # Install Unbound
    sudo apt-get update -qq
    sudo apt-get install -y -qq unbound
    
    # Stop Unbound for configuration
    sudo systemctl stop unbound
    
    # Create forwarding configuration (not recursive)
    sudo mkdir -p /etc/unbound/unbound.conf.d
    sudo tee /etc/unbound/unbound.conf.d/pi-hole.conf > /dev/null <<'EOF'
server:
    # Network configuration
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    prefer-ip6: no
    
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
    cache-min-ttl: 300
    cache-max-ttl: 86400
    
    # Privacy settings
    hide-identity: yes
    hide-version: yes
    
    # Access control
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse

# Forward all queries to Quad9 (reliable in WSL)
forward-zone:
    name: "."
    forward-addr: 9.9.9.9        # Quad9 Primary
    forward-addr: 149.112.112.112 # Quad9 Secondary
    forward-addr: 1.1.1.1        # Cloudflare backup
    forward-addr: 1.0.0.1        # Cloudflare backup
EOF
    
    # Start Unbound
    sudo systemctl enable unbound
    sudo systemctl start unbound
    
    log_message "Unbound configured with Quad9 forwarding"
}

# Step 4: Disable conflicting services
disable_conflicts() {
    log_message "Disabling conflicting services..."
    
    # Disable systemd-resolved
    if systemctl is-active systemd-resolved &>/dev/null; then
        sudo systemctl stop systemd-resolved
        sudo systemctl disable systemd-resolved
    fi
    
    # Fix resolv.conf
    sudo rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
    sudo chattr +i /etc/resolv.conf
    
    # Disable IPv6 system-wide
    if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
        echo 'net.ipv6.conf.all.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
        echo 'net.ipv6.conf.default.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
        echo 'net.ipv6.conf.lo.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
        sudo sysctl -p >/dev/null 2>&1
    fi
    
    log_message "Conflicts resolved"
}

# Step 5: Start services in correct order
start_services() {
    log_message "Starting services..."
    
    # Stop all services first
    sudo systemctl stop pihole-FTL 2>/dev/null || true
    sudo systemctl stop unbound 2>/dev/null || true
    
    # Start Unbound first
    sudo systemctl start unbound
    sleep 3
    
    # Verify Unbound
    if ! dig @127.0.0.1 -p 5335 google.com +short &>/dev/null; then
        log_message "ERROR: Unbound not responding"
        return 1
    fi
    
    # Start Pi-hole
    sudo systemctl start pihole-FTL
    sleep 5
    
    log_message "Services started"
}

# Step 6: Verify complete chain
verify_dns_chain() {
    log_message "Verifying DNS chain..."
    
    echo "Testing DNS resolution chain:"
    
    # Test Unbound
    echo -n "1. Unbound (127.0.0.1:5335): "
    if dig @127.0.0.1 -p 5335 google.com +short &>/dev/null; then
        echo "✅ Working"
    else
        echo "❌ Failed"
        return 1
    fi
    
    # Test Pi-hole on localhost
    echo -n "2. Pi-hole localhost (127.0.0.1:53): "
    if dig @127.0.0.1 google.com +short &>/dev/null; then
        echo "✅ Working"
    else
        echo "❌ Failed"
        return 1
    fi
    
    # Test Pi-hole on WSL IP (critical for Windows)
    echo -n "3. Pi-hole WSL IP ($WSL_IP:53): "
    if dig @$WSL_IP google.com +short &>/dev/null; then
        echo "✅ Working"
    else
        echo "❌ Failed"
        return 1
    fi
    
    # Test network accessibility
    echo -n "4. Pi-hole accessible from network: "
    if nc -z -w2 $WSL_IP 53 2>/dev/null; then
        echo "✅ Yes"
    else
        echo "❌ No"
        return 1
    fi
    
    log_message "DNS chain verified successfully"
    return 0
}

# Main installation flow
main() {
    echo "🚀 Starting Pi-hole + Unbound installation with proper network configuration"
    echo "WSL IP: $WSL_IP"
    
    # Check prerequisites
    if [[ -z "$WSL_IP" ]]; then
        echo "ERROR: Cannot determine WSL IP"
        exit 1
    fi
    
    # Installation steps
    install_pihole
    configure_pihole_network
    install_configure_unbound
    disable_conflicts
    start_services
    
    # Verify everything works
    if verify_dns_chain; then
        echo ""
        echo "✅ Installation successful!"
        echo "📊 Pi-hole Dashboard: http://$WSL_IP/admin"
        echo "🌐 DNS Server: $WSL_IP"
        echo ""
        echo "The Windows app can now safely set DNS to $WSL_IP"
        exit 0
    else
        echo ""
        echo "❌ Installation completed but verification failed"
        echo "Check $SCRIPT_LOG for details"
        exit 1
    fi
}

# Run main
main "$@"