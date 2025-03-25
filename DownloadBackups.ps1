$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir "config.json"

if (-Not (Test-Path $configPath)) {
    Write-Host "[ERROR] Configuration file not found: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class SleepUtil {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@

# Prevent sleep
# ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x00000001)
[Sleeputil]::SetThreadExecutionState(0x80000001)

function RestoreSleep(){
    # Re-enable sleep
    [Sleeputil]::SetThreadExecutionState(0x80000000)
}

function Show-Message($msg, $type = "INFO") {
    $prefix = "[{0}] {1}" -f $type, (Get-Date -Format "HH:mm:ss")
    Write-Host "$prefix $msg"
}

function Rollback {
    param($copiedFiles, $movedFiles)

    if ($copiedFiles.Count -gt 0) {
        Show-Message "Rolling back copied files..." "WARN"
        foreach ($file in $copiedFiles) {
            if (Test-Path $file) {
                Remove-Item $file -Force
            }
        }
    }

    if ($movedFiles.Count -gt 0) {
        Show-Message "Rolling back moved files..." "WARN"
        foreach ($pair in $movedFiles) {
            Move-Item -Path $pair.Destination -Destination $pair.Original -Force
        }
    }

    Show-Message "Rollback completed." "DONE"
}

function Main {
    $copiedFiles = @()
    $movedFiles = @()

    try {
        Show-Message "Step 1: Connecting to remote path: $($config.RemotePath)"

        if (!(Test-Path $config.RemotePath)) {
            throw "Remote path $($config.RemotePath) not accessible."
        }

        $remoteFiles = Get-ChildItem -Path $config.RemotePath -File

        $matchedFiles = @()

        foreach ($prefix in $config.Prefixes) {
            $matched = $remoteFiles | Where-Object { $_.Name.StartsWith($prefix) }

            if ($matched.Count -gt 0) {
                # Parse date from filename and pick the latest
                $latest = $matched | Sort-Object {
                    if ($_ -match "$prefix(\d{4}_\d{2}_\d{2}_\d{6})") {
                        [datetime]::ParseExact($matches[1], "yyyy_MM_dd_HHmmss", $null)
                    } else {
                        [datetime]::MinValue
                    }
                } -Descending | Select-Object -First 1

                $matchedFiles += $latest
            }
        }

        if ($matchedFiles.Count -eq 0) {
            throw "No matching files found on remote path."
        }

        Show-Message "Step 2: Moving existing .bak files to archive..."

        $existingBakFiles = Get-ChildItem -Path $config.LocalPath -File -Filter "*.bak"
        foreach ($file in $existingBakFiles) {
            $destination = Join-Path $config.ArchivePath $file.Name
            Move-Item -Path $file.FullName -Destination $destination -Force
            $movedFiles += [PSCustomObject]@{ Original = $file.FullName; Destination = $destination }
        }

        Show-Message "Step 3: Copying files from remote..."

        $i = 0
        foreach ($file in $matchedFiles) {
            $i++
            $percent = [int](($i / $matchedFiles.Count) * 100)
            Write-Progress -Activity "Copying files" -Status "$percent% Complete" -PercentComplete $percent

            $destination = Join-Path $config.LocalPath $file.Name
            Copy-Item -Path $file.FullName -Destination $destination -Force
            $copiedFiles += $destination
        }

        Write-Progress -Activity "Copying files" -Completed
        Show-Message "Step 4: All files copied successfully." "SUCCESS"
    }
    catch {
        Show-Message "ERROR: $_" "ERROR"
        Rollback -copiedFiles $copiedFiles -movedFiles $movedFiles
    }
}

try {
    Main
}
catch {
    Write-Host "[FATAL ERROR] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    RestoreSleep

    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}