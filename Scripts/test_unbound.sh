#!/bin/bash
#
# Unbound Comprehensive Diagnostic Script
# This script runs a series of checks to diagnose issues with the Unbound DNS resolver service
# configured for Pi-hole. It provides clear pass/fail results and recommendations.

# --- Configuration ---
UNBOUND_CONF="/etc/unbound/unbound.conf.d/pi-hole.conf"
UNBOUND_PORT="5335"
UNBOUND_IP="127.0.0.1"
TEST_DOMAIN="google.com"

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Globals ---
FAIL_COUNT=0

# --- Helper Functions ---
print_check() {
    printf "%-55s" "$1"
}

print_success() {
    echo -e "[${GREEN}✅ PASS${NC}]"
}

print_fail() {
    echo -e "[${RED}❌ FAIL${NC}]"
    ((FAIL_COUNT++))
}

# --- Diagnostic Functions ---

##
# 1. Checks if the unbound systemd service is active.
##
check_service_status() {
    print_check "1. Checking Unbound service status"
    if systemctl is-active --quiet unbound; then
        print_success
    else
        print_fail
        echo -e "${YELLOW}   -> Hint: The 'unbound' service is not running or has failed.${NC}"
        echo -e "${YELLOW}   -> Try restarting it with: sudo systemctl restart unbound${NC}"
        echo -e "${YELLOW}   -> To see detailed errors, check the logs with:${NC}"
        echo -e "${YELLOW}      sudo journalctl -u unbound --no-pager | tail -n 10${NC}"
        # Display the last few log lines for immediate context
        sudo journalctl -u unbound --no-pager | tail -n 10 | sed 's/^/      /g'
    fi
}

##
# 2. Validates the syntax of the Unbound configuration file.
##
check_config_syntax() {
    print_check "2. Validating Unbound configuration file syntax"
    if [ ! -f "$UNBOUND_CONF" ]; then
        print_fail
        echo -e "${YELLOW}   -> Error: Configuration file not found at ${UNBOUND_CONF}${NC}"
        echo -e "${YELLOW}   -> The Pi-hole/Unbound integration is not properly set up.${NC}"
        return
    fi

    if unbound-checkconf "$UNBOUND_CONF" &> /dev/null; then
        print_success
    else
        print_fail
        echo -e "${YELLOW}   -> Hint: The Unbound configuration file has syntax errors.${NC}"
        echo -e "${YELLOW}   -> The command 'unbound-checkconf ${UNBOUND_CONF}' failed:${NC}"
        # Show the actual error output from the command
        unbound-checkconf "$UNBOUND_CONF" 2>&1 | sed 's/^/      /g'
    fi
}

##
# 3. Verifies that Unbound is listening on the correct IP and port.
##
check_network_listener() {
    print_check "3. Checking network listener on ${UNBOUND_IP}:${UNBOUND_PORT}"
    # Use 'ss' as it is the modern replacement for 'netstat'
    if command -v ss &> /dev/null; then
        LISTENER_CMD="sudo ss -lunp"
    else
        LISTENER_CMD="sudo netstat -lunp"
    fi

    if $LISTENER_CMD | grep -q "unbound" | grep -q "${UNBOUND_IP}:${UNBOUND_PORT}"; then
        print_success
    else
        print_fail
        echo -e "${YELLOW}   -> Hint: Unbound is not listening on ${UNBOUND_IP}:${UNBOUND_PORT}.${NC}"
        echo -e "${YELLOW}   -> Check the 'interface' and 'port' settings in your config file.${NC}"
        echo -e "${YELLOW}   -> Current listeners for 'unbound':${NC}"
        $LISTENER_CMD | grep "unbound" | sed 's/^/      /g' || echo "      (No listeners found for unbound)"
    fi
}

##
# 4. Performs a simple, local query to see if the service responds.
##
test_local_resolution() {
    print_check "4. Testing local query response from Unbound"
    # This tests if the service is alive and can process a basic query.
    # The domain "pi-hole.net" is used as a neutral test target.
    if dig @${UNBOUND_IP} -p ${UNBOUND_PORT} pi-hole.net +time=2 +tries=1 &> /dev/null; then
        print_success
    else
        print_fail
        echo -e "${YELLOW}   -> Hint: Unbound is not responding to local queries.${NC}"
        echo -e "${YELLOW}   -> The service may have crashed, or a local firewall could be blocking it.${NC}"
    fi
}

##
# 5. Tests if Unbound can resolve an external domain via its upstream.
##
test_upstream_connectivity() {
    print_check "5. Testing upstream connectivity via Unbound"
    # This query must succeed for internet access to work via Pi-hole.
    RESPONSE=$(dig @${UNBOUND_IP} -p ${UNBOUND_PORT} ${TEST_DOMAIN} +time=4 +tries=1)

    if echo "$RESPONSE" | grep -q "status: NOERROR"; then
        print_success
        IP=$(echo "$RESPONSE" | awk '/^'${TEST_DOMAIN}'./ {print $5}' | head -n 1)
        echo -e "   -> Successfully resolved ${TEST_DOMAIN} to: ${GREEN}${IP}${NC}"
    else
        print_fail
        echo -e "${YELLOW}   -> Hint: Unbound FAILED to resolve an external domain.${NC}"
        echo -e "${YELLOW}   -> This is the most likely cause of your internet outage.${NC}"
        echo -e "${YELLOW}   -> It means Unbound cannot reach its upstream DNS (e.g., Quad9). Common causes:${NC}"
        echo -e "${YELLOW}      1. WSL itself has no internet. Check /etc/resolv.conf.${NC}"
        echo -e "${YELLOW}      2. A firewall is blocking outgoing traffic on UDP/TCP port 853 (DNS-over-TLS).${NC}"
    fi
}

##
# Prints a final summary of the diagnostic results.
##
print_summary() {
    echo -e "\n------------------------------------------------------"
    echo "               Diagnostic Summary"
    echo "------------------------------------------------------"
    if [ $FAIL_COUNT -eq 0 ]; then
        echo -e "${GREEN}✅ All checks passed! Unbound appears to be configured and working correctly.${NC}"
        echo -e "\n${YELLOW}Recommendation:${NC} If DNS still fails, the issue is likely outside of Unbound. Verify that:"
        echo "1. Pi-hole is configured to use only ${UNBOUND_IP}#${UNBOUND_PORT} as its upstream DNS server."
        echo "2. No other DNS servers are configured in Pi-hole."
    else
        echo -e "${RED}❌ Found ${FAIL_COUNT} issue(s). Unbound is likely misconfigured or not functioning correctly.${NC}"
        echo -e "\n${YELLOW}Recommendation:${NC} Review the [FAIL] messages above. The most critical failure is likely the root cause. Start by fixing the first error reported and run this script again."
    fi
    echo "------------------------------------------------------"
}

# --- Main Execution ---
main() {
    echo "======================================================"
    echo "      Unbound DNS Resolver Diagnostic Script"
    echo "======================================================"
    
    # Check for root privileges, as some commands require it
    if [[ $EUID -ne 0 ]]; then
       echo -e "\n${YELLOW}This script needs to run with sudo to check services and listeners.${NC}"
       echo "Please run it with: sudo $0"
       # exit 1 # Or attempt to re-run with sudo
    fi

    # Ensure necessary tools are installed before starting
    if ! command -v dig &> /dev/null; then
        echo -e "${RED}Error: 'dnsutils' (which provides 'dig') is not installed.${NC}"
        echo -e "${YELLOW}Please run 'sudo apt-get update && sudo apt-get install dnsutils' first.${NC}"
        exit 1
    fi

    # Run all diagnostic checks
    check_service_status
    check_config_syntax
    check_network_listener
    test_local_resolution
    test_upstream_connectivity
    
    # Provide the final summary
    print_summary
}

main