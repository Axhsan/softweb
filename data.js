// netlify/functions/data.js
// Serverless Data Sync API for SonyBox ISP on Netlify
// Supports Netlify Blobs for persistent cross-device sync with graceful /tmp and static fallback

const fs = require('fs');
const path = require('path');

// In-memory cache across Lambda invocations in warm containers
let cachedData = null;

// Persistent scratchpad file in Lambda /tmp directory
const TMP_FILE = path.join('/tmp', 'sonybox_data.json');

function getBlobStore() {
    try {
        const { getStore } = require('@netlify/blobs');
        if (typeof getStore === 'function') {
            return getStore('sonybox_isp');
        }
    } catch (e) {
        // @netlify/blobs not available in environment
    }
    return null;
}

function loadData() {
    // 1. In-memory warm container cache
    if (cachedData && Array.isArray(cachedData.customers)) {
        return cachedData;
    }

    // 2. Ephemeral container file in /tmp
    try {
        if (fs.existsSync(TMP_FILE)) {
            const rawTmp = fs.readFileSync(TMP_FILE, 'utf8');
            const parsedTmp = JSON.parse(rawTmp);
            if (parsedTmp && Array.isArray(parsedTmp.customers)) {
                cachedData = parsedTmp;
                return cachedData;
            }
        }
    } catch (e) {
        // Ignore /tmp read error
    }

    // 3. Bundled or local static data.json
    const possiblePaths = [
        path.resolve(__dirname, 'data.json'),
        path.resolve(__dirname, '../data.json'),
        path.resolve(__dirname, '../../data.json'),
        path.resolve(process.cwd(), 'data.json')
    ];

    for (const p of possiblePaths) {
        try {
            if (fs.existsSync(p)) {
                const raw = fs.readFileSync(p, 'utf8');
                const parsed = JSON.parse(raw);
                if (parsed && Array.isArray(parsed.customers)) {
                    cachedData = parsed;
                    return cachedData;
                }
            }
        } catch (pe) {
            // Ignore path read error
        }
    }

    return {
        customers: [],
        areas: [],
        recoveryOfficers: [],
        billBatches: [],
        expenses: [],
        updatedAt: new Date().toISOString()
    };
}

exports.handler = async function(event, context) {
    const headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type, Accept, Authorization, X-Requested-With',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Content-Type': 'application/json'
    };

    if (event.httpMethod === 'OPTIONS') {
        return { statusCode: 200, headers, body: '' };
    }

    try {
        if (event.httpMethod === 'GET') {
            let data = null;

            // 1. Try reading from Netlify Blobs (shared persistent storage across containers)
            try {
                const store = getBlobStore();
                if (store) {
                    const blobData = await store.get('latest_data', { type: 'json' });
                    if (blobData && Array.isArray(blobData.customers)) {
                        data = blobData;
                        cachedData = blobData;
                    }
                }
            } catch (be) {
                // Blob read fallback
            }

            // 2. Fallback to in-memory, /tmp, or static data.json
            if (!data) {
                data = loadData();
            }

            return {
                statusCode: 200,
                headers,
                body: JSON.stringify(data)
            };
        }

        if (event.httpMethod === 'POST') {
            const body = JSON.parse(event.body || '{}');
            if (body.wipeAllCustomers === true) {
                body.customers = [];
            }
            cachedData = body;

            // 1. Save to Netlify Blobs for persistent sync across phones & PCs
            try {
                const store = getBlobStore();
                if (store) {
                    await store.setJSON('latest_data', body);
                }
            } catch (be) {
                // Blob write fallback
            }

            // 2. Attempt to write to /tmp for warm execution persistence
            try {
                fs.writeFileSync(TMP_FILE, JSON.stringify(body), 'utf8');
            } catch (we) {
                // Ignore /tmp write failure
            }

            return {
                statusCode: 200,
                headers,
                body: JSON.stringify({
                    success: true,
                    count: Array.isArray(body.customers) ? body.customers.length : 0,
                    updatedAt: body.updatedAt || new Date().toISOString()
                })
            };
        }

        return {
            statusCode: 405,
            headers,
            body: JSON.stringify({ error: 'Method Not Allowed' })
        };
    } catch (err) {
        return {
            statusCode: 500,
            headers,
            body: JSON.stringify({ error: err.message || 'Internal Server Error' })
        };
    }
};
