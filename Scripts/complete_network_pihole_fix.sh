#!/bin/bash

# Complete Pi-hole Network Configuration Fix
# Ensures Pi-hole receives queries from Windows via WSL IP

echo "🔧 Complete Pi-hole Network Configuration Fix"
echo "=============================================="
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

log_msg "Starting comprehensive Pi-hole network fix..."

# Step 1: Stop all DNS services
echo ""
echo "🔧 Step 1: Stop conflicting services"
echo "------------------------------------"

log_msg "Stopping all DNS services..."
sudo systemctl stop pihole-FTL 2>/dev/null || true
sudo systemctl stop unbound 2>/dev/null || true
sudo systemctl stop systemd-resolved 2>/dev/null || true

# Disable systemd-resolved permanently
if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
    log_msg "Disabling systemd-resolved..."
    sudo systemctl disable systemd-resolved
    echo "✅ systemd-resolved disabled"
else
    echo "✅ systemd-resolved already disabled"
fi

# Step 2: Fix system DNS resolution
echo ""
echo "🔧 Step 2: Configure system DNS"
echo "-------------------------------"

log_msg "Configuring /etc/resolv.conf..."
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOF
# Fixed DNS configuration for WSL
nameserver 8.8.8.8
nameserver 1.1.1.1
search localdomain
EOF
sudo chattr +i /etc/resolv.conf  # Make immutable
echo "✅ System DNS configured and locked"

# Step 3: Configure Pi-hole for correct interface binding
echo ""
echo "🔧 Step 3: Configure Pi-hole interface binding"
echo "----------------------------------------------"

log_msg "Configuring Pi-hole to listen on all interfaces..."

# Pi-hole v6 configuration
if [[ -f "/etc/pihole/pihole.toml" ]]; then
    log_msg "Updating Pi-hole v6 configuration..."
    sudo cp /etc/pihole/pihole.toml /etc/pihole/pihole.toml.backup.$(date +%s)
    
    # Create optimized Pi-hole v6 configuration
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
    echo "✅ Pi-hole v6 configuration updated"

# Pi-hole v5 configuration (fallback)
elif [[ -f "/etc/pihole/setupVars.conf" ]]; then
    log_msg "Updating Pi-hole v5 configuration..."
    sudo cp /etc/pihole/setupVars.conf /etc/pihole/setupVars.conf.backup.$(date +%s)
    
    # Update setupVars for all interfaces
    sudo sed -i "s/PIHOLE_INTERFACE=.*/PIHOLE_INTERFACE=/" /etc/pihole/setupVars.conf
    sudo sed -i "s/PIHOLE_DNS_1=.*/PIHOLE_DNS_1=127.0.0.1#5335/" /etc/pihole/setupVars.conf
    sudo sed -i "s/PIHOLE_DNS_2=.*/PIHOLE_DNS_2=/" /etc/pihole/setupVars.conf
    sudo sed -i "s/IPV6_ADDRESS=.*/IPV6_ADDRESS=/" /etc/pihole/setupVars.conf
    echo "✅ Pi-hole v5 configuration updated"
else
    echo "❌ No Pi-hole configuration found!"
    exit 1
fi

# Step 4: Configure dnsmasq directly
echo ""
echo "🔧 Step 4: Configure dnsmasq for proper listening"
echo "-------------------------------------------------"

if [[ -f "/etc/dnsmasq.d/01-pihole.conf" ]]; then
    log_msg "Updating dnsmasq configuration..."
    sudo cp /etc/dnsmasq.d/01-pihole.conf /etc/dnsmasq.d/01-pihole.conf.backup.$(date +%s)
    
    # Remove IPv6 DNS servers
    sudo sed -i '/server=.*:.*#/d' /etc/dnsmasq.d/01-pihole.conf
    sudo sed -i '/server=2620:fe/d' /etc/dnsmasq.d/01-pihole.conf
    
    # Ensure only Unbound is upstream
    if ! grep -q "server=127.0.0.1#5335" /etc/dnsmasq.d/01-pihole.conf; then
        echo "server=127.0.0.1#5335" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
    fi
    
    # Configure to listen on all interfaces
    if ! grep -q "bind-interfaces" /etc/dnsmasq.d/01-pihole.conf; then
        echo "bind-interfaces" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
        echo "listen-address=0.0.0.0" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
    fi
    
    echo "✅ dnsmasq configuration updated"
else
    echo "⚠️ dnsmasq configuration not found"
fi

# Step 5: Configure Unbound for IPv4-only operation
echo ""
echo "🔧 Step 5: Configure Unbound (IPv4 only)"
echo "----------------------------------------"

log_msg "Updating Unbound configuration..."
sudo tee /etc/unbound/unbound.conf.d/pi-hole.conf > /dev/null <<'EOF'
server:
    # Basic configuration - IPv4 only
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
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    
    # Privacy settings
    hide-identity: yes
    hide-version: yes
    
    # Access control
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    
    # Root hints
    root-hints: "/var/lib/unbound/root.hints"
EOF

# Ensure root hints exist
if [[ ! -f "/var/lib/unbound/root.hints" ]]; then
    log_msg "Downloading root hints..."
    sudo mkdir -p /var/lib/unbound
    sudo curl -s -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache
    sudo chown unbound:unbound /var/lib/unbound/root.hints
fi

echo "✅ Unbound configuration updated"

# Step 6: Disable IPv6 system-wide
echo ""
echo "🔧 Step 6: Disable IPv6 system-wide"
echo "-----------------------------------"

log_msg "Disabling IPv6..."
if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.default.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.lo.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p >/dev/null 2>&1
    echo "✅ IPv6 disabled system-wide"
else
    echo "✅ IPv6 already disabled"
fi

# Step 7: Start services in correct order
echo ""
echo "🔧 Step 7: Start services in correct order"
echo "------------------------------------------"

log_msg "Starting Unbound..."
sudo systemctl enable unbound
sudo systemctl start unbound
sleep 3

if systemctl is-active unbound >/dev/null; then
    echo "✅ Unbound started successfully"
    test_dns "127.0.0.1" "google.com" "Unbound direct" "-p 5335"
else
    echo "❌ Unbound failed to start"
    sudo journalctl -u unbound --no-pager -n 5
    exit 1
fi

log_msg "Starting Pi-hole FTL..."
sudo systemctl enable pihole-FTL
sudo systemctl start pihole-FTL
sleep 5

if systemctl is-active pihole-FTL >/dev/null; then
    echo "✅ Pi-hole FTL started successfully"
else
    echo "❌ Pi-hole FTL failed to start"
    sudo journalctl -u pihole-FTL --no-pager -n 5
    exit 1
fi

# Step 8: Verify network configuration
echo ""
echo "🔧 Step 8: Verify network configuration"
echo "--------------------------------------"

log_msg "Verifying Pi-hole is listening on correct interfaces..."

echo "Pi-hole listening on:"
sudo netstat -ln 2>/dev/null | grep :53 | head -5 || ss -ln 2>/dev/null | grep :53 | head -5

echo ""
echo "Testing accessibility:"
echo -n "Pi-hole on localhost (127.0.0.1:53): "
if nc -z -w2 127.0.0.1 53 2>/dev/null; then
    echo "✅ Accessible"
else
    echo "❌ Not accessible"
fi

echo -n "Pi-hole on WSL IP ($WSL_IP:53): "
if nc -z -w2 $WSL_IP 53 2>/dev/null; then
    echo "✅ Accessible"
else
    echo "❌ Not accessible - This is the problem!"
fi

echo -n "Unbound on localhost (127.0.0.1:5335): "
if nc -z -w2 127.0.0.1 5335 2>/dev/null; then
    echo "✅ Accessible"
else
    echo "❌ Not accessible"
fi

# Step 9: Test DNS resolution chain
echo ""
echo "🔧 Step 9: Test complete DNS resolution chain"
echo "---------------------------------------------"

log_msg "Testing DNS resolution chain..."

echo "DNS Chain Test:"
echo "Windows -> Pi-hole ($WSL_IP) -> Unbound (127.0.0.1:5335) -> Internet"
echo ""

# Test each step
test_dns "127.0.0.1" "example.com" "Unbound direct" "-p 5335"
test_dns "127.0.0.1" "example.com" "Pi-hole localhost"
test_dns "$WSL_IP" "example.com" "Pi-hole WSL IP (what Windows uses)"

# Step 10: Test query logging
echo ""
echo "🔧 Step 10: Test query logging"
echo "------------------------------"

log_msg "Testing query logging..."

if command -v pihole >/dev/null; then
    before_count=$(pihole -c -j 2>/dev/null | jq -r '.dns_queries_today // "0"' 2>/dev/null || echo "0")
    echo "Queries before test: $before_count"
    
    # Perform test query to WSL IP (what Windows would do)
    dig @$WSL_IP test-query-$(date +%s).example.org +short >/dev/null 2>&1
    sleep 3
    
    after_count=$(pihole -c -j 2>/dev/null | jq -r '.dns_queries_today // "0"' 2>/dev/null || echo "0")
    echo "Queries after test: $after_count"
    
    if [[ "$after_count" -gt "$before_count" ]]; then
        echo "✅ Query logging is working!"
    else
        echo "❌ Queries not being logged - Pi-hole not receiving queries from WSL IP"
    fi
else
    echo "⚠️ Pi-hole command not available"
fi

# Step 11: Final verification and recommendations
echo ""
echo "🎯 Final Status and Recommendations"
echo "==================================="

echo ""
echo "Service Status:"
echo "- Unbound: $(systemctl is-active unbound 2>/dev/null || echo 'inactive')"
echo "- Pi-hole FTL: $(systemctl is-active pihole-FTL 2>/dev/null || echo 'inactive')"
echo ""

echo "Network Accessibility:"
echo -n "- Pi-hole accessible from WSL IP: "
if nc -z -w2 $WSL_IP 53 2>/dev/null; then
    echo "✅ YES - Windows can reach Pi-hole"
    network_ok=true
else
    echo "❌ NO - This is why Windows loses internet!"
    network_ok=false
fi

echo ""
if [[ "$network_ok" == "true" ]]; then
    echo "🎉 Network configuration is correct!"
    echo ""
    echo "📋 Next steps for your Windows app:"
    echo "1. Set Windows DNS to: $WSL_IP"
    echo "2. Clear Windows DNS cache: ipconfig /flushdns"
    echo "3. Disable browser DNS over HTTPS (DoH)"
    echo "4. Test with new websites (not cached ones)"
    echo ""
    echo "📊 Pi-hole Dashboard: http://$WSL_IP/admin"
else
    echo "❌ Network configuration still has issues!"
    echo ""
    echo "🔧 Additional troubleshooting needed:"
    echo "1. Check Pi-hole logs: sudo tail -f /var/log/pihole-FTL.log"
    echo "2. Verify Pi-hole interface binding"
    echo "3. Check firewall settings in WSL"
    echo "4. Consider Pi-hole reconfiguration"
fi

echo ""
echo "⚠️ Important Browser Settings:"
echo "- Chrome: Settings → Privacy → Security → Use secure DNS → OFF"
echo "- Firefox: Settings → Network Settings → DNS over HTTPS → OFF"
echo "- Edge: Settings → Privacy → Security → Use secure DNS → OFF"
echo ""

echo "✅ Network configuration fix completed!"
exit 0