using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace PifillCore
{
    public static class WSLManager
    {
        private static readonly int DefaultTimeoutMs = 30000;

        public static string? GetWslIpAddress(string distributionName)
        {
            WriteDetailedLog("=== IMPROVED WSL IP DETECTION ===");

            try
            {
                // Method 1: Direct hostname -I command (most reliable)
                string? directIp = GetWslIpDirect(distributionName);
                if (!string.IsNullOrEmpty(directIp))
                {
                    WriteDetailedLog($"Found WSL IP via direct method: {directIp}");
                    return directIp;
                }

                // Method 2: Try to find WSL network interfaces directly
                string? networkIp = GetWslIpFromNetworkInterfaces();
                if (!string.IsNullOrEmpty(networkIp))
                {
                    WriteDetailedLog($"Found WSL IP via network interfaces: {networkIp}");
                    return networkIp;
                }

                // Method 3: Try PowerShell instead of WSL command
                string? powershellIp = GetWslIpViaPowerShell(distributionName);
                if (!string.IsNullOrEmpty(powershellIp))
                {
                    WriteDetailedLog($"Found WSL IP via PowerShell: {powershellIp}");
                    return powershellIp;
                }

                // Method 4: Scan for Pi-hole specifically
                string? piholeIp = FindPiholeIp();
                if (!string.IsNullOrEmpty(piholeIp))
                {
                    WriteDetailedLog($"Found Pi-hole IP via scanning: {piholeIp}");
                    return piholeIp;
                }

                WriteDetailedLog("All IP detection methods failed");
                return null;
            }
            catch (Exception ex)
            {
                WriteDetailedLog($"Exception in IP detection: {ex.Message}");
                return null;
            }
        }

        /// <summary>
        /// Method 1: Direct hostname -I command - most reliable
        /// </summary>
        private static string? GetWslIpDirect(string distributionName)
        {
            try
            {
                WriteDetailedLog("Trying direct hostname -I method...");

                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d {distributionName} -- hostname -I",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process == null) return null;

                    process.WaitForExit(DefaultTimeoutMs);
                    string output = process.StandardOutput.ReadToEnd().Trim();
                    string error = process.StandardError.ReadToEnd().Trim();

                    WriteDetailedLog($"Direct method output: '{output}'");
                    if (!string.IsNullOrEmpty(error))
                    {
                        WriteDetailedLog($"Direct method error: '{error}'");
                    }

                    if (!string.IsNullOrWhiteSpace(output))
                    {
                        // hostname -I can return multiple IPs, take the first one
                        var firstIp = output.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)[0];

                        if (System.Net.IPAddress.TryParse(firstIp, out var addr))
                        {
                            WriteDetailedLog($"Valid IP found: {firstIp}");
                            return firstIp;
                        }
                    }
                }

                return null;
            }
            catch (Exception ex)
            {
                WriteDetailedLog($"Direct method failed: {ex.Message}");
                return null;
            }
        }

        /// <summary>
        /// Method 2: Scan network interfaces for WSL adapters
        /// </summary>
        private static string? GetWslIpFromNetworkInterfaces()
        {
            try
            {
                WriteDetailedLog("Scanning network interfaces for WSL...");

                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    WriteDetailedLog($"Checking interface: {nic.Name} - {nic.Description}");

                    // Look for WSL-related network interfaces
                    if (nic.Name.Contains("WSL", StringComparison.OrdinalIgnoreCase) ||
                        nic.Description.Contains("WSL", StringComparison.OrdinalIgnoreCase) ||
                        nic.Description.Contains("vEthernet", StringComparison.OrdinalIgnoreCase))
                    {
                        var ipProps = nic.GetIPProperties();
                        foreach (var addr in ipProps.UnicastAddresses)
                        {
                            if (addr.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                            {
                                string ip = addr.Address.ToString();
                                WriteDetailedLog($"Found potential WSL IP on {nic.Name}: {ip}");

                                // Check if it's in a typical WSL range
                                if (IsTypicalWslIp(ip))
                                {
                                    return ip;
                                }
                            }
                        }
                    }
                }

                WriteDetailedLog("No WSL network interfaces found");
                return null;
            }
            catch (Exception ex)
            {
                WriteDetailedLog($"Error scanning network interfaces: {ex.Message}");
                return null;
            }
        }

        /// <summary>
        /// Method 3: Use PowerShell to get WSL IP
        /// </summary>
        private static string? GetWslIpViaPowerShell(string distributionName)
        {
            try
            {
                WriteDetailedLog("Trying PowerShell approach...");

                string powershellScript = $@"
                    try {{
                        $result = wsl -d {distributionName} -- hostname -I
                        Write-Output $result
                    }} catch {{
                        Write-Output 'ERROR: ' + $_.Exception.Message
                    }}
                ";

                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-Command \"{powershellScript}\"",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process == null) return null;

                    process.WaitForExit(DefaultTimeoutMs);
                    string output = process.StandardOutput.ReadToEnd().Trim();

                    WriteDetailedLog($"PowerShell output: '{output}'");

                    if (!string.IsNullOrWhiteSpace(output) && !output.StartsWith("ERROR:"))
                    {
                        var ipMatch = Regex.Match(output, @"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b");
                        if (ipMatch.Success)
                        {
                            return ipMatch.Value;
                        }
                    }
                }

                return null;
            }
            catch (Exception ex)
            {
                WriteDetailedLog($"PowerShell method failed: {ex.Message}");
                return null;
            }
        }

        /// <summary>
        /// Method 4: Scan common ranges but verify Pi-hole is actually running
        /// </summary>
        private static string? FindPiholeIp()
        {
            WriteDetailedLog("Scanning for Pi-hole specifically...");

            // Known good IP from your working installation
            string[] candidateIps = {
                "172.24.2.95",  // Your working IP
                "172.24.0.1",   // The incorrect one your app found
                "172.20.0.1",
                "172.21.0.1",
                "172.22.0.1",
                "172.23.0.1",
                "172.24.0.2",
                "172.24.2.1"
            };

            foreach (string ip in candidateIps)
            {
                WriteDetailedLog($"Testing IP: {ip}");

                if (TestPiholeConnection(ip))
                {
                    WriteDetailedLog($"Found working Pi-hole at: {ip}");
                    return ip;
                }
            }

            // If specific IPs don't work, scan the 172.24.2.x range (your working range)
            WriteDetailedLog("Scanning 172.24.2.x range...");
            for (int i = 1; i < 255; i++)
            {
                string testIp = $"172.24.2.{i}";
                if (TestPiholeConnection(testIp))
                {
                    WriteDetailedLog($"Found working Pi-hole via scanning: {testIp}");
                    return testIp;
                }
            }

            return null;
        }

        /// <summary>
        /// Test if an IP has Pi-hole running (not just ping)
        /// </summary>
        private static bool TestPiholeConnection(string ip)
        {
            try
            {
                using (var client = new System.Net.Http.HttpClient())
                {
                    client.Timeout = TimeSpan.FromSeconds(2);

                    // Test if Pi-hole admin interface is accessible
                    var task = client.GetAsync($"http://{ip}/admin/");
                    task.Wait(2000);

                    if (task.Result.IsSuccessStatusCode)
                    {
                        WriteDetailedLog($"Pi-hole admin interface accessible at {ip}");
                        return true;
                    }

                    // Also test the API endpoint
                    var apiTask = client.GetAsync($"http://{ip}/admin/api.php");
                    apiTask.Wait(2000);

                    if (apiTask.Result.IsSuccessStatusCode)
                    {
                        WriteDetailedLog($"Pi-hole API accessible at {ip}");
                        return true;
                    }
                }
            }
            catch (Exception ex)
            {
                WriteDetailedLog($"Connection test failed for {ip}: {ex.Message}");
            }

            return false;
        }

        /// <summary>
        /// Check if an IP is in typical WSL ranges
        /// </summary>
        private static bool IsTypicalWslIp(string ip)
        {
            if (!System.Net.IPAddress.TryParse(ip, out var addr))
                return false;

            byte[] bytes = addr.GetAddressBytes();

            // Typical WSL ranges
            return (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) || // 172.16-31.x.x
                   (bytes[0] == 192 && bytes[1] == 168) ||                   // 192.168.x.x
                   (bytes[0] == 10);                                         // 10.x.x.x
        }

        /// <summary>
        /// Enhanced command execution with detailed logging
        /// </summary>
        public static async Task<string> ExecuteWslCommandAsync(string distributionName, string command)
        {
            WriteDetailedLog($"=== EXECUTING WSL COMMAND ===");
            WriteDetailedLog($"Distribution: {distributionName}");
            WriteDetailedLog($"Command: {command}");

            try
            {
                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d {distributionName} -- {command}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System)
                };

                WriteDetailedLog($"Process: {psi.FileName}");
                WriteDetailedLog($"Arguments: {psi.Arguments}");
                WriteDetailedLog($"Working Directory: {psi.WorkingDirectory}");

                using (Process process = Process.Start(psi))
                {
                    if (process == null)
                    {
                        WriteDetailedLog("ERROR: Failed to start process");
                        return "ERROR: Failed to start process";
                    }

                    WriteDetailedLog("Process started, waiting for completion...");

                    // Set up async reading
                    Task<string> outputTask = process.StandardOutput.ReadToEndAsync();
                    Task<string> errorTask = process.StandardError.ReadToEndAsync();

                    // Wait for process with timeout
                    bool finished = process.WaitForExit(300000); // 5 minutes timeout

                    if (!finished)
                    {
                        WriteDetailedLog("ERROR: Process timed out after 5 minutes");
                        process.Kill();
                        return "ERROR: Process timed out";
                    }

                    string output = await outputTask;
                    string error = await errorTask;

                    WriteDetailedLog($"Process exit code: {process.ExitCode}");
                    WriteDetailedLog($"Output length: {output?.Length ?? 0} characters");
                    WriteDetailedLog($"Error length: {error?.Length ?? 0} characters");

                    if (!string.IsNullOrEmpty(output))
                    {
                        WriteDetailedLog($"STDOUT: {output.Substring(0, Math.Min(500, output.Length))}");
                    }

                    if (!string.IsNullOrEmpty(error))
                    {
                        WriteDetailedLog($"STDERR: {error.Substring(0, Math.Min(500, error.Length))}");
                        return $"Error: {error}";
                    }

                    WriteDetailedLog("Command completed successfully");
                    return output ?? string.Empty;
                }
            }
            catch (Exception ex)
            {
                WriteDetailedLog($"Exception in ExecuteWslCommandAsync: {ex.Message}");
                WriteDetailedLog($"Stack trace: {ex.StackTrace}");
                return $"Exception: {ex.Message}";
            }
        }

        /// <summary>
        /// Simple synchronous command execution for compatibility
        /// </summary>
        public static string ExecuteWslCommand(string distributionName, string command)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d {distributionName} -- {command}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process == null) return "Failed to start process";

                    process.WaitForExit(DefaultTimeoutMs);
                    string output = process.StandardOutput.ReadToEnd();
                    string error = process.StandardError.ReadToEnd();

                    if (!string.IsNullOrEmpty(error))
                    {
                        WriteDetailedLog($"WSL command error: {error}");
                        return $"Error: {error}";
                    }

                    return output;
                }
            }
            catch (Exception ex)
            {
                WriteDetailedLog($"WSL command execution failed: {ex.Message}");
                return $"Exception: {ex.Message}";
            }
        }

        private static void WriteDetailedLog(string message)
        {
            Debug.WriteLine($"[WSL-ALT] {message}");
            Console.WriteLine($"[WSL-ALT] {message}");

            try
            {
                string logPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), "pifill_wsl_debug.log");
                File.AppendAllText(logPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [ALT] {message}\n");
            }
            catch
            {
                // Ignore file write errors
            }
        }

        // Async wrappers
        public static async Task<string?> GetWslIpAddressAsync(string distributionName, int maxRetries = 3)
        {
            return await Task.Run(() => GetWslIpAddress(distributionName));
        }

        public static async Task<bool> EnsureDistributionRunningAsync(string distributionName)
        {
            return await Task.Run(() => {
                // Try to get IP - if we can get it, WSL is running
                string? ip = GetWslIpAddress(distributionName);
                return !string.IsNullOrEmpty(ip);
            });
        }

        public static async Task<string?> GetWslIpAlternativeAsync(string distributionName)
        {
            return await GetWslIpAddressAsync(distributionName);
        }

        public static void TestWslAccess()
        {
            WriteDetailedLog("=== ALTERNATIVE WSL DETECTION TEST ===");
            string? ip = GetWslIpAddress("Ubuntu");
            WriteDetailedLog($"Result: {ip ?? "No IP found"}");
        }
    }
}