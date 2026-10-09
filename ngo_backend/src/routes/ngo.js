// src/routes/ngo.js
const express = require('express');
const db = require('../config/db');
const path = require('path');
const fs = require('fs');
const { authenticate, authorize } = require('../middleware/auth');

const router = express.Router();
const isNgo = [authenticate, authorize('ngo')];

// ────────────────────────────────────────────────
// GET /api/v1/ngos/documents/file/:filename
// Admin-accessible endpoint to serve uploaded document files
// ────────────────────────────────────────────────
router.get('/documents/file/:filename', authenticate, (req, res) => {
    const filename = req.params.filename;
    // Sanitise: reject path traversal
    if (filename.includes('..') || filename.includes('/') || filename.includes('\\')) {
        return res.status(400).json({ success: false, message: 'Invalid filename.' });
    }
    const uploadsDir = path.resolve(__dirname, '..', '..', 'uploads');
    const filePath = path.join(uploadsDir, filename);
    if (!fs.existsSync(filePath)) {
        return res.status(404).json({ success: false, message: 'File not found.' });
    }
    res.sendFile(filePath);
});

// ────────────────────────────────────────────────
// GET /api/v1/ngos/profile  — own profile
// ────────────────────────────────────────────────
router.get('/profile', ...isNgo, async (req, res) => {
    const ngoId = req.user.roleId;
    try {
        const { rows } = await db.execute(`
      SELECT
        n.ngo_id, n.ngo_name, n.city, n.description, n.status, n.registered_at,
        u.name AS contact_name, u.email,
        LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name) AS categories
      FROM XYZ.NGOS n
      JOIN XYZ.USERS u ON n.user_id = u.user_id
      LEFT JOIN XYZ.NGO_CATEGORIES nc ON n.ngo_id = nc.ngo_id
      LEFT JOIN XYZ.CATEGORIES c      ON nc.category_id = c.category_id
      WHERE n.ngo_id = :1
      GROUP BY n.ngo_id, n.ngo_name, n.city, n.description, n.status, n.registered_at,
               u.name, u.email
    `, [ngoId]);

        if (!rows.length)
            return res.status(404).json({ success: false, message: 'NGO not found.' });

        res.json({ success: true, data: rows[0] });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// POST /api/v1/ngos/categories  — assign category to own NGO
// Calls stored procedure: set_ngo_category(p_ngo_id, p_category_id)
// ────────────────────────────────────────────────
router.post('/categories', ...isNgo, async (req, res) => {
    const ngoId = req.user.roleId;
    const { category_id } = req.body;
    if (!category_id)
        return res.status(400).json({ success: false, message: 'category_id is required.' });

    try {
        await db.executeProc(
            `BEGIN XYZ.set_ngo_category(:p_ngo_id, :p_category_id); END;`,
            { p_ngo_id: ngoId, p_category_id: category_id }
        );
        res.status(201).json({ success: true, message: 'Category assigned.' });
    } catch (err) {
        if (err.errorNum === 1)
            return res.status(409).json({ success: false, message: 'Category already assigned.' });
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// POST /api/v1/ngos/documents  — upload document reference
// Calls stored procedure: upload_document(p_ngo_id, p_file_path, p_doc_type)
// ────────────────────────────────────────────────
router.post('/documents', ...isNgo, async (req, res) => {
    const ngoId = req.user.roleId;
    const { file_path, file_name, doc_type } = req.body;
    const filePath = file_path || file_name;
    if (!filePath)
        return res.status(400).json({ success: false, message: 'file_path or file_name is required.' });

    try {
        await db.executeProc(
            `BEGIN XYZ.upload_document(:p_ngo_id, :p_file_path, :p_doc_type); END;`,
            {
                p_ngo_id: ngoId,
                p_file_path: filePath,
                p_doc_type: doc_type || null,
            }
        );
        res.status(201).json({ success: true, message: 'Document record saved.' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// GET /api/v1/ngos/documents  — list own documents
router.get('/documents', ...isNgo, async (req, res) => {
    const ngoId = req.user.roleId;
    try {
        const { rows } = await db.execute(
            `SELECT doc_id, doc_type, file_path, uploaded_at
       FROM XYZ.DOCUMENTS WHERE ngo_id = :1 ORDER BY uploaded_at ASC`,
            [ngoId]
        );
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// XYZ.NEEDS CRUD
// ────────────────────────────────────────────────

// GET /api/v1/ngos/needs  — list own needs (REQ-NEED-05)
router.get('/needs', ...isNgo, async (req, res) => {
    const ngoId = req.user.roleId;
    try {
        const { rows } = await db.execute(`
      SELECT
        nd.need_id, nd.title, nd.description, c.name AS category,
        nd.urgency_level, nd.target_quantity, nd.status, nd.created_at,
        COUNT(don.donation_id) AS commitment_count
      FROM XYZ.NEEDS nd
      JOIN XYZ.CATEGORIES c ON nd.category_id = c.category_id
      LEFT JOIN XYZ.DONATIONS don ON nd.need_id = don.need_id
      WHERE nd.ngo_id = :1
      GROUP BY nd.need_id, nd.title, nd.description, c.name,
               nd.urgency_level, nd.target_quantity, nd.status, nd.created_at
      ORDER BY nd.created_at DESC
    `, [ngoId]);
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// POST /api/v1/ngos/needs  — create need (REQ-NEED-01, REQ-VER-04)
// Calls stored procedure: post_need(p_ngo_id, p_category_id, p_title, p_description, p_urgency_level)
router.post('/needs', ...isNgo, async (req, res) => {
    const ngoId = req.user.roleId;
    const { title, description, category_id, urgency_level, target_quantity } = req.body;
    if (!title || !category_id || !urgency_level)
        return res.status(400).json({ success: false, message: 'title, category_id and urgency_level are required.' });

    try {
        // REQ-VER-04: only approved NGOs can post needs
        const { rows } = await db.execute(
            `SELECT status FROM XYZ.NGOS WHERE ngo_id = :1`, [ngoId]
        );
        if (!rows.length || rows[0].STATUS.toLowerCase() !== 'approved')
            return res.status(403).json({ success: false, message: 'Only approved NGOs can post needs.' });

        // Delegate to the stored procedure — it handles INSERT + COMMIT internally
        await db.executeProc(
            `BEGIN XYZ.post_need(:p_ngo_id, :p_category_id, :p_title, :p_description, :p_urgency_level); END;`,
            {
                p_ngo_id: ngoId,
                p_category_id: category_id,
                p_title: title,
                p_description: description || null,
                p_urgency_level: urgency_level,
            }
        );
        res.status(201).json({ success: true, message: 'Need posted.' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// PUT /api/v1/ngos/needs/:needId  — update need fields (REQ-NEED-02, REQ-NEED-04)
// NOTE: post_need only creates; field-level updates use direct SQL with NVL
// to merge partial payloads, which is beyond the procedure's scope.
router.put('/needs/:needId', ...isNgo, async (req, res) => {
    const ngoId = req.user.roleId;
    const needId = parseInt(req.params.needId, 10);
    const { title, description, category_id, urgency_level, target_quantity } = req.body;

    try {
        const { rows } = await db.execute(
            `SELECT ngo_id FROM XYZ.NEEDS WHERE need_id = :1`, [needId]
        );
        if (!rows.length)
            return res.status(404).json({ success: false, message: 'Need not found.' });
        if (rows[0].NGO_ID !== ngoId)
            return res.status(403).json({ success: false, message: 'You do not own this need.' });

        await db.execute(
            `UPDATE XYZ.NEEDS SET
        title           = NVL(:1, title),
        description     = NVL(:2, description),
        category_id     = NVL(:3, category_id),
        urgency_level   = NVL(:4, urgency_level),
        target_quantity = NVL(:5, target_quantity)
       WHERE need_id = :6`,
            [
                title || null,
                description || null,
                category_id || null,
                urgency_level || null,
                target_quantity || null,
                needId
            ]
        );
        res.json({ success: true, message: 'Need updated.' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// DELETE /api/v1/ngos/needs/:needId  — soft close (REQ-NEED-03)
// Calls stored procedure: update_need_status(p_need_id, p_status)
router.delete('/needs/:needId', ...isNgo, async (req, res) => {
    const ngoId = req.user.roleId;
    const needId = parseInt(req.params.needId, 10);

    try {
        const { rows } = await db.execute(
            `SELECT ngo_id FROM XYZ.NEEDS WHERE need_id = :1`, [needId]
        );
        if (!rows.length)
            return res.status(404).json({ success: false, message: 'Need not found.' });
        if (rows[0].NGO_ID !== ngoId)
            return res.status(403).json({ success: false, message: 'You do not own this need.' });

        await db.executeProc(
            `BEGIN XYZ.update_need_status(:p_need_id, :p_status); END;`,
            { p_need_id: needId, p_status: 'closed' }
        );
        res.json({ success: true, message: 'Need closed (soft deleted).' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// GET /api/v1/ngos/committed-donors  — donors who committed (REQ-DON-05)
// ────────────────────────────────────────────────
router.get('/committed-donors', ...isNgo, async (req, res) => {
    const ngoId = req.user.roleId;
    try {
        const { rows } = await db.execute(`
      SELECT
        don.donation_id,
        nd.need_id,
        nd.title          AS need_title,
        d.donor_id,
        u.name            AS donor_name,
        u.email           AS donor_email,
        don.item_description,
        don.amount,
        don.status        AS commitment_status,
        don.committed_at,
        (SELECT LISTAGG(dl.city, ', ') WITHIN GROUP (ORDER BY dl.city)
           FROM XYZ.DONOR_LOCATIONS dl
          WHERE dl.donor_id = d.donor_id)                        AS donor_cities,
        (SELECT LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name)
           FROM XYZ.DONOR_PREFERENCES dp
           JOIN XYZ.CATEGORIES c ON dp.category_id = c.category_id
          WHERE dp.donor_id = d.donor_id)                        AS donor_preferences,
        (SELECT LISTAGG(c2.name, ', ') WITHIN GROUP (ORDER BY c2.name)
           FROM XYZ.NGO_CATEGORIES nc
           JOIN XYZ.CATEGORIES c2 ON nc.category_id = c2.category_id
          WHERE nc.ngo_id = nd.ngo_id)                           AS ngo_categories
      FROM XYZ.DONATIONS don
      JOIN XYZ.DONORS d  ON don.donor_id = d.donor_id
      JOIN XYZ.USERS  u  ON d.user_id    = u.user_id
      JOIN XYZ.NEEDS  nd ON don.need_id  = nd.need_id
      WHERE nd.ngo_id = :1
      ORDER BY don.committed_at DESC
    `, [ngoId]);
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// GET /api/v1/ngos/analytics  — per-need commitment counts (REQ-ANLYT-03)
// ────────────────────────────────────────────────
router.get('/analytics', ...isNgo, async (req, res) => {
    const ngoId = req.user.roleId;
    try {
        const { rows } = await db.execute(`
      SELECT need_id, need_title, urgency_level, commitment_count
      FROM XYZ.vw_ngo_need_commitments
      WHERE ngo_id = :1
      ORDER BY commitment_count DESC
    `, [ngoId]);
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// GET /api/v1/ngos  — public: all verified (approved) NGOs for donor browsing
// ────────────────────────────────────────────────
router.get('/', async (req, res) => {
    try {
        const { rows } = await db.execute(`
      SELECT
        n.ngo_id,
        n.ngo_name,
        n.city,
        n.description,
        n.registered_at,
        LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name) AS categories,
        (SELECT COUNT(*) FROM XYZ.NEEDS nd WHERE nd.ngo_id = n.ngo_id AND LOWER(nd.status) = 'open') AS open_need_count
      FROM XYZ.NGOS n
      LEFT JOIN XYZ.NGO_CATEGORIES nc ON n.ngo_id = nc.ngo_id
      LEFT JOIN XYZ.CATEGORIES c      ON nc.category_id = c.category_id
      WHERE LOWER(n.status) = 'approved'
      GROUP BY n.ngo_id, n.ngo_name, n.city, n.description, n.registered_at
      ORDER BY n.registered_at DESC
    `);
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// GET /api/v1/ngos/:ngoId/open-needs  — public: open needs for a matched org (donor use)
// ────────────────────────────────────────────────
router.get('/:ngoId/open-needs', async (req, res) => {
    const ngoId = parseInt(req.params.ngoId, 10);
    try {
        const { rows } = await db.execute(`
      SELECT
        nd.need_id, nd.title, nd.description, c.name AS category,
        nd.urgency_level, nd.target_quantity, nd.status, nd.created_at,
        COUNT(don.donation_id) AS commitment_count
      FROM XYZ.NEEDS nd
      JOIN XYZ.CATEGORIES c ON nd.category_id = c.category_id
      LEFT JOIN XYZ.DONATIONS don ON nd.need_id = don.need_id
      WHERE nd.ngo_id = :1 AND LOWER(nd.status) = 'open'
      GROUP BY nd.need_id, nd.title, nd.description, c.name,
               nd.urgency_level, nd.target_quantity, nd.status, nd.created_at
      ORDER BY nd.created_at DESC
    `, [ngoId]);
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

module.exports = router;