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

## Appendix: Recovering hidden SSID names (Linux)

**Out of scope for this tool.** Windows' built-in WiFi APIs cannot recover the
name of a hidden network — the OS scan cache returns an empty SSID and there
is no monitor-mode access. If you want to put a name to a hidden BSSID you
captured here, you'll need a Linux box with a monitor-mode-capable adapter.

> ⚠️ **Legality.** Sending deauthentication frames against networks or
> stations you do not own (step 6 below) is illegal in many jurisdictions
> and is treated as a denial-of-service attack. Only do this on equipment
> you own or have explicit written permission to test.

### 1. Prerequisites

- A Linux machine (Kali/Parrot ship the tools below; on Debian/Ubuntu:
  `sudo apt install aircrack-ng iw`).
- A WiFi adapter whose driver supports monitor mode and frame injection.
  Common known-good chipsets: Atheros AR9271 (TP-Link TL-WN722N **v1**),
  Ralink RT3070/RT5370, Realtek RTL8812AU (with `aircrack-ng/rtl8812au` DKMS).
- Root.

### 2. Verify the adapter

Find the interface name and check whether `monitor` appears in its supported
modes:

```bash
iw dev                                   # find the interface, e.g. wlan0
iw list | grep -A 10 "Supported interface modes"
```

If `* monitor` is missing, the driver/firmware will not work — pick a different
adapter.

### 3. Stop interfering services

`NetworkManager` and `wpa_supplicant` will fight you for the radio. The easiest
way is to let `airmon-ng` kill them for you:

```bash
sudo airmon-ng check kill
```

If you prefer to do it by hand:

```bash
sudo systemctl stop NetworkManager
sudo systemctl stop wpa_supplicant
```

(These are re-enabled in step 7 when you exit monitor mode.)

### 4. Enable monitor mode

```bash
sudo airmon-ng start wlan0
```

This usually creates a virtual interface named `wlan0mon` (or renames `wlan0`
in place). Confirm:

```bash
iw dev                                   # type should now be "monitor"
```

### 5. Capture frames

You can either watch every network at once, or pin a single hidden AP for a
higher per-frame capture rate. Pick whichever fits the situation.

#### 5a. Scan all networks (broad sweep)

```bash
sudo airodump-ng -w all-capture wlan0mon
```

`airodump-ng` channel-hops across every channel it can. Hidden APs show up
in the upper pane with `<length: 0>` (or `<length: N>`) in the `ESSID`
column. Names get filled in passively whenever any nearby client probes for
or associates with one of them.

Useful refinements:

- `--band bg` — 2.4 GHz only. `--band a` — 5 GHz only. `--band abg` — both.
- `-w all-capture` writes a pcap you can open later in Wireshark
  (`wlan.fc.type_subtype == 0x04` filters probe requests, which often leak
  SSIDs that no AP in range is currently broadcasting).
- The longer you leave it running, the more SSIDs surface. Peak hours with
  active clients are most productive; an empty office at 3 AM will find
  almost nothing.

#### 5b. Target one specific BSSID

Take the BSSID and `Channel` from your wifi-survey CSV/JSON, then:

```bash
sudo airodump-ng --bssid AA:BB:CC:DD:EE:FF -c <channel> -w hidden-capture wlan0mon
```

The top pane shows the AP (SSID still hidden as `<length: 0>`); the bottom
pane lists associated client MACs (the `STATION` column). Locking to one
channel skips the channel-hop dwell time, so you capture every frame on that
channel — useful once you've narrowed down to a specific hidden AP and want
the active-deauth method in step 6 to land reliably.

#### 5c. Hidden-only filtering with `tshark`

`airodump-ng` does not have a "hidden APs only" flag. If that's what you
want — see only the networks that are concealing their name and ignore the
rest — use `tshark` (the Wireshark CLI; `sudo apt install tshark`). The
trick is to filter on the SSID information element having length 0, which
is exactly what hidden beacons advertise.

##### Phase 1 — discover hidden BSSIDs (live)

```bash
sudo tshark -i wlan0mon \
  -Y 'wlan.fc.type_subtype == 0x08 && wlan.tag.number == 0 && wlan.tag.length == 0' \
  -T fields -e wlan.bssid | sort -u
```

That stream is "every BSSID broadcasting a length-0 SSID beacon", deduped.

##### Phase 2 — watch for the SSID to be revealed

The same filter would *exclude* the moment of reveal, because a frame
carrying the real name has a non-empty SSID IE. Drop the length constraint
and pin to the BSSID you're chasing:

```bash
sudo tshark -i wlan0mon \
  -Y 'wlan.bssid == AA:BB:CC:DD:EE:FF \
      && wlan.tag.number == 0 && wlan.tag.length > 0' \
  -T fields -e wlan.fc.type_subtype -e wlan.ssid
```

Whatever shows up in the `wlan.ssid` column the next time a client probes,
associates, or the AP answers a directed probe is the real network name.

##### Cleaner pattern — capture once, filter offline

For surveys, save everything to a pcap and answer the question for every
hidden BSSID after the fact:

```bash
sudo tshark -i wlan0mon -w sweep.pcap            # let this run for a while

# discover hidden BSSIDs in the capture
tshark -r sweep.pcap \
  -Y 'wlan.fc.type_subtype == 0x08 && wlan.tag.number == 0 && wlan.tag.length == 0' \
  -T fields -e wlan.bssid | sort -u

# look for the reveal of one of them
tshark -r sweep.pcap \
  -Y 'wlan.bssid == AA:BB:CC:DD:EE:FF \
      && wlan.tag.number == 0 && wlan.tag.length > 0' \
  -T fields -e wlan.ssid | sort -u
```

Two caveats worth knowing:

- **Probe Requests (subtype `0x04`) come from clients, not the AP.** Their
  `wlan.bssid` field is usually the broadcast wildcard, not the hidden AP's
  MAC, so a phone in your pocket leaking the SSID via probe-request will
  *not* match `wlan.bssid == <ap-mac>`. To catch those, drop the BSSID
  filter and search on the SSID string itself.
- **Some APs implement "hidden" by sending the SSID field zeroed but
  length-padded** (e.g. 8 NUL bytes for an 8-character name) instead of
  length-0. Those won't match `wlan.tag.length == 0`; switch to
  `wlan.ssid matches "^\\x00+$"` to catch them. Modern firmware mostly uses
  length-0; older gear sometimes does the NUL-padded variant.

### 6. Reveal the SSID

The SSID is **not** broadcast in the beacons of a hidden AP, but it travels
in the clear in:

- a client's **Probe Request / Response**, and
- the **Association Request** during the WPA handshake.

**Passive:** just leave `airodump-ng` running. As soon as any associated
client sends a probe or re-associates, the `ESSID` column fills in. This can
take minutes to days depending on traffic.

**Active (faster, more aggressive):** force an associated station to
reconnect by deauthenticating it. From a second terminal:

```bash
sudo aireplay-ng --deauth 5 -a AA:BB:CC:DD:EE:FF -c <client-mac> wlan0mon
```

The client will normally re-associate within a few seconds and `airodump-ng`
will populate the SSID. If no clients are associated, you cannot use this
method — passive capture is your only option.

### 7. Restore normal operation

```bash
sudo airmon-ng stop wlan0mon
sudo systemctl start NetworkManager      # only if you stopped it manually
sudo systemctl start wpa_supplicant      # only if you stopped it manually
```

The original managed-mode interface (`wlan0`) is back and your machine should
reconnect to its usual network.
