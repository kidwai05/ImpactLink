// src/routes/notifications.js
const express = require('express');
const db = require('../config/db');
const { authenticate } = require('../middleware/auth');

const router = express.Router();

// GET /api/v1/notifications  — own notifications
router.get('/', authenticate, async (req, res) => {
    const userId = req.user.userId;
    try {
        const { rows } = await db.execute(`
      SELECT notif_id, notif_type, message, is_read, created_at
      FROM XYZ.NOTIFICATIONS
      WHERE user_id = :userId
      ORDER BY created_at DESC
    `, { userId });
        res.json({ success: true, data: rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// GET /api/v1/notifications/unread-count  — badge count (REQ-NOTIF-03)
router.get('/unread-count', authenticate, async (req, res) => {
    const userId = req.user.userId;
    try {
        const { rows } = await db.execute(
            `SELECT COUNT(*) AS unread FROM XYZ.NOTIFICATIONS WHERE user_id = :userId AND is_read = 0`,
            { userId }
        );
        res.json({ success: true, unread: rows[0].UNREAD });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// PATCH /api/v1/notifications/:notifId/read  — mark one read
router.patch('/:notifId/read', authenticate, async (req, res) => {
    const userId = req.user.userId;
    const notifId = parseInt(req.params.notifId, 10);
    try {
        const { rows } = await db.execute(
            `SELECT user_id FROM XYZ.NOTIFICATIONS WHERE notif_id = :notifId`, { notifId }
        );
        if (!rows.length)
            return res.status(404).json({ success: false, message: 'Notification not found.' });
        if (rows[0].USER_ID !== userId)
            return res.status(403).json({ success: false, message: 'Not your notification.' });

        await db.execute(
            `UPDATE XYZ.NOTIFICATIONS SET is_read = 1 WHERE notif_id = :notifId`, { notifId }
        );
        res.json({ success: true, message: 'Marked as read.' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// PATCH /api/v1/notifications/read-all  — mark all read (REQ-NOTIF-04)
router.patch('/read-all', authenticate, async (req, res) => {
    const userId = req.user.userId;
    try {
        await db.execute(
            `UPDATE XYZ.NOTIFICATIONS SET is_read = 1 WHERE user_id = :userId AND is_read = 0`,
            { userId }
        );
        res.json({ success: true, message: 'All notifications marked as read.' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, message: err.message });
    }
});

module.exports = router;