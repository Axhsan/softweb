<?php
/**
 * SonyBox ISP Management System - Backend API for aaPanel / Linux Hosting
 * Handles /api/data, /api/backup, /api/backup-settings
 */

// Enable CORS
header("Access-Control-Allow-Origin: *");
header("Access-Control-Allow-Methods: GET, POST, OPTIONS");
header("Access-Control-Allow-Headers: Content-Type, Accept, Authorization, X-Requested-With");

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit;
}

// ========================================================
// SERVER-SIDE LOSSLESS MERGE & DATA PROTECTION HELPERS (PHP)
// ========================================================
function getPhpCustKey($c) {
    if (!is_array($c)) return '';
    if (isset($c['id']) && trim((string)$c['id']) !== '') return 'id:' . trim((string)$c['id']);
    if (!empty($c['userid']) && trim((string)$c['userid']) !== '-') return 'u:' . strtolower(trim((string)$c['userid']));
    if (!empty($c['phone'])) {
        $clean = preg_replace('/[^0-9]/', '', (string)$c['phone']);
        if (strlen($clean) >= 7) return 'p:' . $clean;
    }
    return 'n:' . strtolower(trim((string)($c['name'] ?? '')));
}

function getPhpCustLatestTs($c) {
    if (!is_array($c)) return 0;
    $maxTs = 0;
    if (!empty($c['updatedAt'])) {
        $t = strtotime($c['updatedAt']) * 1000;
        if ($t > $maxTs) $maxTs = $t;
    }
    if (!empty($c['history']) && is_array($c['history'])) {
        foreach ($c['history'] as $h) {
            if (!empty($h['timestamp']) && is_numeric($h['timestamp']) && $h['timestamp'] > $maxTs) {
                $maxTs = (float)$h['timestamp'];
            } elseif (!empty($h['receivedDate'])) {
                $t = strtotime($h['receivedDate']) * 1000;
                if ($t > $maxTs) $maxTs = $t;
            }
        }
    }
    return $maxTs;
}

function phpMergeCustomers($existingCusts, $incomingCusts, $deletedIds = [], $isRecoveryPayload = false) {
    $delSet = array_flip(array_map('strval', $deletedIds ?: []));
    $map = [];

    foreach ($existingCusts ?: [] as $c) {
        if (!is_array($c) || empty($c['name'])) continue;
        if (isset($c['id']) && isset($delSet[(string)$c['id']])) continue;
        $k = getPhpCustKey($c);
        if ($k) $map[$k] = $c;
    }

    foreach ($incomingCusts ?: [] as $inc) {
        if (!is_array($inc) || empty($inc['name'])) continue;
        if (isset($inc['id']) && isset($delSet[(string)$inc['id']])) continue;
        $k = getPhpCustKey($inc);
        if (!$k) continue;

        if (!isset($map[$k])) {
            $map[$k] = $inc;
        } else {
            $ex = $map[$k];

            $histMap = [];
            foreach ($ex['history'] ?? [] as $h) {
                $hk = !empty($h['billId']) ? (string)$h['billId'] : (($h['receivedDate'] ?? '') . '_' . ($h['receivedAmount'] ?? '') . '_' . ($h['monthYear'] ?? ''));
                if (!isset($histMap[$hk])) $histMap[$hk] = $h;
            }
            foreach ($inc['history'] ?? [] as $h) {
                $hk = !empty($h['billId']) ? (string)$h['billId'] : (($h['receivedDate'] ?? '') . '_' . ($h['receivedAmount'] ?? '') . '_' . ($h['monthYear'] ?? ''));
                if (!isset($histMap[$hk])) $histMap[$hk] = $h;
            }
            $mergedHistory = array_values($histMap);
            usort($mergedHistory, function($a, $b) {
                $ta = $a['timestamp'] ?? (isset($a['receivedDate']) ? strtotime($a['receivedDate']) * 1000 : 0);
                $tb = $b['timestamp'] ?? (isset($b['receivedDate']) ? strtotime($b['receivedDate']) * 1000 : 0);
                return $tb <=> $ta;
            });

            $exTs = getPhpCustLatestTs($ex);
            $incTs = getPhpCustLatestTs($inc);

            $incWinsPayment = false;
            if ($incTs > $exTs) {
                $incWinsPayment = true;
            } elseif ($exTs > $incTs) {
                $incWinsPayment = false;
            } else {
                $incIsPaid = (($inc['status'] ?? '') === 'PAID' || ($inc['status'] ?? '') === 'PARTIAL' || (float)($inc['paidAmount'] ?? 0) > 0);
                $exIsPaid = (($ex['status'] ?? '') === 'PAID' || ($ex['status'] ?? '') === 'PARTIAL' || (float)($ex['paidAmount'] ?? 0) > 0);
                if ($incIsPaid && !$exIsPaid) {
                    $incWinsPayment = true;
                } elseif ($exIsPaid && !$incIsPaid) {
                    $incWinsPayment = false;
                } else {
                    $incWinsPayment = ((float)($inc['paidAmount'] ?? 0) >= (float)($ex['paidAmount'] ?? 0));
                }
            }

            $pw = $incWinsPayment ? $inc : $ex;
            $other = $incWinsPayment ? $ex : $inc;

            $mergedCust = array_merge($ex, $inc, [
                'name' => ($isRecoveryPayload && !empty($ex['name'])) ? $ex['name'] : (!empty($inc['name']) ? $inc['name'] : ($ex['name'] ?? '')),
                'phone' => ($isRecoveryPayload && !empty($ex['phone'])) ? $ex['phone'] : (!empty($inc['phone']) ? $inc['phone'] : ($ex['phone'] ?? '')),
                'userid' => ($isRecoveryPayload && !empty($ex['userid'])) ? $ex['userid'] : (!empty($inc['userid']) ? $inc['userid'] : ($ex['userid'] ?? '')),
                'area' => ($isRecoveryPayload && !empty($ex['area']) && $ex['area'] !== '-') ? $ex['area'] : ((!empty($inc['area']) && $inc['area'] !== '-') ? $inc['area'] : ($ex['area'] ?? '-')),
                'package' => ($isRecoveryPayload && !empty($ex['package'])) ? $ex['package'] : (!empty($inc['package']) ? $inc['package'] : ($ex['package'] ?? '')),
                'fee' => ($isRecoveryPayload && isset($ex['fee'])) ? $ex['fee'] : (isset($inc['fee']) ? $inc['fee'] : ($ex['fee'] ?? 0)),
                'password' => ($isRecoveryPayload && isset($ex['password'])) ? $ex['password'] : (isset($inc['password']) ? $inc['password'] : ($ex['password'] ?? '')),
                'accountStatus' => ($isRecoveryPayload && !empty($ex['accountStatus'])) ? $ex['accountStatus'] : (!empty($inc['accountStatus']) ? $inc['accountStatus'] : ($ex['accountStatus'] ?? 'ACTIVE')),
                'isActive' => ($isRecoveryPayload && isset($ex['isActive'])) ? $ex['isActive'] : (isset($inc['isActive']) ? $inc['isActive'] : ($ex['isActive'] ?? true)),
                'connectionType' => ($isRecoveryPayload && !empty($ex['connectionType'])) ? $ex['connectionType'] : (!empty($inc['connectionType']) ? $inc['connectionType'] : ($ex['connectionType'] ?? 'Internet')),
                'notes' => isset($inc['notes']) ? $inc['notes'] : ($ex['notes'] ?? ''),
                'expireDate' => !empty($inc['expireDate']) ? $inc['expireDate'] : ($ex['expireDate'] ?? ''),

                'status' => $pw['status'] ?? 'PENDING',
                'paidAmount' => $pw['paidAmount'] ?? 0,
                'dueAmount' => $pw['dueAmount'] ?? ($pw['fee'] ?? 0),
                'paidAt' => $pw['paidAt'] ?? null,
                'pendingBills' => $pw['pendingBills'] ?? ($other['pendingBills'] ?? []),
                'arrears' => $pw['arrears'] ?? ($other['arrears'] ?? 0),
                'receiptId' => $pw['receiptId'] ?? ($other['receiptId'] ?? null),
                'receivingDate' => $pw['receivingDate'] ?? ($other['receivingDate'] ?? null),
                'cashType' => $pw['cashType'] ?? ($other['cashType'] ?? null),
                'currentBillMonth' => $pw['currentBillMonth'] ?? ($other['currentBillMonth'] ?? null),
                'history' => $mergedHistory,
                'updatedAt' => gmdate('Y-m-d\TH:i:s\Z')
            ]);

            $map[$k] = $mergedCust;
        }
    }

    return array_values($map);
}

$baseDir = __DIR__;
$dbFile = $baseDir . '/data.json';
$backupFile = $baseDir . '/data.backup.json';
$cfgFile = $baseDir . '/email_config.json';

// Detect requested endpoint
$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$method = $_SERVER['REQUEST_METHOD'];

// Route 1: /api/data (Sync, Load, Save Customers)
if (strpos($uri, '/api/data') !== false || (isset($_GET['route']) && $_GET['route'] === 'data')) {
    if ($method === 'GET') {
        header('Content-Type: application/json; charset=utf-8');
        header('Cache-Control: no-cache, no-store, must-revalidate');
        if (!file_exists($dbFile)) {
            $initData = [
                'customers' => [],
                'ispName' => 'SonyBox',
                'ispJazzcash' => '',
                'ispHelpline' => '',
                'currentPin' => '1234',
                'isLockEnabled' => true,
                'updatedAt' => gmdate('Y-m-d\TH:i:s\Z')
            ];
            file_put_contents($dbFile, json_encode($initData, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
        }
        readfile($dbFile);
        exit;
    }

    if ($method === 'POST') {
        $rawBody = file_get_contents('php://input');
        if (empty($rawBody)) {
            http_response_code(400);
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode(['status' => 'error', 'message' => 'Empty body']);
            exit;
        }

        $parsed = json_decode($rawBody, true);
        if ($parsed === null) {
            http_response_code(400);
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON payload']);
            exit;
        }

        // Backup existing data
        $existing = null;
        if (file_exists($dbFile)) {
            @copy($dbFile, $backupFile);
            $existing = json_decode(file_get_contents($dbFile), true);
        }

        if (is_array($existing)) {
            if (empty($parsed['currentPin']) && !empty($existing['currentPin'])) $parsed['currentPin'] = $existing['currentPin'];
            if (empty($parsed['lockType']) && !empty($existing['lockType'])) $parsed['lockType'] = $existing['lockType'];
            if (!isset($parsed['isLockEnabled']) && isset($existing['isLockEnabled'])) $parsed['isLockEnabled'] = $existing['isLockEnabled'];
            if (!isset($parsed['expenses']) && isset($existing['expenses'])) $parsed['expenses'] = $existing['expenses'];
            if (empty($parsed['billBatches']) && !empty($existing['billBatches'])) $parsed['billBatches'] = $existing['billBatches'];
            if (!empty($existing['areas']) && !empty($parsed['areas'])) {
                $parsed['areas'] = array_values(array_unique(array_merge($parsed['areas'], $existing['areas'])));
            } elseif (!empty($existing['areas']) && empty($parsed['areas'])) {
                $parsed['areas'] = $existing['areas'];
            }
            if (!empty($existing['recoveryOfficers']) && !empty($parsed['recoveryOfficers'])) {
                $oMap = [];
                foreach ($existing['recoveryOfficers'] as $o) { if (!empty($o['id'])) $oMap[(string)$o['id']] = $o; }
                foreach ($parsed['recoveryOfficers'] as $o) { if (!empty($o['id'])) $oMap[(string)$o['id']] = $o; }
                $parsed['recoveryOfficers'] = array_values($oMap);
            } elseif (!empty($existing['recoveryOfficers']) && empty($parsed['recoveryOfficers'])) {
                $parsed['recoveryOfficers'] = $existing['recoveryOfficers'];
            }
            $delIds = $parsed['deletedCustomerIds'] ?? [];
            $isRecovery = (($parsed['source'] ?? '') === 'recovery_portal');
            if (!empty($parsed['wipeAllCustomers'])) {
                            $parsed['customers'] = [];
                        } else {
                            $parsed['customers'] = phpMergeCustomers($existing['customers'] ?? [], $parsed['customers'] ?? [], $delIds, $isRecovery);
                        }
        }

        $parsed['updatedAt'] = gmdate('Y-m-d\TH:i:s\Z');
        file_put_contents($dbFile, json_encode($parsed, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));

        $count = (isset($parsed['customers']) && is_array($parsed['customers'])) ? count($parsed['customers']) : 0;
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode([
            'status' => 'ok',
            'message' => 'Data merged & saved successfully',
            'count' => $count,
            'updatedAt' => $parsed['updatedAt']
        ]);
        exit;
    }
}

// Route 2: /api/backup-settings
if (strpos($uri, '/api/backup-settings') !== false || (isset($_GET['route']) && $_GET['route'] === 'backup-settings')) {
    if ($method === 'GET') {
        header('Content-Type: application/json; charset=utf-8');
        header('Cache-Control: no-cache, no-store, must-revalidate');
        if (!file_exists($cfgFile)) {
            $defCfg = [
                'enabled' => true,
                'backup_interval_hours' => 6,
                'recipient' => 'sonycafelahore@gmail.com',
                'sender_email' => 'sonycafelahore@gmail.com',
                'smtp_server' => 'smtp.gmail.com',
                'smtp_port' => 587,
                'app_password' => '',
                'email_enabled' => true,
                'cloud_sync_enabled' => false,
                'cloud_folder' => ''
            ];
            file_put_contents($cfgFile, json_encode($defCfg, JSON_PRETTY_PRINT));
        }
        readfile($cfgFile);
        exit;
    }

    if ($method === 'POST') {
        $rawBody = file_get_contents('php://input');
        $parsed = json_decode($rawBody, true);
        if ($parsed !== null) {
            $existing = [];
            if (file_exists($cfgFile)) {
                $existing = json_decode(file_get_contents($cfgFile), true) ?: [];
            }
            $merged = array_merge($existing, $parsed);
            file_put_contents($cfgFile, json_encode($merged, JSON_PRETTY_PRINT));
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode(['status' => 'ok', 'message' => 'Settings saved successfully']);
            exit;
        }
    }
}

// Route 3: /api/backup (Trigger Instant Backup)
if (strpos($uri, '/api/backup') !== false || (isset($_GET['route']) && $_GET['route'] === 'backup')) {
    $zipFile = $baseDir . '/SonyBox_Backup_Latest.zip';
    if (class_exists('ZipArchive') && file_exists($dbFile)) {
        $zip = new ZipArchive();
        if ($zip->open($zipFile, ZipArchive::CREATE | ZipArchive::OVERWRITE) === true) {
            $zip->addFile($dbFile, 'data.json');
            if (file_exists($baseDir . '/index.html')) $zip->addFile($baseDir . '/index.html', 'index.html');
            if (file_exists($baseDir . '/recovery.html')) $zip->addFile($baseDir . '/recovery.html', 'recovery.html');
            if (file_exists($cfgFile)) $zip->addFile($cfgFile, 'email_config.json');
            $zip->close();
        }
    }

    $resp = [
        'status' => 'ok',
        'message' => 'Backup job executed successfully',
        'last_backup_file' => 'SonyBox_Backup_Latest.zip',
        'last_backup_time' => date('d-M-Y h:i A'),
        'last_backup_size_kb' => file_exists($zipFile) ? round(filesize($zipFile) / 1024, 1) : 0
    ];

    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($resp);
    exit;
}

// Fallback 404
http_response_code(404);
header('Content-Type: application/json; charset=utf-8');
echo json_encode(['status' => 'error', 'message' => 'API endpoint not found: ' . $uri]);
exit;
