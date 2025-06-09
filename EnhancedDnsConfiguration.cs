using System;
using System.Diagnostics;
using System.Net.Sockets;
using System.Threading.Tasks;

namespace PifillCore
{
    public class EnhancedDnsConfiguration
    {
        /// <summary>
        /// Complete DNS configuration verification and setup
        /// </summary>
        public static async Task<bool> ConfigureAndVerifyDnsChain(string wslIp, string networkAdapter)
        {
            Debug.WriteLine($"Starting DNS chain configuration for WSL IP: {wslIp}");

            try
            {
                // Step 1: Verify Pi-hole is accessible from Windows
                if (!await VerifyPiholeAccessibility(wslIp))
                {
                    Debug.WriteLine("Pi-hole is not accessible from Windows");
                    return false;
                }

                // Step 2: Test DNS resolution through Pi-hole BEFORE changing Windows DNS
                if (!await TestDnsResolutionViaWsl(wslIp))
                {
                    Debug.WriteLine("DNS resolution through Pi-hole failed");
                    return false;
                }

                // Step 3: Save current DNS settings for rollback
                string[] originalDns = WindowsDNSManager.GetCurrentDnsServers(networkAdapter);
                Debug.WriteLine($"Original DNS servers: {string.Join(", ", originalDns)}");

                // Step 4: Configure Windows DNS
                Debug.WriteLine("Configuring Windows DNS...");
                WindowsDNSManager.SetDnsServers(networkAdapter, new[] { wslIp });

                // Step 5: Wait for DNS propagation
                await Task.Delay(3000);

                // Step 6: Verify Windows can resolve through new DNS
                if (!await VerifyWindowsDnsWorking(wslIp))
                {
                    Debug.WriteLine("Windows DNS verification failed, rolling back...");

                    // Rollback DNS settings
                    if (originalDns.Length > 0)
                    {
                        WindowsDNSManager.SetDnsServers(networkAdapter, originalDns);
                    }
                    else
                    {
                        WindowsDNSManager.RevertDnsToDhcp(networkAdapter);
                    }

                    return false;
                }

                Debug.WriteLine("DNS configuration successful!");
                return true;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"DNS configuration failed: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Verify Pi-hole is accessible on port 53 from Windows
        /// </summary>
        private static async Task<bool> VerifyPiholeAccessibility(string wslIp)
        {
            Debug.WriteLine($"Verifying Pi-hole accessibility at {wslIp}:53...");

            try
            {
                // Test 1: TCP connection to port 53
                using (var tcpClient = new TcpClient())
                {
                    var connectTask = tcpClient.ConnectAsync(wslIp, 53);
                    if (await Task.WhenAny(connectTask, Task.Delay(5000)) == connectTask)
                    {
                        Debug.WriteLine("✓ Port 53 is accessible");
                    }
                    else
                    {
                        Debug.WriteLine("✗ Port 53 connection timeout");
                        return false;
                    }
                }

                // Test 2: HTTP connection to Pi-hole admin
                using (var httpClient = new System.Net.Http.HttpClient())
                {
                    httpClient.Timeout = TimeSpan.FromSeconds(5);
                    try
                    {
                        var response = await httpClient.GetAsync($"http://{wslIp}/admin/");
                        if (response.IsSuccessStatusCode)
                        {
                            Debug.WriteLine("✓ Pi-hole web interface accessible");
                            return true;
                        }
                    }
                    catch
                    {
                        // Web interface might not be accessible, but DNS might still work
                    }
                }

                return true; // Port 53 accessible is enough
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Accessibility check failed: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Test DNS resolution through WSL Pi-hole
        /// </summary>
        private static async Task<bool> TestDnsResolutionViaWsl(string wslIp)
        {
            Debug.WriteLine($"Testing DNS resolution via {wslIp}...");

            return await Task.Run(() =>
            {
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo
                    {
                        FileName = "nslookup",
                        Arguments = $"google.com {wslIp}",
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    };

                    using (Process process = Process.Start(psi))
                    {
                        if (process == null) return false;

                        process.WaitForExit(10000);
                        string output = process.StandardOutput.ReadToEnd();
                        string error = process.StandardError.ReadToEnd();

                        bool success = process.ExitCode == 0 &&
                                      output.Contains("Address") &&
                                      !output.Contains("can't find") &&
                                      !output.Contains("timeout");

                        Debug.WriteLine($"DNS test result: {(success ? "SUCCESS" : "FAILED")}");
                        if (!success)
                        {
                            Debug.WriteLine($"Output: {output}");
                            Debug.WriteLine($"Error: {error}");
                        }

                        return success;
                    }
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"DNS resolution test failed: {ex.Message}");
                    return false;
                }
            });
        }

        /// <summary>
        /// Verify Windows DNS is working after configuration
        /// </summary>
        private static async Task<bool> VerifyWindowsDnsWorking(string expectedDnsServer)
        {
            Debug.WriteLine("Verifying Windows DNS configuration...");

            // Test 1: Check if DNS server is set correctly
            await Task.Run(() =>
            {
                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "ipconfig",
                    Arguments = "/all",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process != null)
                    {
                        process.WaitForExit(5000);
                        string output = process.StandardOutput.ReadToEnd();

                        if (output.Contains(expectedDnsServer))
                        {
                            Debug.WriteLine("✓ DNS server is set in Windows");
                        }
                        else
                        {
                            Debug.WriteLine("✗ DNS server not found in Windows config");
                        }
                    }
                }
            });

            // Test 2: Actual DNS resolution
            return await Task.Run(() =>
            {
                try
                {
                    // Test multiple domains to ensure it's working
                    string[] testDomains = { "google.com", "microsoft.com", "cloudflare.com" };
                    int successCount = 0;

                    foreach (var domain in testDomains)
                    {
                        ProcessStartInfo psi = new ProcessStartInfo
                        {
                            FileName = "nslookup",
                            Arguments = domain,
                            RedirectStandardOutput = true,
                            RedirectStandardError = true,
                            UseShellExecute = false,
                            CreateNoWindow = true
                        };

                        using (Process process = Process.Start(psi))
                        {
                            if (process == null) continue;

                            process.WaitForExit(5000);
                            if (process.ExitCode == 0)
                            {
                                successCount++;
                                Debug.WriteLine($"✓ Resolved {domain}");
                            }
                            else
                            {
                                Debug.WriteLine($"✗ Failed to resolve {domain}");
                            }
                        }
                    }

                    bool success = successCount >= 2; // At least 2 out of 3 should work
                    Debug.WriteLine($"DNS verification: {successCount}/3 domains resolved");
                    return success;
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"Windows DNS verification failed: {ex.Message}");
                    return false;
                }
            });
        }

        /// <summary>
        /// Run Pi-hole network fix if needed
        /// </summary>
        public static async Task<bool> FixPiholeNetworkBinding(string wslIp)
        {
            Debug.WriteLine("Attempting to fix Pi-hole network binding...");

            string fixScript = @"#!/bin/bash
# Quick fix for Pi-hole network binding

WSL_IP=$(hostname -I | awk '{print $1}')

# Stop Pi-hole
sudo systemctl stop pihole-FTL

# Update Pi-hole to listen on all interfaces
if [[ -f '/etc/pihole/pihole.toml' ]]; then
    sudo sed -i 's/interface = "".*""/interface = ""all""/' /etc/pihole/pihole.toml
    sudo sed -i 's/bind = "".*""/bind = ""0.0.0.0""/' /etc/pihole/pihole.toml
fi

# Update dnsmasq
if [[ -f '/etc/dnsmasq.d/01-pihole.conf' ]]; then
    if ! grep -q 'listen-address=0.0.0.0' /etc/dnsmasq.d/01-pihole.conf; then
        echo 'listen-address=0.0.0.0' | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
    fi
fi

# Start Pi-hole
sudo systemctl start pihole-FTL
sleep 5

# Test
if nc -z -w2 $WSL_IP 53; then
    echo 'SUCCESS'
else
    echo 'FAILED'
fi
";

            return await Task.Run(() =>
            {
                try
                {
                    // Write fix script to temp file
                    string tempScript = System.IO.Path.GetTempFileName();
                    System.IO.File.WriteAllText(tempScript, fixScript);

                    ProcessStartInfo psi = new ProcessStartInfo
                    {
                        FileName = "wsl.exe",
                        Arguments = $"-d Ubuntu -- bash -c \"cat > /tmp/fix_network.sh && chmod +x /tmp/fix_network.sh && /tmp/fix_network.sh\"",
                        RedirectStandardInput = true,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    };

                    using (Process process = Process.Start(psi))
                    {
                        if (process == null) return false;

                        // Write script to stdin
                        process.StandardInput.Write(fixScript);
                        process.StandardInput.Close();

                        process.WaitForExit(30000);
                        string output = process.StandardOutput.ReadToEnd();

                        bool success = output.Contains("SUCCESS");
                        Debug.WriteLine($"Network fix result: {(success ? "SUCCESS" : "FAILED")}");

                        return success;
                    }
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"Network fix failed: {ex.Message}");
                    return false;
                }
                finally
                {
                    // Cleanup temp file
                }
            });
        }
    }
}