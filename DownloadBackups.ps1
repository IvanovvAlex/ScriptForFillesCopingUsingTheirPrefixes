$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir "config.json"

if (-Not (Test-Path $configPath)) {
    Show-Message "Configuration file not found: $configPath" "ERROR"
    exit 1
}

$configRaw = Get-Content $configPath -Raw | ConvertFrom-Json

$config = [ordered]@{
    RemotePath = $configRaw.RemotePath
    Prefixes = $configRaw.Prefixes
    LocalPath = $configRaw.LocalPath
    ArchivePath = $configRaw.ArchivePath
    SqlServerInstance = $configRaw.SqlServerInstance
    SqlDataPath = $configRaw.SqlDataPath
    SqlLogPath = $configRaw.SqlLogPath
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

function Show-Message {
    param (
        [string]$msg,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DONE")]
        [string]$type = "INFO"
    )

    $prefix = "[{0}] {1}" -f $type, (Get-Date -Format "HH:mm:ss")

    switch ($type) {
        "INFO"    { Write-Host "$prefix [INFO] $msg" -ForegroundColor White -BackgroundColor DarkCyan }
        "WARN"    { Write-Host "$prefix [WARN] $msg" -ForegroundColor Yellow -BackgroundColor DarkGray }
        "ERROR"   { Write-Host "$prefix [ERROR] $msg" -ForegroundColor White -BackgroundColor DarkRed }
        "SUCCESS" { Write-Host "$prefix [OK] $msg" -ForegroundColor Black -BackgroundColor Green }
        "DONE"    { Write-Host "$prefix [DONE] $msg" -ForegroundColor Black -BackgroundColor Cyan }
        default   { Write-Host "$prefix $msg" }
    }
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

function Get-LogicalFileNames {
    param (
        [string]$backupPath,
        [string]$sqlInstance
    )

    $query = "RESTORE FILELISTONLY FROM DISK = N'$backupPath';"
    $result = sqlcmd -S $sqlInstance -Q $query -h -1 -s "|"

    $logicalFiles = @()
    foreach ($line in $result) {
        if ($line -match '^\s*(.+?)\|') {
            $columns = $line -split '\|'
            $logicalFiles += [PSCustomObject]@{
                LogicalName = $columns[0].Trim()
                PhysicalName = $columns[1].Trim()
            }
        }
    }

    return $logicalFiles
}

function Restore-Database {
    Show-Message "Starting database restore process..." "INFO"

    foreach ($prefix in $config.Prefixes) {
        $dbName = $config.DbMap[$prefix]
        $latestBackup = Get-ChildItem -Path $config.LocalPath -Filter "$prefix*.bak" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if (-not $latestBackup) {
            Show-Message "No backup file found for prefix '$prefix'. Skipping..." "WARN"
            continue
        }

        Show-Message "Restoring database '$dbName' from file '$($latestBackup.Name)'" "INFO"

        $mdfPath = Join-Path $config.SqlDataPath "$dbName.mdf"
        $ldfPath = Join-Path $config.SqlLogPath "${dbName}_log.ldf"

        $logicalFiles = Get-LogicalFileNames -backupPath $latestBackup.FullName -sqlInstance $config.SqlServerInstance

        $mdfLogical = $logicalFiles | Where-Object { $_.PhysicalName -like "*.mdf" } | Select-Object -First 1
        $ldfLogical = $logicalFiles | Where-Object { $_.PhysicalName -like "*.ldf" } | Select-Object -First 1
        
        if (-not $mdfLogical -or -not $ldfLogical) {
            Show-Message "Unable to determine logical file names for '$($latestBackup.Name)'" "ERROR"
            continue
        }
        
        $sql = @"
        USE [master];
        IF EXISTS (SELECT name FROM sys.databases WHERE name = N'$dbName')
        BEGIN
            ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
            DROP DATABASE [$dbName];
        END;
        
        RESTORE DATABASE [$dbName]
        FROM DISK = N'$($latestBackup.FullName)'
        WITH MOVE N'$($mdfLogical.LogicalName)' TO N'$mdfPath',
             MOVE N'$($ldfLogical.LogicalName)' TO N'$ldfPath',
             REPLACE;
"@

        $tempSqlFile = Join-Path $env:TEMP "restore_$dbName.sql"
        $sql | Out-File -FilePath $tempSqlFile -Encoding UTF8

        $cmd = "sqlcmd -S `"$($config.SqlServerInstance)`" -i `"$tempSqlFile`""
        $restoreResult = Invoke-Expression $cmd

        if ($LASTEXITCODE -eq 0) {
            Show-Message "Successfully restored '$dbName'." "SUCCESS"
        } else {
            Show-Message "Failed to restore '$dbName'. Check SQL Server logs for more details." "ERROR"
        }

        Remove-Item -Path $tempSqlFile -Force
    }

    Show-Message "Database restore process complete." "DONE"
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

                $prefix = $config.Prefixes | Where-Object { $file.Name.StartsWith($_) } | Select-Object -First 1
                if (-not $prefix) {
                    Show-Message "No matching prefix for file '$($file.Name)'. Skipping..." "WARN"
                    continue
                }

                $localMatches = Get-ChildItem -Path $config.LocalPath -Filter "$prefix*.bak"
                $skip = $false

                foreach ($local in $localMatches) {
                    if ($local.Name -eq $file.Name -and
                        (Get-Item $local.FullName).Length -eq (Get-Item $file.FullName).Length) {
                        Show-Message "File '$($file.Name)' already exists with same name and size. Skipping." "INFO"
                        $skip = $true
                        break
                    }
                }

                if (-not $skip) {
                    foreach ($local in $localMatches) {
                        $archivePath = Join-Path $config.ArchivePath $local.Name
                        Move-Item -Path $local.FullName -Destination $archivePath -Force
                        $movedFiles += [PSCustomObject]@{ Original = $local.FullName; Destination = $archivePath }
                        Show-Message "Archived old file '$($local.Name)'." "WARN"
                    }

                    $destination = Join-Path $config.LocalPath $file.Name
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
    Show-Message -msg "FATAL ERROR: $($_.Exception.Message)" -type "ERROR"
}
finally {
    RestoreSleep
}