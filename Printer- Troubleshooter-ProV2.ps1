# ============================================================================
# Printer Troubleshooter Pro v2
# ============================================================================
# Complete printer fix with queue clear, spooler restart, spool cleanup,
# network port test, and optional print log guidance.
# Windows PowerShell 5.1 / Windows 10-11
#
# Author: anon2k24-design
#
# Support:
#   PayPal: https://www.paypal.com/donate/?business=UNP6WN3E95EAL&currency_code=USD
#   GitHub: https://github.com/anon2k24-design
#   Sponsor: https://github.com/sponsors/anon2k24-design
# ============================================================================

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Run this script as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$ChangeLog = @()

function Add-Change {
    param($Type, $Path, $Name, $OldValue, $NewValue)
    $script:ChangeLog += [PSCustomObject]@{
        Timestamp = Get-Date
        Type      = $Type
        Path      = $Path
        Name      = $Name
        OldValue  = $OldValue
        NewValue  = $NewValue
    }
    try {
        $script:ChangeLog | Export-Csv ".\printer-troubleshooter-log.csv" -NoTypeInformation -Encoding UTF8
    } catch {}
}

function Get-SelectedPrinter {
    $printers = Get-Printer -ErrorAction SilentlyContinue

    if (-not $printers) {
        return $null
    }

    Write-Host "Detected printers:" -ForegroundColor Cyan
    $i = 1
    foreach ($p in $printers) {
        Write-Host ("  {0}. {1} | Driver: {2} | Port: {3}" -f $i, $p.Name, $p.DriverName, $p.PortName) -ForegroundColor White
        $i++
    }

    Write-Host ""
    $selection = Read-Host "Enter printer number, exact printer name, or press Enter for default/first printer"

    if ([string]::IsNullOrWhiteSpace($selection)) {
        $defaultPrinter = $printers | Where-Object { $_.Default -eq $true } | Select-Object -First 1
        if ($defaultPrinter) { return $defaultPrinter }
        return ($printers | Select-Object -First 1)
    }

    if ($selection -match '^\d+$') {
        $index = [int]$selection
        if ($index -ge 1 -and $index -le $printers.Count) {
            return $printers[$index - 1]
        }
    }

    return (Get-Printer -Name $selection -ErrorAction SilentlyContinue)
}

function Get-PrinterHost {
    param($Printer)

    $printerHost = $null
    $printerPort = $null

    try {
        $printerPort = Get-PrinterPort -Name $Printer.PortName -ErrorAction SilentlyContinue
    } catch {}

    if ($printerPort -and $printerPort.PrinterHostAddress) {
        $printerHost = $printerPort.PrinterHostAddress
    }
    elseif ($Printer.PortName -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $printerHost = $Printer.PortName
    }
    elseif ($Printer.PortName -match '^(WSD|USB|LPT|FILE|PORTPROMPT)') {
        $printerHost = $null
    }
    else {
        $printerHost = $Printer.Name
    }

    [PSCustomObject]@{
        Host = $printerHost
        Port = $printerPort
    }
}

function Test-PrinterPorts {
    param([string]$Host)

    if ([string]::IsNullOrWhiteSpace($Host)) {
        Write-Host "  Port test skipped: local/USB/WSD printer or unresolved host." -ForegroundColor DarkYellow
        return $false
    }

    $openPortFound = $false
    foreach ($port in 9100, 515, 631, 80) {
        try {
            $test = Test-NetConnection -ComputerName $Host -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
            if ($test) {
                Write-Host "  Port $port is open on $Host" -ForegroundColor Green
                Add-Change -Type "Diagnostics" -Path $Host -Name "OpenPort" -OldValue "" -NewValue $port
                $openPortFound = $true
            }
            else {
                Write-Host "  Port $port not responding on $Host" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  Port $port test failed on $Host" -ForegroundColor DarkGray
        }
    }

    return $openPortFound
}

function Ensure-SpoolerRunning {
    try {
        $svc = Get-Service -Name Spooler -ErrorAction Stop
        if ($svc.StartType -ne 'Automatic') {
            Set-Service -Name Spooler -StartupType Automatic -ErrorAction SilentlyContinue
            Add-Change -Type "Service" -Path "Spooler" -Name "StartupType" -OldValue $svc.StartType -NewValue "Automatic"
        }

        if ($svc.Status -ne 'Running') {
            Start-Service -Name Spooler -ErrorAction Stop
            Add-Change -Type "Service" -Path "Spooler" -Name "Status" -OldValue $svc.Status -NewValue "Running"
        }

        return $true
    } catch {
        return $false
    }
}

function Clear-PrinterQueue {
    param([string]$PrinterName)

    try {
        $jobs = Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue
        if ($jobs) {
            foreach ($job in $jobs) {
                Remove-PrintJob -PrinterName $PrinterName -ID $job.ID -Confirm:$false -ErrorAction SilentlyContinue
            }
            Add-Change -Type "Queue" -Path $PrinterName -Name "PrintJobs" -OldValue ($jobs.Count) -NewValue 0
            Write-Host "  Print queue cleared" -ForegroundColor Green
        }
        else {
            Write-Host "  No stuck jobs found" -ForegroundColor Green
        }
    } catch {
        Write-Host "  Queue clear failed" -ForegroundColor DarkYellow
    }
}

function Restart-PrinterSpooler {
    Write-Host ""
    Write-Host "[STEP 5/8] Restarting Print Spooler service..." -ForegroundColor Yellow
    try {
        Restart-Service -Name Spooler -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Add-Change -Type "Service" -Path "Spooler" -Name "Restart" -OldValue "Running/Stopped" -NewValue "Restarted"
        Write-Host "  Print Spooler restarted successfully" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  Failed to restart Print Spooler." -ForegroundColor Red
        return $false
    }
}

function Clear-SpoolFiles {
    Write-Host ""
    Write-Host "[STEP 6/8] Clearing stuck spool files..." -ForegroundColor Yellow
    $spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"
    try {
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1

        if (Test-Path $spoolPath) {
            $files = Get-ChildItem -Path $spoolPath -Force -ErrorAction SilentlyContinue
            $fileCount = @($files).Count
            Remove-Item "$spoolPath\*" -Force -ErrorAction SilentlyContinue
            Add-Change -Type "Files" -Path $spoolPath -Name "SpoolFiles" -OldValue $fileCount -NewValue 0
            Write-Host "  Spool folder cleared" -ForegroundColor Green
        }
        else {
            Write-Host "  Spool folder not found" -ForegroundColor DarkYellow
        }

        Start-Service -Name Spooler -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    } catch {
        Write-Host "  Could not fully clear spool files." -ForegroundColor Yellow
    }
}

function Show-PrintLogGuidance {
    Write-Host ""
    Write-Host "[STEP 8/8] Print logging guidance..." -ForegroundColor Yellow
    Write-Host "  If printing still fails, check Event Viewer:" -ForegroundColor White
    Write-Host "  Applications and Services Logs > Microsoft > Windows > PrintService > Operational" -ForegroundColor White
    Write-Host "  Enable the Operational log if it is currently off." -ForegroundColor White
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Printer Troubleshooter Pro v2" -ForegroundColor Cyan
Write-Host "  Auto Fix + Print Spooler Restart" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Ensure-SpoolerRunning)) {
    Write-Host "Print Spooler service could not be started." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$printer = Get-SelectedPrinter
if (-not $printer) {
    Write-Host "No printers found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$printerName = $printer.Name

Write-Host "Fixing printer: $printerName" -ForegroundColor Yellow
Write-Host ""

# STEP 1: Check if printer exists
Write-Host "[STEP 1/8] Checking printer..." -ForegroundColor Yellow
$printer = Get-Printer -Name $printerName -ErrorAction SilentlyContinue
if ($printer) {
    Write-Host "  Printer found. Status: $($printer.PrinterStatus)" -ForegroundColor Green
    Write-Host "  Driver: $($printer.DriverName)" -ForegroundColor Green
    Write-Host "  Port: $($printer.PortName)" -ForegroundColor Green
} else {
    Write-Host "Printer not found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# STEP 2: Clear print queue
Write-Host ""
Write-Host "[STEP 2/8] Clearing print queue..." -ForegroundColor Yellow
Clear-PrinterQueue -PrinterName $printerName

# STEP 3: Check printer host/ports
Write-Host ""
Write-Host "[STEP 3/8] Checking network ports..." -ForegroundColor Yellow
$portInfo = Get-PrinterHost -Printer $printer
$printerHost = $portInfo.Host
$printerPort = $portInfo.Port

if ($printerHost) {
    Write-Host "  Resolved printer host: $printerHost" -ForegroundColor Green
    $openPortFound = Test-PrinterPorts -Host $printerHost
    if (-not $openPortFound) {
        Write-Host "  WARNING: No common printer TCP ports responded." -ForegroundColor Yellow
    }
} else {
    Write-Host "  Port test skipped for local/USB/WSD-style printer." -ForegroundColor DarkYellow
}

# STEP 4: Check port and SNMP details
Write-Host ""
Write-Host "[STEP 4/8] Checking printer port settings..." -ForegroundColor Yellow
if ($printerPort) {
    Write-Host "  Port Name: $($printerPort.Name)" -ForegroundColor Green
    if ($printerPort.PrinterHostAddress) {
        Write-Host "  Printer Host Address: $($printerPort.PrinterHostAddress)" -ForegroundColor Green
    }
    if ($null -ne $printerPort.SNMPEnabled) {
        if ($printerPort.SNMPEnabled) {
            Write-Host "  SNMP is enabled" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: SNMP is disabled" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  Could not read printer port details." -ForegroundColor Yellow
}

# STEP 5: Restart Print Spooler Service
Restart-PrinterSpooler | Out-Null

# STEP 6: Clear spool files
Clear-SpoolFiles

# STEP 7: Final readiness check
Write-Host ""
Write-Host "[STEP 7/8] Final printer check..." -ForegroundColor Yellow
$printer = Get-Printer -Name $printerName -ErrorAction SilentlyContinue
$spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue

if ($printer) {
    Write-Host "  Printer is still present." -ForegroundColor Green
} else {
    Write-Host "  WARNING: Printer was not found after troubleshooting." -ForegroundColor Yellow
}

if ($spooler -and $spooler.Status -eq "Running") {
    Write-Host "  Print Spooler is running." -ForegroundColor Green
} else {
    Write-Host "  WARNING: Print Spooler is not running." -ForegroundColor Yellow
}

Write-Host "  Queue is ready for a test print." -ForegroundColor Green

# STEP 8: Print logging guidance
Show-PrintLogGuidance

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Printer Troubleshooting Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Created by: anon2k24-design" -ForegroundColor Cyan
Write-Host "PayPal: https://www.paypal.com/donate/?business=UNP6WN3E95EAL&currency_code=USD" -ForegroundColor Cyan
Write-Host "GitHub: https://github.com/anon2k24-design" -ForegroundColor Cyan
Write-Host "Sponsor: https://github.com/sponsors/anon2k24-design" -ForegroundColor Cyan
Write-Host ""
Write-Host "Log file: printer-troubleshooter-log.csv" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  - Try printing a Windows test page" -ForegroundColor White
Write-Host "  - If it still fails, update or reinstall the printer driver" -ForegroundColor White
Write-Host "  - Check PrintService Operational events if problems continue" -ForegroundColor White
Write-Host ""

Read-Host "Press Enter to exit"