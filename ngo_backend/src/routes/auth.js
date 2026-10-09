// src/routes/auth.js
const express = require('express');
const jwt = require('jsonwebtoken');
const db = require('../config/db');

const router = express.Router();

// ────────────────────────────────────────────────
// POST /api/v1/auth/register/donor
// ────────────────────────────────────────────────
router.post('/register/donor', async (req, res) => {
    const { name, email, password } = req.body;
    if (!name || !email || !password)
        return res.status(400).json({ success: false, message: 'name, email and password are required.' });

    try {
        // Store password as plain text
        await db.execute(
            `INSERT INTO XYZ.USERS (user_id, name, email, password_hash, user_role, created_at)
       VALUES (XYZ.users_seq.NEXTVAL, :1, :2, :3, 'donor', SYSDATE)`,
            [name, email, password]
        );

        const { rows } = await db.execute(
            `SELECT user_id FROM XYZ.USERS WHERE email = :1`,
            [email]
        );
        const userId = rows[0].USER_ID;

        try {
            await db.execute(
                `INSERT INTO XYZ.DONORS (donor_id, user_id) VALUES (XYZ.donors_seq.NEXTVAL, :1)`,
                [userId]
            );
        } catch (donorErr) {
            console.error('Error creating donor profile:', donorErr);
            await db.execute(`DELETE FROM XYZ.USERS WHERE user_id = :1`, [userId]);
            throw donorErr;
        }

        res.status(201).json({ success: true, message: 'Donor registered successfully.' });
    } catch (err) {
        if (err.errorNum === 1)
            return res.status(409).json({ success: false, message: 'Email already in use.' });
        console.error(err);
        res.status(500).json({ success: false, message: 'Registration failed.', error: err.message });
    }
});

// ────────────────────────────────────────────────
// POST /api/v1/auth/register/ngo
// ────────────────────────────────────────────────
router.post('/register/ngo', async (req, res) => {
    const { name, email, password, ngo_name, city, description, phone, category } = req.body;
    if (!name || !email || !password || !ngo_name)
        return res.status(400).json({ success: false, message: 'name, email, password and ngo_name are required.' });

    try {
        await db.execute(
            `INSERT INTO XYZ.USERS (user_id, name, email, password_hash, user_role, created_at)
       VALUES (XYZ.users_seq.NEXTVAL, :1, :2, :3, 'ngo', SYSDATE)`,
            [name, email, password]
        );

        const { rows } = await db.execute(
            `SELECT user_id FROM XYZ.USERS WHERE email = :1`, [email]
        );
        const userId = rows[0].USER_ID;

        await db.execute(
            `INSERT INTO XYZ.NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
       VALUES (XYZ.ngos_seq.NEXTVAL, :1, :2, :3, :4, :5, 'pending', SYSDATE)`,
            [userId, ngo_name, city || null, description || null, phone || null]
        );

        // Assign category if provided
        if (category) {
            try {
                const ngoRes = await db.execute(
                    `SELECT ngo_id FROM XYZ.NGOS WHERE user_id = :1`, [userId]
                );
                const ngoId = ngoRes.rows[0]?.NGO_ID;
                const catRes = await db.execute(
                    `SELECT category_id FROM XYZ.CATEGORIES WHERE LOWER(name) = LOWER(:1)`, [category]
                );
                if (ngoId && catRes.rows.length) {
                    await db.execute(
                        `INSERT INTO XYZ.NGO_CATEGORIES (ngo_id, category_id) VALUES (:1, :2)`,
                        [ngoId, catRes.rows[0].CATEGORY_ID]
                    ).catch(() => { }); // ignore duplicate
                }
            } catch (catErr) {
                console.warn('Category assignment failed (non-fatal):', catErr.message);
            }
        }

        res.status(201).json({ success: true, message: 'NGO application submitted. Pending admin review.' });
    } catch (err) {
        if (err.errorNum === 1)
            return res.status(409).json({ success: false, message: 'Email already in use.' });
        console.error(err);
        res.status(500).json({ success: false, message: 'Registration failed.', error: err.message });
    }
});

// ────────────────────────────────────────────────
// POST /api/v1/auth/login
// ────────────────────────────────────────────────
router.post('/login', async (req, res) => {
    const { email, password } = req.body;
    if (!email || !password)
        return res.status(400).json({ success: false, message: 'email and password are required.' });

    try {
        const { rows } = await db.execute(
            `SELECT user_id, name, email, password_hash, user_role FROM XYZ.USERS WHERE email = :1`,
            [email]
        );

        if (!rows.length)
            return res.status(401).json({ success: false, message: 'Invalid credentials.' });

        const user = rows[0];

        // Plain text comparison
        if (password !== user.PASSWORD_HASH)
            return res.status(401).json({ success: false, message: 'Invalid credentials.' });

        let roleId = null;
        if (user.USER_ROLE === 'donor') {
            const r = await db.execute(`SELECT donor_id FROM XYZ.DONORS WHERE user_id = :1`, [user.USER_ID]);
            roleId = r.rows[0]?.DONOR_ID ?? null;
        } else if (user.USER_ROLE === 'ngo') {
            const r = await db.execute(`SELECT ngo_id, status FROM XYZ.NGOS WHERE user_id = :1`, [user.USER_ID]);
            roleId = r.rows[0]?.NGO_ID ?? null;
        }

        const token = jwt.sign(
            { userId: user.USER_ID, role: user.USER_ROLE, roleId },
            process.env.JWT_SECRET,
            { expiresIn: process.env.JWT_EXPIRES_IN || '24h' }
        );

        res.json({
            success: true,
            token,
            user: { id: user.USER_ID, name: user.NAME, email: user.EMAIL, role: user.USER_ROLE, roleId }
        });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: 'Login failed.', error: err.message });
    }
});

module.exports = router;