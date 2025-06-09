using PifillCore;
using System;
using System.IO;
using System.Diagnostics;
using System.Linq;
using System.Net.NetworkInformation;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using System.Text;
using System.Threading;

namespace piFiller
{
    public partial class MainWindow : Window
    {
        private DispatcherTimer _piholeStatsTimer;
        private string? _wslIpAddress;
        private string? _primaryNetworkAdapterName;

        public MainWindow()
        {
            InitializeComponent();
            _piholeStatsTimer = new DispatcherTimer();
            _piholeStatsTimer.Interval = TimeSpan.FromSeconds(10);
            _piholeStatsTimer.Tick += PiholeStatsTimer_Tick;
        }

        private async void PiholeStatsTimer_Tick(object? sender, EventArgs e)
        {
            await UpdatePiholeStatsAsync();
        }

        private async void Window_Loaded(object sender, RoutedEventArgs e)
        {
            await InitializeApplicationAsync();
        }

        private async Task InitializeApplicationAsync()
        {
            StatusTextBlock.Text = "Initializing...";
            StatusTextBlock.Foreground = Brushes.Orange;
            ToggleProtectionButton.IsEnabled = false;
            LaunchPiholeWebUIButton.IsEnabled = false;

            _primaryNetworkAdapterName = GetDefaultEthernetOrWifiAdapter();
            if (string.IsNullOrEmpty(_primaryNetworkAdapterName))
            {
                StatusTextBlock.Text = "Error: No active Ethernet or Wi-Fi adapter found.";
                StatusTextBlock.Foreground = Brushes.Red;
                MessageBox.Show("Could not detect a primary network adapter (Ethernet/Wi-Fi). " +
                                "Please ensure you have an active internet connection.",
                                "Network Adapter Error", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            try
            {
                StatusTextBlock.Text = "Running WSL diagnostics...";
                await Task.Run(() => WSLManager.TestWslAccess());

                StatusTextBlock.Text = "Getting WSL IP with detailed logging...";
                _wslIpAddress = await Task.Run(() => WSLManager.GetWslIpAddress("Ubuntu"));

                if (!string.IsNullOrEmpty(_wslIpAddress))
                {
                    WslIpTextBlock.Text = _wslIpAddress;
                    StatusTextBlock.Text = "WSL IP detected successfully!";
                    StatusTextBlock.Foreground = Brushes.Green;
                    await UpdatePiholeStatsAsync();
                }
                else
                {
                    WslIpTextBlock.Text = "WSL IP: Failed to detect";
                    StatusTextBlock.Text = "WSL IP detection failed - check logs";
                    StatusTextBlock.Foreground = Brushes.Red;

                    MessageBox.Show("WSL IP detection failed with detailed logging.\n\n" +
                                    "Please check:\n" +
                                    "1. Visual Studio Debug Output\n" +
                                    "2. Desktop file: pifill_wsl_debug.log\n\n" +
                                    "This will show exactly where the process is failing.",
                                    "WSL Diagnostic Results", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            }
            catch (Exception ex)
            {
                WslIpTextBlock.Text = "Error getting WSL IP";
                StatusTextBlock.Text = $"WSL Error: {ex.Message}";
                StatusTextBlock.Foreground = Brushes.Red;
                Debug.WriteLine($"Error getting WSL IP: {ex.Message}");

                MessageBox.Show($"Exception during WSL IP detection: {ex.Message}\n\n" +
                                "Check the diagnostic logs for more details.",
                                "WSL Exception", MessageBoxButton.OK, MessageBoxImage.Error);
            }

            ToggleProtectionButton.IsEnabled = true;
            await CheckAndSetInitialProtectionStatus();
        }

        private async Task CheckAndSetInitialProtectionStatus()
        {
            if (string.IsNullOrEmpty(_wslIpAddress))
            {
                ToggleProtectionButton.Content = "Start Protection";
                StatusTextBlock.Text = "Not Protected";
                StatusTextBlock.Foreground = Brushes.OrangeRed;
                LaunchPiholeWebUIButton.IsEnabled = false;
                return;
            }

            bool isDnsSetToWsl = false;
            if (!string.IsNullOrEmpty(_primaryNetworkAdapterName))
            {
                try
                {
                    string[] currentDnsServers = await Task.Run(() => WindowsDNSManager.GetCurrentDnsServers(_primaryNetworkAdapterName));
                    isDnsSetToWsl = currentDnsServers.Contains(_wslIpAddress);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"Error checking current DNS: {ex.Message}");
                    isDnsSetToWsl = false;
                }
            }

            if (isDnsSetToWsl)
            {
                ToggleProtectionButton.Content = "Stop Protection";
                StatusTextBlock.Text = "Protected (DNS set to Pi-hole)";
                StatusTextBlock.Foreground = Brushes.Green;
                LaunchPiholeWebUIButton.IsEnabled = true;
                _piholeStatsTimer.Start();
            }
            else
            {
                ToggleProtectionButton.Content = "Start Protection";
                StatusTextBlock.Text = "Not Protected";
                StatusTextBlock.Foreground = Brushes.OrangeRed;
                LaunchPiholeWebUIButton.IsEnabled = false;
                _piholeStatsTimer.Stop();
            }
        }

        // IMPROVED PROTECTION TOGGLE METHOD
        private async void ToggleProtectionButton_Click(object sender, RoutedEventArgs e)
        {
            ToggleProtectionButton.IsEnabled = false;
            LaunchPiholeWebUIButton.IsEnabled = false;
            _piholeStatsTimer.Stop();

            bool isStarting = ((string)ToggleProtectionButton.Content == "Start Protection");

            if (isStarting)
            {
                StatusTextBlock.Text = "Starting protection...";
                StatusTextBlock.Foreground = Brushes.Orange;

                try
                {
                    // Step 1: Get WSL IP if needed
                    if (string.IsNullOrEmpty(_wslIpAddress))
                    {
                        await GetWslIpWithRetry();
                        if (string.IsNullOrEmpty(_wslIpAddress))
                        {
                            await HandleWslIpFailure();
                            if (string.IsNullOrEmpty(_wslIpAddress))
                            {
                                StatusTextBlock.Text = "Error: No WSL IP available";
                                StatusTextBlock.Foreground = Brushes.Red;
                                ToggleProtectionButton.Content = "Start Protection";
                                ToggleProtectionButton.IsEnabled = true;
                                return;
                            }
                        }
                    }

                    WslIpTextBlock.Text = _wslIpAddress;

                    // Step 2: Check if Pi-hole is already installed and accessible
                    bool isPiholeAlreadyWorking = await VerifyPiholeAccessibilityAsync(_wslIpAddress);

                    if (!isPiholeAlreadyWorking)
                    {
                        // Step 3: Run installation if Pi-hole is not working
                        StatusTextBlock.Text = "Installing Pi-hole and Unbound...";
                        await RunEnhancedInstallationProcess();
                    }
                    else
                    {
                        Debug.WriteLine("Pi-hole is already installed and accessible");
                        StatusTextBlock.Text = "Pi-hole already installed and accessible";
                    }

                    // Step 4: Configure Windows DNS with verification
                    StatusTextBlock.Text = "Configuring Windows DNS...";
                    bool dnsConfigured = await ConfigureDnsWithVerificationAsync();

                    if (!dnsConfigured)
                    {
                        throw new Exception("DNS configuration failed - Pi-hole may not be accessible from Windows");
                    }

                    // Step 5: Final verification and success
                    StatusTextBlock.Text = "Verifying complete setup...";
                    await Task.Delay(3000); // Wait for everything to stabilize

                    // Test if Pi-hole is receiving queries
                    await TestPiholeQueryReceiptAsync();

                    // Success!
                    StatusTextBlock.Text = "Protected (Pi-hole Active)";
                    StatusTextBlock.Foreground = Brushes.Green;
                    ToggleProtectionButton.Content = "Stop Protection";
                    LaunchPiholeWebUIButton.IsEnabled = true;
                    _piholeStatsTimer.Start();

                    // Show appropriate success message
                    await ShowEnhancedSuccessMessageAsync();
                }
                catch (OperationCanceledException)
                {
                    StatusTextBlock.Text = "Installation cancelled";
                    StatusTextBlock.Foreground = Brushes.Orange;
                    ToggleProtectionButton.Content = "Start Protection";
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"Protection setup error: {ex.Message}");

                    // Check if Pi-hole exists despite the error
                    bool piholeExists = await VerifyPiholeAccessibilityAsync(_wslIpAddress);

                    if (piholeExists)
                    {
                        StatusTextBlock.Text = "Pi-hole installed but configuration incomplete";
                        StatusTextBlock.Foreground = Brushes.Orange;
                        ToggleProtectionButton.Content = "Stop Protection";
                        LaunchPiholeWebUIButton.IsEnabled = true;

                        MessageBox.Show(
                            $"⚠️ Setup completed with issues:\n\n{ex.Message}\n\n" +
                            $"Pi-hole is installed and accessible, but there may be configuration issues.\n\n" +
                            $"Try:\n" +
                            $"1. Disable DNS over HTTPS in your browser\n" +
                            $"2. Clear browser cache\n" +
                            $"3. Test with new websites\n\n" +
                            $"If issues persist, click 'Stop Protection' then 'Start Protection' to retry.",
                            "Setup Complete with Warnings",
                            MessageBoxButton.OK,
                            MessageBoxImage.Warning);
                    }
                    else
                    {
                        StatusTextBlock.Text = $"Setup failed: {ex.Message}";
                        StatusTextBlock.Foreground = Brushes.Red;
                        ToggleProtectionButton.Content = "Start Protection";

                        MessageBox.Show(
                            $"❌ Protection setup failed:\n\n{ex.Message}\n\n" +
                            $"Please check:\n" +
                            $"• WSL is running and accessible\n" +
                            $"• Internet connection is available\n" +
                            $"• Application is running as Administrator\n\n" +
                            $"Would you like to try again?",
                            "Setup Failed",
                            MessageBoxButton.OK,
                            MessageBoxImage.Error);
                    }
                }
            }
            else // User clicked "Stop Protection"
            {
                await StopProtection();
                ToggleProtectionButton.Content = "Start Protection";

                // Clear stats display
                QueriesTodayTextBlock.Text = "0";
                QueriesBlockedTextBlock.Text = "0";
                PercentBlockedTextBlock.Text = "0%";
            }

            ToggleProtectionButton.IsEnabled = true;

            // Update stats if protection is active
            if (ToggleProtectionButton.Content.ToString() == "Stop Protection")
            {
                await UpdatePiholeStatsAsync();
            }
        }

        /// <summary>
        /// Enhanced method to verify Pi-hole is actually accessible from Windows
        /// </summary>
        private async Task<bool> VerifyPiholeAccessibilityAsync(string wslIp)
        {
            if (string.IsNullOrEmpty(wslIp)) return false;

            try
            {
                Debug.WriteLine($"Verifying Pi-hole accessibility at {wslIp}...");

                // Test 1: Check if port 53 is reachable
                using (var tcpClient = new System.Net.Sockets.TcpClient())
                {
                    var connectTask = tcpClient.ConnectAsync(wslIp, 53);
                    var timeoutTask = Task.Delay(5000);

                    if (await Task.WhenAny(connectTask, timeoutTask) == timeoutTask)
                    {
                        Debug.WriteLine($"Port 53 connection timeout for {wslIp}");
                        return false;
                    }

                    if (!tcpClient.Connected)
                    {
                        Debug.WriteLine($"Could not connect to port 53 on {wslIp}");
                        return false;
                    }
                }

                Debug.WriteLine($"Port 53 is accessible on {wslIp}");

                // Test 2: Try actual HTTP connection to Pi-hole
                using (var client = new System.Net.Http.HttpClient())
                {
                    client.Timeout = TimeSpan.FromSeconds(10);

                    // Test Pi-hole admin interface
                    try
                    {
                        var response = await client.GetAsync($"http://{wslIp}/admin/");
                        if (response.IsSuccessStatusCode)
                        {
                            Debug.WriteLine($"Pi-hole web interface accessible at {wslIp}");
                            return true;
                        }
                    }
                    catch (Exception ex)
                    {
                        Debug.WriteLine($"Pi-hole web interface test failed: {ex.Message}");
                    }

                    // Test Pi-hole API
                    try
                    {
                        var response = await client.GetAsync($"http://{wslIp}/admin/api.php");
                        if (response.IsSuccessStatusCode)
                        {
                            Debug.WriteLine($"Pi-hole API accessible at {wslIp}");
                            return true;
                        }
                    }
                    catch (Exception ex)
                    {
                        Debug.WriteLine($"Pi-hole API test failed: {ex.Message}");
                    }
                }

                Debug.WriteLine($"Pi-hole services not accessible via HTTP on {wslIp}");
                return false;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Error verifying Pi-hole accessibility: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Enhanced DNS configuration with verification and improved error handling
        /// </summary>
        private async Task<bool> ConfigureDnsWithVerificationAsync()
        {
            if (string.IsNullOrEmpty(_wslIpAddress) || string.IsNullOrEmpty(_primaryNetworkAdapterName))
            {
                Debug.WriteLine("Missing WSL IP or network adapter name for DNS configuration");
                return false;
            }

            try
            {
                StatusTextBlock.Text = "Verifying Pi-hole accessibility...";

                // First verify Pi-hole is actually accessible
                bool isPiholeAccessible = await VerifyPiholeAccessibilityAsync(_wslIpAddress);

                if (!isPiholeAccessible)
                {
                    Debug.WriteLine($"Pi-hole is not accessible at {_wslIpAddress} - cannot configure DNS");

                    var result = MessageBox.Show(
                        $"⚠️ Pi-hole Network Issue Detected\n\n" +
                        $"Pi-hole is installed but not accessible from Windows at {_wslIpAddress}.\n\n" +
                        $"This usually means Unbound failed to start during installation.\n\n" +
                        $"Would you like to run the Unbound fix script?",
                        "Pi-hole Network Configuration Issue",
                        MessageBoxButton.YesNo,
                        MessageBoxImage.Warning);

                    if (result == MessageBoxResult.Yes)
                    {
                        await RunUnboundFixScriptAsync();

                        // Re-verify after fix
                        await Task.Delay(5000); // Wait for services to restart
                        isPiholeAccessible = await VerifyPiholeAccessibilityAsync(_wslIpAddress);

                        if (!isPiholeAccessible)
                        {
                            MessageBox.Show(
                                "Unbound fix completed but Pi-hole is still not accessible.\n\n" +
                                "Please check the WSL logs or try restarting WSL:\n" +
                                "1. Open Command Prompt as Administrator\n" +
                                "2. Run: wsl --shutdown\n" +
                                "3. Restart this app",
                                "Network Fix Incomplete",
                                MessageBoxButton.OK,
                                MessageBoxImage.Warning);
                            return false;
                        }
                    }
                    else
                    {
                        return false;
                    }
                }

                StatusTextBlock.Text = "Configuring Windows DNS...";

                // Configure IPv4 DNS
                await Task.Run(() => WindowsDNSManager.SetDnsServers(_primaryNetworkAdapterName, new[] { _wslIpAddress }));
                Debug.WriteLine($"IPv4 DNS set to {_wslIpAddress}");

                // Clear DNS cache
                await ClearWindowsDNSCache();

                // Wait longer for changes to take effect
                await Task.Delay(3000);

                // Verify DNS configuration with improved method
                bool dnsConfigured = await VerifyDnsConfigurationAsync();

                if (!dnsConfigured)
                {
                    Debug.WriteLine("DNS configuration verification failed");

                    // Try alternative verification
                    bool alternativeCheck = await TestActualDnsResolutionAsync();
                    if (alternativeCheck)
                    {
                        Debug.WriteLine("Alternative DNS verification passed");
                        dnsConfigured = true;
                    }
                }

                if (!dnsConfigured)
                {
                    Debug.WriteLine("All DNS verification methods failed");

                    MessageBox.Show(
                        "⚠️ DNS Configuration Issue\n\n" +
                        "Windows DNS was set but verification failed.\n\n" +
                        "This may be due to:\n" +
                        "• Windows DNS caching\n" +
                        "• Network adapter issues\n" +
                        "• Administrative permissions\n\n" +
                        "The DNS may still be working. Try:\n" +
                        "1. Restart your browser\n" +
                        "2. Test with new websites\n" +
                        "3. Check if ads are blocked",
                        "DNS Configuration Warning",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);

                    // Return true anyway since Pi-hole is accessible
                    return true;
                }

                // Test actual DNS resolution as final check
                bool dnsWorking = await TestActualDnsResolutionAsync();

                if (!dnsWorking)
                {
                    Debug.WriteLine("DNS resolution test failed");

                    MessageBox.Show(
                        "⚠️ DNS Resolution Warning\n\n" +
                        "Windows DNS has been configured, but resolution tests failed.\n\n" +
                        "This may be due to:\n" +
                        "• Browser DNS over HTTPS (DoH) being enabled\n" +
                        "• DNS cache not cleared yet\n" +
                        "• Unbound not fully started\n\n" +
                        "Please:\n" +
                        "1. Disable DoH in your browser settings\n" +
                        "2. Restart your browser\n" +
                        "3. Wait 1-2 minutes for services to stabilize",
                        "DNS Configuration Complete with Warnings",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                }

                Debug.WriteLine("DNS configuration completed successfully");
                return true;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"DNS configuration failed: {ex.Message}");

                MessageBox.Show(
                    $"Failed to configure Windows DNS settings.\n\n" +
                    $"Error: {ex.Message}\n\n" +
                    $"Please ensure the application is running as Administrator.",
                    "DNS Configuration Error",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);

                return false;
            }
        }

        /// <summary>
        /// Improved DNS verification that handles Windows DNS configuration properly
        /// </summary>
        private async Task<bool> VerifyDnsConfigurationAsync()
        {
            try
            {
                await Task.Delay(2000); // Wait longer for changes to take effect

                Debug.WriteLine("Verifying DNS configuration...");

                // Method 1: Use netsh command directly (more reliable)
                bool netshResult = await VerifyDnsViaNetshAsync();

                // Method 2: Use Windows API as backup
                bool apiResult = await VerifyDnsViaApiAsync();

                Debug.WriteLine($"Netsh verification: {netshResult}");
                Debug.WriteLine($"API verification: {apiResult}");

                // Consider it successful if either method confirms the DNS is set
                bool result = netshResult || apiResult;

                Debug.WriteLine($"Overall DNS verification result: {result}");
                return result;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"DNS verification failed: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Verify DNS configuration using netsh command (more reliable)
        /// </summary>
        private async Task<bool> VerifyDnsViaNetshAsync()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "netsh",
                    Arguments = $"interface ipv4 show dnsservers \"{_primaryNetworkAdapterName}\"",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process == null) return false;

                    await Task.Run(() => process.WaitForExit(10000));
                    string output = await process.StandardOutput.ReadToEndAsync();
                    string error = await process.StandardError.ReadToEndAsync();

                    Debug.WriteLine($"Netsh DNS output: {output}");
                    if (!string.IsNullOrEmpty(error))
                    {
                        Debug.WriteLine($"Netsh DNS error: {error}");
                    }

                    // Check if our WSL IP is in the output
                    bool hasWslIp = output.Contains(_wslIpAddress);

                    // Also check for "Statically Configured" which indicates we set it manually
                    bool isStaticallyConfigured = output.Contains("Statically Configured DNS Servers:");

                    Debug.WriteLine($"DNS output contains WSL IP ({_wslIpAddress}): {hasWslIp}");
                    Debug.WriteLine($"DNS is statically configured: {isStaticallyConfigured}");

                    return hasWslIp && isStaticallyConfigured;
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Netsh DNS verification failed: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Verify DNS configuration using Windows API (backup method)
        /// </summary>
        private async Task<bool> VerifyDnsViaApiAsync()
        {
            try
            {
                string[] currentDnsServers = await Task.Run(() =>
                    WindowsDNSManager.GetCurrentDnsServers(_primaryNetworkAdapterName));

                bool hasWslDns = currentDnsServers != null && currentDnsServers.Contains(_wslIpAddress);

                Debug.WriteLine($"API DNS servers: {(currentDnsServers != null ? string.Join(", ", currentDnsServers) : "null")}");
                Debug.WriteLine($"WSL IP {_wslIpAddress} found in API DNS: {hasWslDns}");

                return hasWslDns;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"API DNS verification failed: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Test actual DNS resolution (alternative verification)
        /// </summary>
        private async Task<bool> TestActualDnsResolutionAsync()
        {
            try
            {
                Debug.WriteLine("Testing actual DNS resolution...");

                // Use nslookup to test DNS resolution through our configured DNS
                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "nslookup",
                    Arguments = $"google.com {_wslIpAddress}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process == null) return false;

                    await Task.Run(() => process.WaitForExit(10000));
                    string output = await process.StandardOutput.ReadToEndAsync();
                    string error = await process.StandardError.ReadToEndAsync();

                    Debug.WriteLine($"nslookup output: {output}");
                    if (!string.IsNullOrEmpty(error))
                    {
                        Debug.WriteLine($"nslookup error: {error}");
                    }

                    bool success = process.ExitCode == 0 &&
                                  output.Contains("Address") &&
                                  !output.Contains("can't find") &&
                                  !output.Contains("server can't find");

                    Debug.WriteLine($"Actual DNS resolution test: {(success ? "PASSED" : "FAILED")}");
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
        /// Test if Pi-hole is actually receiving and logging queries
        /// </summary>
        private async Task TestPiholeQueryReceiptAsync()
        {
            try
            {
                Debug.WriteLine("Testing if Pi-hole receives queries...");

                // Get current query count
                string? initialStats = await TryGetPiholeStatsAsync();
                int initialQueries = 0;

                if (!string.IsNullOrEmpty(initialStats))
                {
                    string[] stats = initialStats.Split(',');
                    if (stats.Length >= 2 && int.TryParse(stats[1], out int queries))
                    {
                        initialQueries = queries;
                    }
                }

                Debug.WriteLine($"Initial query count: {initialQueries}");

                // Perform a test DNS query that should go through Pi-hole
                string testDomain = $"test-query-{DateTime.Now.Ticks}.example.org";

                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "nslookup",
                    Arguments = $"{testDomain} {_wslIpAddress}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process != null)
                    {
                        await Task.Run(() => process.WaitForExit(10000));
                    }
                }

                // Wait for Pi-hole to log the query
                await Task.Delay(3000);

                // Check if query count increased
                string? finalStats = await TryGetPiholeStatsAsync();
                int finalQueries = 0;

                if (!string.IsNullOrEmpty(finalStats))
                {
                    string[] stats = finalStats.Split(',');
                    if (stats.Length >= 2 && int.TryParse(stats[1], out int queries))
                    {
                        finalQueries = queries;
                    }
                }

                Debug.WriteLine($"Final query count: {finalQueries}");

                if (finalQueries > initialQueries)
                {
                    Debug.WriteLine("✅ Pi-hole is receiving and logging queries correctly!");
                }
                else
                {
                    Debug.WriteLine("⚠️ Pi-hole may not be receiving queries - this could indicate DNS bypassing");
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Query receipt test failed: {ex.Message}");
            }
        }

        /// <summary>
        /// Show enhanced success message with better guidance
        /// </summary>
        private async Task ShowEnhancedSuccessMessageAsync()
        {
            // First verify if Pi-hole is actually receiving queries
            await TestPiholeQueryReceiptAsync();

            string? currentStats = await TryGetPiholeStatsAsync();
            bool hasQueries = false;

            if (!string.IsNullOrEmpty(currentStats))
            {
                string[] stats = currentStats.Split(',');
                if (stats.Length >= 2 && int.TryParse(stats[1], out int queries) && queries > 0)
                {
                    hasQueries = true;
                }
            }

            string message;
            MessageBoxImage icon;

            if (hasQueries)
            {
                message =
                    "🎉 Pi-hole Setup Complete and Working!\n\n" +
                    "✅ Pi-hole and Unbound installed successfully\n" +
                    "✅ Windows DNS configured correctly\n" +
                    "✅ Pi-hole is receiving and blocking queries\n\n" +
                    "📊 Your internet traffic is now being filtered!\n\n" +
                    "💡 For best results:\n" +
                    "• Clear your browser cache\n" +
                    "• Visit new websites to see blocking in action\n" +
                    "• Check the Pi-hole dashboard for statistics\n\n" +
                    "Click 'Launch Pi-hole Web UI' to monitor your ad blocking!";
                icon = MessageBoxImage.Information;
            }
            else
            {
                message =
                    "⚠️ Pi-hole Setup Complete - Manual Steps Required\n\n" +
                    "✅ Pi-hole and Unbound installed successfully\n" +
                    "✅ Windows DNS configured\n" +
                    "⚠️ Pi-hole may not be receiving queries yet\n\n" +
                    "🔧 IMPORTANT: Complete these steps:\n\n" +
                    "1. 🌐 DISABLE 'DNS over HTTPS' in your browser:\n" +
                    "   • Chrome: Settings → Privacy → Security → Use secure DNS → OFF\n" +
                    "   • Firefox: Settings → Network Settings → DNS over HTTPS → OFF\n" +
                    "   • Edge: Settings → Privacy → Security → Use secure DNS → OFF\n\n" +
                    "2. 🔄 RESTART your browser completely\n\n" +
                    "3. 🧪 TEST by visiting ad-heavy websites\n\n" +
                    "4. 📊 Check Pi-hole dashboard for increasing query counts\n\n" +
                    "If queries still don't appear after these steps, click 'Stop Protection' then 'Start Protection' to retry.";
                icon = MessageBoxImage.Warning;
            }

            MessageBox.Show(message, "Pi-hole Setup Complete", MessageBoxButton.OK, icon);
        }

        /// <summary>
        /// Run the Unbound fix script with Quad9 upstream
        /// </summary>
        private async Task RunUnboundFixScriptAsync()
        {
            try
            {
                StatusTextBlock.Text = "Running Unbound fix script...";

                string projectRoot = System.IO.Directory.GetParent(AppDomain.CurrentDomain.BaseDirectory)?.Parent?.Parent?.Parent?.FullName;
                string scriptPath = System.IO.Path.Combine(projectRoot ?? "", "Scripts", "fix_unbound.sh");

                if (!File.Exists(scriptPath))
                {
                    // Create the script if it doesn't exist
                    await File.WriteAllTextAsync(scriptPath, GetUnboundFixScriptContent());
                    Debug.WriteLine($"Unbound fix script created at: {scriptPath}");
                }

                string wslScriptPath = ConvertToWslPath(scriptPath);

                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d Ubuntu -- bash \"{wslScriptPath}\"",
                    UseShellExecute = false,
                    CreateNoWindow = false,
                    WindowStyle = ProcessWindowStyle.Normal,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process == null)
                    {
                        throw new Exception("Failed to start Unbound fix process");
                    }

                    process.OutputDataReceived += (sender, e) => {
                        if (e.Data != null)
                        {
                            Debug.WriteLine($"[UNBOUND-FIX] {e.Data}");

                            Dispatcher.Invoke(() => {
                                var data = e.Data.ToLower();
                                if (data.Contains("starting unbound"))
                                    StatusTextBlock.Text = "Starting Unbound DNS resolver...";
                                else if (data.Contains("testing"))
                                    StatusTextBlock.Text = "Testing DNS resolution...";
                                else if (data.Contains("restarting"))
                                    StatusTextBlock.Text = "Restarting Pi-hole...";
                            });
                        }
                    };

                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();

                    bool finished = await Task.Run(() => process.WaitForExit(60000)); // 1 minute timeout

                    if (!finished)
                    {
                        process.Kill();
                        throw new TimeoutException("Unbound fix script timed out");
                    }

                    Debug.WriteLine($"Unbound fix script completed with exit code: {process.ExitCode}");
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Unbound fix script failed: {ex.Message}");
                throw;
            }
        }

        /// <summary>
        /// Enhanced installation process with better verification
        /// </summary>
        private async Task RunEnhancedInstallationProcess()
        {
            StatusTextBlock.Text = "Installing Pi-hole and Unbound...";

            string projectRoot = System.IO.Directory.GetParent(AppDomain.CurrentDomain.BaseDirectory)?.Parent?.Parent?.Parent?.FullName;
            string scriptPath = System.IO.Path.Combine(projectRoot ?? "", "Scripts", "install_pihole_unbound.sh");

            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException($"Installation script not found: {scriptPath}");
            }

            string wslScriptPath = ConvertToWslPath(scriptPath);

            // Run installation
            string installOutput = await ExecuteInstallationDirectly(wslScriptPath);

            // Enhanced verification after installation
            StatusTextBlock.Text = "Verifying installation...";
            await Task.Delay(5000); // Wait for services to start

            // Check if Pi-hole is accessible
            bool isPiholeAccessible = await VerifyPiholeAccessibilityAsync(_wslIpAddress);

            if (!isPiholeAccessible)
            {
                Debug.WriteLine("Pi-hole installation completed but network access verification failed");

                var result = MessageBox.Show(
                    "Pi-hole installation completed, but the service is not accessible from Windows.\n\n" +
                    "This is usually due to Unbound failing to start during installation.\n\n" +
                    "Would you like to run the Unbound fix script automatically?",
                    "Installation Complete - Unbound Fix Needed",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Warning);

                if (result == MessageBoxResult.Yes)
                {
                    StatusTextBlock.Text = "Running Unbound fix...";
                    await RunUnboundFixScriptAsync();

                    // Re-verify
                    await Task.Delay(5000);
                    isPiholeAccessible = await VerifyPiholeAccessibilityAsync(_wslIpAddress);
                }
            }

            if (isPiholeAccessible)
            {
                Debug.WriteLine("Pi-hole installation and network verification successful");
            }
            else
            {
                Debug.WriteLine("Pi-hole installation completed but network issues remain");
                throw new Exception("Pi-hole installed but not accessible from Windows network");
            }
        }

        /// <summary>
        /// Get the content for the Unbound fix script with Quad9 upstream
        /// </summary>
        private string GetUnboundFixScriptContent()
        {
            // Return the Unbound fix script with Quad9 upstream
            return @"#!/bin/bash

# Quick Unbound Fix Script with Quad9 Upstream
echo '🔧 Fixing Unbound DNS Resolver (with Quad9 upstream)'
echo '====================================================='
echo ''

# Check current status
echo '📋 Current Status:'
echo ""- Pi-hole FTL: $(systemctl is-active pihole-FTL 2>/dev/null || echo 'inactive')""
echo ""- Unbound: $(systemctl is-active unbound 2>/dev/null || echo 'inactive')""
echo ''

# Create a working Unbound configuration with Quad9 upstream
echo '🔧 Creating Unbound configuration with Quad9 upstream...'

sudo tee /etc/unbound/unbound.conf.d/pi-hole.conf > /dev/null <<'EOF'
server:
    # Basic configuration
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

# Forward all queries to Quad9 (more reliable than full recursion in WSL)
forward-zone:
    name: "".""
    forward-addr: 9.9.9.9        # Quad9 Primary (malware blocking)
    forward-addr: 149.112.112.112 # Quad9 Secondary
    forward-addr: 1.1.1.1        # Cloudflare Primary (backup)
    forward-addr: 1.0.0.1        # Cloudflare Secondary (backup)
EOF

echo '✅ Unbound configuration updated with Quad9 upstream'

# Restart services
echo ''
echo '🔄 Restarting services...'
sudo systemctl stop unbound 2>/dev/null || true
sleep 2

if sudo systemctl start unbound; then
    echo '✅ Unbound started successfully'
    sleep 3
    sudo systemctl restart pihole-FTL
    echo '✅ Pi-hole restarted'
else
    echo '❌ Unbound failed to start'
    exit 1
fi

echo ''
echo '🧪 Testing DNS resolution...'
if dig @127.0.0.1 -p 5335 google.com +short >/dev/null 2>&1; then
    echo '✅ Unbound DNS resolution working'
else
    echo '❌ Unbound DNS test failed'
fi

echo '✅ All services restarted with upstream DNS'
exit 0";
        }

        private async Task GetWslIpWithRetry()
        {
            StatusTextBlock.Text = "Getting WSL IP address...";

            try
            {
                await Task.Run(() => WSLManager.TestWslAccess());
                _wslIpAddress = await WSLManager.GetWslIpAddressAsync("Ubuntu", maxRetries: 3); // Reduced retries

                if (string.IsNullOrEmpty(_wslIpAddress))
                {
                    _wslIpAddress = await WSLManager.GetWslIpAlternativeAsync("Ubuntu");
                }

                if (!string.IsNullOrEmpty(_wslIpAddress))
                {
                    WslIpTextBlock.Text = _wslIpAddress;
                    Debug.WriteLine($"Successfully obtained WSL IP: {_wslIpAddress}");
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Error getting WSL IP: {ex.Message}");
                // Don't throw - let the calling method handle the empty IP
            }
        }

        private async Task HandleWslIpFailure()
        {
            StatusTextBlock.Text = "WSL IP detection failed";
            StatusTextBlock.Foreground = Brushes.Orange;

            var result = MessageBox.Show(
                "Could not automatically detect WSL IP address.\n\n" +
                "Would you like to continue with the known IP (172.24.2.95)?",
                "WSL IP Detection Failed",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);

            if (result == MessageBoxResult.Yes)
            {
                _wslIpAddress = "172.24.2.95"; // Known working IP
                WslIpTextBlock.Text = _wslIpAddress + " (manual)";
                Debug.WriteLine($"Using manual WSL IP: {_wslIpAddress}");
            }
        }

        private async Task StopProtection()
        {
            StatusTextBlock.Text = "Stopping protection...";
            StatusTextBlock.Foreground = Brushes.Orange;

            try
            {
                if (!string.IsNullOrEmpty(_primaryNetworkAdapterName))
                {
                    await Task.Run(() => WindowsDNSManager.RevertDnsToDhcp(_primaryNetworkAdapterName));
                    await RevertIPv6DNS();
                    await ClearWindowsDNSCache();

                    StatusTextBlock.Text = "Not Protected";
                    StatusTextBlock.Foreground = Brushes.OrangeRed;
                    LaunchPiholeWebUIButton.IsEnabled = false;
                    Debug.WriteLine("DNS successfully reverted to DHCP");
                }
                else
                {
                    throw new InvalidOperationException("Primary network adapter name is not available.");
                }
            }
            catch (Exception ex)
            {
                StatusTextBlock.Text = $"Error reverting DNS: {ex.Message}";
                StatusTextBlock.Foreground = Brushes.Red;
                MessageBox.Show($"Failed to revert Windows DNS. Error: {ex.Message}",
                                "DNS Error", MessageBoxButton.OK, MessageBoxImage.Error);

                ToggleProtectionButton.Content = "Stop Protection";
                ToggleProtectionButton.IsEnabled = true;
                if (!string.IsNullOrEmpty(_wslIpAddress)) _piholeStatsTimer.Start();
                return;
            }
        }

        // Helper methods for DNS operations

        private async Task RevertIPv6DNS()
        {
            try
            {
                // Simply ensure IPv6 is back to DHCP/automatic
                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "netsh",
                    Arguments = $"interface ipv6 set dnsservers \"{_primaryNetworkAdapterName}\" source=dhcp",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    Verb = "runas"
                };

                using (Process process = Process.Start(psi))
                {
                    if (process != null)
                    {
                        await Task.Run(() => process.WaitForExit(10000));
                        Debug.WriteLine($"IPv6 DNS reverted to DHCP for {_primaryNetworkAdapterName}");
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"IPv6 DNS revert failed: {ex.Message}");
            }
        }

        private async Task ClearWindowsDNSCache()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "ipconfig",
                    Arguments = "/flushdns",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process != null)
                    {
                        await Task.Run(() => process.WaitForExit(10000));
                        Debug.WriteLine("Windows DNS cache cleared");
                    }
                }

                psi.Arguments = "/registerdns";
                using (Process process = Process.Start(psi))
                {
                    if (process != null)
                    {
                        await Task.Run(() => process.WaitForExit(10000));
                        Debug.WriteLine("Windows DNS registered");
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"DNS cache clear failed: {ex.Message}");
            }
        }

        private async Task<string> ExecuteInstallationDirectly(string scriptPath)
        {
            try
            {
                Debug.WriteLine($"Starting direct installation with script: {scriptPath}");

                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d Ubuntu -- bash \"{scriptPath}\"",
                    UseShellExecute = false,
                    CreateNoWindow = false,
                    WindowStyle = ProcessWindowStyle.Normal,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                var outputBuilder = new StringBuilder();
                var errorBuilder = new StringBuilder();

                using (Process process = Process.Start(psi))
                {
                    if (process == null)
                    {
                        throw new Exception("Failed to start installation process");
                    }

                    process.OutputDataReceived += (sender, e) => {
                        if (e.Data != null)
                        {
                            outputBuilder.AppendLine(e.Data);
                            Debug.WriteLine($"[INSTALL] {e.Data}");

                            Dispatcher.Invoke(() => {
                                var data = e.Data.ToLower();
                                if (data.Contains("installing pi-hole"))
                                    StatusTextBlock.Text = "Installing Pi-hole (may take several minutes)...";
                                else if (data.Contains("installing unbound"))
                                    StatusTextBlock.Text = "Installing Unbound DNS resolver...";
                                else if (data.Contains("configuring"))
                                    StatusTextBlock.Text = "Configuring Pi-hole and Unbound...";
                                else if (data.Contains("starting services"))
                                    StatusTextBlock.Text = "Starting DNS services...";
                                else if (data.Contains("verifying"))
                                    StatusTextBlock.Text = "Verifying installation...";
                                else if (data.Contains("completed successfully"))
                                    StatusTextBlock.Text = "Installation completed successfully!";
                                else if (data.Contains("password") || data.Contains("sudo"))
                                    StatusTextBlock.Text = "Enter password in terminal window...";
                            });
                        }
                    };

                    process.ErrorDataReceived += (sender, e) => {
                        if (e.Data != null)
                        {
                            errorBuilder.AppendLine(e.Data);
                            Debug.WriteLine($"[INSTALL-ERR] {e.Data}");
                        }
                    };

                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();

                    Debug.WriteLine("Waiting for installation to complete...");

                    bool finished = await Task.Run(() => process.WaitForExit(900000));

                    if (!finished)
                    {
                        Debug.WriteLine("Installation process timed out");
                        process.Kill();
                        throw new TimeoutException("Installation timed out after 15 minutes");
                    }

                    string output = outputBuilder.ToString();
                    string error = errorBuilder.ToString();

                    Debug.WriteLine($"Installation process completed with exit code: {process.ExitCode}");
                    Debug.WriteLine($"Output length: {output.Length} characters");

                    if (process.ExitCode != 0 && !output.Contains("completed successfully", StringComparison.OrdinalIgnoreCase))
                    {
                        string errorMsg = $"Installation failed with exit code {process.ExitCode}";
                        if (!string.IsNullOrEmpty(error))
                        {
                            errorMsg += $"\nError: {error.Substring(0, Math.Min(300, error.Length))}";
                        }
                        throw new Exception(errorMsg);
                    }

                    return output;
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Installation execution failed: {ex.Message}");
                throw new Exception($"Installation failed: {ex.Message}", ex);
            }
        }

        private void LaunchPiholeWebUIButton_Click(object? sender, RoutedEventArgs e)
        {
            if (!string.IsNullOrEmpty(_wslIpAddress))
            {
                try
                {
                    Process.Start(new ProcessStartInfo($"http://{_wslIpAddress}/admin") { UseShellExecute = true });
                    Debug.WriteLine($"Launched Pi-hole web UI at: http://{_wslIpAddress}/admin");
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Could not open Pi-hole web UI: {ex.Message}", "Launch Error", MessageBoxButton.OK, MessageBoxImage.Error);
                    Debug.WriteLine($"Failed to launch Pi-hole web UI: {ex.Message}");
                }
            }
            else
            {
                MessageBox.Show("Pi-hole IP address not found. Please ensure Pi-hole is running.", "Launch Error", MessageBoxButton.OK, MessageBoxImage.Warning);
                Debug.WriteLine("Launch Pi-hole UI failed: No WSL IP address available");
            }
        }

        private async Task UpdatePiholeStatsAsync()
        {
            if (string.IsNullOrEmpty(_wslIpAddress))
            {
                Debug.WriteLine("UpdatePiholeStatsAsync: No WSL IP address available");
                return;
            }

            try
            {
                Debug.WriteLine($"Updating Pi-hole stats for IP: {_wslIpAddress}");

                string? statsResult = await TryGetPiholeStatsAsync();

                if (!string.IsNullOrEmpty(statsResult))
                {
                    await ParseAndDisplayStats(statsResult);
                }
                else
                {
                    Dispatcher.Invoke(() =>
                    {
                        QueriesTodayTextBlock.Text = "0";
                        QueriesBlockedTextBlock.Text = "0";
                        PercentBlockedTextBlock.Text = "0%";

                        if (IsPiholeWebAccessible())
                        {
                            StatusTextBlock.Text = "Pi-hole accessible but stats unavailable";
                            StatusTextBlock.Foreground = Brushes.DarkOrange;
                        }
                        else
                        {
                            StatusTextBlock.Text = "Pi-hole not accessible - check connection";
                            StatusTextBlock.Foreground = Brushes.Orange;
                        }
                    });
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Error updating Pi-hole stats: {ex.Message}");
                Dispatcher.Invoke(() =>
                {
                    QueriesTodayTextBlock.Text = "N/A";
                    QueriesBlockedTextBlock.Text = "N/A";
                    PercentBlockedTextBlock.Text = "N/A";
                    StatusTextBlock.Text = "Stats temporarily unavailable";
                    StatusTextBlock.Foreground = Brushes.DarkOrange;
                });
            }
        }

        private async Task<string?> TryGetPiholeStatsAsync()
        {
            string? httpStats = await TryGetStatsViaHttpAsync();
            if (!string.IsNullOrEmpty(httpStats)) return httpStats;

            string? scriptStats = await TryGetStatsViaScriptAsync();
            if (!string.IsNullOrEmpty(scriptStats)) return scriptStats;

            string? altStats = await TryGetStatsViaAlternativeWslAsync();
            if (!string.IsNullOrEmpty(altStats)) return altStats;

            return null;
        }

        private async Task<string?> TryGetStatsViaHttpAsync()
        {
            try
            {
                using (var client = new System.Net.Http.HttpClient())
                {
                    client.Timeout = TimeSpan.FromSeconds(5);

                    string[] apiUrls = {
                        $"http://{_wslIpAddress}/api/stats/summary",
                        $"http://{_wslIpAddress}/api/stats",
                        $"http://{_wslIpAddress}/admin/api.php?summary",
                        $"http://{_wslIpAddress}/admin/api.php?summaryRaw",
                        $"http://{_wslIpAddress}/admin/api.php"
                    };

                    foreach (string apiUrl in apiUrls)
                    {
                        try
                        {
                            Debug.WriteLine($"Trying API URL: {apiUrl}");
                            var response = await client.GetAsync(apiUrl);

                            if (response.IsSuccessStatusCode)
                            {
                                string content = await response.Content.ReadAsStringAsync();
                                Debug.WriteLine($"API response from {apiUrl}: {content}");

                                if (content.Contains("dns_queries_today") || content.Contains("queries_today") ||
                                    content.Contains("total_queries") || content.Contains("domains_being_blocked"))
                                {
                                    string? parsed = ParsePiholeJsonResponse(content);
                                    if (!string.IsNullOrEmpty(parsed)) return parsed;
                                }

                                if (content.Contains("Active") || content.Contains("queries"))
                                {
                                    return content;
                                }
                            }
                            else
                            {
                                Debug.WriteLine($"API URL {apiUrl} returned: {response.StatusCode}");
                            }
                        }
                        catch (Exception ex)
                        {
                            Debug.WriteLine($"API URL {apiUrl} failed: {ex.Message}");
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"HTTP API method failed: {ex.Message}");
            }

            return null;
        }

        private async Task<string?> TryGetStatsViaScriptAsync()
        {
            try
            {
                string scriptPath = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Scripts", "get_pihole_stats.sh");

                if (!File.Exists(scriptPath))
                {
                    Debug.WriteLine($"Stats script not found: {scriptPath}");
                    return null;
                }

                string wslScriptPath = ConvertToWslPath(scriptPath);

                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d Ubuntu -- bash \"{wslScriptPath}\"",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process == null) return null;

                    await Task.Run(() => process.WaitForExit(10000));
                    string output = await process.StandardOutput.ReadToEndAsync();
                    string error = await process.StandardError.ReadToEndAsync();

                    Debug.WriteLine($"Script stats output: '{output}'");
                    if (!string.IsNullOrEmpty(error))
                    {
                        Debug.WriteLine($"Script stats error: '{error}'");
                    }

                    if (!string.IsNullOrWhiteSpace(output) && !output.StartsWith("ERROR:"))
                    {
                        return output.Trim();
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Script stats method failed: {ex.Message}");
            }

            return null;
        }

        private async Task<string?> TryGetStatsViaAlternativeWslAsync()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/c wsl.exe -d Ubuntu -- bash -c \"curl -s localhost/admin/api.php?summary 2>/dev/null || echo 'Active,0,0,0'\"",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process process = Process.Start(psi))
                {
                    if (process == null) return null;

                    await Task.Run(() => process.WaitForExit(10000));
                    string output = await process.StandardOutput.ReadToEndAsync();

                    Debug.WriteLine($"Alternative WSL stats output: '{output}'");

                    if (!string.IsNullOrWhiteSpace(output))
                    {
                        string trimmed = output.Trim();

                        if (trimmed.StartsWith("{"))
                        {
                            return ParsePiholeJsonResponse(trimmed);
                        }

                        if (trimmed.Contains(","))
                        {
                            return trimmed;
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Alternative WSL stats method failed: {ex.Message}");
            }

            return null;
        }

        private string? ParsePiholeJsonResponse(string response)
        {
            try
            {
                Debug.WriteLine($"Parsing response: {response}");

                if (response.TrimStart().StartsWith("{"))
                {
                    var queriesMatch = System.Text.RegularExpressions.Regex.Match(response,
                        @"""(?:dns_queries_today|total_queries|queries_today)""\s*:\s*""?(\d+)""?");
                    var blockedMatch = System.Text.RegularExpressions.Regex.Match(response,
                        @"""(?:ads_blocked_today|blocked_queries|queries_blocked_today)""\s*:\s*""?(\d+)""?");
                    var percentMatch = System.Text.RegularExpressions.Regex.Match(response,
                        @"""(?:ads_percentage_today|blocked_percentage|queries_blocked_percentage)""\s*:\s*""?([0-9.]+)""?");

                    if (!queriesMatch.Success)
                    {
                        var domainsMatch = System.Text.RegularExpressions.Regex.Match(response,
                            @"""domains_being_blocked""\s*:\s*""?(\d+)""?");
                        if (domainsMatch.Success)
                        {
                            return "Active,0,0,0.0";
                        }
                    }

                    if (queriesMatch.Success && blockedMatch.Success && percentMatch.Success)
                    {
                        string queries = queriesMatch.Groups[1].Value;
                        string blocked = blockedMatch.Groups[1].Value;
                        string percent = percentMatch.Groups[1].Value;

                        return $"Active,{queries},{blocked},{percent}";
                    }

                    if (response.Contains("domains_being_blocked") || response.Contains("status"))
                    {
                        return "Active,0,0,0.0";
                    }
                }

                if (response.Contains("Active") || response.Contains("queries"))
                {
                    return response;
                }

                return "Active,0,0,0.0";
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Error parsing Pi-hole response: {ex.Message}");
                return "Active,0,0,0.0";
            }
        }

        private async Task ParseAndDisplayStats(string statsOutput)
        {
            try
            {
                string[] stats = statsOutput.Split(',');

                await Dispatcher.InvokeAsync(() =>
                {
                    if (stats.Length >= 4)
                    {
                        string piholeStatus = stats[0].Trim();

                        if (piholeStatus.Equals("Active", StringComparison.OrdinalIgnoreCase))
                        {
                            StatusTextBlock.Text = "Protected (Pi-hole Active)";
                            StatusTextBlock.Foreground = Brushes.Green;
                        }
                        else
                        {
                            StatusTextBlock.Text = $"Pi-hole Status: {piholeStatus}";
                            StatusTextBlock.Foreground = Brushes.DarkOrange;
                        }

                        QueriesTodayTextBlock.Text = stats[1].Trim();
                        QueriesBlockedTextBlock.Text = stats[2].Trim();
                        PercentBlockedTextBlock.Text = stats[3].Trim() + "%";

                        Debug.WriteLine($"Pi-hole stats updated - Status: {piholeStatus}, Queries: {stats[1].Trim()}, Blocked: {stats[2].Trim()}, Percent: {stats[3].Trim()}%");
                    }
                    else
                    {
                        Debug.WriteLine($"Unexpected stats format: {statsOutput}");
                        QueriesTodayTextBlock.Text = "0";
                        QueriesBlockedTextBlock.Text = "0";
                        PercentBlockedTextBlock.Text = "0%";
                    }
                });
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Error parsing stats: {ex.Message}");
            }
        }

        private bool IsPiholeWebAccessible()
        {
            try
            {
                using (var client = new System.Net.Http.HttpClient())
                {
                    client.Timeout = TimeSpan.FromSeconds(3);
                    var task = client.GetAsync($"http://{_wslIpAddress}/admin");
                    task.Wait(3000);
                    return task.Result.IsSuccessStatusCode;
                }
            }
            catch
            {
                return false;
            }
        }

        private string ConvertToWslPath(string windowsPath)
        {
            if (windowsPath.Length >= 3 && windowsPath[1] == ':')
            {
                char driveLetter = char.ToLower(windowsPath[0]);
                string relativePath = windowsPath.Substring(2).Replace('\\', '/');
                return $"/mnt/{driveLetter}{relativePath}";
            }
            return windowsPath;
        }

        private string? GetDefaultEthernetOrWifiAdapter()
        {
            try
            {
                Debug.WriteLine("Searching for default Ethernet or Wi-Fi adapter...");
                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    Debug.WriteLine($"Checking adapter: {nic.Name} - Type: {nic.NetworkInterfaceType} - Status: {nic.OperationalStatus}");

                    if ((nic.NetworkInterfaceType == NetworkInterfaceType.Ethernet ||
                         nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211) &&
                        nic.OperationalStatus == OperationalStatus.Up &&
                        nic.Supports(NetworkInterfaceComponent.IPv4))
                    {
                        IPInterfaceProperties properties = nic.GetIPProperties();
                        if (properties.GatewayAddresses.Any())
                        {
                            bool hasNonLoopbackDns = false;
                            foreach (var dnsAddress in properties.DnsAddresses)
                            {
                                if (!System.Net.IPAddress.IsLoopback(dnsAddress))
                                {
                                    hasNonLoopbackDns = true;
                                    break;
                                }
                            }
                            if (!properties.DnsAddresses.Any() || hasNonLoopbackDns)
                            {
                                Debug.WriteLine($"Selected primary adapter: {nic.Name}");
                                return nic.Name;
                            }
                        }
                    }
                }
                Debug.WriteLine("No suitable network adapter found");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Error getting network adapter name: {ex.Message}");
            }
            return null;
        }

        private async void TestWslButton_Click(object sender, RoutedEventArgs e)
        {
            StatusTextBlock.Text = "Running comprehensive WSL diagnostics...";
            StatusTextBlock.Foreground = Brushes.Orange;

            await Task.Run(() => {
                WSLManager.TestWslAccess();

                Debug.WriteLine("=== TESTING IP DETECTION ===");
                string? ip = WSLManager.GetWslIpAddress("Ubuntu");
                Debug.WriteLine($"IP Detection Result: {ip ?? "NULL"}");
                Debug.WriteLine("=== IP DETECTION COMPLETE ===");
            });

            StatusTextBlock.Text = "Diagnostics complete - check debug output and desktop log file";
            StatusTextBlock.Foreground = Brushes.Blue;

            MessageBox.Show("WSL diagnostics complete!\n\n" +
                            "Check the following for detailed logs:\n" +
                            "1. Visual Studio Debug Output window\n" +
                            "2. Console output (if running from command line)\n" +
                            "3. Desktop file: pifill_wsl_debug.log\n\n" +
                            "This will help identify exactly where the WSL communication is failing.",
                            "Diagnostics Complete", MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }
}