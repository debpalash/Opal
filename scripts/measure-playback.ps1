param(
    [string]$Binary = "$env:LOCALAPPDATA\Opal\opal.exe",
    [Parameter(Mandatory = $true)][string]$Media,
    [ValidateRange(1, 20)][int]$Runs = 5,
    [ValidateRange(1, 60)][int]$TimeoutSeconds = 15,
    [ValidateRange(50, 30000)][int]$FirstFrameBudgetMs = 500,
    [switch]$KeepOpenOnFailure
)

$ErrorActionPreference = 'Stop'
$resolvedBinary = (Resolve-Path -LiteralPath $Binary).Path
$mediaTarget = if ([Uri]::IsWellFormedUriString($Media, [UriKind]::Absolute)) {
    $Media
} else {
    (Resolve-Path -LiteralPath $Media).Path
}
$timingLog = Join-Path $env:APPDATA 'opal\timing.log'

$running = @(Get-Process -Name opal -ErrorAction SilentlyContinue)
if ($running.Count -ne 0) { throw 'Close Opal before measuring playback.' }

$samples = [System.Collections.Generic.List[double]]::new()
for ($run = 1; $run -le $Runs; $run++) {
    $before = if (Test-Path -LiteralPath $timingLog) {
        (Get-Item -LiteralPath $timingLog).LastWriteTimeUtc
    } else { [DateTime]::MinValue }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $resolvedBinary
    $psi.Arguments = '"' + $mediaTarget + '"'
    $psi.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($psi)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $timingText = ''

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 10
        if ($process.HasExited) { throw "Opal exited during playback run $run." }
        if (-not (Test-Path -LiteralPath $timingLog)) { continue }
        $item = Get-Item -LiteralPath $timingLog
        if ($item.LastWriteTimeUtc -le $before) { continue }
        $timingText = Get-Content -LiteralPath $timingLog -Raw
        if ($timingText -match 'first-frame: trigger\+([0-9]+)ms') { break }
    }

    if ($timingText -notmatch 'first-frame: trigger\+([0-9]+)ms') {
        if ($KeepOpenOnFailure) {
            Write-Output "Opal PID $($process.Id) kept open after missing first-frame milestone."
            exit 2
        }
        if (-not $process.HasExited) { $process.Kill() }
        throw "No first-frame milestone within $TimeoutSeconds seconds on run $run."
    }
    if ($timingText.IndexOf('file-loaded:') -gt $timingText.IndexOf('first-frame:')) {
        if (-not $process.HasExited) { $process.Kill() }
        throw "Invalid milestone order on run ${run}: first frame preceded file-loaded."
    }
    $samples.Add([double]$Matches[1])

    [void]$process.CloseMainWindow()
    if (-not $process.WaitForExit(5000)) {
        $process.Kill()
        [void]$process.WaitForExit(2000)
    }
    Start-Sleep -Milliseconds 250
}

$ordered = @($samples | Sort-Object)
$p95Index = [Math]::Max(0, [Math]::Ceiling($Runs * 0.95) - 1)
$median = if (($Runs % 2) -eq 1) {
    $ordered[[int][Math]::Floor($Runs / 2)]
} else {
    ($ordered[$Runs / 2 - 1] + $ordered[$Runs / 2]) / 2
}
$p95 = [Math]::Round($ordered[$p95Index], 1)
$passed = $p95 -le $FirstFrameBudgetMs

[pscustomobject]@{
    binary = $resolvedBinary
    media = $mediaTarget
    metric = 'open-trigger-to-first-frame-ms'
    runs = $Runs
    median_ms = [Math]::Round($median, 1)
    p95_ms = $p95
    max_ms = [Math]::Round($ordered[-1], 1)
    budget_ms = $FirstFrameBudgetMs
    samples_ms = @($samples)
    passed = $passed
} | ConvertTo-Json -Depth 3
if (-not $passed) { exit 1 }
