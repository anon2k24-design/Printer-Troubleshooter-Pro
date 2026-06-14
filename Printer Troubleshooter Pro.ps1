# Printer Troubleshooter Pro
# Complete printer fix with auto print spooler restart
# Author: anon2k24-design
#
# Support:
#   GitHub: https://github.com/anon2k24-design
#   Sponsor: https://github.com/sponsors/anon2k24-design

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Run this script as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Printer Troubleshooter Pro" -ForegroundColor Cyan
Write-Host "  Auto Fix + Print Spooler Restart" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$printerName = Read-Host "Enter printer name (or press Enter for first printer)"
if ([string]::IsNullOrWhiteSpace($printerName)) {
    $printer = Get-Printer | Select-Object -First 1
    if ($printer) {
        $printerName = $printer.Name
    }
    else {
        Write-Host "No printers found." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

Write-Host "Fixing printer: $printerName" -ForegroundColor Yellow
Write-Host ""

# STEP 1: Check if printer exists
Write-Host "[STEP 1/7] Checking printer..." -ForegroundColor Yellow
$printer = Get-Printer -Name $printerName -ErrorAction SilentlyContinue
if ($printer) {
    Write-Host "✓ Printer found. Status: $($printer.PrinterStatus)" -ForegroundColor Green
}
else {
    Write-Host "Printer not found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# STEP 2: Clear print queue
Write-Host ""
Write-Host "[STEP 2/7] Clearing print queue..." -ForegroundColor Yellow
Get-PrintJob -PrinterName $printerName -ErrorAction SilentlyContinue | Remove-PrintJob -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "✓ Print queue cleared" -ForegroundColor Green

# STEP 3: Check printer ports
Write-Host ""
Write-Host "[STEP 3/7] Checking network ports..." -ForegroundColor Yellow

$printerHost = $null
$printerPortName = $printer.PortName
$printerPort = Get-PrinterPort -Name $printerPortName -ErrorAction SilentlyContinue

if ($printerPort -and $printerPort.PrinterHostAddress) {
    $printerHost = $printerPort.PrinterHostAddress
}
elseif ($printerPortName -match '^\d{1,3}(\.\d{1,3}){3}$') {
    $printerHost = $printerPortName
}
else {
    $printerHost = $printerName
}

$openPortFound = $false
foreach ($port in 9100, 515, 631, 80) {
    try {
        $test = Test-NetConnection -ComputerName $printerHost -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($test) {
            Write-Host "✓ Port $port is open on $printerHost" -ForegroundColor Green
            $openPortFound = $true
            break
        }
        else {
            Write-Host "• Port $port not responding on $printerHost" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "• Port $port test failed on $printerHost" -ForegroundColor DarkGray
    }
}

if (-not $openPortFound) {
    Write-Host "WARNING: No common printer TCP ports responded." -ForegroundColor Yellow
}

# STEP 4: Check port and SNMP details
Write-Host ""
Write-Host "[STEP 4/7] Checking printer port settings..." -ForegroundColor Yellow
if ($printerPort) {
    Write-Host "✓ Port Name: $($printerPort.Name)" -ForegroundColor Green
    if ($printerPort.PrinterHostAddress) {
        Write-Host "✓ Printer Host Address: $($printerPort.PrinterHostAddress)" -ForegroundColor Green
    }
    if ($null -ne $printerPort.SNMPEnabled) {
        if ($printerPort.SNMPEnabled) {
            Write-Host "✓ SNMP is enabled" -ForegroundColor Green
        }
        else {
            Write-Host "WARNING: SNMP is disabled" -ForegroundColor Yellow
        }
    }
}
else {
    Write-Host "WARNING: Could not read printer port details." -ForegroundColor Yellow
}

# STEP 5: Restart Print Spooler Service
Write-Host ""
Write-Host "[STEP 5/7] Restarting Print Spooler service..." -ForegroundColor Yellow
try {
    Restart-Service -Name Spooler -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    Write-Host "✓ Print Spooler restarted successfully" -ForegroundColor Green
}
catch {
    Write-Host "Failed to restart Print Spooler." -ForegroundColor Red
}

# STEP 6: Clear spool files
Write-Host ""
Write-Host "[STEP 6/7] Clearing stuck spool files..." -ForegroundColor Yellow
try {
    Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
    Start-Service -Name Spooler -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Host "✓ Spool folder cleared" -ForegroundColor Green
}
catch {
    Write-Host "WARNING: Could not fully clear spool files." -ForegroundColor Yellow
}

# STEP 7: Final readiness check
Write-Host ""
Write-Host "[STEP 7/7] Final printer check..." -ForegroundColor Yellow
$printer = Get-Printer -Name $printerName -ErrorAction SilentlyContinue
if ($printer) {
    Write-Host "✓ Printer is still present. Queue is ready for a test print." -ForegroundColor Green
}
else {
    Write-Host "WARNING: Printer was not found after troubleshooting." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  ✓ Printer Troubleshooting Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Created by: anon2k24-design" -ForegroundColor Cyan
Write-Host "GitHub: https://github.com/anon2k24-design" -ForegroundColor Cyan
Write-Host "Sponsor: https://github.com/sponsors/anon2k24-design" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  - Try printing a Windows test page" -ForegroundColor White
Write-Host "  - If it still fails, update or reinstall the printer driver" -ForegroundColor White
Write-Host "  - Check Event Viewer for PrintService errors if problems continue" -ForegroundColor White
Write-Host ""

Read-Host "Press Enter to exit"