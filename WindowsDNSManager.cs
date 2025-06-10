using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net.NetworkInformation;
using System.Text;
using System.Text.RegularExpressions;

namespace PifillCore
{
    public static class WindowsDNSManager
    {
        public static void SetDnsServers(string adapterName, string[] dnsServers)
        {
            if (string.IsNullOrWhiteSpace(adapterName))
            {
                throw new ArgumentException("Adapter name cannot be empty.", nameof(adapterName));
            }
            if (dnsServers == null || dnsServers.Length == 0 || string.IsNullOrWhiteSpace(dnsServers[0]))
            {
                throw new ArgumentException("At least one DNS server must be specified.", nameof(dnsServers));
            }

            string primaryDns = dnsServers[0];

            // IMPORTANT: Remove ALL IPv6 DNS servers first to prevent bypass
            RemoveAllIPv6DnsServers(adapterName);

            // Set IPv4 DNS
            string arguments = $"interface ipv4 set dnsservers name=\"{adapterName}\" static {primaryDns} primary validate=no";
            ExecuteNetshCommand(arguments);

            if (dnsServers.Length > 1 && !string.IsNullOrWhiteSpace(dnsServers[1]))
            {
                string secondaryDns = dnsServers[1];
                arguments = $"interface ipv4 add dnsservers name=\"{adapterName}\" address={secondaryDns} index=2 validate=no";
                ExecuteNetshCommand(arguments);
            }

            // Clear DNS cache to force new lookups
            ClearDNSCache();
        }

        /// <summary>
        /// Remove ALL IPv6 DNS servers to force IPv4-only DNS resolution
        /// </summary>
        private static void RemoveAllIPv6DnsServers(string adapterName)
        {
            try
            {
                Debug.WriteLine($"Removing all IPv6 DNS servers from adapter: {adapterName}");

                // Method 1: Delete all IPv6 DNS servers
                try
                {
                    string arguments = $"interface ipv6 delete dnsservers \"{adapterName}\" all";
                    ExecuteNetshCommand(arguments);
                    Debug.WriteLine("Successfully removed all IPv6 DNS servers");
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"Failed to delete IPv6 DNS servers: {ex.Message}");

                    // Method 2: Reset IPv6 DNS to automatic/DHCP then disable
                    try
                    {
                        string arguments = $"interface ipv6 set dnsservers \"{adapterName}\" source=dhcp";
                        ExecuteNetshCommand(arguments);
                        Debug.WriteLine("Reset IPv6 DNS to DHCP");

                        // Then try to set to none/static with no servers
                        arguments = $"interface ipv6 set dnsservers \"{adapterName}\" static none";
                        ExecuteNetshCommand(arguments);
                    }
                    catch
                    {
                        Debug.WriteLine("Failed to reset IPv6 DNS");
                    }
                }

                // Method 3: Disable IPv6 DNS resolution by setting to invalid address
                // This is a more aggressive approach if the above doesn't work
                try
                {
                    // Set to an invalid/unreachable IPv6 address to effectively disable it
                    string arguments = $"interface ipv6 set dnsservers \"{adapterName}\" static ::0 validate=no";
                    ExecuteNetshCommand(arguments);
                    Debug.WriteLine("Set IPv6 DNS to null address");
                }
                catch
                {
                    Debug.WriteLine("Could not set IPv6 DNS to null address");
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"IPv6 DNS removal failed completely: {ex.Message}");
                // Continue anyway - IPv4 DNS should still work
            }
        }

        public static void RevertDnsToDhcp(string adapterName)
        {
            if (string.IsNullOrWhiteSpace(adapterName))
            {
                throw new ArgumentException("Adapter name cannot be empty.", nameof(adapterName));
            }

            // Revert IPv4 DNS
            string arguments = $"interface ipv4 set dnsservers name=\"{adapterName}\" source=dhcp";
            ExecuteNetshCommand(arguments);

            // Revert IPv6 DNS
            arguments = $"interface ipv6 set dnsservers name=\"{adapterName}\" source=dhcp";
            ExecuteNetshCommand(arguments);

            // Clear DNS cache
            ClearDNSCache();
        }

        /// <summary>
        /// Creates netsh portproxy rules to forward traffic from the host to the WSL instance.
        /// </summary>
        /// <param name="wslIp">The IP address of the WSL instance.</param>
        public static void CreatePortForwardingRules(string wslIp)
        {
            if (string.IsNullOrWhiteSpace(wslIp))
            {
                throw new ArgumentException("WSL IP address cannot be empty.", nameof(wslIp));
            }

            Debug.WriteLine($"Creating port forwarding rules to target WSL IP: {wslIp}");

            // Forward DNS TCP Port 53 for DNS lookups
            ExecuteNetshCommand($"interface portproxy add v4tov4 listenport=53 listenaddress=0.0.0.0 protocol=tcp connectport=53 connectaddress={wslIp}");

            // Forward Web UI Port 80 for Pi-hole admin dashboard
            ExecuteNetshCommand($"interface portproxy add v4tov4 listenport=80 listenaddress=0.0.0.0 protocol=tcp connectport=80 connectaddress={wslIp}");

            Debug.WriteLine("Successfully created port forwarding rules for DNS and Web UI.");
        }

        /// <summary>
        /// Removes all netsh portproxy rules.
        /// </summary>
        public static void RemovePortForwardingRules()
        {
            Debug.WriteLine("Resetting all netsh port forwarding rules...");
            ExecuteNetshCommand("interface portproxy reset");
            Debug.WriteLine("Port forwarding rules have been reset.");
        }

        /// <summary>
        /// Creates Windows Firewall rules to allow inbound traffic to Pi-hole.
        /// </summary>
        public static void CreateFirewallRules()
        {
            Debug.WriteLine("Creating Windows Firewall rules for Pi-hole...");

            ExecuteNetshCommand("advfirewall firewall add rule name=\"PiHoleDNS-TCP\" dir=in action=allow protocol=TCP localport=53");
            ExecuteNetshCommand("advfirewall firewall add rule name=\"PiHoleDNS-UDP\" dir=in action=allow protocol=UDP localport=53");
            ExecuteNetshCommand("advfirewall firewall add rule name=\"PiHoleWeb-TCP\" dir=in action=allow protocol=TCP localport=80");

            Debug.WriteLine("Firewall rules created successfully.");
        }

        /// <summary>
        /// Removes the Windows Firewall rules created for Pi-hole.
        /// </summary>
        public static void RemoveFirewallRules()
        {
            Debug.WriteLine("Removing Windows Firewall rules for Pi-hole...");

            // Use try-catch for each rule in case it doesn't exist, to prevent crashing.
            try { ExecuteNetshCommand("advfirewall firewall delete rule name=\"PiHoleDNS-TCP\""); }
            catch (Exception ex) { Debug.WriteLine("Could not remove 'PiHoleDNS-TCP' rule (may not exist). Error: " + ex.Message); }

            try { ExecuteNetshCommand("advfirewall firewall delete rule name=\"PiHoleDNS-UDP\""); }
            catch (Exception ex) { Debug.WriteLine("Could not remove 'PiHoleDNS-UDP' rule (may not exist). Error: " + ex.Message); }

            try { ExecuteNetshCommand("advfirewall firewall delete rule name=\"PiHoleWeb-TCP\""); }
            catch (Exception ex) { Debug.WriteLine("Could not remove 'PiHoleWeb-TCP' rule (may not exist). Error: " + ex.Message); }

            Debug.WriteLine("Firewall rules removal process completed.");
        }

        /// <summary>
        /// Clear Windows DNS cache to force new lookups
        /// </summary>
        public static void ClearDNSCache()
        {
            try
            {
                Debug.WriteLine("Clearing Windows DNS cache...");

                ProcessStartInfo psi = new ProcessStartInfo("ipconfig", "/flushdns")
                {
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process != null)
                    {
                        string output = process.StandardOutput.ReadToEnd() ?? string.Empty;
                        process.WaitForExit();
                        Debug.WriteLine($"DNS cache flush result: {output}");
                    }
                }

                // Also register DNS
                psi.Arguments = "/registerdns";
                using (Process process = Process.Start(psi))
                {
                    if (process != null)
                    {
                        process.WaitForExit(10000); // 10 second timeout
                        Debug.WriteLine("DNS registration completed");
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"DNS cache clear failed: {ex.Message}");
            }
        }

        /// <summary>
        /// Get current DNS servers for both IPv4 and IPv6
        /// </summary>
        /// <param name="adapterName">Network adapter name</param>
        /// <returns>Array of current DNS servers</returns>
        public static string[] GetCurrentDnsServers(string adapterName)
        {
            if (string.IsNullOrWhiteSpace(adapterName))
            {
                Debug.WriteLine("WindowsDNSManager.GetCurrentDnsServers: Adapter name is null or empty.");
                return Array.Empty<string>();
            }

            List<string> dnsServers = new List<string>();

            try
            {
                // Get IPv4 DNS servers
                var ipv4Servers = GetDnsServers(adapterName, "ipv4");
                dnsServers.AddRange(ipv4Servers);

                // Get IPv6 DNS servers
                var ipv6Servers = GetDnsServers(adapterName, "ipv6");
                dnsServers.AddRange(ipv6Servers);

                Debug.WriteLine($"Found DNS servers for {adapterName}: {string.Join(", ", dnsServers)}");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"WindowsDNSManager.GetCurrentDnsServers: Error getting current DNS for '{adapterName}': {ex.Message}");
                return Array.Empty<string>();
            }

            return dnsServers.ToArray();
        }

        /// <summary>
        /// Get DNS servers for specific IP version
        /// </summary>
        private static List<string> GetDnsServers(string adapterName, string ipVersion)
        {
            List<string> dnsServers = new List<string>();

            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("netsh", $"interface {ipVersion} show dnsservers \"{adapterName}\"")
                {
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    Verb = "runas",
                    StandardOutputEncoding = Encoding.UTF8
                };

                using (Process process = Process.Start(psi))
                {
                    if (process == null)
                    {
                        Debug.WriteLine($"Failed to start netsh process for {ipVersion} DNS on adapter '{adapterName}'.");
                        return dnsServers;
                    }

                    string output = process.StandardOutput.ReadToEnd() ?? string.Empty;
                    process.WaitForExit();

                    // Parse static DNS servers
                    var staticDnsBlockMatch = Regex.Match(output, @"(?:Statically Configured DNS Servers|DNS Servers):\s*\r?\n((?:\s*[\d\.:a-fA-F]+\s*\r?\n)+)");
                    if (staticDnsBlockMatch.Success)
                    {
                        var ipPattern = ipVersion == "ipv4" ? @"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}" : @"[\da-fA-F]*:[\da-fA-F:]*";
                        var ips = Regex.Matches(staticDnsBlockMatch.Groups[1].Value, ipPattern);
                        foreach (Match ipMatch in ips)
                        {
                            dnsServers.Add(ipMatch.Value);
                        }
                    }

                    // If no static DNS, check DHCP DNS
                    if (!dnsServers.Any())
                    {
                        var dhcpPattern = ipVersion == "ipv4"
                            ? @"DNS server(?:s)? configured through DHCP:\s+(\d{1,3}(?:\.\d{1,3}){3}(?:\s*\(Preferred\))?)"
                            : @"DNS server(?:s)? configured through DHCP:\s+([\da-fA-F]*:[\da-fA-F:]*)";

                        Match dhcpMatch = Regex.Match(output, dhcpPattern);
                        if (dhcpMatch.Success && dhcpMatch.Groups.Count > 1 && !dhcpMatch.Groups[1].Value.Equals("None", StringComparison.OrdinalIgnoreCase))
                        {
                            var ipPattern = ipVersion == "ipv4" ? @"\d{1,3}(?:\.\d{1,3}){3}" : @"[\da-fA-F]*:[\da-fA-F:]*";
                            var ipOnlyMatch = Regex.Match(dhcpMatch.Groups[1].Value, ipPattern);
                            if (ipOnlyMatch.Success)
                            {
                                dnsServers.Add(ipOnlyMatch.Value);
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Error getting {ipVersion} DNS servers for '{adapterName}': {ex.Message}");
            }

            return dnsServers;
        }

        /// <summary>
        /// Verify DNS configuration is working properly
        /// </summary>
        /// <param name="adapterName">Network adapter name</param>
        /// <param name="expectedDnsServer">Expected DNS server IP</param>
        /// <returns>True if DNS is configured correctly</returns>
        public static bool VerifyDnsConfiguration(string adapterName, string expectedDnsServer)
        {
            try
            {
                Debug.WriteLine($"Verifying DNS configuration for {adapterName}...");

                var currentServers = GetCurrentDnsServers(adapterName);

                // Check if Pi-hole is the ONLY IPv4 DNS server
                var ipv4Servers = currentServers.Where(s => !s.Contains(":")).ToArray();
                var ipv6Servers = currentServers.Where(s => s.Contains(":")).ToArray();

                bool hasExpectedServer = ipv4Servers.Contains(expectedDnsServer);
                bool hasOnlyExpectedServer = ipv4Servers.Length == 1 && ipv4Servers[0] == expectedDnsServer;
                bool hasNoIpv6Servers = ipv6Servers.Length == 0;

                Debug.WriteLine($"Expected DNS server: {expectedDnsServer}");
                Debug.WriteLine($"Current IPv4 DNS servers: {string.Join(", ", ipv4Servers)}");
                Debug.WriteLine($"Current IPv6 DNS servers: {string.Join(", ", ipv6Servers)}");
                Debug.WriteLine($"Configuration correct: {hasOnlyExpectedServer && hasNoIpv6Servers}");

                return hasExpectedServer; // Return true if Pi-hole is at least present
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"DNS verification failed: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Test DNS resolution to verify it's working
        /// </summary>
        /// <param name="dnsServer">DNS server to test</param>
        /// <param name="domain">Domain to resolve</param>
        /// <returns>True if DNS resolution works</returns>
        public static bool TestDnsResolution(string dnsServer, string domain = "google.com")
        {
            try
            {
                Debug.WriteLine($"Testing DNS resolution: {domain} via {dnsServer}");

                ProcessStartInfo psi = new ProcessStartInfo("nslookup", $"{domain} {dnsServer}")
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process == null) return false;

                    process.WaitForExit(5000); // 5 second timeout
                    string output = process.StandardOutput.ReadToEnd();
                    string error = process.StandardError.ReadToEnd();

                    bool success = process.ExitCode == 0 &&
                                  output.Contains("Address") &&
                                  !output.Contains("can't find") &&
                                  !output.Contains("Non-existent");

                    Debug.WriteLine($"DNS test result: {(success ? "SUCCESS" : "FAILED")}");
                    if (!success)
                    {
                        Debug.WriteLine($"DNS test output: {output}");
                        Debug.WriteLine($"DNS test error: {error}");
                    }

                    return success;
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"DNS resolution test failed: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Get detailed network adapter information
        /// </summary>
        /// <param name="adapterName">Network adapter name</param>
        /// <returns>Network adapter details</returns>
        public static string GetAdapterInfo(string adapterName)
        {
            try
            {
                var nic = NetworkInterface.GetAllNetworkInterfaces()
                    .FirstOrDefault(n => n.Name.Equals(adapterName, StringComparison.OrdinalIgnoreCase));

                if (nic == null) return "Adapter not found";

                var properties = nic.GetIPProperties();
                var sb = new StringBuilder();

                sb.AppendLine($"Adapter: {nic.Name}");
                sb.AppendLine($"Type: {nic.NetworkInterfaceType}");
                sb.AppendLine($"Status: {nic.OperationalStatus}");
                sb.AppendLine($"Speed: {nic.Speed / 1_000_000} Mbps");

                // IPv4 addresses
                var ipv4Addresses = properties.UnicastAddresses
                    .Where(addr => addr.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                    .Select(addr => addr.Address.ToString());
                sb.AppendLine($"IPv4 Addresses: {string.Join(", ", ipv4Addresses)}");

                // DNS servers
                var dnsAddresses = properties.DnsAddresses.Select(addr => addr.ToString());
                sb.AppendLine($"DNS Servers: {string.Join(", ", dnsAddresses)}");

                // Gateway
                var gateways = properties.GatewayAddresses.Select(gw => gw.Address.ToString());
                sb.AppendLine($"Gateways: {string.Join(", ", gateways)}");

                return sb.ToString();
            }
            catch (Exception ex)
            {
                return $"Error getting adapter info: {ex.Message}";
            }
        }

        private static void ExecuteNetshCommand(string arguments)
        {
            ProcessStartInfo psi = new ProcessStartInfo("netsh", arguments)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                Verb = "runas"
            };

            try
            {
                using (Process process = Process.Start(psi))
                {
                    if (process == null)
                    {
                        throw new Exception("Failed to start netsh process. Ensure it can be run with admin rights.");
                    }

                    string output = process.StandardOutput.ReadToEnd() ?? string.Empty;
                    string error = process.StandardError.ReadToEnd() ?? string.Empty;
                    process.WaitForExit();

                    if (process.ExitCode != 0)
                    {
                        string errorMessage = $"Netsh command failed (Exit Code: {process.ExitCode}) with arguments: {arguments}";
                        if (!string.IsNullOrWhiteSpace(error))
                        {
                            errorMessage += $"\nSTDERR: {error}";
                        }
                        if (!string.IsNullOrWhiteSpace(output))
                        {
                            errorMessage += $"\nSTDOUT: {output}";
                        }
                        throw new Exception(errorMessage);
                    }
                    Debug.WriteLine($"Netsh command successful: netsh {arguments}\nOutput: {output}");
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"WindowsDNSManager.ExecuteNetshCommand: Exception - {ex.Message} for arguments: {arguments}");
                throw new Exception($"Failed to execute netsh command: '{arguments}'. Ensure the application is run as Administrator. Details: {ex.Message}", ex);
            }
        }
    }
}