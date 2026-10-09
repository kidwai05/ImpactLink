// src/routes/donor.js
const express = require('express');
const db = require('../config/db');
const { authenticate, authorize } = require('../middleware/auth');

const router = express.Router();
const isDonor = [authenticate, authorize('donor')];

// ────────────────────────────────────────────────
// Helper: Resolve donor_id from userId
// ────────────────────────────────────────────────
async function resolveDonorId(userId) {
    console.log("Resolving donor_id for userId:", userId);
    const result = await db.execute(
        `SELECT donor_id FROM XYZ.DONORS WHERE user_id = :1`,
        [userId]
    );
    if (!result.rows.length) {
        return null;
    }
    return result.rows[0].DONOR_ID;
}

// ────────────────────────────────────────────────
// GET /api/v1/donors/profile
// ────────────────────────────────────────────────
router.get('/profile', ...isDonor, async (req, res) => {
    console.log("JWT:", req.user);
    const donorId = await resolveDonorId(req.user.userId);
    console.log("Resolved donor_id:", donorId);
    if (!donorId) {
        return res.status(400).json({ success: false, message: "Donor profile not found" });
    }
    try {
        const [profileRes, locsRes] = await Promise.all([
            db.execute(`
        SELECT u.name, u.email,
               (SELECT LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name)
                FROM XYZ.DONOR_PREFERENCES dp2
                JOIN XYZ.CATEGORIES c ON dp2.category_id = c.category_id
                WHERE dp2.donor_id = :1) AS preferences
        FROM XYZ.DONORS d
        JOIN XYZ.USERS u ON d.user_id = u.user_id
        WHERE d.donor_id = :1
      `, [donorId, donorId]),
            db.execute(
                `SELECT location_id, city, province, country, postal_code
         FROM XYZ.DONOR_LOCATIONS WHERE donor_id = :1`,
                [donorId]
            ),
        ]);

        if (!profileRes.rows.length)
            return res.status(404).json({ success: false, message: 'Donor not found.' });

        res.json({
            success: true,
            data: { ...profileRes.rows[0], locations: locsRes.rows }
        });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// LOCATIONS
// ────────────────────────────────────────────────

// POST /api/v1/donors/locations
// Calls stored procedure: add_donor_location(p_donor_id, p_city, p_province, p_country, p_postal_code)
router.post('/locations', ...isDonor, async (req, res) => {
    console.log("JWT:", req.user);
    const donorId = await resolveDonorId(req.user.userId);
    console.log("Resolved donor_id:", donorId);
    if (!donorId) {
        return res.status(400).json({ success: false, message: "Donor profile not found" });
    }
    const { city, province, country, postal_code } = req.body;
    try {
        await db.executeProc(
            `BEGIN XYZ.add_donor_location(:p_donor_id, :p_city, :p_province, :p_country, :p_postal_code); END;`,
            {
                p_donor_id: donorId,
                p_city: city || null,
                p_province: province || null,
                p_country: country || null,
                p_postal_code: postal_code || null,
            }
        );
        res.status(201).json({ success: true, message: 'Location added.' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// DELETE /api/v1/donors/locations/:locationId
// Calls stored procedure: remove_donor_location(p_location_id)
router.delete('/locations/:locationId', ...isDonor, async (req, res) => {
    console.log("JWT:", req.user);
    const donorId = await resolveDonorId(req.user.userId);
    console.log("Resolved donor_id:", donorId);
    if (!donorId) {
        return res.status(400).json({ success: false, message: "Donor profile not found" });
    }
    const locationId = parseInt(req.params.locationId, 10);
    try {
        // Ownership check (read-only, before calling the procedure)
        const { rows } = await db.execute(
            `SELECT donor_id FROM XYZ.DONOR_LOCATIONS WHERE location_id = :1`,
            [locationId]
        );
        if (!rows.length)
            return res.status(404).json({ success: false, message: 'Location not found.' });
        if (rows[0].DONOR_ID !== donorId)
            return res.status(403).json({ success: false, message: 'Not your location.' });

        await db.executeProc(
            `BEGIN XYZ.remove_donor_location(:p_location_id); END;`,
            { p_location_id: locationId }
        );
        res.json({ success: true, message: 'Location removed.' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// PREFERENCES
// ────────────────────────────────────────────────

// POST /api/v1/donors/preferences
// Calls stored procedure: set_donor_preference(p_donor_id, p_category_id)
router.post('/preferences', ...isDonor, async (req, res) => {
    console.log("JWT:", req.user);
    const donorId = await resolveDonorId(req.user.userId);
    console.log("Resolved donor_id:", donorId);
    if (!donorId) {
        return res.status(400).json({ success: false, message: "Donor profile not found" });
    }
    const { category_id } = req.body;
    if (!category_id)
        return res.status(400).json({ success: false, message: 'category_id is required.' });

    try {
        await db.executeProc(
            `BEGIN XYZ.set_donor_preference(:p_donor_id, :p_category_id); END;`,
            { p_donor_id: donorId, p_category_id: category_id }
        );
        res.status(201).json({ success: true, message: 'Preference added.' });
    } catch (err) {
        if (err.errorNum === 1)
            return res.status(409).json({ success: false, message: 'Preference already set for this category.' });
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// DELETE /api/v1/donors/preferences/:categoryId
router.delete('/preferences/:categoryId', ...isDonor, async (req, res) => {
    console.log("JWT:", req.user);
    const donorId = await resolveDonorId(req.user.userId);
    console.log("Resolved donor_id:", donorId);
    if (!donorId) {
        return res.status(400).json({ success: false, message: "Donor profile not found" });
    }
    const categoryId = parseInt(req.params.categoryId, 10);
    try {
        await db.execute(
            `DELETE FROM XYZ.DONOR_PREFERENCES WHERE donor_id = :1 AND category_id = :2`,
            [donorId, categoryId]
        );
        res.json({ success: true, message: 'Preference removed.' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// GET /api/v1/donors/matches  — weighted matching engine
// REQ-MATCH-01 / 02 / 03 / 04
// ────────────────────────────────────────────────
router.get('/matches', ...isDonor, async (req, res) => {
    console.log("JWT:", req.user);
    const donorId = await resolveDonorId(req.user.userId);
    console.log("Resolved donor_id:", donorId);
    if (!donorId) {
        return res.status(400).json({ success: false, message: "Donor profile not found" });
    }
    const { category, city } = req.query; // optional filters (REQ-MATCH-04)

    try {
        // Check preferences exist
        const prefCheck = await db.execute(
            `SELECT COUNT(*) AS cnt FROM XYZ.DONOR_PREFERENCES WHERE donor_id = :1`,
            [donorId]
        );
        if (prefCheck.rows[0].CNT === 0)
            return res.status(200).json({
                success: true,
                data: [],
                message: 'No preferences set. Please configure your cause preferences.'
            });

        const { rows: prefRows } = await db.execute(
            `SELECT COUNT(*) AS cnt FROM XYZ.DONOR_PREFERENCES WHERE donor_id = :1`,
            [donorId]
        );
        const prefCount = prefRows[0].CNT;

        const { rows } = await db.execute(`
      SELECT
        n.ngo_id,
        n.ngo_name,
        n.city,
        n.description,
        (
          SELECT LISTAGG(c3.name, ', ') WITHIN GROUP (ORDER BY c3.name)
          FROM XYZ.NGO_CATEGORIES nc3
          JOIN XYZ.CATEGORIES c3 ON nc3.category_id = c3.category_id
          WHERE nc3.ngo_id = n.ngo_id
        ) AS categories,
        ROUND(
          MAX(CASE WHEN dl.city = n.city THEN 100 ELSE 0 END) * 0.4
          + (COUNT(DISTINCT nc.category_id) / :prefCount * 100) * 0.4
          + MAX(CASE nd.urgency_level
                  WHEN 'critical' THEN 100
                  WHEN 'high'     THEN 75
                  WHEN 'medium'   THEN 40
                  WHEN 'low'      THEN 10
                  ELSE 0 END) * 0.2
        , 2) AS match_score,
        COUNT(DISTINCT nd.need_id) AS open_need_count
      FROM XYZ.NGOS n
      JOIN XYZ.NGO_CATEGORIES    nc  ON n.ngo_id       = nc.ngo_id
      JOIN XYZ.DONOR_PREFERENCES dp  ON dp.category_id = nc.category_id
                                 AND dp.donor_id   = :donorId
      JOIN XYZ.NEEDS             nd  ON nd.ngo_id       = n.ngo_id
                                 AND LOWER(nd.status)      = 'open'
      LEFT JOIN XYZ.DONOR_LOCATIONS dl ON dl.donor_id   = :donorId
      WHERE LOWER(n.status) IN ('approved','verified')
        AND (:cityFilter     IS NULL OR n.city = :cityFilter)
        AND (:catFilter IS NULL OR EXISTS (
              SELECT 1 FROM XYZ.NGO_CATEGORIES nc2
              JOIN XYZ.CATEGORIES c2 ON nc2.category_id = c2.category_id
              WHERE nc2.ngo_id = n.ngo_id AND c2.name = :catFilter
            ))
      GROUP BY n.ngo_id, n.ngo_name, n.city, n.description
      ORDER BY match_score DESC
    `, { donorId, prefCount, cityFilter: city || null, catFilter: category || null });

        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ────────────────────────────────────────────────
// DONATIONS
// ────────────────────────────────────────────────

// POST /api/v1/donors/donations  — commit to a need (REQ-DON-01/02/03)
// Calls stored procedure: make_donation(p_donor_id, p_need_id, p_item_description)
// The procedure handles the donation INSERT + both notifications in one atomic unit.
router.post('/donations', ...isDonor, async (req, res) => {
    console.log("JWT:", req.user);
    const donorId = await resolveDonorId(req.user.userId);
    console.log("Resolved donor_id:", donorId);
    if (!donorId) {
        return res.status(400).json({ success: false, message: "Donor profile not found" });
    }
    const { need_id, item_description, amount } = req.body;
    if (!need_id)
        return res.status(400).json({ success: false, message: 'need_id is required.' });

    try {
        // Verify need is open before calling procedure (provides a clean 404 to the client)
        const needRes = await db.execute(
            `SELECT nd.need_id, nd.title, nd.ngo_id, n.ngo_name
       FROM XYZ.NEEDS nd JOIN XYZ.NGOS n ON nd.ngo_id = n.ngo_id
       WHERE nd.need_id = :1 AND LOWER(nd.status) = 'open'`,
            [need_id]
        );
        if (!needRes.rows.length)
            return res.status(404).json({ success: false, message: 'Need not found or is no longer open.' });

        // Call the stored procedure — it inserts the donation row and
        // sends notifications to both the donor and the NGO atomically.
        await db.executeProc(
            `BEGIN XYZ.make_donation(:p_donor_id, :p_need_id, :p_item_description); END;`,
            {
                p_donor_id: donorId,
                p_need_id: need_id,
                p_item_description: item_description || null,
            }
        );

        // If an amount was supplied, record it as a separate update
        // (make_donation in the SQL file defaults amount to 0).
        const donationAmount = parseFloat(amount) || 0;
        if (donationAmount > 0) {
            await db.execute(
                `UPDATE XYZ.DONATIONS SET amount = :1
         WHERE donor_id = :2 AND need_id = :3
           AND committed_at = (
                 SELECT MAX(committed_at) FROM XYZ.DONATIONS
                 WHERE donor_id = :2 AND need_id = :3
               )`,
                [donationAmount, donorId, need_id]
            );
        }

        res.status(201).json({ success: true, message: `Committed to: ${needRes.rows[0].TITLE}` });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// GET /api/v1/donors/donations  — history (REQ-DON-04)
router.get('/donations', ...isDonor, async (req, res) => {
    console.log("JWT:", req.user);
    const donorId = await resolveDonorId(req.user.userId);
    console.log("Resolved donor_id:", donorId);
    if (!donorId) {
        return res.status(400).json({ success: false, message: "Donor profile not found" });
    }
    const { sort } = req.query; // 'asc' or 'desc' (default: desc)
    const order = sort === 'asc' ? 'ASC' : 'DESC';
    try {
        const { rows } = await db.execute(`
      SELECT donation_id, need_title, ngo_name, item_description, amount, status, committed_at
      FROM XYZ.vw_donor_history
      WHERE donor_id = :1
      ORDER BY committed_at ${order}
    `, [donorId]);
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// PATCH /api/v1/donors/donations/:donationId  — update status (cancel / complete)
// Calls stored procedure: update_donation_status(p_donation_id, p_status)
router.patch('/donations/:donationId', ...isDonor, async (req, res) => {
    console.log("JWT:", req.user);
    const donorId = await resolveDonorId(req.user.userId);
    console.log("Resolved donor_id:", donorId);
    if (!donorId) {
        return res.status(400).json({ success: false, message: "Donor profile not found" });
    }
    const donationId = parseInt(req.params.donationId, 10);
    const { status } = req.body;

    if (!['completed', 'cancelled'].includes(status))
        return res.status(400).json({ success: false, message: "status must be 'completed' or 'cancelled'." });

    try {
        // Ownership check before delegating to the procedure
        const { rows } = await db.execute(
            `SELECT donor_id FROM XYZ.DONATIONS WHERE donation_id = :1`, [donationId]
        );
        if (!rows.length)
            return res.status(404).json({ success: false, message: 'Donation not found.' });
        if (rows[0].DONOR_ID !== donorId)
            return res.status(403).json({ success: false, message: 'Not your donation.' });

        await db.executeProc(
            `BEGIN XYZ.update_donation_status(:p_donation_id, :p_status); END;`,
            { p_donation_id: donationId, p_status: status }
        );
        res.json({ success: true, message: `Donation marked as ${status}.` });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

module.exports = router;