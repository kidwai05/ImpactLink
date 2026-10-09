// src/routes/admin.js
const express = require('express');
const db = require('../config/db');
const { authenticate, authorize } = require('../middleware/auth');

const router = express.Router();
const isAdmin = [authenticate, authorize('admin')];

// ────────────────────────────────────────────────
// GET /api/v1/admin/ngos/pending  — verification queue
// REQ-VER-05: returns name, registered_at, categories
// ────────────────────────────────────────────────
router.get('/ngos/pending', ...isAdmin, async (req, res) => {
    try {
        // Try with phone column first; fall back gracefully if column doesn't exist yet
        let rows;
        try {
            ({ rows } = await db.execute(`
      SELECT
        n.ngo_id,
        n.ngo_name,
        n.city,
        n.description,
        n.phone,
        n.status,
        n.registered_at,
        u.email,
        LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name) AS categories
      FROM XYZ.NGOS n
      JOIN XYZ.USERS u ON n.user_id = u.user_id
      LEFT JOIN XYZ.NGO_CATEGORIES nc ON n.ngo_id = nc.ngo_id
      LEFT JOIN XYZ.CATEGORIES c      ON nc.category_id = c.category_id
      WHERE n.status = 'pending'
      GROUP BY n.ngo_id, n.ngo_name, n.city, n.description, n.phone, n.status, n.registered_at, u.email
      ORDER BY n.registered_at ASC
    `));
        } catch (colErr) {
            // phone column not yet added — run migration: ALTER TABLE XYZ.NGOS ADD (phone VARCHAR2(30))
            ({ rows } = await db.execute(`
      SELECT
        n.ngo_id,
        n.ngo_name,
        n.city,
        n.description,
        NULL AS phone,
        n.status,
        n.registered_at,
        u.email,
        LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name) AS categories
      FROM XYZ.NGOS n
      JOIN XYZ.USERS u ON n.user_id = u.user_id
      LEFT JOIN XYZ.NGO_CATEGORIES nc ON n.ngo_id = nc.ngo_id
      LEFT JOIN XYZ.CATEGORIES c      ON nc.category_id = c.category_id
      WHERE n.status = 'pending'
      GROUP BY n.ngo_id, n.ngo_name, n.city, n.description, n.status, n.registered_at, u.email
      ORDER BY n.registered_at ASC
    `));
        }
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// GET /api/v1/admin/ngos  — all NGOs with status filter
// Includes donor count, total raised, and open needs per NGO.
// Pass ?status=pending|approved|rejected to filter; omit for all.
// NOTE: "pending" filter excludes rejected NGOs so they never appear
//       in the pending verification tab.
// ────────────────────────────────────────────────
router.get('/ngos', ...isAdmin, async (req, res) => {
    const { status } = req.query;
    // Oracle does not support LISTAGG(DISTINCT ...).
    // Fix: aggregate categories in a subquery so LISTAGG sees one row per
    // (ngo_id, category) before the outer joins multiply rows.
    // Donation stats are also pulled via correlated subqueries to avoid
    // double-counting that occurs when joining both DONATIONS and NEEDS.
    const sqlWithPhone = `
      SELECT
        n.ngo_id, n.ngo_name, n.city, n.phone, n.status, n.registered_at,
        u.email,
        (SELECT LISTAGG(c2.name, ', ') WITHIN GROUP (ORDER BY c2.name)
           FROM XYZ.NGO_CATEGORIES nc2
           JOIN XYZ.CATEGORIES c2 ON nc2.category_id = c2.category_id
          WHERE nc2.ngo_id = n.ngo_id)            AS categories,
        (SELECT COUNT(*)  FROM XYZ.DONATIONS d2   WHERE d2.ngo_id = n.ngo_id) AS donor_count,
        (SELECT NVL(SUM(d3.amount), 0)
           FROM XYZ.DONATIONS d3                  WHERE d3.ngo_id = n.ngo_id) AS total_raised,
        (SELECT COUNT(*)  FROM XYZ.NEEDS nd2
          WHERE nd2.ngo_id = n.ngo_id AND nd2.status = 'open')                AS open_needs
      FROM XYZ.NGOS n
      JOIN XYZ.USERS u ON n.user_id = u.user_id
      WHERE (:status IS NULL OR n.status = :status)
      ORDER BY n.registered_at DESC
    `;
    const sqlNoPhone = `
      SELECT
        n.ngo_id, n.ngo_name, n.city, NULL AS phone, n.status, n.registered_at,
        u.email,
        (SELECT LISTAGG(c2.name, ', ') WITHIN GROUP (ORDER BY c2.name)
           FROM XYZ.NGO_CATEGORIES nc2
           JOIN XYZ.CATEGORIES c2 ON nc2.category_id = c2.category_id
          WHERE nc2.ngo_id = n.ngo_id)            AS categories,
        (SELECT COUNT(*)  FROM XYZ.DONATIONS d2   WHERE d2.ngo_id = n.ngo_id) AS donor_count,
        (SELECT NVL(SUM(d3.amount), 0)
           FROM XYZ.DONATIONS d3                  WHERE d3.ngo_id = n.ngo_id) AS total_raised,
        (SELECT COUNT(*)  FROM XYZ.NEEDS nd2
          WHERE nd2.ngo_id = n.ngo_id AND nd2.status = 'open')                AS open_needs
      FROM XYZ.NGOS n
      JOIN XYZ.USERS u ON n.user_id = u.user_id
      WHERE (:status IS NULL OR n.status = :status)
      ORDER BY n.registered_at DESC
    `;
    try {
        let rows;
        try {
            ({ rows } = await db.execute(sqlWithPhone, { status: status || null }));
        } catch (colErr) {
            // phone column not yet added — run: ALTER TABLE XYZ.NGOS ADD (phone VARCHAR2(30))
            ({ rows } = await db.execute(sqlNoPhone, { status: status || null }));
        }
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// POST /api/v1/admin/ngos/:ngoId/verify  — approve or reject
// REQ-VER-02, REQ-VER-03
// ────────────────────────────────────────────────
router.post('/ngos/:ngoId/verify', ...isAdmin, async (req, res) => {
    const { ngoId } = req.params;
    const { action, remarks } = req.body; // action: 'approved' | 'rejected'
    const adminId = req.user.userId;

    if (!['approved', 'rejected'].includes(action))
        return res.status(400).json({ success: false, message: "action must be 'approved' or 'rejected'." });

    try {
        // Check NGO exists
        const { rows } = await db.execute(
            `SELECT ngo_id FROM XYZ.NGOS WHERE ngo_id = :ngoId`, { ngoId }
        );
        if (!rows.length)
            return res.status(404).json({ success: false, message: 'NGO not found.' });

        // Update status — trigger fires here to send notification
        await db.execute(
            `UPDATE XYZ.NGOS SET status = :action WHERE ngo_id = :ngoId`,
            { action, ngoId }
        );

        // Write audit log
        await db.execute(
            `INSERT INTO XYZ.VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
       VALUES (verif_log_seq.NEXTVAL, :ngoId, :adminId, :action, :remarks, SYSDATE)`,
            { ngoId, adminId, action, remarks: remarks || null }
        );

        res.json({ success: true, message: `NGO ${action} successfully.` });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// GET /api/v1/admin/analytics  — admin summary dashboard
// REQ-ANLYT-01, REQ-ANLYT-02
// ────────────────────────────────────────────────
router.get('/analytics', ...isAdmin, async (req, res) => {
    try {
        const [summary, byCategory, totalRaised] = await Promise.all([
            db.execute(`SELECT * FROM XYZ.vw_admin_summary`),
            db.execute(`SELECT * FROM XYZ.vw_donations_by_category ORDER BY total_commitments DESC`),
            db.execute(`SELECT NVL(SUM(amount), 0) AS total_raised FROM XYZ.DONATIONS`),
        ]);

        res.json({
            success: true,
            data: {
                summary: {
                    ...summary.rows[0],
                    TOTAL_RAISED: totalRaised.rows[0]?.TOTAL_RAISED || totalRaised.rows[0]?.['NVL(SUM(AMOUNT),0)'] || 0,
                },
                donationsByCategory: byCategory.rows,
            }
        });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// POST /api/v1/admin/categories  — add a cause category
// ────────────────────────────────────────────────
router.post('/categories', ...isAdmin, async (req, res) => {
    const { name, description } = req.body;
    if (!name)
        return res.status(400).json({ success: false, message: 'name is required.' });

    try {
        await db.execute(
            `INSERT INTO XYZ.CATEGORIES (category_id, name, description)
       VALUES (categories_seq.NEXTVAL, :name, :description)`,
            { name, description: description || null }
        );
        res.status(201).json({ success: true, message: `Category '${name}' created.` });
    } catch (err) {
        if (err.errorNum === 1)
            return res.status(409).json({ success: false, message: 'Category already exists.' });
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// GET /api/v1/admin/ngos/:ngoId/documents  — view NGO documents
// ────────────────────────────────────────────────
router.get('/ngos/:ngoId/documents', ...isAdmin, async (req, res) => {
    const { ngoId } = req.params;
    try {
        const { rows } = await db.execute(`
      SELECT doc_id, doc_type, file_path, uploaded_at
      FROM XYZ.DOCUMENTS
      WHERE ngo_id = :ngoId
      ORDER BY uploaded_at ASC
    `, { ngoId });
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// GET /api/v1/admin/donors  — all donors with details
// ────────────────────────────────────────────────
router.get('/donors', ...isAdmin, async (req, res) => {
    try {
        const { rows } = await db.execute(`
      SELECT
        d.donor_id,
        u.name,
        u.email,
        u.created_at,
        COUNT(don.donation_id) AS total_commitments,
        NVL(SUM(don.amount), 0) AS total_donated,
        LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name) AS preferences
      FROM XYZ.DONORS d
      JOIN XYZ.USERS u ON d.user_id = u.user_id
      LEFT JOIN XYZ.DONATIONS don ON d.donor_id = don.donor_id
      LEFT JOIN XYZ.DONOR_PREFERENCES dp ON d.donor_id = dp.donor_id
      LEFT JOIN XYZ.CATEGORIES c ON dp.category_id = c.category_id
      GROUP BY d.donor_id, u.name, u.email, u.created_at
      ORDER BY u.created_at DESC
    `);
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// GET /api/v1/admin/donors/:donorId/donations  — full donation history for one donor
// ────────────────────────────────────────────────
router.get('/donors/:donorId/donations', ...isAdmin, async (req, res) => {
    const donorId = parseInt(req.params.donorId, 10);
    try {
        const { rows } = await db.execute(`
      SELECT don.donation_id, nd.title AS need_title, n.ngo_name,
             don.item_description, don.amount, don.status, don.committed_at
      FROM XYZ.DONATIONS don
      JOIN XYZ.NEEDS nd ON don.need_id = nd.need_id
      JOIN XYZ.NGOS  n  ON don.ngo_id  = n.ngo_id
      WHERE don.donor_id = :1
      ORDER BY don.committed_at DESC
    `, [donorId]);
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

module.exports = router;
// ────────────────────────────────────────────────
// GET /api/v1/admin/ngos/:ngoId/documents  — view NGO documents
// ────────────────────────────────────────────────
// NOTE: This route is defined after module.exports above via monkey-patching
// but we add it here for clarity - it's registered via the router below.