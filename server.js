/**
 * SonyBox ISP Management System - Zero-Dependency Node.js Server
 * Works directly in aaPanel Node.js Project Manager / PM2 or local Node
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = process.env.PORT || 22558;
const BASE_DIR = __dirname;
const DB_FILE = path.join(BASE_DIR, 'data.json');
const BACKUP_FILE = path.join(BASE_DIR, 'data.backup.json');
const CFG_FILE = path.join(BASE_DIR, 'email_config.json');

// Ensure data.json exists
if (!fs.existsSync(DB_FILE)) {
    const initData = {
        customers: [],
        ispName: 'SonyBox',
        ispJazzcash: '',
        ispHelpline: '',
        currentPin: '1234',
        isLockEnabled: true,
        updatedAt: new Date().toISOString()
    };
    fs.writeFileSync(DB_FILE, JSON.stringify(initData, null, 2), 'utf8');
}

// ========================================================
// SERVER-SIDE LOSSLESS MERGE & DATA PROTECTION HELPERS
// ========================================================
function getServerCustKey(c) {
    if (!c) return '';
    if (c.id !== undefined && c.id !== null && String(c.id).trim() !== '') return 'id:' + String(c.id).trim();
    if (c.userid && String(c.userid).trim() && String(c.userid).trim() !== '-') return 'u:' + String(c.userid).trim().toLowerCase();
    if (c.phone && String(c.phone).trim()) {
        const clean = String(c.phone).replace(/[^0-9]/g, '');
        if (clean.length >= 7) return 'p:' + clean;
    }
    return 'n:' + String(c.name || '').trim().toLowerCase();
}

function getServerCustLatestTs(c) {
    if (!c) return 0;
    let maxTs = 0;
    if (c.updatedAt) {
        const t = Date.parse(c.updatedAt);
        if (!isNaN(t) && t > maxTs) maxTs = t;
    }
    if (Array.isArray(c.history)) {
        for (let i = 0; i < c.history.length; i++) {
            const h = c.history[i];
            if (h.timestamp && typeof h.timestamp === 'number' && h.timestamp > maxTs) {
                maxTs = h.timestamp;
            } else if (h.receivedDate) {
                let t = Date.parse(h.receivedDate);
                if (isNaN(t)) {
                    const m = String(h.receivedDate).match(/(\d{1,2})\/([A-Za-z]{3})\/(\d{4})\s+(\d{1,2}):(\d{1,2}):(\d{1,2})/);
                    if (m) {
                        const mObj = { jan:0, feb:1, mar:2, apr:3, may:4, jun:5, jul:6, aug:7, sep:8, oct:9, nov:10, dec:11 };
                        t = new Date(Number(m[3]), mObj[m[2].toLowerCase()] || 0, Number(m[1]), Number(m[4]), Number(m[5]), Number(m[6])).getTime();
                    }
                }
                if (!isNaN(t) && t > maxTs) maxTs = t;
            }
        }
    }
    return maxTs;
}

function serverMergeCustomers(existingCusts, incomingCusts, deletedIds = [], isRecoveryPayload = false) {
    const delSet = new Set((deletedIds || []).map(id => String(id)));
    const map = new Map();

    (existingCusts || []).forEach(c => {
        if (!c || !c.name || delSet.has(String(c.id))) return;
        const k = getServerCustKey(c);
        if (k) map.set(k, { ...c });
    });

    (incomingCusts || []).forEach(inc => {
        if (!inc || !inc.name || delSet.has(String(inc.id))) return;
        const k = getServerCustKey(inc);
        if (!k) return;

        if (!map.has(k)) {
            map.set(k, { ...inc });
        } else {
            const ex = map.get(k);

            // Lossless history merge by billId
            const histMap = new Map();
            const addH = (h) => {
                if (!h) return;
                const hk = h.billId ? String(h.billId) : `${h.receivedDate || ''}_${h.receivedAmount || ''}_${h.monthYear || ''}`;
                if (!histMap.has(hk)) histMap.set(hk, { ...h });
            };
            if (Array.isArray(ex.history)) ex.history.forEach(addH);
            if (Array.isArray(inc.history)) inc.history.forEach(addH);
            const mergedHistory = Array.from(histMap.values());
            mergedHistory.sort((a, b) => {
                const ta = a.timestamp || (a.receivedDate ? Date.parse(a.receivedDate) : 0) || 0;
                const tb = b.timestamp || (b.receivedDate ? Date.parse(b.receivedDate) : 0) || 0;
                return tb - ta;
            });

            // Decide payment winner
            const exTs = getServerCustLatestTs(ex);
            const incTs = getServerCustLatestTs(inc);

            let incWinsPayment = false;
            if (incTs > exTs) {
                incWinsPayment = true;
            } else if (exTs > incTs) {
                incWinsPayment = false;
            } else {
                const incIsPaid = (inc.status === 'PAID' || inc.status === 'PARTIAL' || Number(inc.paidAmount) > 0);
                const exIsPaid = (ex.status === 'PAID' || ex.status === 'PARTIAL' || Number(ex.paidAmount) > 0);
                if (incIsPaid && !exIsPaid) {
                    incWinsPayment = true;
                } else if (exIsPaid && !incIsPaid) {
                    incWinsPayment = false;
                } else {
                    incWinsPayment = (Number(inc.paidAmount || 0) >= Number(ex.paidAmount || 0));
                }
            }

            const pw = incWinsPayment ? inc : ex;
            const other = incWinsPayment ? ex : inc;

            const mergedCust = {
                ...ex,
                ...inc,
                // Demographic authority:
                // If from recovery portal, preserve server/admin master demographic data
                name: (isRecoveryPayload && ex.name) ? ex.name : (inc.name || ex.name),
                phone: (isRecoveryPayload && ex.phone) ? ex.phone : (inc.phone || ex.phone),
                userid: (isRecoveryPayload && ex.userid) ? ex.userid : (inc.userid || ex.userid),
                area: (isRecoveryPayload && ex.area && ex.area !== '-') ? ex.area : ((inc.area && inc.area !== '-') ? inc.area : (ex.area || '-')),
                package: (isRecoveryPayload && ex.package) ? ex.package : (inc.package || ex.package),
                fee: (isRecoveryPayload && ex.fee !== undefined) ? ex.fee : (inc.fee !== undefined ? inc.fee : ex.fee),
                password: (isRecoveryPayload && ex.password !== undefined) ? ex.password : (inc.password !== undefined ? inc.password : ex.password),
                accountStatus: (isRecoveryPayload && ex.accountStatus) ? ex.accountStatus : (inc.accountStatus || ex.accountStatus),
                isActive: (isRecoveryPayload && ex.isActive !== undefined) ? ex.isActive : (inc.isActive !== undefined ? inc.isActive : ex.isActive),
                connectionType: (isRecoveryPayload && ex.connectionType) ? ex.connectionType : (inc.connectionType || ex.connectionType),
                notes: inc.notes !== undefined ? inc.notes : ex.notes,
                expireDate: inc.expireDate || ex.expireDate,

                // Payment authority
                status: pw.status,
                paidAmount: pw.paidAmount,
                dueAmount: pw.dueAmount,
                paidAt: pw.paidAt,
                pendingBills: Array.isArray(pw.pendingBills) ? pw.pendingBills : (Array.isArray(other.pendingBills) ? other.pendingBills : []),
                arrears: pw.arrears !== undefined ? pw.arrears : (other.arrears || 0),
                receiptId: pw.receiptId || other.receiptId,
                receivingDate: pw.receivingDate || other.receivingDate,
                cashType: pw.cashType || other.cashType,
                currentBillMonth: pw.currentBillMonth || other.currentBillMonth,
                history: mergedHistory,
                updatedAt: new Date().toISOString()
            };

            map.set(k, mergedCust);
        }
    });

    return Array.from(map.values());
}

const MIME_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.ico': 'image/x-icon',
    '.zip': 'application/zip'
};

const server = http.createServer((req, res) => {
    // CORS Headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Accept, Authorization, X-Requested-With');

    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }

    const parsedUrl = url.parse(req.url);
    const pathname = parsedUrl.pathname;

    // Helper: collect body
    const collectBody = (cb) => {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => cb(body));
    };

    // Route 1: /api/data
    if (pathname === '/api/data') {
        if (req.method === 'GET') {
            fs.readFile(DB_FILE, 'utf8', (err, data) => {
                if (err) {
                    res.writeHead(500, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ status: 'error', message: 'Failed to read data' }));
                    return;
                }
                res.writeHead(200, {
                    'Content-Type': 'application/json; charset=utf-8',
                    'Cache-Control': 'no-cache, no-store, must-revalidate'
                });
                res.end(data);
            });
            return;
        }

        if (req.method === 'POST') {
            collectBody(body => {
                try {
                    const parsed = JSON.parse(body);
                    let existing = null;
                    if (fs.existsSync(DB_FILE)) {
                        try {
                            existing = JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
                            fs.copyFileSync(DB_FILE, BACKUP_FILE);
                        } catch (e) {}
                    }

                    if (existing) {
                        if (!parsed.currentPin && existing.currentPin) parsed.currentPin = existing.currentPin;
                        if (!parsed.lockType && existing.lockType) parsed.lockType = existing.lockType;
                        if (parsed.isLockEnabled === undefined && existing.isLockEnabled !== undefined) parsed.isLockEnabled = existing.isLockEnabled;
                        if (!parsed.expenses && existing.expenses) parsed.expenses = existing.expenses;
                        if ((!parsed.billBatches || parsed.billBatches.length === 0) && (existing.billBatches && existing.billBatches.length > 0)) {
                            parsed.billBatches = existing.billBatches;
                        }
                        if (existing.areas && parsed.areas) {
                            parsed.areas = Array.from(new Set([...parsed.areas, ...existing.areas]));
                        } else if (existing.areas && !parsed.areas) {
                            parsed.areas = existing.areas;
                        }
                        if (existing.recoveryOfficers && parsed.recoveryOfficers) {
                            const oMap = new Map();
                            existing.recoveryOfficers.forEach(o => { if (o && o.id) oMap.set(String(o.id), o); });
                            parsed.recoveryOfficers.forEach(o => { if (o && o.id) oMap.set(String(o.id), o); });
                            parsed.recoveryOfficers = Array.from(oMap.values());
                        } else if (existing.recoveryOfficers && !parsed.recoveryOfficers) {
                            parsed.recoveryOfficers = existing.recoveryOfficers;
                        }
                        const delIds = parsed.deletedCustomerIds || [];
                        const isRecovery = (parsed.source === 'recovery_portal');
                        if (parsed.wipeAllCustomers === true) {
                            parsed.customers = [];
                        } else {
                            parsed.customers = serverMergeCustomers(existing.customers, parsed.customers, delIds, isRecovery);
                        }
                    }

                    parsed.updatedAt = new Date().toISOString();
                    fs.writeFileSync(DB_FILE, JSON.stringify(parsed, null, 2), 'utf8');
                    const count = (parsed.customers && Array.isArray(parsed.customers)) ? parsed.customers.length : 0;
                    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
                    res.end(JSON.stringify({
                        status: 'ok',
                        message: 'Data merged & saved successfully',
                        count: count,
                        updatedAt: parsed.updatedAt
                    }));
                } catch (e) {
                    res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
                    res.end(JSON.stringify({ status: 'error', message: 'Invalid JSON payload' }));
                }
            });
            return;
        }
    }

    // Route 2: /api/backup-settings
    if (pathname === '/api/backup-settings') {
        if (req.method === 'GET') {
            if (!fs.existsSync(CFG_FILE)) {
                const defCfg = {
                    enabled: true,
                    backup_interval_hours: 6,
                    recipient: 'sonycafelahore@gmail.com',
                    sender_email: 'sonycafelahore@gmail.com',
                    smtp_server: 'smtp.gmail.com',
                    smtp_port: 587,
                    app_password: '',
                    email_enabled: true,
                    cloud_sync_enabled: false,
                    cloud_folder: ''
                };
                fs.writeFileSync(CFG_FILE, JSON.stringify(defCfg, null, 2), 'utf8');
            }
            fs.readFile(CFG_FILE, 'utf8', (err, data) => {
                res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
                res.end(data || '{}');
            });
            return;
        }

        if (req.method === 'POST') {
            collectBody(body => {
                try {
                    const parsed = JSON.parse(body);
                    let existing = {};
                    if (fs.existsSync(CFG_FILE)) {
                        try { existing = JSON.parse(fs.readFileSync(CFG_FILE, 'utf8')); } catch (e) {}
                    }
                    const merged = Object.assign({}, existing, parsed);
                    fs.writeFileSync(CFG_FILE, JSON.stringify(merged, null, 2), 'utf8');
                    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
                    res.end(JSON.stringify({ status: 'ok', message: 'Settings saved successfully' }));
                } catch (e) {
                    res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
                    res.end(JSON.stringify({ status: 'error', message: 'Invalid JSON payload' }));
                }
            });
            return;
        }
    }

    // Route 3: /api/backup
    if (pathname === '/api/backup') {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({
            status: 'ok',
            message: 'Backup executed',
            time: new Date().toISOString()
        }));
        return;
    }

    // Serve Static Files
    let cleanPath = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
    let safePath = path.normalize(path.join(BASE_DIR, cleanPath));

    if (!safePath.startsWith(BASE_DIR)) {
        res.writeHead(403);
        res.end('Access Denied');
        return;
    }

    fs.stat(safePath, (err, stats) => {
        if (err || !stats.isFile()) {
            res.writeHead(404, { 'Content-Type': 'text/plain' });
            res.end('404 Not Found');
            return;
        }

        const ext = path.extname(safePath).toLowerCase();
        const contentType = MIME_TYPES[ext] || 'application/octet-stream';

        res.writeHead(200, {
            'Content-Type': contentType,
            'Cache-Control': 'no-cache, no-store, must-revalidate'
        });
        fs.createReadStream(safePath).pipe(res);
    });
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`SonyBox ISP Node Server running on http://0.0.0.0:${PORT}`);
});
