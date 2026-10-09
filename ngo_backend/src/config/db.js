// src/config/db.js
const oracledb = require('oracledb');

// Try to initialise Oracle Thick client if available. Do NOT exit if it fails
// because a thin (pure JS) driver may be used in environments without
// Oracle Instant Client. Optionally supply ORACLE_CLIENT_LIB_DIR via env.
try {
    if (process.env.ORACLE_CLIENT_LIB_DIR) {
        oracledb.initOracleClient({ libDir: process.env.ORACLE_CLIENT_LIB_DIR });
    } else {
        // initOracleClient with no args will attempt default locations
        oracledb.initOracleClient();
    }
    console.log('✅ Oracle Thick mode initialised');
} catch (err) {
    console.warn('⚠️ Oracle Thick mode init failed, continuing (thin mode may be used):', err.message);
}

let pool;

// ✅ Create pool
async function initPool() {
    pool = await oracledb.createPool({
        user: process.env.DB_USER,
        password: process.env.DB_PASSWORD,
        connectString: process.env.DB_CONNECT_STRING,
        poolMin: 2,
        poolMax: 10,
        poolIncrement: 1,
    });

    console.log('✅ Oracle connection pool created');
}

// ✅ Helper: ALWAYS set schema per connection
async function getConnection() {
    const conn = await pool.getConnection();

    // If DB_SCHEMA is provided, set the current schema for the session.
    // This avoids hard-coded schema names and prevents failures when the
    // schema is different across environments.
    if (process.env.DB_SCHEMA) {
        // Only allow simple schema names (letters, numbers, underscore) and
        // ensure the identifier starts with a letter. If it doesn't meet
        // requirements, skip altering the session and log a warning.
        const raw = process.env.DB_SCHEMA;
        const safe = (raw || '').replace(/[^A-Za-z0-9_]/g, '');
        if (/^[A-Za-z][A-Za-z0-9_]*$/.test(safe)) {
            try {
                await conn.execute(`ALTER SESSION SET CURRENT_SCHEMA = ${safe}`);
            } catch (e) {
                console.warn('Could not set CURRENT_SCHEMA to', safe, e.message);
            }
        } else {
            console.warn('DB_SCHEMA ignored; must start with a letter and contain only alphanumeric or underscore characters');
        }
    }

    return conn;
}

// ✅ Execute normal SQL
async function execute(sql, binds = {}, opts = {}) {
    const conn = await getConnection();
    try {
        const result = await conn.execute(
            sql,
            binds,
            {
                outFormat: oracledb.OUT_FORMAT_OBJECT,
                autoCommit: true,
                ...opts,
            }
        );
        return result;
    } finally {
        await conn.close();
    }
}

// ✅ Execute stored procedures (with DBMS_OUTPUT)
async function executeProc(sql, binds = {}) {
    const conn = await getConnection();
    try {
        await conn.execute('BEGIN DBMS_OUTPUT.ENABLE(NULL); END;');

        await conn.execute(sql, binds, { autoCommit: true });

        const lines = [];
        let status;

        do {
            const res = await conn.execute(
                `BEGIN DBMS_OUTPUT.GET_LINE(:line, :status); END;`,
                {
                    line: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 32767 },
                    status: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER }
                }
            );

            status = res.outBinds.status;

            if (status === 0) {
                lines.push(res.outBinds.line);
            }

        } while (status === 0);

        return lines;
    } finally {
        await conn.close();
    }
}

// ✅ Execute multiple statements in a single transaction.
// `work` receives the raw oracledb connection; it must NOT call conn.commit/close.
// If `work` throws, the transaction is rolled back automatically.
//
// Usage:
//   await db.executeTransaction(async (conn) => {
//       await conn.execute(sql1, binds1);
//       await conn.execute(sql2, binds2);
//   });
async function executeTransaction(work) {
    const conn = await getConnection();
    try {
        // Run all statements supplied by the caller
        await work(conn);
        // All succeeded — commit
        await conn.commit();
    } catch (err) {
        // Something failed — roll back every statement in this transaction
        try { await conn.rollback(); } catch (_) { /* ignore rollback errors */ }
        throw err;          // re-throw so the route can return 500
    } finally {
        await conn.close();
    }
}

module.exports = {
    initPool,
    execute,
    executeProc,
    executeTransaction,
};