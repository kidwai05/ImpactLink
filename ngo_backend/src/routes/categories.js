// src/routes/categories.js
const express = require('express');
const db = require('../config/db');

const router = express.Router();
console.log("XYZ.CATEGORIES ROUTE LOADED");
// GET /api/v1/categories  — public list of all categories (for dropdowns)
router.get('/', async (req, res) => {
    try {
        // Use the correct schema prefix (other routes use XYZ.)
        const { rows } = await db.execute(
            `SELECT category_id, name, description FROM XYZ.CATEGORIES ORDER BY name`
        );
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

router.get('/whoami', async (req, res) => {
    // Avoid using reserved words as column aliases without quoting.
    const r = await db.execute(`
        SELECT
            USER AS connected_user,
            sys_context('USERENV','DB_NAME') AS db_name,
            sys_context('USERENV','CURRENT_SCHEMA') AS current_schema
        FROM dual
    `);

    res.json(r.rows[0]);
});

module.exports = router;