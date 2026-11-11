$port = 8080
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any, $port)
$listener.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
$listener.Start()
$baseDir = "i:\Ai\softweb"
$dbFile = Join-Path $baseDir "data.json"
$backupFile = Join-Path $baseDir "data.backup.json"

# Ensure data.json exists
if (-not (Test-Path $dbFile)) {
    $initObj = @{
        customers = @()
        ispName = "SonyBox"
        ispJazzcash = ""
        ispHelpline = ""
        currentPin = "1234"
        isLockEnabled = $true
        updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $initJson = $initObj | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($dbFile, $initJson, $utf8NoBom)
}

# ========================================================
# SERVER-SIDE LOSSLESS MERGE & DATA PROTECTION HELPERS
# ========================================================
function Get-CustKey($c) {
    if ($null -ne $c.id -and [string]::IsNullOrWhiteSpace([string]$c.id) -eq $false) { return "id:" + [string]$c.id }
    if ($c.userid -and [string]$c.userid.Trim() -ne "" -and [string]$c.userid.Trim() -ne "-") { return "u:" + [string]$c.userid.Trim().ToLower() }
    if ($c.phone -and [string]$c.phone.Trim() -ne "") {
        $clean = [string]$c.phone -replace '[^0-9]', ''
        if ($clean.Length -ge 7) { return "p:" + $clean }
    }
    return "n:" + [string]$c.name.Trim().ToLower()
}

function Get-CustLatestTs($c) {
    [double]$maxTs = 0
    if ($c.updatedAt) {
        $d = [DateTime]::MinValue
        if ([DateTime]::TryParse([string]$c.updatedAt, [ref]$d)) {
            $ts = [double]([DateTimeOffset]$d).ToUnixTimeMilliseconds()
            if ($ts -gt $maxTs) { $maxTs = $ts }
        }
    }
    if ($c.history) {
        foreach ($h in $c.history) {
            if ($h.timestamp) {
                [double]$ts = [double]$h.timestamp
                if ($ts -gt $maxTs) { $maxTs = $ts }
            } elseif ($h.receivedDate) {
                $d = [DateTime]::MinValue
                if ([DateTime]::TryParse([string]$h.receivedDate, [ref]$d)) {
                    $ts = [double]([DateTimeOffset]$d).ToUnixTimeMilliseconds()
                    if ($ts -gt $maxTs) { $maxTs = $ts }
                }
            }
        }
    }
    return $maxTs
}

function Merge-ServerCustomers($existingCusts, $incomingCusts, $deletedIds = @(), $isRecoveryPayload = $false) {
    $delSet = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($deletedIds) {
        foreach ($id in $deletedIds) {
            if ($null -ne $id) { [void]$delSet.Add([string]$id) }
        }
    }

    $map = [ordered]@{}

    if ($existingCusts) {
        foreach ($c in $existingCusts) {
            if ($null -eq $c -or -not $c.name) { continue }
            if ($c.id -and $delSet.Contains([string]$c.id)) { continue }
            $k = Get-CustKey $c
            if ($k) { $map[$k] = $c }
        }
    }

    if ($incomingCusts) {
        foreach ($inc in $incomingCusts) {
            if ($null -eq $inc -or -not $inc.name) { continue }
            if ($inc.id -and $delSet.Contains([string]$inc.id)) { continue }
            $k = Get-CustKey $inc
            if (-not $k) { continue }

            if (-not $map.Contains($k)) {
                $map[$k] = $inc
            } else {
                $ex = $map[$k]

                # Merge histories losslessly
                $histMap = [ordered]@{}
                if ($ex.history) {
                    foreach ($h in $ex.history) {
                        $hk = if ($h.billId) { [string]$h.billId } else { "$($h.receivedDate)_$($h.receivedAmount)_$($h.monthYear)" }
                        if (-not $histMap.Contains($hk)) { $histMap[$hk] = $h }
                    }
                }
                if ($inc.history) {
                    foreach ($h in $inc.history) {
                        $hk = if ($h.billId) { [string]$h.billId } else { "$($h.receivedDate)_$($h.receivedAmount)_$($h.monthYear)" }
                        if (-not $histMap.Contains($hk)) { $histMap[$hk] = $h }
                    }
                }
                $mergedHistory = @($histMap.Values)

                # Determine payment winner
                $exTs = Get-CustLatestTs $ex
                $incTs = Get-CustLatestTs $inc

                $incWinsPayment = $false
                if ($incTs -gt $exTs) {
                    $incWinsPayment = $true
                } elseif ($exTs -gt $incTs) {
                    $incWinsPayment = $false
                } else {
                    $incIsPaid = ($inc.status -eq "PAID" -or $inc.status -eq "PARTIAL" -or [double]($inc.paidAmount) -gt 0)
                    $exIsPaid = ($ex.status -eq "PAID" -or $ex.status -eq "PARTIAL" -or [double]($ex.paidAmount) -gt 0)
                    if ($incIsPaid -and -not $exIsPaid) {
                        $incWinsPayment = $true
                    } elseif ($exIsPaid -and -not $incIsPaid) {
                        $incWinsPayment = $false
                    } else {
                        $incWinsPayment = ([double]($inc.paidAmount) -ge [double]($ex.paidAmount))
                    }
                }

                $pw = if ($incWinsPayment) { $inc } else { $ex }
                $other = if ($incWinsPayment) { $ex } else { $inc }

                # Demographic authority:
                # If incoming is from Recovery Officer, preserve server/admin demographic master data
                # Otherwise if incoming is from Admin, incoming updates demographics
                $custName = if ($isRecoveryPayload -and $ex.name) { $ex.name } elseif ($inc.name) { $inc.name } else { $ex.name }
                $custPhone = if ($isRecoveryPayload -and $ex.phone) { $ex.phone } elseif ($inc.phone) { $inc.phone } else { $ex.phone }
                $custUserid = if ($isRecoveryPayload -and $ex.userid) { $ex.userid } elseif ($inc.userid) { $inc.userid } else { $ex.userid }
                $custArea = if ($isRecoveryPayload -and $ex.area -and $ex.area -ne "-") { $ex.area } elseif ($inc.area -and $inc.area -ne "-") { $inc.area } elseif ($ex.area) { $ex.area } else { "-" }
                $custPkg = if ($isRecoveryPayload -and $ex.package) { $ex.package } elseif ($inc.package) { $inc.package } else { $ex.package }
                $custFee = if ($isRecoveryPayload -and $null -ne $ex.fee) { $ex.fee } elseif ($null -ne $inc.fee) { $inc.fee } else { $ex.fee }
                $custAccStatus = if ($isRecoveryPayload -and $ex.accountStatus) { $ex.accountStatus } elseif ($inc.accountStatus) { $inc.accountStatus } else { $ex.accountStatus }
                $custIsActive = if ($isRecoveryPayload -and $null -ne $ex.isActive) { $ex.isActive } elseif ($null -ne $inc.isActive) { $inc.isActive } else { $ex.isActive }
                $custConn = if ($isRecoveryPayload -and $ex.connectionType) { $ex.connectionType } elseif ($inc.connectionType) { $inc.connectionType } else { $ex.connectionType }

                $mergedCust = [PSCustomObject]@{
                    id = if ($ex.id) { $ex.id } else { $inc.id }
                    name = $custName
                    phone = $custPhone
                    userid = $custUserid
                    area = $custArea
                    package = $custPkg
                    fee = $custFee
                    status = $pw.status
                    paidAt = $pw.paidAt
                    paidAmount = $pw.paidAmount
                    dueAmount = $pw.dueAmount
                    history = $mergedHistory
                    arrears = if ($null -ne $pw.arrears) { $pw.arrears } elseif ($null -ne $other.arrears) { $other.arrears } else { 0 }
                    pendingBills = if ($pw.pendingBills) { $pw.pendingBills } elseif ($other.pendingBills) { $other.pendingBills } else { @() }
                    expireDate = if ($inc.expireDate) { $inc.expireDate } else { $ex.expireDate }
                    password = if ($inc.password) { $inc.password } else { $ex.password }
                    accountStatus = $custAccStatus
                    isActive = $custIsActive
                    connectionType = $custConn
                    receiptId = if ($pw.receiptId) { $pw.receiptId } else { $other.receiptId }
                    receivingDate = if ($pw.receivingDate) { $pw.receivingDate } else { $other.receivingDate }
                    cashType = if ($pw.cashType) { $pw.cashType } else { $other.cashType }
                    currentBillMonth = if ($pw.currentBillMonth) { $pw.currentBillMonth } else { $other.currentBillMonth }
                    updatedAt = if ($pw.updatedAt) { $pw.updatedAt } elseif ($other.updatedAt) { $other.updatedAt } else { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
                }

                $map[$k] = $mergedCust
            }
        }
    }

    return @($map.Values)
}

Write-Host "=========================================================="
Write-Host " SonyBox ISP Server + Cloud Sync API Chalu Hai!" -ForegroundColor Green
Write-Host " PC par URL   : http://localhost:$port" -ForegroundColor Cyan
Write-Host " Phone par URL: http://192.168.0.15:$port" -ForegroundColor Yellow
Write-Host " Data API     : http://192.168.0.15:$port/api/data" -ForegroundColor Magenta
Write-Host "=========================================================="

while ($true) {
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 15000
        $client.SendTimeout = 15000
        $stream = $client.GetStream()
        $stream.ReadTimeout = 15000
        $stream.WriteTimeout = 15000
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        
        $requestLine = $reader.ReadLine()
        if (-not $requestLine) {
            $client.Close()
            continue
        }

        # Parse request line (e.g. "GET /api/data HTTP/1.1")
        $tokens = $requestLine.Split(" ")
        if ($tokens.Length -lt 2) {
            $client.Close()
            continue
        }
        $method = $tokens[0].ToUpper()
        $rawUrl = $tokens[1].Split("?")[0]

        # Read remaining HTTP headers
        $headers = @{}
        while ($true) {
            $h = $reader.ReadLine()
            if ([string]::IsNullOrEmpty($h)) { break }
            $colon = $h.IndexOf(":")
            if ($colon -gt 0) {
                $key = $h.Substring(0, $colon).Trim().ToLower()
                $val = $h.Substring($colon + 1).Trim()
                $headers[$key] = $val
            }
        }

        # Handle CORS Preflight OPTIONS
        if ($method -eq "OPTIONS") {
            $cors = "HTTP/1.1 200 OK`r`n" +
                    "Access-Control-Allow-Origin: *`r`n" +
                    "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
                    "Access-Control-Allow-Headers: Content-Type, Accept, Authorization`r`n" +
                    "Content-Length: 0`r`n" +
                    "Connection: close`r`n`r`n"
            $b = [System.Text.Encoding]::ASCII.GetBytes($cors)
            $stream.Write($b, 0, $b.Length)
            $stream.Flush()
            $stream.Close()
            $client.Close()
            continue
        }

        # Handle REST API Endpoint /api/data
        if ($rawUrl -eq "/api/data") {
            if ($method -eq "GET") {
                if (-not (Test-Path $dbFile)) {
                    $defJson = '{"customers":[],"ispName":"SonyBox","updatedAt":"' + (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") + '"}'
                    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                    [System.IO.File]::WriteAllText($dbFile, $defJson, $utf8NoBom)
                }
                $jsonBytes = [System.IO.File]::ReadAllBytes($dbFile)
                $resp = "HTTP/1.1 200 OK`r`n" +
                        "Content-Type: application/json; charset=utf-8`r`n" +
                        "Content-Length: $($jsonBytes.Length)`r`n" +
                        "Access-Control-Allow-Origin: *`r`n" +
                        "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
                        "Connection: close`r`n`r`n"
                $respH = [System.Text.Encoding]::ASCII.GetBytes($resp)
                $stream.Write($respH, 0, $respH.Length)
                $stream.Write($jsonBytes, 0, $jsonBytes.Length)
                $stream.Flush()
            }
            elseif ($method -eq "POST") {
                $cl = 0
                if ($headers.ContainsKey("content-length")) {
                    [int]::TryParse($headers["content-length"], [ref]$cl) | Out-Null
                }

                $bodyStr = ""
                if ($cl -gt 0) {
                    $charBuf = New-Object char[] $cl
                    $totalChars = 0
                    $totalBytes = 0
                    $enc = [System.Text.Encoding]::UTF8
                    while ($totalBytes -lt $cl) {
                        $toRead = [Math]::Min(16384, $cl - $totalBytes)
                        $read = $reader.Read($charBuf, $totalChars, $toRead)
                        if ($read -le 0) { break }
                        $chunkBytes = $enc.GetByteCount($charBuf, $totalChars, $read)
                        $totalChars += $read
                        $totalBytes += $chunkBytes
                    }
                    $bodyStr = New-Object string ($charBuf, 0, $totalChars)
                }

                if (-not [string]::IsNullOrEmpty($bodyStr)) {
                    try {
                        # Validate valid JSON
                        $parsed = $bodyStr | ConvertFrom-Json
                        
                        # Load existing data for atomic lossless merge
                        $existing = $null
                        if (Test-Path $dbFile) {
                            try {
                                $existingRaw = [System.IO.File]::ReadAllText($dbFile, [System.Text.Encoding]::UTF8)
                                $existing = $existingRaw | ConvertFrom-Json
                                Copy-Item -Path $dbFile -Destination $backupFile -Force
                            } catch {}
                        }

                        # Intelligent server-side merge: protect PIN, lock, batches, expenses, and merge customers
                        if ($existing) {
                            if (-not $parsed.currentPin -and $existing.currentPin) {
                                $parsed | Add-Member -NotePropertyName "currentPin" -NotePropertyValue $existing.currentPin -Force
                            }
                            if (-not $parsed.lockType -and $existing.lockType) {
                                $parsed | Add-Member -NotePropertyName "lockType" -NotePropertyValue $existing.lockType -Force
                            }
                            if ($null -eq $parsed.isLockEnabled -and $null -ne $existing.isLockEnabled) {
                                $parsed | Add-Member -NotePropertyName "isLockEnabled" -NotePropertyValue $existing.isLockEnabled -Force
                            }
                            if (-not $parsed.expenses -and $existing.expenses) {
                                $parsed | Add-Member -NotePropertyName "expenses" -NotePropertyValue $existing.expenses -Force
                            }
                            $inBatchesCount = if ($parsed.billBatches) { $parsed.billBatches.Count } else { 0 }
                            $exBatchesCount = if ($existing.billBatches) { $existing.billBatches.Count } else { 0 }
                            if ($inBatchesCount -eq 0 -and $exBatchesCount -gt 0) {
                                $parsed.billBatches = $existing.billBatches
                            }
                            if ($existing.areas -and $parsed.areas) {
                                $allAreas = @($parsed.areas) + @($existing.areas) | Select-Object -Unique
                                $parsed.areas = $allAreas
                            } elseif ($existing.areas -and -not $parsed.areas) {
                                $parsed | Add-Member -NotePropertyName "areas" -NotePropertyValue $existing.areas -Force
                            }
                            if ($existing.recoveryOfficers -and $parsed.recoveryOfficers) {
                                $officerMap = [ordered]@{}
                                foreach ($o in $existing.recoveryOfficers) { if ($o.id) { $officerMap[[string]$o.id] = $o } }
                                foreach ($o in $parsed.recoveryOfficers) { if ($o.id) { $officerMap[[string]$o.id] = $o } }
                                $parsed.recoveryOfficers = @($officerMap.Values)
                            } elseif ($existing.recoveryOfficers -and -not $parsed.recoveryOfficers) {
                                $parsed | Add-Member -NotePropertyName "recoveryOfficers" -NotePropertyValue $existing.recoveryOfficers -Force
                            }
                            $delIds = if ($parsed.deletedCustomerIds) { @($parsed.deletedCustomerIds) } else { @() }
                            $isRecovery = ($parsed.source -eq "recovery_portal")
                            if ($parsed.wipeAllCustomers -eq $true) {
                            $parsed.customers = @()
                        } else {
                            $parsed.customers = Merge-ServerCustomers $existing.customers $parsed.customers $delIds $isRecovery
                        }
                        }

                        $parsed.updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                        $finalJson = $parsed | ConvertTo-Json -Depth 10

                        # Write data.json without UTF-8 BOM
                        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                        [System.IO.File]::WriteAllText($dbFile, $finalJson, $utf8NoBom)
                        
                        $count = 0
                        if ($parsed.customers) { $count = $parsed.customers.Count }
                        $okJson = '{"status":"ok","message":"Data merged & saved successfully","count":' + $count + ',"updatedAt":"' + $parsed.updatedAt + '"}'
                        $okBytes = [System.Text.Encoding]::UTF8.GetBytes($okJson)
                        $resp = "HTTP/1.1 200 OK`r`n" +
                                "Content-Type: application/json; charset=utf-8`r`n" +
                                "Content-Length: $($okBytes.Length)`r`n" +
                                "Access-Control-Allow-Origin: *`r`n" +
                                "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
                                "Connection: close`r`n`r`n"
                        $respH = [System.Text.Encoding]::ASCII.GetBytes($resp)
                        $stream.Write($respH, 0, $respH.Length)
                        $stream.Write($okBytes, 0, $okBytes.Length)
                        $stream.Flush()
                    } catch {
                        $errJson = '{"status":"error","message":"Invalid JSON payload: ' + $_.Exception.Message.Replace('"', '\"') + '"}'
                        $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
                        $resp = "HTTP/1.1 400 Bad Request`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($errBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $respH = [System.Text.Encoding]::ASCII.GetBytes($resp)
                        $stream.Write($respH, 0, $respH.Length)
                        $stream.Write($errBytes, 0, $errBytes.Length)
                        $stream.Flush()
                    }
                } else {
                    $errJson = '{"status":"error","message":"Empty body"}'
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
                    $resp = "HTTP/1.1 400 Bad Request`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($errBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                    $respH = [System.Text.Encoding]::ASCII.GetBytes($resp)
                    $stream.Write($respH, 0, $respH.Length)
                    $stream.Write($errBytes, 0, $errBytes.Length)
                    $stream.Flush()
                }
            }
            $stream.Close()
            $client.Close()
            continue
        }

        # Handle REST API Endpoint /api/backup (Trigger Instant Backup)
        if ($rawUrl -eq "/api/backup") {
            $backupScript = Join-Path $baseDir "backup_job.ps1"
            if (Test-Path $backupScript) {
                Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$backupScript`"" -WindowStyle Hidden -Wait
            }
            $cfgPath = Join-Path $baseDir "email_config.json"
            $respJson = '{"status":"ok","message":"Backup job executed successfully"}'
            if (Test-Path $cfgPath) {
                try {
                    $cObj = Get-Content -Path $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $respJson = @{
                        status = "ok"
                        message = "Backup job executed successfully"
                        last_backup_file = $cObj.last_backup_file
                        last_backup_time = $cObj.last_backup_time
                        last_backup_size_kb = $cObj.last_backup_size_kb
                        last_email_sent = $cObj.last_email_sent
                        recipient = $cObj.recipient
                    } | ConvertTo-Json -Depth 5
                } catch {}
            }
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
            $resp = "HTTP/1.1 200 OK`r`n" +
                    "Content-Type: application/json; charset=utf-8`r`n" +
                    "Content-Length: $($respBytes.Length)`r`n" +
                    "Access-Control-Allow-Origin: *`r`n" +
                    "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
                    "Connection: close`r`n`r`n"
            $respH = [System.Text.Encoding]::ASCII.GetBytes($resp)
            $stream.Write($respH, 0, $respH.Length)
            $stream.Write($respBytes, 0, $respBytes.Length)
            $stream.Flush()
            $stream.Close()
            $client.Close()
            continue
        }

        # Handle REST API Endpoint /api/backup-settings
        if ($rawUrl -eq "/api/backup-settings") {
            $cfgPath = Join-Path $baseDir "email_config.json"
            if ($method -eq "GET") {
                if (-not (Test-Path $cfgPath)) {
                    $defCfg = '{"enabled":true,"backup_interval_hours":6,"recipient":"sonycafelahore@gmail.com","sender_email":"sonycafelahore@gmail.com","smtp_server":"smtp.gmail.com","smtp_port":587,"app_password":"","email_enabled":true,"cloud_sync_enabled":false,"cloud_folder":""}'
                    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                    [System.IO.File]::WriteAllText($cfgPath, $defCfg, $utf8NoBom)
                }
                $jsonBytes = [System.IO.File]::ReadAllBytes($cfgPath)
                $resp = "HTTP/1.1 200 OK`r`n" +
                        "Content-Type: application/json; charset=utf-8`r`n" +
                        "Content-Length: $($jsonBytes.Length)`r`n" +
                        "Access-Control-Allow-Origin: *`r`n" +
                        "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
                        "Connection: close`r`n`r`n"
                $respH = [System.Text.Encoding]::ASCII.GetBytes($resp)
                $stream.Write($respH, 0, $respH.Length)
                $stream.Write($jsonBytes, 0, $jsonBytes.Length)
                $stream.Flush()
            }
            elseif ($method -eq "POST") {
                $cl = 0
                if ($headers.ContainsKey("content-length")) {
                    [int]::TryParse($headers["content-length"], [ref]$cl) | Out-Null
                }
                $bodyStr = ""
                if ($cl -gt 0) {
                    $charList = New-Object System.Collections.Generic.List[char]
                    $charBuf = New-Object char[] 1024
                    $bytesAccum = 0
                    while ($bytesAccum -lt $cl) {
                        $toRead = [Math]::Min(1024, $cl - $bytesAccum)
                        $r = $reader.Read($charBuf, 0, $toRead)
                        if ($r -le 0) { break }
                        for ($i = 0; $i -lt $r; $i++) { $charList.Add($charBuf[$i]) }
                        $bodyStr = -join $charList
                        $bytesAccum = [System.Text.Encoding]::UTF8.GetByteCount($bodyStr)
                    }
                }
                if (-not [string]::IsNullOrEmpty($bodyStr)) {
                    try {
                        $parsed = $bodyStr | ConvertFrom-Json
                        $existing = @{}
                        if (Test-Path $cfgPath) {
                            try { $existing = Get-Content -Path $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
                        }
                        if ($null -ne $parsed.enabled) { $existing.enabled = [bool]$parsed.enabled }
                        if ($parsed.backup_interval_hours) { $existing.backup_interval_hours = [int]$parsed.backup_interval_hours }
                        if ($parsed.recipient) { $existing.recipient = $parsed.recipient }
                        if ($parsed.sender_email) { $existing.sender_email = $parsed.sender_email }
                        if ($parsed.smtp_server) { $existing.smtp_server = $parsed.smtp_server }
                        if ($parsed.smtp_port) { $existing.smtp_port = [int]$parsed.smtp_port }
                        if ($null -ne $parsed.app_password) { $existing.app_password = $parsed.app_password }
                        if ($null -ne $parsed.email_enabled) { $existing.email_enabled = [bool]$parsed.email_enabled }
                        if ($null -ne $parsed.cloud_sync_enabled) { $existing.cloud_sync_enabled = [bool]$parsed.cloud_sync_enabled }
                        if ($null -ne $parsed.cloud_folder) { $existing.cloud_folder = $parsed.cloud_folder }
                        
                        $saveJson = $existing | ConvertTo-Json -Depth 5
                        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                        [System.IO.File]::WriteAllText($cfgPath, $saveJson, $utf8NoBom)

                        # Update Windows Task Scheduler accordingly
                        $hours = [int]$existing.backup_interval_hours
                        if ($hours -lt 1) { $hours = 6 }
                        $taskScript = Join-Path $baseDir "run_backup.bat"
                        if ($existing.enabled -eq $false) {
                            schtasks.exe /Change /TN "SonyBox_ISP_6Hour_Backup" /DISABLE | Out-Null
                        } else {
                            if ($hours -ge 24) {
                                schtasks.exe /Create /SC DAILY /MO 1 /TN "SonyBox_ISP_6Hour_Backup" /TR "`"$taskScript`"" /F | Out-Null
                            } else {
                                schtasks.exe /Create /SC HOURLY /MO $hours /TN "SonyBox_ISP_6Hour_Backup" /TR "`"$taskScript`"" /F | Out-Null
                            }
                            schtasks.exe /Change /TN "SonyBox_ISP_6Hour_Backup" /ENABLE | Out-Null
                        }

                        $okJson = '{"status":"ok","message":"Settings saved & schedule updated successfully","hours":' + $hours + '}'
                        $okBytes = [System.Text.Encoding]::UTF8.GetBytes($okJson)
                        $resp = "HTTP/1.1 200 OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($okBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $respH = [System.Text.Encoding]::ASCII.GetBytes($resp)
                        $stream.Write($respH, 0, $respH.Length)
                        $stream.Write($okBytes, 0, $okBytes.Length)
                        $stream.Flush()
                    } catch {
                        $errJson = '{"status":"error","message":"Invalid payload: ' + $_.Exception.Message.Replace('"', '\"') + '"}'
                        $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
                        $resp = "HTTP/1.1 400 Bad Request`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($errBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $respH = [System.Text.Encoding]::ASCII.GetBytes($resp)
                        $stream.Write($respH, 0, $respH.Length)
                        $stream.Write($errBytes, 0, $errBytes.Length)
                        $stream.Flush()
                    }
                }
            }
            $stream.Close()
            $client.Close()
            continue
        }

        # Handle Static Files
        $cleanPath = $rawUrl.TrimStart("/")
        if ([string]::IsNullOrEmpty($cleanPath) -or $cleanPath -eq "/") { $cleanPath = "index.html" }
        $filePath = Join-Path $baseDir $cleanPath

        if (Test-Path $filePath -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $ctype = switch ($ext) {
                ".html" { "text/html; charset=utf-8" }
                ".json" { "application/json; charset=utf-8" }
                ".js"   { "application/javascript; charset=utf-8" }
                ".css"  { "text/css; charset=utf-8" }
                ".svg"  { "image/svg+xml" }
                ".png"  { "image/png" }
                ".jpg"  { "image/jpeg" }
                default { "application/octet-stream" }
            }
            $header = "HTTP/1.1 200 OK`r`nContent-Type: $ctype`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-cache, no-store, must-revalidate`r`nPragma: no-cache`r`nExpires: 0`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
            $hBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
            $stream.Write($hBytes, 0, $hBytes.Length)
            $stream.Write($bytes, 0, $bytes.Length)
        } else {
            $err = "HTTP/1.1 404 Not Found`r`nContent-Length: 9`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`nNot Found"
            $errBytes = [System.Text.Encoding]::ASCII.GetBytes($err)
            $stream.Write($errBytes, 0, $errBytes.Length)
        }
        $stream.Flush()
        $stream.Close()
        $client.Close()
    } catch {
        if ($client) { $client.Close() }
    }
}
