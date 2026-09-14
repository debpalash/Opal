param(
    [string]$Binary = "$env:LOCALAPPDATA\Opal\opal.exe",
    [ValidateRange(1, 20)][int]$Runs = 5,
    [ValidateRange(1, 30)][int]$TimeoutSeconds = 10,
    [ValidateRange(50, 10000)][int]$StartupBudgetMs = 350,
    [ValidateRange(50, 10000)][int]$CloseBudgetMs = 2000
)

$ErrorActionPreference = 'Stop'
$resolvedBinary = (Resolve-Path -LiteralPath $Binary).Path

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class OpalStartupNative {
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$sameBinary = @(Get-Process -Name opal -ErrorAction SilentlyContinue | Where-Object {
    try { [string]::Equals($_.Path, $resolvedBinary, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
})
if ($sameBinary.Count -ne 0) {
    throw "Close the installed Opal before measuring startup."
}

$samples = [System.Collections.Generic.List[double]]::new()
$closeSamples = [System.Collections.Generic.List[double]]::new()
$forcedCloses = 0
$snapContractFailures = 0
for ($run = 1; $run -le $Runs; $run++) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $resolvedBinary
    $psi.UseShellExecute = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($psi)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $visibleMs = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) { throw "Opal exited during startup run $run." }
        $handle = $process.MainWindowHandle
        if ($handle -ne [IntPtr]::Zero -and
            [OpalStartupNative]::IsWindowVisible($handle) -and
            $process.Responding) {
            $visibleMs = $watch.Elapsed.TotalMilliseconds
            break
        }
        Start-Sleep -Milliseconds 5
    }

    if ($null -eq $visibleMs) {
        if (-not $process.HasExited) { $process.Kill() }
        throw "Opal did not expose a responsive painted window within $TimeoutSeconds seconds."
    }
    $samples.Add($visibleMs)

    # Aero Snap needs both the native sizing/caption styles and a real caption
    # hit-test. This checks the installed window contract without moving it.
    $requiredStyle = 0x00CF0000L # CAPTION|THICKFRAME|MINBOX|MAXBOX|SYSMENU
    $style = [OpalStartupNative]::GetWindowLongPtr($handle, -16).ToInt64()
    $rect = [OpalStartupNative+RECT]::new()
    $captionHit = $false
    if ([OpalStartupNative]::GetWindowRect($handle, [ref]$rect)) {
        $x = $rect.Left + [int](($rect.Right - $rect.Left) / 2)
        $y = $rect.Top + 15
        $packed = (($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF)
        $hit = [OpalStartupNative]::SendMessageW($handle, 0x0084, [IntPtr]::Zero, [IntPtr]$packed).ToInt64()
        $captionHit = $hit -eq 2 # HTCAPTION
    }
    if (($style -band $requiredStyle) -ne $requiredStyle -or -not $captionHit) {
        $snapContractFailures++
    }

    $closeWatch = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$process.CloseMainWindow()
    if (-not $process.WaitForExit(5000)) {
        $forcedCloses++
        $process.Kill()
        [void]$process.WaitForExit(2000)
    }
    $closeSamples.Add($closeWatch.Elapsed.TotalMilliseconds)
    Start-Sleep -Milliseconds 250
}

$ordered = @($samples | Sort-Object)
$median = if (($Runs % 2) -eq 1) {
    $ordered[[int][Math]::Floor($Runs / 2)]
} else {
    ($ordered[$Runs / 2 - 1] + $ordered[$Runs / 2]) / 2
}
$p95Index = [Math]::Max(0, [Math]::Ceiling($Runs * 0.95) - 1)
$orderedClose = @($closeSamples | Sort-Object)
$closeMedian = if (($Runs % 2) -eq 1) {
    $orderedClose[[int][Math]::Floor($Runs / 2)]
} else {
    ($orderedClose[$Runs / 2 - 1] + $orderedClose[$Runs / 2]) / 2
}

$startupP95 = [Math]::Round($ordered[$p95Index], 1)
$closeP95 = [Math]::Round($orderedClose[$p95Index], 1)
$passed = $startupP95 -le $StartupBudgetMs -and $closeP95 -le $CloseBudgetMs -and $forcedCloses -eq 0 -and $snapContractFailures -eq 0
$report = [pscustomobject]@{
    binary = $resolvedBinary
    metric = 'process-start-to-visible-responsive-window-ms'
    runs = $Runs
    min_ms = [Math]::Round($ordered[0], 1)
    median_ms = [Math]::Round($median, 1)
    p95_ms = $startupP95
    max_ms = [Math]::Round($ordered[-1], 1)
    samples_ms = @($samples | ForEach-Object { [Math]::Round($_, 1) })
    close_median_ms = [Math]::Round($closeMedian, 1)
    close_p95_ms = $closeP95
    forced_closes = $forcedCloses
    aero_snap_contract_failures = $snapContractFailures
    startup_budget_ms = $StartupBudgetMs
    close_budget_ms = $CloseBudgetMs
    passed = $passed
}
$report | ConvertTo-Json -Depth 3
if (-not $passed) { exit 1 }
