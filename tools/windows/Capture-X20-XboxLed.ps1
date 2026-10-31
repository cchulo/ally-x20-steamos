# SPDX-License-Identifier: GPL-2.0-only
<#
.SYNOPSIS
  Capture the USB commands Armoury Crate sends to the ROG Xbox Ally X20's
  controller MCU while you change the Xbox button light (brightness / on-off).

.DESCRIPTION
  The ally-x20-steamos project (SteamOS support for the X20) can drive the
  joystick ring LEDs but nobody has documented the command for the Xbox button
  light. This script records the USB traffic to the controller (VID 0B05,
  PID 1B4C "N-KEY Device") for a short window while you toggle the light in
  Armoury Crate, then zips the result so you can share it.

  Requirements: Windows 10/11, administrator PowerShell, USBPcap installed
  (free, https://desowin.org/usbpcap/ - install with the "USBPcapCMD" component;
  it is also bundled with Wireshark when you tick "USBPcap" in its installer).
  Nothing else is installed or changed. The capture contains only USB traffic
  to/from the controller; no personal data.

.EXAMPLE
  Right-click PowerShell -> Run as administrator, then:
    Set-ExecutionPolicy -Scope Process Bypass
    .\Capture-X20-XboxLed.ps1
  Follow the prompts. Send the resulting zip to the person who asked for it.
#>
[CmdletBinding()]
param(
  [int]$Seconds = 45,
  [string]$OutDir = (Join-Path $env:USERPROFILE 'Desktop\x20-xboxled-capture')
)

$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# --- preconditions -----------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail 'please run this script from an administrator PowerShell (USBPcap needs it).' }

$usbpcap = @(
  "$env:ProgramFiles\USBPcap\USBPcapCMD.exe",
  "${env:ProgramFiles(x86)}\USBPcap\USBPcapCMD.exe",
  "$env:ProgramFiles\Wireshark\extcap\USBPcapCMD.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $usbpcap) { Fail 'USBPcapCMD.exe not found. Install USBPcap from https://desowin.org/usbpcap/ (or re-run the Wireshark installer and tick USBPcap), then reboot and run this again.' }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# --- find the controller and its root hub ------------------------------------
$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_0B05&PID_1B4C*' -and $_.InstanceId -notlike '*MI_*' } | Select-Object -First 1
if (-not $dev) { Fail 'the X20 controller (USB VID_0B05 PID_1B4C) was not found. Is this a ROG Xbox Ally X20 with the ASUS drivers?' }
Write-Host "Controller: $($dev.FriendlyName) [$($dev.InstanceId)]"

$notes = @()
$notes += "ally-x20-steamos Xbox-button-light capture $stamp"
$notes += "Controller: $($dev.FriendlyName) [$($dev.InstanceId)]"
$notes += "Armoury Crate version: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -like 'Armoury Crate*' | Select-Object -First 1 -ExpandProperty DisplayVersion))"
$notes += "BIOS: $((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion)"

# USBPcap exposes one filter per root hub (\\.\USBPcap1, 2, ...). We capture
# every hub for the window (small on a handheld) so you do not have to work out
# which one the controller hangs off.
$hubs = @()
$i = 1
while ($i -le 8) {
  $name = "\\.\USBPcap$i"
  try {
    # -I prints the device tree for a filter; non-zero exit = no such filter.
    $null = & $usbpcap -d $name -I 2>$null
    if ($LASTEXITCODE -eq 0) { $hubs += $name }
  } catch { }
  $i++
}
if ($hubs.Count -eq 0) { Fail 'no USBPcap filters found (\\.\USBPcap1..8). Reboot after installing USBPcap and try again.' }
Write-Host "USB root hubs to capture: $($hubs -join ', ')"

# --- capture ---------------------------------------------------------------
Write-Host ''
Write-Host 'Please open Armoury Crate now and go to the Xbox button lighting setting.' -ForegroundColor Yellow
Write-Host "When you press Enter the capture starts and runs for $Seconds seconds." -ForegroundColor Yellow
Write-Host 'During that time: 1) turn the Xbox button light OFF, wait 3 s, 2) turn it ON, wait 3 s,' -ForegroundColor Yellow
Write-Host '3) set brightness to minimum, wait 3 s, 4) set brightness to maximum, 5) if there is a colour' -ForegroundColor Yellow
Write-Host 'setting, pick a clearly different colour. Note the order you did things.' -ForegroundColor Yellow
Read-Host 'Press Enter to start'

$procs = @()
$files = @()
foreach ($h in $hubs) {
  $f = Join-Path $OutDir ("usb-" + ($h -replace '[\\\.]', '') + "-$stamp.pcap")
  $files += $f
  # -A: capture all devices on the hub; -b: snaplen large enough for HID reports
  $procs += Start-Process -FilePath $usbpcap -ArgumentList @('-d', $h, '-o', "`"$f`"", '-A', '-b', '65535') -PassThru -WindowStyle Hidden
}
$t0 = Get-Date
Write-Host "Capturing... (do the steps now)" -ForegroundColor Green
for ($s = $Seconds; $s -gt 0; $s--) { Write-Host -NoNewline "`r$s s left   "; Start-Sleep -Seconds 1 }
Write-Host ''
foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
Start-Sleep -Seconds 1

$what = Read-Host 'Type what you did and in which order (e.g. "off, on, min, max, colour red")'
$notes += "Window: $t0 for $Seconds s"
$notes += "Actions: $what"
$notes | Set-Content -Path (Join-Path $OutDir "notes-$stamp.txt")

# --- optional quick summary if tshark is around ------------------------------
$tshark = @("$env:ProgramFiles\Wireshark\tshark.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($tshark) {
  $sum = Join-Path $OutDir "summary-$stamp.txt"
  foreach ($f in $files) {
    if ((Get-Item $f).Length -gt 0) {
      "== $f" | Add-Content $sum
      # Host-to-device transfers only: SET_REPORT control requests and interrupt/bulk OUT with payload.
      & $tshark -r $f -Y '(usb.setup.bRequest == 9 && usb.bmRequestType == 0x21) || (usb.endpoint_address.direction == 0 && usb.data_len > 0)' -T fields -e frame.time_relative -e usb.device_address -e usb.setup.wValue -e usb.setup.wIndex -e usb.data_len -e usb.capdata 2>$null | Add-Content $sum
    }
  }
  Write-Host "Wrote a text summary: $sum"
}

# --- pack ------------------------------------------------------------------
$zip = Join-Path $OutDir "x20-xboxled-capture-$stamp.zip"
Compress-Archive -Path (Join-Path $OutDir "*-$stamp.*") -DestinationPath $zip -Force
Write-Host ''
Write-Host "Done. Please share this file: $zip" -ForegroundColor Green
Write-Host 'It contains only USB traffic to the controller and the notes you typed.'
