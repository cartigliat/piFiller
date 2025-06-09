#!/bin/bash

# Fix Pi-hole IPv6 DNS Issue
# This script disables IPv6 DNS and ensures Pi-hole only uses Unbound

echo "🔧 Fixing Pi-hole IPv6 DNS Issue"
echo "================================="
echo ""

# Function to restart Pi-hole
restart_pihole() {
    echo "🔄 Restarting Pi-hole..."
    sudo systemctl stop pihole-FTL
    sleep 3
    sudo systemctl start pihole-FTL
    sleep 5
    
    if systemctl is-active pihole-FTL >/dev/null; then
        echo "✅ Pi-hole restarted successfully"
    else
        echo "❌ Pi-hole restart failed"
        return 1
    fi
}

# Fix 1: Configure Pi-hole to use only IPv4 Unbound
echo "🔧 Fix 1: Configure Pi-hole upstream DNS"
echo "----------------------------------------"

# Clear any existing upstream DNS servers and set only Unbound
if command -v pihole >/dev/null; then
    echo "Setting Pi-hole to use only Unbound (IPv4)..."
    
    # Method 1: Try the direct command approach
    sudo pihole -a -d 127.0.0.1#5335 >/dev/null 2>&1
    
    # Method 2: Edit the configuration file directly for Pi-hole v6
    if [[ -f "/etc/pihole/pihole.toml" ]]; then
        echo "Updating Pi-hole v6 configuration..."
        sudo cp /etc/pihole/pihole.toml /etc/pihole/pihole.toml.backup
        
        # Set upstream DNS to only use Unbound
        sudo sed -i 's/dns.upstreams = \[.*\]/dns.upstreams = ["127.0.0.1#5335"]/' /etc/pihole/pihole.toml
        
        # Disable IPv6
        sudo sed -i 's/dns.ipv6 = true/dns.ipv6 = false/' /etc/pihole/pihole.toml
        sudo sed -i 's/dhcp.ipv6 = true/dhcp.ipv6 = false/' /etc/pihole/pihole.toml
        
        echo "✅ Pi-hole v6 configuration updated"
    fi
    
    # Method 3: Edit setupVars.conf if it exists (Pi-hole v5 fallback)
    if [[ -f "/etc/pihole/setupVars.conf" ]]; then
        echo "Updating Pi-hole v5 configuration..."
        sudo cp /etc/pihole/setupVars.conf /etc/pihole/setupVars.conf.backup
        
        sudo sed -i 's/PIHOLE_DNS_1=.*/PIHOLE_DNS_1=127.0.0.1#5335/' /etc/pihole/setupVars.conf
        sudo sed -i 's/PIHOLE_DNS_2=.*/PIHOLE_DNS_2=/' /etc/pihole/setupVars.conf
        sudo sed -i 's/IPV6_ADDRESS=.*/IPV6_ADDRESS=/' /etc/pihole/setupVars.conf
        
        echo "✅ Pi-hole v5 configuration updated"
    fi
    
else
    echo "❌ Pi-hole command not found"
fi

# Fix 2: Disable IPv6 in the system
echo ""
echo "🔧 Fix 2: Disable IPv6 in WSL"
echo "-----------------------------"

# Disable IPv6 in sysctl
echo "Disabling IPv6 system-wide..."
echo 'net.ipv6.conf.all.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf >/dev/null
echo 'net.ipv6.conf.default.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf >/dev/null
echo 'net.ipv6.conf.lo.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf >/dev/null

# Apply the changes
sudo sysctl -p >/dev/null 2>&1

echo "✅ IPv6 disabled in system"

# Fix 3: Update Unbound configuration to be IPv4 only
echo ""
echo "🔧 Fix 3: Configure Unbound for IPv4 only"
echo "-----------------------------------------"

if [[ -f "/etc/unbound/unbound.conf.d/pi-hole.conf" ]]; then
    echo "Updating Unbound configuration..."
    sudo cp /etc/unbound/unbound.conf.d/pi-hole.conf /etc/unbound/unbound.conf.d/pi-hole.conf.backup
    
    # Create a clean IPv4-only Unbound configuration
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
    
    # Access control - IPv4 only
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    
    # Root hints
    root-hints: "/var/lib/unbound/root.hints"
    
    # Force IPv4 only for outgoing queries
    do-not-query-localhost: no
    outgoing-interface: 0.0.0.0
EOF
    
    echo "✅ Unbound configured for IPv4 only"
else
    echo "❌ Unbound configuration file not found"
fi

# Fix 4: Restart services in correct order
echo ""
echo "🔧 Fix 4: Restart services"
echo "--------------------------"

# Restart Unbound first
echo "Restarting Unbound..."
sudo systemctl restart unbound
if systemctl is-active unbound >/dev/null; then
    echo "✅ Unbound restarted successfully"
else
    echo "❌ Unbound restart failed"
fi

# Test Unbound
echo -n "Testing Unbound: "
if dig @127.0.0.1 -p 5335 google.com +short >/dev/null 2>&1; then
    echo "✅ Working"
else
    echo "❌ Failed"
fi

# Restart Pi-hole
restart_pihole

# Fix 5: Verify the configuration
echo ""
echo "🔧 Fix 5: Verify configuration"
echo "------------------------------"

echo "Current Pi-hole upstream DNS configuration:"
if [[ -f "/etc/pihole/pihole.toml" ]]; then
    sudo grep -E "dns.upstreams|ipv6" /etc/pihole/pihole.toml 2>/dev/null || echo "Could not read configuration"
fi

echo ""
echo "Testing DNS resolution through Pi-hole:"
WSL_IP=$(hostname -I | awk '{print $1}')

# Test with query logging
before_count=$(pihole -c -j 2>/dev/null | jq -r '.dns_queries_today // "0"' 2>/dev/null || echo "0")
echo "Queries before test: $before_count"

echo "Performing test query..."
dig @$WSL_IP example.org +short >/dev/null 2>&1
sleep 3

after_count=$(pihole -c -j 2>/dev/null | jq -r '.dns_queries_today // "0"' 2>/dev/null || echo "0")
echo "Queries after test: $after_count"

if [[ "$after_count" -gt "$before_count" ]]; then
    echo "✅ Query logging is working!"
else
    echo "❌ Queries still not being logged"
fi

# Fix 6: Check for IPv6 errors in Pi-hole logs
echo ""
echo "🔧 Fix 6: Check for remaining IPv6 errors"
echo "-----------------------------------------"

echo "Checking recent Pi-hole logs for IPv6 errors..."
if [[ -f "/var/log/pihole-FTL.log" ]]; then
    recent_ipv6_errors=$(sudo tail -20 /var/log/pihole-FTL.log | grep -i "ipv6\|2620:fe" | wc -l)
    if [[ "$recent_ipv6_errors" -eq 0 ]]; then
        echo "✅ No recent IPv6 errors found"
    else
        echo "⚠️ Still some IPv6 errors in logs"
        sudo tail -10 /var/log/pihole-FTL.log | grep -i "ipv6\|2620:fe" || echo "None in last 10 lines"
    fi
else
    echo "Pi-hole log file not found"
fi

echo ""
echo "🎉 IPv6 fix completed!"
echo ""
echo "Next steps:"
echo "1. Go to your Windows app and restart protection (Stop → Start)"
echo "2. Wait 30 seconds for changes to take effect"
echo "3. Try visiting new websites in your browser"
echo "4. Check if Pi-hole query count increases"
echo ""
echo "If issues persist, run: sudo tail -f /var/log/pihole-FTL.log"
echo "to monitor for any remaining connection errors."