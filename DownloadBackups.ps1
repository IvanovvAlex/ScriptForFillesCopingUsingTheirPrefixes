$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir "config.json"

if (-Not (Test-Path $configPath)) {
    Write-Host "[ERROR] Configuration file not found: $configPath"
    exit 1
}

$configRaw = Get-Content $configPath -Raw | ConvertFrom-Json

$config = [ordered]@{
    RemotePath = $configRaw.RemotePath
    Prefixes = $configRaw.Prefixes
    LocalPath = $configRaw.LocalPath
    ArchivePath = $configRaw.ArchivePath
    SqlServerInstance = $configRaw.SqlServerInstance
    DbMap = @{}
}

foreach ($key in $configRaw.DbMap.PSObject.Properties.Name) {
    $config.DbMap[$key] = $configRaw.DbMap.$key
}
$actionMap = @{
    "D" = "Download"
    "R" = "Restore"
    "B" = "Both"
}

do {
    $inputAction = Read-Host "Choose an action: [D]ownload, [R]estore, or [B]oth"
    $normalizedAction = $inputAction.Trim().ToUpper()
} while (-not $actionMap.ContainsKey($normalizedAction))

$action = $actionMap[$normalizedAction]

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class SleepUtil {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@

[Sleeputil]::SetThreadExecutionState([uint32]2147483649) | Out-Null
function RestoreSleep() {
    [Sleeputil]::SetThreadExecutionState([uint32]2147483648) | Out-Null
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

function Restore-Database {
    Show-Message "Restoring Is Not Developed Yet" "INFO"
}

function Main($action) {
    $copiedFiles = @()
    $movedFiles = @()

    try {
        if ($action -eq "Download" -or $action -eq "Both") {
            Show-Message "Connecting to remote path: $($config.RemotePath)"

            if (!(Test-Path $config.RemotePath)) {
                throw "Remote path $($config.RemotePath) not accessible."
            }

            $remoteFiles = Get-ChildItem -Path $config.RemotePath -File
            $matchedFiles = @()

            foreach ($prefix in $config.Prefixes) {
                $matched = $remoteFiles | Where-Object { $_.Name.StartsWith($prefix) }

                if ($matched.Count -gt 0) {
                    $latest = $matched | Sort-Object {
                        if ($_ -match "$prefix(\d{4}_\d{2}_\d{2}_\d{6})") {
                            [datetime]::ParseExact($matches[1], "yyyy_MM_dd_HHmmss", $null)
                        }
                        else {
                            [datetime]::MinValue
                        }
                    } -Descending | Select-Object -First 1

                    $matchedFiles += $latest
                }
            }

            if ($matchedFiles.Count -eq 0) {
                throw "No matching files found on remote path."
            }

            if (!(Test-Path $config.ArchivePath)) {
                New-Item -Path $config.ArchivePath -ItemType Directory -Force | Out-Null
                Show-Message "Created archive folder: $($config.ArchivePath)" "INFO"
            }

            Show-Message "Syncing files from remote..."

            $i = 0
            foreach ($file in $matchedFiles) {
                $i++
                $percent = [int](($i / $matchedFiles.Count) * 100)
                Write-Progress -Activity "Syncing files" -Status "$percent% Complete" -PercentComplete $percent

                $destination = Join-Path $config.LocalPath $file.Name
                $shouldCopy = $true

                if (Test-Path $destination) {
                    $sourceHash = Get-FileHash -Path $file.FullName -Algorithm SHA256
                    $destHash = Get-FileHash -Path $destination -Algorithm SHA256

                    if ($sourceHash.Hash -eq $destHash.Hash) {
                        Show-Message "File '$($file.Name)' already exists and is identical. Skipping." "INFO"
                        $shouldCopy = $false
                    }
                    else {
                        # Archive the old version before replacing
                        $archivePath = Join-Path $config.ArchivePath $file.Name
                        Move-Item -Path $destination -Destination $archivePath -Force
                        $movedFiles += [PSCustomObject]@{ Original = $destination; Destination = $archivePath }
                        Show-Message "Archived old version of '$($file.Name)'." "WARN"
                    }
                }

                if ($shouldCopy) {
                    Copy-Item -Path $file.FullName -Destination $destination -Force
                    $copiedFiles += $destination
                    Show-Message "Copied: $($file.Name)" "INFO"
                }
            }

            Write-Progress -Activity "Syncing files" -Completed
            Show-Message "File sync complete." "SUCCESS"
        }

        if ($action -eq "Restore" -or $action -eq "Both") {
            Restore-Database
        }
    }
    catch {
        Show-Message "ERROR: $_" "ERROR"
        Rollback -copiedFiles $copiedFiles -movedFiles $movedFiles
    }
}

try {
    Main $action
}
catch {
    Write-Host "[FATAL ERROR] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    RestoreSleep
}