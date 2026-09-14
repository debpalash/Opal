param(
    [string]$Binary = "$env:LOCALAPPDATA\Opal\opal.exe",
    [string]$Media = '',
    [ValidateRange(1, 120)][int]$SampleSeconds = 8,
    [ValidateRange(64, 4096)][int]$WorkingSetBudgetMb = 700,
    [ValidateRange(100, 20000)][int]$HandleBudget = 3000
)

$ErrorActionPreference = 'Stop'
$resolvedBinary = (Resolve-Path -LiteralPath $Binary).Path
$mediaTarget = if ([string]::IsNullOrWhiteSpace($Media)) {
    ''
} elseif ([Uri]::IsWellFormedUriString($Media, [UriKind]::Absolute)) {
    $Media
} else {
    (Resolve-Path -LiteralPath $Media).Path
}

if (-not ('OpalResourceNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class OpalResourceNative {
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);
}
'@
}

$running = @(Get-Process -Name opal -ErrorAction SilentlyContinue | Where-Object {
    try { [string]::Equals($_.Path, $resolvedBinary, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
})
if ($running.Count -ne 0) { throw 'Close the installed Opal before measuring resources.' }

function Get-DescendantIds([int]$RootId) {
    $rows = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId)
    $known = [System.Collections.Generic.HashSet[int]]::new()
    [void]$known.Add($RootId)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($row in $rows) {
            if ($known.Contains([int]$row.ParentProcessId) -and $known.Add([int]$row.ProcessId)) {
                $changed = $true
            }
        }
    }
    return @($known | Where-Object { $_ -ne $RootId })
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $resolvedBinary
if ($mediaTarget) { $psi.Arguments = '"' + $mediaTarget + '"' }
$psi.UseShellExecute = $false
$process = [System.Diagnostics.Process]::Start($psi)
$observedChildren = [System.Collections.Generic.HashSet[int]]::new()

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) { throw 'Opal exited before the resource sample.' }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero -and
            [OpalResourceNative]::IsWindowVisible($process.MainWindowHandle) -and
            $process.Responding) { break }
        Start-Sleep -Milliseconds 20
    }
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Opal did not expose a window.' }

    $peakWorkingSet = 0L
    $peakPrivate = 0L
    $peakHandles = 0
    $peakChildren = 0
    $sampleDeadline = [DateTime]::UtcNow.AddSeconds($SampleSeconds)
    while ([DateTime]::UtcNow -lt $sampleDeadline) {
        $process.Refresh()
        if ($process.HasExited) { throw 'Opal exited during the resource sample.' }
        $peakWorkingSet = [Math]::Max($peakWorkingSet, $process.WorkingSet64)
        $peakPrivate = [Math]::Max($peakPrivate, $process.PrivateMemorySize64)
        $peakHandles = [Math]::Max($peakHandles, $process.HandleCount)
        $children = @(Get-DescendantIds $process.Id)
        foreach ($childId in $children) { [void]$observedChildren.Add([int]$childId) }
        $peakChildren = [Math]::Max($peakChildren, $children.Count)
        Start-Sleep -Milliseconds 250
    }

    [void]$process.CloseMainWindow()
    if (-not $process.WaitForExit(5000)) { throw 'Opal did not close within five seconds.' }
    Start-Sleep -Milliseconds 300
    $orphans = @($observedChildren | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    $workingSetMb = [Math]::Round($peakWorkingSet / 1MB, 1)
    $privateMb = [Math]::Round($peakPrivate / 1MB, 1)
    $passed = $workingSetMb -le $WorkingSetBudgetMb -and $peakHandles -le $HandleBudget -and $orphans.Count -eq 0

    [pscustomobject]@{
        binary = $resolvedBinary
        media = $mediaTarget
        metric = 'peak-process-resources-and-clean-shutdown'
        sample_seconds = $SampleSeconds
        peak_working_set_mb = $workingSetMb
        peak_private_mb = $privateMb
        peak_handles = $peakHandles
        peak_child_processes = $peakChildren
        orphan_child_processes = $orphans.Count
        working_set_budget_mb = $WorkingSetBudgetMb
        handle_budget = $HandleBudget
        passed = $passed
    } | ConvertTo-Json -Depth 3
    if (-not $passed) { exit 1 }
} finally {
    if (-not $process.HasExited) {
        $process.Kill()
        [void]$process.WaitForExit(2000)
    }
}
