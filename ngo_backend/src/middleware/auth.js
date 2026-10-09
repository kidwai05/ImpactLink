// src/middleware/auth.js
const jwt = require('jsonwebtoken');

/**
 * Verifies the Bearer JWT and attaches decoded payload to req.user.
 */
function authenticate(req, res, next) {
    const header = req.headers.authorization;
    if (!header || !header.startsWith('Bearer ')) {
        return res.status(401).json({ success: false, message: 'No token provided.' });
    }
    const token = header.split(' ')[1];
    try {
        req.user = jwt.verify(token, process.env.JWT_SECRET);
        next();
    } catch {
        return res.status(401).json({ success: false, message: 'Invalid or expired token.' });
    }
}

/**
 * Factory: require that req.user.role is one of the allowed roles.
 * @param {...string} roles
 */
function authorize(...roles) {
    return (req, res, next) => {
        if (!roles.includes(req.user.role)) {
            return res.status(403).json({ success: false, message: 'Access denied.' });
        }
        next();
    };
}

module.exports = { authenticate, authorize };