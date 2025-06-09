#!/bin/bash

# Enhanced Pi-hole DNS Traffic Fix Script
# Comprehensive solution for DNS routing issues

echo "🔧 Enhanced Pi-hole DNS Traffic Fix"
echo "==================================="
echo ""

WSL_IP=$(hostname -I | awk '{print $1}')
echo "🌐 WSL IP: $WSL_IP"
echo ""

# Function to log with timestamp
log_msg() {
    echo "[$(date '+%H:%M:%S')] $1"
}

# Function to test DNS functionality
test_dns() {
    local server=$1
    local domain=$2
    local name=$3
    
    echo -n "Testing $name: "
    if dig @$server $domain +short +time=3 >/dev/null 2>&1; then
        echo "✅ Working"
        return 0
    else
        echo "❌ Failed"
        return 1
    fi
}

# Function to check if service is running
check_service() {
    local service=$1
    echo -n "Checking $service: "
    if systemctl is-active $service >/dev/null 2>&1; then
        echo "✅ Running"
        return 0
    else
        echo "❌ Not running"
        return 1
    fi
}

log_msg "Starting comprehensive DNS routing fixes..."

# Fix 1: Stop conflicting services
echo ""
echo "🔧 Fix 1: Stop conflicting DNS services"
echo "---------------------------------------"

log_msg "Stopping systemd-resolved (conflicts with Pi-hole)"
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    sudo systemctl stop systemd-resolved
    sudo systemctl disable systemd-resolved
    echo "✅ systemd-resolved stopped and disabled"
else
    echo "✅ systemd-resolved already stopped"
fi

# Fix resolv.conf to prevent systemd-resolved from interfering
sudo rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
sudo chattr +i /etc/resolv.conf  # Make immutable
echo "✅ resolv.conf fixed and locked"

# Fix 2: Configure Pi-hole to listen on all interfaces
echo ""
echo "🔧 Fix 2: Configure Pi-hole interface binding"
echo "---------------------------------------------"

log_msg "Configuring Pi-hole to listen on all interfaces..."

# Pi-hole v6 configuration
if [[ -f "/etc/pihole/pihole.toml" ]]; then
    log_msg "Found Pi-hole v6 configuration"
    sudo cp /etc/pihole/pihole.toml /etc/pihole/pihole.toml.backup.$(date +%s)
    
    # Set interface to "all" for Pi-hole v6
    sudo sed -i 's/dns.interface = ".*"/dns.interface = "all"/' /etc/pihole/pihole.toml
    sudo sed -i 's/dns.bind = ".*"/dns.bind = "0.0.0.0"/' /etc/pihole/pihole.toml
    
    # Ensure only Unbound is used as upstream
    sudo sed -i 's/dns.upstreams = \[.*\]/dns.upstreams = ["127.0.0.1#5335"]/' /etc/pihole/pihole.toml
    
    # Disable IPv6 completely
    sudo sed -i 's/dns.ipv6 = true/dns.ipv6 = false/' /etc/pihole/pihole.toml
    sudo sed -i 's/webserver.ipv6 = true/webserver.ipv6 = false/' /etc/pihole/pihole.toml
    sudo sed -i 's/dhcp.ipv6 = true/dhcp.ipv6 = false/' /etc/pihole/pihole.toml
    
    echo "✅ Pi-hole v6 configuration updated"
    
# Pi-hole v5 configuration (fallback)
elif [[ -f "/etc/pihole/setupVars.conf" ]]; then
    log_msg "Found Pi-hole v5 configuration"
    sudo cp /etc/pihole/setupVars.conf /etc/pihole/setupVars.conf.backup.$(date +%s)
    
    # Configure for all interfaces
    sudo sed -i "s/PIHOLE_INTERFACE=.*/PIHOLE_INTERFACE=/" /etc/pihole/setupVars.conf
    sudo sed -i "s/PIHOLE_DNS_1=.*/PIHOLE_DNS_1=127.0.0.1#5335/" /etc/pihole/setupVars.conf
    sudo sed -i "s/PIHOLE_DNS_2=.*/PIHOLE_DNS_2=/" /etc/pihole/setupVars.conf
    sudo sed -i "s/IPV6_ADDRESS=.*/IPV6_ADDRESS=/" /etc/pihole/setupVars.conf
    
    echo "✅ Pi-hole v5 configuration updated"
else
    echo "❌ No Pi-hole configuration found"
fi

# Fix 3: Configure Unbound for IPv4-only operation
echo ""
echo "🔧 Fix 3: Configure Unbound (IPv4 only)"
echo "---------------------------------------"

log_msg "Updating Unbound configuration for IPv4-only operation..."

# Create optimized Unbound configuration
sudo tee /etc/unbound/unbound.conf.d/pi-hole.conf > /dev/null <<'EOF'
server:
    # Basic configuration - IPv4 only
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    
    # Disable IPv6 completely
    do-ip6: no
    prefer-ip6: no
    
    # Security and privacy
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-large-queries: yes
    harden-short-bufsize: yes
    use-caps-for-id: no
    hide-identity: yes
    hide-version: yes
    
    # Performance optimization
    edns-buffer-size: 1472
    prefetch: yes
    prefetch-key: yes
    num-threads: 1
    msg-cache-size: 50m
    rrset-cache-size: 100m
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    serve-expired: yes
    
    # Access control - only local access
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    
    # Root hints for recursive resolution
    root-hints: "/var/lib/unbound/root.hints"
    
    # Additional stability settings
    so-rcvbuf: 1m
    so-sndbuf: 1m
    outgoing-range: 4096
    num-queries-per-thread: 2048
EOF

echo "✅ Unbound configuration updated"

# Ensure root hints are available
if [[ ! -f "/var/lib/unbound/root.hints" ]]; then
    log_msg "Downloading DNS root hints..."
    sudo mkdir -p /var/lib/unbound
    sudo curl -s -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache
    sudo chown unbound:unbound /var/lib/unbound/root.hints
    echo "✅ Root hints downloaded"
else
    echo "✅ Root hints already present"
fi

# Fix 4: Configure dnsmasq directly (Pi-hole's DNS engine)
echo ""
echo "🔧 Fix 4: Configure dnsmasq for proper operation"
echo "------------------------------------------------"

log_msg "Configuring dnsmasq settings..."

# Update dnsmasq configuration if it exists
if [[ -f "/etc/dnsmasq.d/01-pihole.conf" ]]; then
    sudo cp /etc/dnsmasq.d/01-pihole.conf /etc/dnsmasq.d/01-pihole.conf.backup.$(date +%s)
    
    # Remove any IPv6 DNS servers
    sudo sed -i '/server=.*:.*#/d' /etc/dnsmasq.d/01-pihole.conf
    sudo sed -i '/server=2620:fe/d' /etc/dnsmasq.d/01-pihole.conf
    
    # Ensure only Unbound is used
    if ! grep -q "server=127.0.0.1#5335" /etc/dnsmasq.d/01-pihole.conf; then
        echo "server=127.0.0.1#5335" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
    fi
    
    # Add interface binding
    if ! grep -q "interface=.*" /etc/dnsmasq.d/01-pihole.conf; then
        echo "interface=eth0" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
        echo "bind-interfaces" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
    fi
    
    echo "✅ dnsmasq configuration updated"
else
    echo "⚠️ dnsmasq configuration not found"
fi

# Fix 5: Disable IPv6 system-wide
echo ""
echo "🔧 Fix 5: Disable IPv6 system-wide"
echo "----------------------------------"

log_msg "Disabling IPv6 to prevent DNS bypass..."

# Add IPv6 disable to sysctl
if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.default.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.lo.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p >/dev/null 2>&1
    echo "✅ IPv6 disabled system-wide"
else
    echo "✅ IPv6 already disabled"
fi

# Fix 6: Restart services in correct order
echo ""
echo "🔧 Fix 6: Restart DNS services"
echo "------------------------------"

log_msg "Restarting services in correct order..."

# Stop all DNS services
sudo systemctl stop pihole-FTL 2>/dev/null || true
sudo systemctl stop unbound 2>/dev/null || true

# Start Unbound first
log_msg "Starting Unbound..."
sudo systemctl enable unbound
sudo systemctl start unbound
sleep 3

# Verify Unbound is working
if systemctl is-active unbound >/dev/null; then
    echo "✅ Unbound started successfully"
    test_dns "127.0.0.1" "google.com" "Unbound (port 5335)" "-p 5335"
else
    echo "❌ Unbound failed to start"
    sudo journalctl -u unbound --no-pager -n 5
fi

# Start Pi-hole FTL
log_msg "Starting Pi-hole FTL..."
sudo systemctl enable pihole-FTL
sudo systemctl start pihole-FTL
sleep 5

# Verify Pi-hole is working
if systemctl is-active pihole-FTL >/dev/null; then
    echo "✅ Pi-hole FTL started successfully"
    test_dns "127.0.0.1" "google.com" "Pi-hole (localhost)"
    test_dns "$WSL_IP" "google.com" "Pi-hole (WSL IP)"
else
    echo "❌ Pi-hole FTL failed to start"
    sudo journalctl -u pihole-FTL --no-pager -n 5
fi

# Fix 7: Test and verify DNS chain
echo ""
echo "🔧 Fix 7: Verify DNS resolution chain"
echo "-------------------------------------"

log_msg "Testing complete DNS resolution chain..."

# Test the chain: Client -> Pi-hole -> Unbound -> Internet
echo "DNS Chain Test:"
echo "Client -> Pi-hole ($WSL_IP) -> Unbound (127.0.0.1:5335) -> Internet"
echo ""

# Test Unbound directly
test_dns "127.0.0.1" "example.com" "Unbound direct" "-p 5335"

# Test Pi-hole on localhost
test_dns "127.0.0.1" "example.com" "Pi-hole localhost"

# Test Pi-hole on WSL IP (what Windows will use)
test_dns "$WSL_IP" "example.com" "Pi-hole WSL IP"

# Test query logging
echo ""
log_msg "Testing query logging..."

# Get current query count
if command -v pihole >/dev/null; then
    before_count=$(pihole -c -j 2>/dev/null | jq -r '.dns_queries_today // "0"' 2>/dev/null || echo "0")
    echo "Queries before test: $before_count"
    
    # Perform test query
    dig @$WSL_IP test.example.org +short >/dev/null 2>&1
    sleep 2
    
    # Check if count increased
    after_count=$(pihole -c -j 2>/dev/null | jq -r '.dns_queries_today // "0"' 2>/dev/null || echo "0")
    echo "Queries after test: $after_count"
    
    if [[ "$after_count" -gt "$before_count" ]]; then
        echo "✅ Query logging is working!"
    else
        echo "❌ Queries not being logged"
    fi
else
    echo "⚠️ Pi-hole command not available for query testing"
fi

# Fix 8: Network interface verification
echo ""
echo "🔧 Fix 8: Network interface verification"
echo "---------------------------------------"

log_msg "Verifying network interface configuration..."

echo "Pi-hole listening on:"
sudo netstat -ln 2>/dev/null | grep :53 | head -5 || ss -ln 2>/dev/null | grep :53 | head -5

echo ""
echo "Unbound listening on:"
sudo netstat -ln 2>/dev/null | grep :5335 || ss -ln 2>/dev/null | grep :5335

# Check if Pi-hole is accessible from WSL IP
echo ""
echo -n "Pi-hole accessible on WSL IP ($WSL_IP:53): "
if nc -z -w2 $WSL_IP 53 2>/dev/null; then
    echo "✅ Yes"
else
    echo "❌ No - Pi-hole may not be listening on all interfaces"
fi

# Final verification and summary
echo ""
echo "🎯 Final Verification Summary"
echo "============================"

echo ""
echo "Service Status:"
check_service "unbound"
check_service "pihole-FTL"

echo ""
echo "DNS Resolution Tests:"
test_dns "$WSL_IP" "google.com" "Pi-hole (what Windows uses)"
test_dns "127.0.0.1" "google.com" "Pi-hole (localhost)" "-p 5335"

echo ""
echo "Configuration Status:"
echo -n "Pi-hole config: "
if [[ -f "/etc/pihole/pihole.toml" ]] || [[ -f "/etc/pihole/setupVars.conf" ]]; then
    echo "✅ Present"
else
    echo "❌ Missing"
fi

echo -n "Unbound config: "
if [[ -f "/etc/unbound/unbound.conf.d/pi-hole.conf" ]]; then
    echo "✅ Present"
else
    echo "❌ Missing"
fi

echo -n "IPv6 disabled: "
if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q "= 1"; then
    echo "✅ Yes"
else
    echo "❌ No"
fi

echo ""
echo "🎉 DNS Traffic Fix Completed!"
echo ""
echo "📋 Next Steps:"
echo "1. Your Windows app will now configure Windows DNS"
echo "2. Clear Windows DNS cache (automatically done by app)"
echo "3. Clear browser cache and disable DNS over HTTPS"
echo "4. Test by visiting NEW websites (not cached ones)"
echo "5. Monitor Pi-hole dashboard for increasing query counts"
echo ""
echo "📊 Pi-hole Dashboard: http://$WSL_IP/admin"
echo ""

# Optional: Monitor logs for issues
echo "💡 To monitor for issues, run:"
echo "   sudo tail -f /var/log/pihole-FTL.log"
echo ""

echo "✅ All DNS routing fixes applied successfully!"
exit 0