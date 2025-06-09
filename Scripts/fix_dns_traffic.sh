#!/bin/bash

# Pi-hole DNS Traffic Fix Script
# Fixes common issues preventing DNS traffic from reaching Pi-hole

echo "🔧 Pi-hole DNS Traffic Fix"
echo "=========================="
echo ""

WSL_IP=$(hostname -I | awk '{print $1}')
echo "WSL IP: $WSL_IP"
echo ""

# Function to restart services properly
restart_pihole() {
    echo "🔄 Restarting Pi-hole services..."
    sudo systemctl stop pihole-FTL
    sleep 2
    sudo systemctl start pihole-FTL
    sleep 3
    
    if systemctl is-active pihole-FTL >/dev/null; then
        echo "✅ Pi-hole FTL restarted successfully"
    else
        echo "❌ Pi-hole FTL failed to restart"
        return 1
    fi
}

# Fix 1: Configure Pi-hole to listen on all interfaces
echo "🔧 Fix 1: Configure Pi-hole interface binding"
echo "----------------------------------------------"

if [[ -f "/etc/pihole/pihole.toml" ]]; then
    # Pi-hole v6 configuration
    echo "Configuring Pi-hole v6 to listen on all interfaces..."
    
    # Backup the config
    sudo cp /etc/pihole/pihole.toml /etc/pihole/pihole.toml.backup
    
    # Update the interface binding to listen on all interfaces
    sudo sed -i 's/dns.interface = ".*"/dns.interface = "all"/' /etc/pihole/pihole.toml
    
    # Also ensure it's listening on the right IP
    sudo sed -i "s/dns.bind = \".*\"/dns.bind = \"0.0.0.0\"/" /etc/pihole/pihole.toml
    
    echo "✅ Pi-hole v6 configuration updated"
    
elif [[ -f "/etc/pihole/setupVars.conf" ]]; then
    # Pi-hole v5 configuration
    echo "Configuring Pi-hole v5 interface..."
    
    sudo sed -i "s/PIHOLE_INTERFACE=.*/PIHOLE_INTERFACE=/" /etc/pihole/setupVars.conf
    echo "✅ Pi-hole v5 configuration updated"
else
    echo "❌ No Pi-hole configuration found"
fi

# Fix 2: Disable systemd-resolved if it's interfering
echo ""
echo "🔧 Fix 2: Handle systemd-resolved conflicts"
echo "-------------------------------------------"

if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    echo "systemd-resolved is running, disabling to prevent conflicts..."
    sudo systemctl stop systemd-resolved
    sudo systemctl disable systemd-resolved
    
    # Fix resolv.conf
    sudo rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
    sudo chattr +i /etc/resolv.conf  # Make it immutable
    
    echo "✅ systemd-resolved disabled"
else
    echo "✅ systemd-resolved not running"
fi

# Fix 3: Ensure Unbound is properly configured and started
echo ""
echo "🔧 Fix 3: Verify Unbound configuration"
echo "--------------------------------------"

if systemctl is-active unbound >/dev/null 2>&1; then
    echo "✅ Unbound is running"
else
    echo "Starting Unbound..."
    sudo systemctl start unbound
    if systemctl is-active unbound >/dev/null 2>&1; then
        echo "✅ Unbound started successfully"
    else
        echo "❌ Failed to start Unbound"
    fi
fi

# Fix 4: Configure Pi-hole to use correct upstream DNS
echo ""
echo "🔧 Fix 4: Configure upstream DNS"
echo "--------------------------------"

if command -v pihole >/dev/null; then
    echo "Setting Pi-hole to use Unbound as upstream..."
    sudo pihole -a -d 127.0.0.1#5335 >/dev/null 2>&1
    echo "✅ Upstream DNS configured"
fi

# Fix 5: Restart Pi-hole with new configuration
echo ""
echo "🔧 Fix 5: Restart Pi-hole services"
echo "----------------------------------"

restart_pihole

# Fix 6: Test and verify the fixes
echo ""
echo "🧪 Fix 6: Verify DNS functionality"
echo "----------------------------------"

echo "Testing DNS resolution..."

# Test localhost
echo -n "Testing Pi-hole on localhost: "
if dig @127.0.0.1 google.com +short +time=3 >/dev/null 2>&1; then
    echo "✅ Working"
else
    echo "❌ Failed"
fi

# Test WSL IP
echo -n "Testing Pi-hole on WSL IP: "
if dig @$WSL_IP google.com +short +time=3 >/dev/null 2>&1; then
    echo "✅ Working"
else
    echo "❌ Failed"
fi

# Test query logging
echo ""
echo "Testing query logging..."
before_count=$(pihole -c -j 2>/dev/null | jq -r '.dns_queries_today // "0"' 2>/dev/null || echo "0")
echo "Queries before test: $before_count"

# Perform test query
dig @$WSL_IP example.com >/dev/null 2>&1
sleep 2

after_count=$(pihole -c -j 2>/dev/null | jq -r '.dns_queries_today // "0"' 2>/dev/null || echo "0")
echo "Queries after test: $after_count"

if [[ "$after_count" -gt "$before_count" ]]; then
    echo "✅ Query logging is working!"
else
    echo "❌ Queries are not being logged"
fi

# Fix 7: Windows-specific DNS cache clearing instructions
echo ""
echo "🔧 Fix 7: Windows DNS cache (run these commands in Windows)"
echo "-----------------------------------------------------------"
echo "1. Open Command Prompt as Administrator"
echo "2. Run: ipconfig /flushdns"
echo "3. Run: ipconfig /registerdns"
echo "4. Restart your browser"
echo ""

# Fix 8: Browser DNS over HTTPS (DoH) instructions
echo "🔧 Fix 8: Disable DNS over HTTPS in browsers"
echo "---------------------------------------------"
echo "Chrome: Go to Settings > Privacy > Security > Use secure DNS > Off"
echo "Firefox: Go to Settings > Network Settings > DNS over HTTPS > Off"
echo "Edge: Go to Settings > Privacy > Security > Use secure DNS > Off"
echo ""

# Final verification
echo "🎯 Final Verification"
echo "====================="
echo ""
echo "Service Status:"
echo "- Pi-hole FTL: $(systemctl is-active pihole-FTL 2>/dev/null || echo 'inactive')"
echo "- Unbound: $(systemctl is-active unbound 2>/dev/null || echo 'inactive')"
echo ""

echo "Network Status:"
echo -n "- Pi-hole listening on $WSL_IP:53: "
if nc -z -w2 $WSL_IP 53 2>/dev/null; then
    echo "✅ Yes"
else
    echo "❌ No"
fi

echo -n "- Unbound listening on 127.0.0.1:5335: "
if nc -z -w2 127.0.0.1 5335 2>/dev/null; then
    echo "✅ Yes"
else
    echo "❌ No"
fi

echo ""
echo "🎉 Fix script completed!"
echo ""
echo "Next steps:"
echo "1. Go back to your Windows app and click 'Stop Protection' then 'Start Protection'"
echo "2. Clear Windows DNS cache (ipconfig /flushdns)"
echo "3. Clear browser cache and disable DoH"
echo "4. Visit YouTube or Gmail to test"
echo ""
echo "If queries still don't appear, the issue is likely browser DoH or Windows DNS caching."