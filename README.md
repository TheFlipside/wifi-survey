# WiFi Survey

A PowerShell tool that collects data about the WiFi environment — SSIDs,
BSSIDs, signal strength (max observed), band, channel, authentication, and
encryption — and writes the findings to disk for further analysis.

Designed to run with the smallest possible footprint on Windows: no installs,
no external dependencies. It uses the built-in `netsh` command and the
`wlanapi.dll` Windows API.

## Requirements

- Windows 10 / 11 with a working WiFi adapter
- The **WLAN AutoConfig** service (`WlanSvc`) running (default on most installs)
- **Location services must be enabled.** Recent Windows builds gate WiFi
  scanning behind the Location permission. Without it, `netsh` returns no
  networks and exits with an error.

  Enable in **Settings → Privacy & security → Location**:
  - Turn on **Location services**
  - Turn on **Let desktop apps access your location**

  Quick open from a shell:

  ```powershell
  Start-Process ms-settings:privacy-location
  ```

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File wifi-survey.ps1
```

The script scans continuously until you press **Ctrl+C**. Each newly seen SSID
is printed once on the first sighting; per-BSSID details (including the
strongest signal observed) are tracked silently in the background and written
to disk on exit.

### Parameters

| Parameter          | Type     | Default                                 | Description                                                                                                            |
| ------------------ | -------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `-IntervalSeconds` | `int`    | `5`                                     | Seconds between scan rounds. Also acts as the settle time after each forced `WlanScan` trigger.                        |
| `-OutputPath`      | `string` | `wifi-survey_<yyyyMMdd_HHmmss>` in cwd  | Base path for the output files. Any extension is stripped; the script writes `<base>.csv` and `<base>.json` alongside. |

Examples:

```powershell
# Default: 5s interval, timestamped output in the current directory
powershell -ExecutionPolicy Bypass -File wifi-survey.ps1

# Faster polling, custom output base path
powershell -ExecutionPolicy Bypass -File wifi-survey.ps1 -IntervalSeconds 3 -OutputPath C:\surveys\office-floor-2

# Run with debug output (e.g. to see WlanScan trigger errors)
powershell -ExecutionPolicy Bypass -File wifi-survey.ps1 -Debug
```

## Whitelist (optional)

To mark certain SSIDs as trusted in the output, copy the sample file:

```powershell
Copy-Item whitelist_ssid.txt.sample whitelist_ssid.txt
```

Then edit `whitelist_ssid.txt` — one SSID per line. Blank lines and lines
starting with `#` are ignored. The file is read from the script's directory
on each run.

Effect:

- Live output: trusted SSIDs are tagged `[trusted]` on first sighting.
- CSV / JSON: a `Trusted` boolean column is added; trusted networks are
  sorted to the top of the output.

## Output

Two files are written on exit (Ctrl+C):

- **`<base>.csv`** — one row per BSSID, sorted by trusted-first, then SSID,
  then strongest signal.
- **`<base>.json`** — same network rows wrapped in a small report object with
  `StartedAt`, `EndedAt`, `ScanRounds`, `UniqueSsids`, `UniqueBssids`.

### Columns

| Column           | Description                                                       |
| ---------------- | ----------------------------------------------------------------- |
| `SSID`           | Network name (empty string for hidden networks)                   |
| `BSSID`          | Access-point MAC address — unique key for each row                |
| `Trusted`        | `true` if the SSID is listed in `whitelist_ssid.txt`              |
| `MaxSignal`      | Highest signal strength observed during the run, in percent       |
| `MaxSignalDbm`   | The same value converted to dBm (`percent / 2 - 100`)             |
| `MaxSignalAt`    | Timestamp of the strongest reading                                |
| `Band`           | e.g. `2.4 GHz`, `5 GHz`, `6 GHz` (depends on Windows version)     |
| `Channel`        | WiFi channel number                                               |
| `RadioType`      | e.g. `802.11n`, `802.11ax`                                        |
| `Authentication` | e.g. `WPA2-Personal`, `WPA3-Personal`, `Open`                     |
| `Encryption`     | e.g. `CCMP`, `GCMP`, `None`                                       |
| `FirstSeen`      | Timestamp of the first sighting in this run                       |
| `LastSeen`       | Timestamp of the most recent sighting                             |
| `Sightings`      | Number of scan rounds in which this BSSID was visible             |
