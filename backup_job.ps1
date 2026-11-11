# ==============================================================================
# SonyBox ISP - Multi-Destination Automated Backup Engine
# Destinations: Local PC + Cloud / Drive Folder + Email (Gmail / SMTP)
# ==============================================================================

$ErrorActionPreference = "Continue"
$baseDir = "I:\Ai\softweb"
$backupDir = Join-Path $baseDir "backups"
$configFile = Join-Path $baseDir "email_config.json"
$logFile = Join-Path $backupDir "backup.log"

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

function Write-BackupLog($msg, $level = "INFO") {
    $timeStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "[$timeStr] [$level] $msg"
    Write-Host $logLine
    Add-Content -Path $logFile -Value $logLine
}

Write-BackupLog "=========================================================="
Write-BackupLog "SonyBox ISP Automated Backup Job Shuru..."

# 1. Read Configuration
$config = @{
    enabled = $true
    backup_interval_hours = 6
    recipient = "sonycafelahore@gmail.com"
    sender_email = "sonycafelahore@gmail.com"
    smtp_server = "smtp.gmail.com"
    smtp_port = 587
    app_password = ""
    email_enabled = $true
    cloud_sync_enabled = $false
    cloud_folder = ""
    max_local_backups_to_keep = 30
}

if (Test-Path $configFile) {
    try {
        $rawConfig = Get-Content -Path $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $rawConfig.enabled) { $config.enabled = [bool]$rawConfig.enabled }
        if ($rawConfig.backup_interval_hours) { $config.backup_interval_hours = [int]$rawConfig.backup_interval_hours }
        if ($rawConfig.recipient) { $config.recipient = $rawConfig.recipient }
        if ($rawConfig.sender_email) { $config.sender_email = $rawConfig.sender_email }
        if ($rawConfig.smtp_server) { $config.smtp_server = $rawConfig.smtp_server }
        if ($rawConfig.smtp_port) { $config.smtp_port = [int]$rawConfig.smtp_port }
        if ($rawConfig.app_password) { $config.app_password = $rawConfig.app_password }
        if ($null -ne $rawConfig.email_enabled) { $config.email_enabled = [bool]$rawConfig.email_enabled }
        if ($null -ne $rawConfig.cloud_sync_enabled) { $config.cloud_sync_enabled = [bool]$rawConfig.cloud_sync_enabled }
        if ($rawConfig.cloud_folder) { $config.cloud_folder = $rawConfig.cloud_folder }
        if ($rawConfig.max_local_backups_to_keep) { $config.max_local_backups_to_keep = [int]$rawConfig.max_local_backups_to_keep }
    } catch {
        Write-BackupLog "Config read error: $($_.Exception.Message)" "WARN"
    }
}

# If backup disabled globally, skip
if ($config.enabled -eq $false) {
    Write-BackupLog "Backup disabled in config. Skipping." "INFO"
    exit 0
}

# 2. Prepare staging folder for clean backup
$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$displayDate = (Get-Date).ToString("dd-MMM-yyyy hh:mm tt")
$stagingDir = Join-Path $env:TEMP "SonyBox_Backup_Staging_$timestamp"

if (Test-Path $stagingDir) {
    Remove-Item -Path $stagingDir -Recurse -Force | Out-Null
}
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

# Files and folders to back up
$filesToBackup = @(
    "data.json",
    "data.backup.json",
    "index.html",
    "sw.js",
    "manifest.json",
    "server.ps1",
    "sonybox.ps1",
    "sonybox.bat",
    "START_MOBILE_SERVER.bat",
    "email_config.json"
)

$customerCount = 0
$dbFile = Join-Path $baseDir "data.json"
if (Test-Path $dbFile) {
    try {
        $dbData = Get-Content -Path $dbFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($dbData.customers) {
            $customerCount = $dbData.customers.Count
        }
    } catch {}
}

# Copy individual core files
foreach ($f in $filesToBackup) {
    $src = Join-Path $baseDir $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $stagingDir -Force
    }
}

# Copy assets folder
$assetsDir = Join-Path $baseDir "assets"
if (Test-Path $assetsDir) {
    Copy-Item -Path $assetsDir -Destination (Join-Path $stagingDir "assets") -Recurse -Force
}

# 3. Create compressed ZIP archive
$zipFileName = "SonyBox_Backup_$timestamp.zip"
$zipFilePath = Join-Path $backupDir $zipFileName

try {
    if (Test-Path $zipFilePath) {
        Remove-Item -Path $zipFilePath -Force
    }
    Compress-Archive -Path "$stagingDir\*" -DestinationPath $zipFilePath -CompressionLevel Optimal
    $fileInfo = Get-Item $zipFilePath
    $sizeKb = [Math]::Round($fileInfo.Length / 1KB, 2)
    Write-BackupLog "Local Backup Save Ho Gaya: $zipFileName ($sizeKb KB) -> $backupDir" "SUCCESS"

    # Also keep a convenient "SonyBox_Backup_Latest.zip" for direct 1-click web download
    $latestZipPath = Join-Path $baseDir "SonyBox_Backup_Latest.zip"
    Copy-Item -Path $zipFilePath -Destination $latestZipPath -Force
    Write-BackupLog "Latest Web Download Backup Updated: SonyBox_Backup_Latest.zip" "INFO"
} catch {
    Write-BackupLog "ZIP creation failed: $($_.Exception.Message)" "ERROR"
    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# Cleanup staging directory
Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

# 4. Prune old backups (Keep latest N backups)
try {
    $existingBackups = Get-ChildItem -Path $backupDir -Filter "SonyBox_Backup_*.zip" | Sort-Object CreationTime -Descending
    if ($existingBackups.Count -gt $config.max_local_backups_to_keep) {
        $toRemove = $existingBackups | Select-Object -Skip $config.max_local_backups_to_keep
        foreach ($old in $toRemove) {
            Write-BackupLog "Purana backup delete kiya ja raha hai: $($old.Name)" "INFO"
            Remove-Item -Path $old.FullName -Force
        }
    }
} catch {
    Write-BackupLog "Prune backups warning: $($_.Exception.Message)" "WARN"
}

# 5. Cloud / Drive Folder Sync (Google Drive, OneDrive, Dropbox, or custom folder)
$cloudSynced = $false
if ($config.cloud_sync_enabled -and (-not [string]::IsNullOrWhiteSpace($config.cloud_folder))) {
    Write-BackupLog "Cloud / Drive Folder Sync shuru: $($config.cloud_folder)..." "INFO"
    try {
        if (-not (Test-Path $config.cloud_folder)) {
            New-Item -ItemType Directory -Path $config.cloud_folder -Force | Out-Null
        }
        Copy-Item -Path $zipFilePath -Destination (Join-Path $config.cloud_folder $zipFileName) -Force
        Copy-Item -Path $zipFilePath -Destination (Join-Path $config.cloud_folder "SonyBox_Backup_Latest.zip") -Force
        $cloudSynced = $true
        Write-BackupLog "Cloud Drive folder mein backup copy ho gaya: $($config.cloud_folder)" "SUCCESS"
    } catch {
        Write-BackupLog "Cloud Drive sync error: $($_.Exception.Message)" "WARN"
    }
}

# 6. Email Delivery to Gmail / SMTP
$emailSent = $false
if ($config.email_enabled -and (-not [string]::IsNullOrWhiteSpace($config.app_password))) {
    Write-BackupLog "Gmail par backup bheja ja raha hai: $($config.recipient)..." "INFO"
    try {
        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = New-Object System.Net.Mail.MailAddress($config.sender_email, "SonyBox ISP System")
        $mail.To.Add($config.recipient)
        $mail.Subject = "SonyBox ISP Website & Database Backup [$displayDate]"

        $mailBody = @"
Assalam-o-Alaikum,

SonyBox ISP Portal aur Customer Database ka Automated Backup kamyabi se ban gaya hai.

==================================================
  BACKUP DETAILS
==================================================
- Tareekh & Waqt : $displayDate
- Interval       : Har $($config.backup_interval_hours) Ghantay Baad
- Total Customers: $customerCount Users
- Backup File    : $zipFileName
- File Size      : $sizeKb KB
- PC Save Path   : $zipFilePath
- Server Status  : Active (Port 8080)
==================================================

Backup zip file is email ke sath attach kar di gayi hai.
Aap is file ko mehfooz rakh sakte hain ya zaroorat parne par foran restore kar sakte hain.

Shukriya,
SonyBox ISP Automated Engine
"@

        $mail.Body = $mailBody
        $mail.IsBodyHtml = $false

        $attachment = New-Object System.Net.Mail.Attachment($zipFilePath)
        $mail.Attachments.Add($attachment)

        $smtp = New-Object System.Net.Mail.SmtpClient($config.smtp_server, $config.smtp_port)
        $smtp.EnableSsl = $true
        $smtp.Timeout = 20000
        $cleanPassword = $config.app_password.Replace(" ", "").Trim()
        $smtp.Credentials = New-Object System.Net.NetworkCredential($config.sender_email, $cleanPassword)
        $smtp.Send($mail)
        $mail.Dispose()

        $emailSent = $true
        Write-BackupLog "Gmail Par Email Kamyabi Say Bheji Gai: $($config.recipient)" "SUCCESS"
    } catch {
        Write-BackupLog "Gmail sending error: $($_.Exception.Message)" "ERROR"
    }
} elseif ($config.email_enabled -and [string]::IsNullOrWhiteSpace($config.app_password)) {
    Write-BackupLog "Email enable hai lekin App Password nahi dala gaya. Local PC aur Cloud folder mein backup mehfooz ho gaya hai." "INFO"
}

# 7. Update status in email_config.json
try {
    if (Test-Path $configFile) {
        $cfgObj = Get-Content -Path $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfgObj.last_backup_time = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
        $cfgObj.last_backup_file = $zipFileName
        $cfgObj.last_backup_size_kb = $sizeKb
        $cfgObj.last_email_sent = $emailSent
        $cfgObj.last_cloud_synced = $cloudSynced
        $cfgObj | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile -Encoding UTF8
    }
} catch {}

Write-BackupLog "SonyBox ISP Automated Backup Job Mukammal!" "DONE"
Write-BackupLog "=========================================================="
