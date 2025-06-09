#!/bin/bash

# Pi-hole DNS Traffic Troubleshooting Script
# This script diagnoses why Pi-hole isn't receiving DNS queries

echo "🔍 Pi-hole DNS Traffic Diagnostic"
echo "================================="
echo ""

# Function to test DNS resolution
test_dns() {
    local server=$1
    local domain=$2
    local name=$3
    
    echo -n "Testing DNS via $name ($server): "
    if result=$(dig @$server $domain +short +time=2 2>/dev/null); then
        if [[ -n "$result" ]]; then
            echo "✅ Working - resolved to: $result"
            return 0
        else
            echo "❌ No response"
            return 1
        fi
    else
        echo "❌ Failed/Timeout"
        return 1
    fi
}

# Function to check if port is listening
check_port() {
    local ip=$1
    local port=$2
    local name=$3
    
    echo -n "Checking if $name is listening on $ip:$port: "
    if nc -z -w2 $ip $port 2>/dev/null; then
        echo "✅ Listening"
        return 0
    else
        echo "❌ Not listening"
        return 1
    fi
}

# Get WSL IP
WSL_IP=$(hostname -I | awk '{print $1}')
echo "🌐 WSL IP Address: $WSL_IP"
echo ""

# 1. Check Pi-hole service status
echo "📋 Service Status Check:"
echo "------------------------"
if systemctl is-active pihole-FTL >/dev/null 2>&1; then
    echo "✅ Pi-hole FTL service: Running"
else
    echo "❌ Pi-hole FTL service: Not running"
fi

if systemctl is-active unbound >/dev/null 2>&1; then
    echo "✅ Unbound service: Running"
else
    echo "❌ Unbound service: Not running"
fi
echo ""

# 2. Check what Pi-hole is listening on
echo "🔌 Network Listening Check:"
echo "---------------------------"
echo "Pi-hole FTL listening on:"
netstat -ln | grep :53 | head -5

echo ""
echo "All processes listening on port 53:"
lsof -i :53 2>/dev/null || ss -ln | grep :53
echo ""

# 3. Check DNS port accessibility
echo "🔍 DNS Port Accessibility:"
echo "--------------------------"
check_port "127.0.0.1" 53 "Pi-hole on localhost"
check_port "$WSL_IP" 53 "Pi-hole on WSL IP"
check_port "127.0.0.1" 5335 "Unbound"
echo ""

# 4. Test DNS resolution from different sources
echo "🧪 DNS Resolution Tests:"
echo "------------------------"
test_dns "127.0.0.1" "google.com" "Pi-hole (localhost)"
test_dns "$WSL_IP" "google.com" "Pi-hole (WSL IP)"
test_dns "127.0.0.1" "google.com" "Pi-hole port 53 explicit"
test_dns "8.8.8.8" "google.com" "Google DNS (baseline)"
echo ""

# 5. Check Pi-hole configuration
echo "⚙️ Pi-hole Configuration:"
echo "-------------------------"
if [[ -f "/etc/pihole/pihole.toml" ]]; then
    echo "Pi-hole v6 configuration found:"
    grep -E "(interface|port|dns\.)" /etc/pihole/pihole.toml | head -10
elif [[ -f "/etc/pihole/setupVars.conf" ]]; then
    echo "Pi-hole v5 configuration found:"
    grep -E "(INTERFACE|DNS)" /etc/pihole/setupVars.conf
else
    echo "❌ No Pi-hole configuration found"
fi
echo ""

# 6. Check what interface Pi-hole should use
echo "🌍 Network Interface Information:"
echo "---------------------------------"
echo "Available network interfaces:"
ip addr show | grep -E "(inet |^\d+:)" | grep -v "127.0.0.1"
echo ""

# 7. Check if systemd-resolved is interfering
echo "🔄 Systemd-resolved Check:"
echo "--------------------------"
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    echo "⚠️ systemd-resolved is running (may conflict)"
    echo "Current resolv.conf:"
    cat /etc/resolv.conf
else
    echo "✅ systemd-resolved is not running"
fi
echo ""

# 8. Test actual DNS query logging
echo "📝 DNS Query Test:"
echo "------------------"
echo "Testing if Pi-hole logs queries..."
echo "Current query count before test:"
if command -v pihole >/dev/null; then
    pihole -c -j | jq -r '.dns_queries_today // "unknown"' 2>/dev/null || echo "unknown"
else
    echo "unknown"
fi

echo ""
echo "Performing test DNS query..."
dig @$WSL_IP example.com >/dev/null 2>&1
sleep 2

echo "Query count after test:"
if command -v pihole >/dev/null; then
    pihole -c -j | jq -r '.dns_queries_today // "unknown"' 2>/dev/null || echo "unknown"
else
    echo "unknown"
fi
echo ""

# 9. Check recent Pi-hole logs
echo "📜 Recent Pi-hole Activity:"
echo "---------------------------"
if [[ -f "/var/log/pihole.log" ]]; then
    echo "Last 5 DNS queries in Pi-hole log:"
    tail -5 /var/log/pihole.log 2>/dev/null || echo "No recent queries found"
else
    echo "Pi-hole log file not found"
fi
echo ""

# 10. Provide specific fixes based on findings
echo "🔧 Recommended Fixes:"
echo "--------------------"

# Check if Pi-hole is listening on the right interface
if ! nc -z -w2 $WSL_IP 53 2>/dev/null; then
    echo "❌ ISSUE: Pi-hole is not listening on WSL IP ($WSL_IP)"
    echo "   Fix: Run 'sudo pihole reconfigure' and set interface to 'all interfaces'"
    echo ""
fi

# Check if systemd-resolved is interfering
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    echo "⚠️ ISSUE: systemd-resolved may be interfering"
    echo "   Fix: sudo systemctl disable systemd-resolved"
    echo "   Fix: sudo systemctl stop systemd-resolved"
    echo ""
fi

# Check if we can query Pi-hole at all
if ! dig @127.0.0.1 google.com +short >/dev/null 2>&1; then
    echo "❌ ISSUE: Pi-hole not responding to DNS queries on localhost"
    echo "   Fix: sudo systemctl restart pihole-FTL"
    echo ""
fi

echo "💡 Additional Tips:"
echo "- Disable browser DNS over HTTPS (DoH) in Chrome/Firefox settings"
echo "- Clear Windows DNS cache: ipconfig /flushdns"
echo "- Clear browser DNS cache: chrome://net-internals/#dns"
echo "- Test with: nslookup google.com $WSL_IP"
echo ""

echo "Run this script again after applying fixes to verify!"