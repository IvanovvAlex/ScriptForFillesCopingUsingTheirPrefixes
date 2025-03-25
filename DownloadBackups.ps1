$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir "config.json"

if (-Not (Test-Path $configPath)) {
    Write-Host "[ERROR] Configuration file not found: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

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

[Sleeputil]::SetThreadExecutionState([uint32]0x80000001)

function RestoreSleep() {
    [Sleeputil]::SetThreadExecutionState([uint32]0x80000000)
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
    Show-Message "Step 5: Restoring databases..." "INFO"

    $bakFiles = Get-ChildItem -Path $config.LocalPath -Filter *.bak -File

    foreach ($bak in $bakFiles) {
        $matchedPrefix = $null
        foreach ($prefix in $config.DbMap.Keys) {
            if ($bak.Name.StartsWith($prefix)) {
                $matchedPrefix = $prefix
                break
            }
        }

        if (-not $matchedPrefix) {
            Show-Message "No DB mapping found for file $($bak.Name). Skipping." "WARN"
            continue
        }

        $dbName = $config.DbMap[$matchedPrefix]
        Show-Message "Restoring database '$dbName' from '$($bak.FullName)'" "INFO"

        $restoreQuery = @"
USE [master];
IF DB_ID(N'$dbName') IS NOT NULL
BEGIN
    ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$dbName];
END;
RESTORE DATABASE [$dbName] FROM DISK = N'$($bak.FullName)' WITH RECOVERY, REPLACE;
"@

        sqlcmd -S $config.SqlServerInstance -Q $restoreQuery

        if ($LASTEXITCODE -eq 0) {
            Show-Message "Successfully restored $dbName." "SUCCESS"
        }
        else {
            Show-Message "Failed to restore $dbName." "ERROR"
        }
    }
}

function Main($action) {
    $copiedFiles = @()
    $movedFiles = @()

    try {
        if ($action -eq "Download" -or $action -eq "Both") {
            Show-Message "Step 1: Connecting to remote path: $($config.RemotePath)"

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

            Show-Message "Step 2 & 3: Syncing files from remote..."

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
    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}