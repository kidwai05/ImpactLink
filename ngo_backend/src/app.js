// src/app.js
require('dotenv').config();

const express = require('express');
const cors = require('cors');

const { initPool } = require('./config/db');

// Route modules
const authRoutes = require('./routes/auth');
const adminRoutes = require('./routes/admin');
const ngoRoutes = require('./routes/ngo');
const donorRoutes = require('./routes/donor');
const notificationRoutes = require('./routes/notifications');
const categoryRoutes = require('./routes/categories');

const app = express();
const PORT = process.env.PORT || 3000;

// ── Middleware ────────────────────────────────────────────────────
app.use(cors({
    origin: true,          // ✅ allow ALL origins (fixes your issue)
    credentials: true,
}));

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// ── Routes ────────────────────────────────────────────────────────
app.use('/api/v1/auth', authRoutes);
app.use('/api/v1/admin', adminRoutes);
app.use('/api/v1/ngos', ngoRoutes);
app.use('/api/v1/donors', donorRoutes);
app.use('/api/v1/notifications', notificationRoutes);
app.use('/api/v1/categories', categoryRoutes);

app.get('/', (req, res) => {
    res.json({
        success: true,
        message: "Backend is running 🚀"
    });
});

// ── Health Check ──────────────────────────────────────────────────
app.get('/api/v1/health', (_, res) =>
    res.json({
        status: 'ok',
        timestamp: new Date(),
    })
);

// ── 404 Handler ───────────────────────────────────────────────────
app.use((req, res) => {
    res.status(404).json({
        success: false,
        message: `Route not found: ${req.path}`,
    });
});

// ── Global Error Handler ─────────────────────────────────────────
app.use((err, req, res, _next) => {
    console.error('[ERROR]', err);

    res.status(500).json({
        success: false,
        message: err.message || 'Internal server error',
    });
});

// ── START SERVER ──────────────────────────────────────────────────
async function start() {
    try {
        await initPool();

        app.listen(PORT, () => {
            console.log(`🚀 API running on http://localhost:${PORT}`);
            console.log(`📌 Environment: ${process.env.NODE_ENV || 'development'}`);
        });

    } catch (err) {
        console.error('❌ Server failed to start:', err);
        process.exit(1);
    }
}

start();

module.exports = app;