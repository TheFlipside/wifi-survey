# wifi-survey.ps1
# Scans the WiFi environment via the built-in `netsh` command and records the
# strongest signal seen per BSSID over the duration of the run. Press Ctrl+C
# to stop; CSV + JSON summaries are written on exit.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'Interactive CLI status output - colour and information-stream behaviour are intentional'
)]
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 5,
    [string]$OutputPath
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $OutputPath) {
    $OutputPath = Join-Path (Get-Location) ("wifi-survey_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
# Resolve to an absolute path now so a later cwd change doesn't move the output files.
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) $OutputPath
}
# Treat -OutputPath as a base; strip a trailing extension so we can write both .csv and .json
$basePath = [System.IO.Path]::Combine(
    [System.IO.Path]::GetDirectoryName($OutputPath),
    [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
)
$csvPath  = "$basePath.csv"
$jsonPath = "$basePath.json"

# Make sure the destination directory exists - otherwise Save-Survey would throw inside
# the Ctrl+C finally and silently lose the entire collected dataset.
$outputDir = [System.IO.Path]::GetDirectoryName($basePath)
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    [void](New-Item -ItemType Directory -Path $outputDir -Force -ErrorAction Stop)
}

# --- WlanScan P/Invoke (wlanapi.dll ships with Windows) ----------------------
$wlanApiSource = @'
using System;
using System.Runtime.InteropServices;

public static class WlanApi {
    [DllImport("wlanapi.dll")]
    public static extern uint WlanOpenHandle(uint dwClientVersion, IntPtr pReserved,
        out uint pdwNegotiatedVersion, out IntPtr phClientHandle);

    [DllImport("wlanapi.dll")]
    public static extern uint WlanCloseHandle(IntPtr hClientHandle, IntPtr pReserved);

    [DllImport("wlanapi.dll")]
    public static extern uint WlanEnumInterfaces(IntPtr hClientHandle, IntPtr pReserved,
        out IntPtr ppInterfaceList);

    [DllImport("wlanapi.dll")]
    public static extern void WlanFreeMemory(IntPtr pMemory);

    [DllImport("wlanapi.dll")]
    public static extern uint WlanScan(IntPtr hClientHandle, ref Guid pInterfaceGuid,
        IntPtr pDot11Ssid, IntPtr pIeData, IntPtr pReserved);

    // Returns the number of interfaces a scan was successfully kicked off on, or -1 on failure.
    public static int TriggerScan() {
        uint negotiated;
        IntPtr handle;
        if (WlanOpenHandle(2, IntPtr.Zero, out negotiated, out handle) != 0) return -1;
        int triggered = 0;
        try {
            IntPtr listPtr;
            if (WlanEnumInterfaces(handle, IntPtr.Zero, out listPtr) != 0) return -1;
            try {
                int count = Marshal.ReadInt32(listPtr);
                IntPtr arrayStart = IntPtr.Add(listPtr, 8); // skip dwNumberOfItems + dwIndex
                int structSize = 16 + 512 + 4;              // Guid + WCHAR[256] + state enum
                for (int i = 0; i < count; i++) {
                    IntPtr cur = IntPtr.Add(arrayStart, i * structSize);
                    byte[] g = new byte[16];
                    Marshal.Copy(cur, g, 0, 16);
                    Guid guid = new Guid(g);
                    if (WlanScan(handle, ref guid, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0) {
                        triggered++;
                    }
                }
            } finally { WlanFreeMemory(listPtr); }
        } finally { WlanCloseHandle(handle, IntPtr.Zero); }
        return triggered;
    }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'WlanApi').Type) {
    Add-Type -TypeDefinition $wlanApiSource -Language CSharp -ErrorAction Stop
}

# --- State -------------------------------------------------------------------
$networks  = @{}
$seenSsids = New-Object System.Collections.Generic.HashSet[string]
$scanCount = 0
$startedAt = Get-Date

# --- Whitelist ---------------------------------------------------------------
function Import-Whitelist {
    param([string]$Dir)
    $set = New-Object System.Collections.Generic.HashSet[string]
    $path = Join-Path $Dir 'whitelist_ssid.txt'
    if (Test-Path $path) {
        Get-Content -LiteralPath $path | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#')) { [void]$set.Add($line) }
        }
        Write-Host ("Whitelist: {0} SSID(s) loaded from {1}" -f $set.Count, $path) -ForegroundColor Cyan
    } else {
        Write-Host "Whitelist: none (whitelist_ssid.txt not found - copy whitelist_ssid.txt.sample to enable)" -ForegroundColor DarkGray
    }
    return ,$set
}
$whitelist = Import-Whitelist -Dir $scriptDir

# --- Helpers -----------------------------------------------------------------
function ConvertTo-Dbm {
    param([Nullable[int]]$Percent)
    if ($null -eq $Percent) { return $null }
    return [int](($Percent / 2) - 100)
}

# Strip ASCII control characters (and DEL) so a hostile SSID cannot inject ANSI/VT escape
# sequences into the terminal (e.g. forging a `[trusted]` tag or overwriting prior output).
# Raw SSID values are preserved verbatim in the CSV/JSON so analysis tools see ground truth.
function Format-SsidForDisplay {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    return ($Value -replace '[\x00-\x1F\x7F]', '?')
}

function ConvertFrom-NetshOutput {
    param([string[]]$Lines)

    $results = New-Object System.Collections.Generic.List[object]

    $script:results = $results
    $script:ssid = $null; $script:auth = $null; $script:enc = $null
    $script:bssid = $null; $script:signal = $null
    $script:band = $null; $script:channel = $null; $script:radio = $null

    function Flush {
        if ($script:bssid) {
            $script:results.Add([PSCustomObject]@{
                SSID           = $script:ssid
                BSSID          = $script:bssid
                Signal         = $script:signal
                Band           = $script:band
                Channel        = $script:channel
                RadioType      = $script:radio
                Authentication = $script:auth
                Encryption     = $script:enc
            })
        }
        $script:bssid = $null; $script:signal = $null
        $script:band  = $null; $script:channel = $null; $script:radio = $null
    }

    foreach ($line in $Lines) {
        if ($line -match '^SSID\s+\d+\s*:\s*(.*)$') {
            Flush
            $script:ssid = $matches[1].Trim()
            $script:auth = $null
            $script:enc  = $null
        }
        elseif ($line -match '^\s*Authentication\s*:\s*(.*)$') {
            $script:auth = $matches[1].Trim()
        }
        elseif ($line -match '^\s*Encryption\s*:\s*(.*)$') {
            $script:enc = $matches[1].Trim()
        }
        elseif ($line -match '^\s*BSSID\s+\d+\s*:\s*(.*)$') {
            Flush
            $script:bssid = $matches[1].Trim()
        }
        elseif ($line -match '^\s*Signal\s*:\s*(\d+)\s*%') {
            $script:signal = [int]$matches[1]
        }
        elseif ($line -match '^\s*Radio type\s*:\s*(.*)$') {
            $script:radio = $matches[1].Trim()
        }
        elseif ($line -match '^\s*Band\s*:\s*(.*)$') {
            $script:band = $matches[1].Trim()
        }
        elseif ($line -match '^\s*Channel\s*:\s*(\d+)') {
            $script:channel = [int]$matches[1]
        }
    }
    Flush
    return $script:results
}

function Save-Survey {
    Write-Host ""
    if ($networks.Count -eq 0) {
        Write-Host "No networks captured - nothing to save." -ForegroundColor Yellow
        return
    }

    $rows = $networks.Values |
        Sort-Object @{Expression='Trusted'; Descending=$true}, SSID,
                    @{Expression='MaxSignal'; Descending=$true}, BSSID

    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    $report = [PSCustomObject]@{
        StartedAt    = $startedAt
        EndedAt      = Get-Date
        ScanRounds   = $scanCount
        UniqueSsids  = $seenSsids.Count
        UniqueBssids = $networks.Count
        Networks     = @($rows)
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8

    $duration = (Get-Date) - $startedAt
    Write-Host ("CSV  saved to: {0}" -f $csvPath)              -ForegroundColor Green
    Write-Host ("JSON saved to: {0}" -f $jsonPath)             -ForegroundColor Green
    Write-Host ("Duration:      {0:hh\:mm\:ss}" -f $duration)  -ForegroundColor Green
    Write-Host ("Scan rounds:   {0}" -f $scanCount)            -ForegroundColor Green
    Write-Host ("Unique SSIDs:  {0}" -f $seenSsids.Count)      -ForegroundColor Green
    Write-Host ("Unique BSSIDs: {0}" -f $networks.Count)       -ForegroundColor Green
}

# --- Main loop ---------------------------------------------------------------
Write-Host "WiFi Survey - press Ctrl+C to stop and save."     -ForegroundColor Cyan
Write-Host ("Interval: {0}s" -f $IntervalSeconds)             -ForegroundColor Cyan
Write-Host ("CSV out:  {0}" -f $csvPath)                      -ForegroundColor Cyan
Write-Host ("JSON out: {0}" -f $jsonPath)                     -ForegroundColor Cyan
Write-Host ""

try {
    while ($true) {
        # Kick off a fresh scan on every WLAN interface; the Start-Sleep below
        # gives the (asynchronous) scan time to complete before we harvest.
        try { [void][WlanApi]::TriggerScan() } catch { Write-Debug "WlanScan failed: $_" }

        Start-Sleep -Seconds $IntervalSeconds

        $output   = & netsh wlan show networks mode=bssid
        $exitCode = $LASTEXITCODE
        $records  = @(ConvertFrom-NetshOutput -Lines $output)

        if ($records.Count -eq 0) {
            # Only complain when netsh both reported failure AND gave us nothing to work with;
            # some Windows builds return non-zero with valid output, which we want to accept.
            if ($exitCode -ne 0) {
                Write-Host ("netsh exited {0} with no parseable networks." -f $exitCode) -ForegroundColor Red
                Write-Host "  Most common cause: Location services are off." -ForegroundColor Red
                Write-Host "  Enable: Settings -> Privacy & security -> Location (also 'Let desktop apps access your location')." -ForegroundColor Red
                Write-Host "  Quick open: Start-Process ms-settings:privacy-location" -ForegroundColor Red
            }
            continue
        }

        $scanCount++
        $now = Get-Date

        foreach ($r in $records) {
            if ([string]::IsNullOrWhiteSpace($r.BSSID)) { continue }

            $key = $r.BSSID
            if ($networks.ContainsKey($key)) {
                $existing = $networks[$key]
                if ($null -ne $r.Signal -and $r.Signal -gt $existing.MaxSignal) {
                    $existing.MaxSignal    = $r.Signal
                    $existing.MaxSignalDbm = ConvertTo-Dbm $r.Signal
                    $existing.MaxSignalAt  = $now
                }
                if ($r.Band)    { $existing.Band    = $r.Band }
                if ($r.Channel) { $existing.Channel = $r.Channel }
                $existing.LastSeen  = $now
                $existing.Sightings = $existing.Sightings + 1
            }
            else {
                $trusted = $false
                if (-not [string]::IsNullOrEmpty($r.SSID)) {
                    $trusted = $whitelist.Contains($r.SSID)
                }
                $networks[$key] = [PSCustomObject]@{
                    SSID           = $r.SSID
                    BSSID          = $r.BSSID
                    Trusted        = $trusted
                    MaxSignal      = $r.Signal
                    MaxSignalDbm   = ConvertTo-Dbm $r.Signal
                    MaxSignalAt    = $now
                    Band           = $r.Band
                    Channel        = $r.Channel
                    RadioType      = $r.RadioType
                    Authentication = $r.Authentication
                    Encryption     = $r.Encryption
                    FirstSeen      = $now
                    LastSeen       = $now
                    Sightings      = 1
                }
            }

            $display = if ([string]::IsNullOrEmpty($r.SSID)) { '<hidden>' } else { $r.SSID }
            if ($seenSsids.Add($display)) {
                $isTrusted = (-not [string]::IsNullOrEmpty($r.SSID)) -and $whitelist.Contains($r.SSID)
                $tag       = if ($isTrusted) { ' [trusted]' } else { '' }
                $colour    = if ($isTrusted) { 'Cyan' } else { 'Green' }
                $safe      = Format-SsidForDisplay $display
                Write-Host ("[{0:HH:mm:ss}] new SSID: {1}{2}" -f $now, $safe, $tag) -ForegroundColor $colour
            }
        }
    }
}
finally {
    Save-Survey
}
