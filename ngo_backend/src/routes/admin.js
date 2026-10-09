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
            // phone column not yet added — run: ALTER TABLE XYZ.NGOS ADD (phone VARCHAR2(30))
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
// ────────────────────────────────────────────────
router.get('/ngos', ...isAdmin, async (req, res) => {
    const { status } = req.query;
    try {
        let rows;
        try {
            ({ rows } = await db.execute(`
      SELECT
        n.ngo_id, n.ngo_name, n.city, n.phone, n.status, n.registered_at,
        u.email,
        LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name) AS categories
      FROM XYZ.NGOS n
      JOIN XYZ.USERS u ON n.user_id = u.user_id
      LEFT JOIN XYZ.NGO_CATEGORIES nc ON n.ngo_id = nc.ngo_id
      LEFT JOIN XYZ.CATEGORIES c      ON nc.category_id = c.category_id
      WHERE (:status IS NULL OR n.status = :status)
      GROUP BY n.ngo_id, n.ngo_name, n.city, n.phone, n.status, n.registered_at, u.email
      ORDER BY n.registered_at DESC
    `, { status: status || null }));
        } catch (colErr) {
            ({ rows } = await db.execute(`
      SELECT
        n.ngo_id, n.ngo_name, n.city, NULL AS phone, n.status, n.registered_at,
        u.email,
        LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name) AS categories
      FROM XYZ.NGOS n
      JOIN XYZ.USERS u ON n.user_id = u.user_id
      LEFT JOIN XYZ.NGO_CATEGORIES nc ON n.ngo_id = nc.ngo_id
      LEFT JOIN XYZ.CATEGORIES c      ON nc.category_id = c.category_id
      WHERE (:status IS NULL OR n.status = :status)
      GROUP BY n.ngo_id, n.ngo_name, n.city, n.status, n.registered_at, u.email
      ORDER BY n.registered_at DESC
    `, { status: status || null }));
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
// Calls stored procedure: verify_ngo(p_ngo_id, p_admin_id, p_action, p_remarks)
// The procedure updates NGOS.status (firing trg_ngo_status_change) and writes
// the audit row to VERIFICATION_LOG in a single atomic COMMIT.
// ────────────────────────────────────────────────
router.post('/ngos/:ngoId/verify', ...isAdmin, async (req, res) => {
    const { ngoId } = req.params;
    const { action, remarks } = req.body; // action: 'approved' | 'rejected'
    const adminId = req.user.userId;

    if (!['approved', 'rejected'].includes(action))
        return res.status(400).json({ success: false, message: "action must be 'approved' or 'rejected'." });

    try {
        // Check NGO exists (read-only guard before calling the procedure)
        const { rows } = await db.execute(
            `SELECT ngo_id FROM XYZ.NGOS WHERE ngo_id = :ngoId`, { ngoId }
        );
        if (!rows.length)
            return res.status(404).json({ success: false, message: 'NGO not found.' });

        // Delegate entirely to the stored procedure.
        // verify_ngo handles: UPDATE NGOS + INSERT VERIFICATION_LOG + COMMIT
        // The DB trigger trg_ngo_status_change fires on the UPDATE and sends
        // the notification row automatically.
        await db.executeProc(
            `BEGIN XYZ.verify_ngo(:p_ngo_id, :p_admin_id, :p_action, :p_remarks); END;`,
            {
                p_ngo_id: parseInt(ngoId, 10),
                p_admin_id: adminId,
                p_action: action,
                p_remarks: remarks || null,
            }
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
// Calls stored procedure: add_category(p_name, p_description)
// ────────────────────────────────────────────────
router.post('/categories', ...isAdmin, async (req, res) => {
    const { name, description } = req.body;
    if (!name)
        return res.status(400).json({ success: false, message: 'name is required.' });

    try {
        await db.executeProc(
            `BEGIN XYZ.add_category(:p_name, :p_description); END;`,
            { p_name: name, p_description: description || null }
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

// ────────────────────────────────────────────────
// GET /api/v1/admin/donations/recent  — latest N donations across platform
// ────────────────────────────────────────────────
router.get('/donations/recent', ...isAdmin, async (req, res) => {
    const limit = Math.min(parseInt(req.query.limit, 10) || 10, 50);
    try {
        const { rows } = await db.execute(`
      SELECT *
      FROM (
        SELECT
          don.donation_id,
          don.amount,
          don.status,
          don.committed_at,
          don.item_description,
          u.name      AS donor_name,
          u.email     AS donor_email,
          n.ngo_name,
          nd.title    AS need_title,
          (SELECT c.name
             FROM XYZ.NGO_CATEGORIES nc
             JOIN XYZ.CATEGORIES c ON nc.category_id = c.category_id
            WHERE nc.ngo_id = n.ngo_id
              AND ROWNUM = 1)       AS category
        FROM XYZ.DONATIONS don
        JOIN XYZ.DONORS d  ON don.donor_id = d.donor_id
        JOIN XYZ.USERS  u  ON d.user_id    = u.user_id
        JOIN XYZ.NGOS   n  ON don.ngo_id   = n.ngo_id
        JOIN XYZ.NEEDS  nd ON don.need_id  = nd.need_id
        ORDER BY don.committed_at DESC
      )
      WHERE ROWNUM <= :limit
    `, { limit });
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

module.exports = router;