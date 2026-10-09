// js/api.js — Real backend API layer for ImpactLink
// Replaces all localStorage mock data with calls to the Express/Oracle backend.
// All function signatures match what the existing HTML pages expect — no page changes needed.

const BASE_URL = 'http://localhost:3000/api/v1';

// ── Internal helpers ─────────────────────────────────────────────────────────

function _getToken() { return localStorage.getItem('il_token'); }
function _getUser() { return JSON.parse(localStorage.getItem('il_user') || localStorage.getItem('impactlink_session') || 'null'); }
function _saveAuth(token, user) {
    localStorage.setItem('il_token', token);
    localStorage.setItem('il_user', JSON.stringify(user));
    // Also write legacy key so any page that reads 'impactlink_session' still works
    localStorage.setItem('impactlink_session', JSON.stringify(user));
}
function _clearAuth() {
    localStorage.removeItem('il_token');
    localStorage.removeItem('il_user');
    localStorage.removeItem('impactlink_session');
}

async function _req(path, options = {}) {
    const res = await fetch(`${BASE_URL}${path}`, options);
    const data = await res.json();
    if (!res.ok) throw new Error(data.message || `Error ${res.status}`);
    return data;
}

function _authHeaders() {
    return {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${_getToken()}`
    };
}

function _noAuthHeaders() {
    return { 'Content-Type': 'application/json' };
}

// ════════════════════════════════════════════════════════════════════════════
//  DONOR NAMESPACE  (top-level api.xxx)
// ════════════════════════════════════════════════════════════════════════════

const api = {

    // ── Auth ──────────────────────────────────────────────────────────────────

    register: async ({ name, email, password }) => {
        const res = await _req('/auth/register/donor', {
            method: 'POST', headers: _noAuthHeaders(),
            body: JSON.stringify({ name, email, password })
        });
        return res;
    },

    login: async ({ email, password }) => {
        const res = await _req('/auth/login', {
            method: 'POST', headers: _noAuthHeaders(),
            body: JSON.stringify({ email, password })
        });
        if (res.user.role !== 'donor') throw new Error('This account is not a donor account. Please use the correct login.');
        _saveAuth(res.token, res.user);
        return { success: true, name: res.user.name };
    },

    logout: () => { _clearAuth(); },

    currentUser: () => _getUser(),

    requireAuth: () => {
        const user = _getUser();
        const token = _getToken();
        if (!token || !user || user.role !== 'donor') {
            window.location.href = '../pages/login.html';
            return null;
        }
        return { email: user.email, name: user.name, type: 'donor' };
    },

    // ── Donor Profile ─────────────────────────────────────────────────────────

    getProfile: async () => {
        const res = await _req('/donors/profile', { headers: _authHeaders() });
        const d = res.data;
        // Deduplicate preferences that may come back as "Health, Health" due to LISTAGG with multiple joins
        const rawPrefs = (d.PREFERENCES || '').split(',').map(s => s.trim()).filter(Boolean);
        const preferences = [...new Set(rawPrefs)];
        return {
            name: d.NAME,
            email: d.EMAIL,
            preferences,
            locations: (d.locations || []).map(l => l.CITY).filter(Boolean),
            _rawLocs: d.locations || [],
        };
    },

    updateProfile: async ({ preferences, locations }) => {
        const [catRes, profileRes] = await Promise.all([
            _req('/categories'),
            _req('/donors/profile', { headers: _authHeaders() })
        ]);

        const allCats = catRes.data;
        const currentPrefs = (profileRes.data.PREFERENCES || '').split(',').map(s => s.trim()).filter(Boolean);
        const currentLocs = profileRes.data.locations || [];

        // Sync preferences
        for (const prefName of preferences) {
            if (!currentPrefs.includes(prefName)) {
                const cat = allCats.find(c => c.NAME === prefName);
                if (cat) await _req('/donors/preferences', {
                    method: 'POST', headers: _authHeaders(),
                    body: JSON.stringify({ category_id: cat.CATEGORY_ID })
                }).catch(() => { });
            }
        }
        for (const prefName of currentPrefs) {
            if (!preferences.includes(prefName)) {
                const cat = allCats.find(c => c.NAME === prefName);
                if (cat) await _req(`/donors/preferences/${cat.CATEGORY_ID}`, {
                    method: 'DELETE', headers: _authHeaders()
                }).catch(() => { });
            }
        }

        // Sync locations
        const currentCities = currentLocs.map(l => (l.CITY || '').toLowerCase());
        for (const city of locations) {
            if (!currentCities.includes(city.toLowerCase())) {
                await _req('/donors/locations', {
                    method: 'POST', headers: _authHeaders(),
                    body: JSON.stringify({ city, country: 'Pakistan' })
                }).catch(() => { });
            }
        }
        for (const loc of currentLocs) {
            if (!locations.map(l => l.toLowerCase()).includes((loc.CITY || '').toLowerCase())) {
                await _req(`/donors/locations/${loc.LOCATION_ID}`, {
                    method: 'DELETE', headers: _authHeaders()
                }).catch(() => { });
            }
        }

        return { success: true };
    },

    // ── Matches ───────────────────────────────────────────────────────────────

    getMatches: async () => {
        const [matchRes, allNgoRes] = await Promise.all([
            _req('/donors/matches', { headers: _authHeaders() }).catch(() => ({ data: [], message: 'no-prefs' })),
            _req('/ngos').catch(() => ({ data: [] })),
        ]);

        const matchData = matchRes.data || [];
        const allNgoData = allNgoRes.data || [];

        const mapMatch = n => ({
            id: n.NGO_ID,
            name: n.NGO_NAME,
            location: n.CITY || 'Pakistan',
            description: n.DESCRIPTION || '',
            category: (n.CATEGORIES || '').split(',')[0]?.trim() || 'General',
            score: n.MATCH_SCORE,
            urgency: 'high',
            donors: n.OPEN_NEED_COUNT,
            raised: 0,
            logo: '🌟',
            openNeeds: n.OPEN_NEED_COUNT,
        });

        const mapAll = n => ({
            id: n.NGO_ID,
            name: n.NGO_NAME,
            location: n.CITY || 'Pakistan',
            description: n.DESCRIPTION || '',
            category: (n.CATEGORIES || '').split(',')[0]?.trim() || 'General',
            score: null,
            urgency: 'medium',
            donors: n.OPEN_NEED_COUNT,
            raised: 0,
            logo: '🏢',
            openNeeds: n.OPEN_NEED_COUNT,
        });

        const matched = matchData.map(mapMatch);
        const matchedIds = new Set(matched.map(n => n.id));
        const others = allNgoData
            .filter(n => !matchedIds.has(n.NGO_ID))
            .map(mapAll);

        const hasProfile = !(matchData.length === 0 && matchRes.message);

        return { matched, others, hasProfile };
    },

    // ── Donations ─────────────────────────────────────────────────────────────

    getDonations: async () => {
        const res = await _req('/donors/donations', { headers: _authHeaders() });
        return (res.data || []).map(d => ({
            id: d.DONATION_ID,
            org: d.NGO_NAME,
            amount: d.AMOUNT || 0,
            category: '',
            date: d.COMMITTED_AT ? new Date(d.COMMITTED_AT).toISOString().split('T')[0] : '—',
            status: d.STATUS.charAt(0).toUpperCase() + d.STATUS.slice(1),
            need: d.NEED_TITLE,
            item: d.ITEM_DESCRIPTION || '',
            donorName: _getUser()?.name || '',
            donorEmail: _getUser()?.email || '',
        }));
    },

    // ── NGO Open Needs (for donor donation flow) ──────────────────────────────

    getNgoOpenNeeds: async (ngoId) => {
        const res = await _req(`/ngos/${ngoId}/open-needs`);
        return (res.data || []).map(n => ({
            id: n.NEED_ID,
            title: n.TITLE,
            description: n.DESCRIPTION || '',
            category: n.CATEGORY || '',
            urgency: n.URGENCY_LEVEL,
            quantity: n.TARGET_QUANTITY || 1,
            pledged: n.COMMITMENT_COUNT || 0,
        }));
    },

    addDonation: async ({ org, amount, category, need_id, item_description }) => {
        let needId = need_id;
        if (!needId) throw new Error('Please use the "View Needs" button to select a specific need to commit to.');
        await _req('/donors/donations', {
            method: 'POST', headers: _authHeaders(),
            body: JSON.stringify({ need_id: needId, item_description: item_description || '', amount: amount || 0 })
        });
        return { success: true };
    },

    // ── Notifications ─────────────────────────────────────────────────────────

    getNotifications: async () => {
        const res = await _req('/notifications', { headers: _authHeaders() });
        return res.data || [];
    },

    getUnreadCount: async () => {
        const res = await _req('/notifications/unread-count', { headers: _authHeaders() });
        return res.unread || 0;
    },

    markAllRead: async () => {
        return _req('/notifications/read-all', { method: 'PATCH', headers: _authHeaders() });
    },

    // ── Public categories ─────────────────────────────────────────────────────

    CATEGORIES: [],
    CITIES: ['Karachi', 'Lahore', 'Islamabad', 'Peshawar', 'Quetta', 'Multan', 'Faisalabad', 'Rawalpindi'],

    loadCategories: async () => {
        const res = await _req('/categories');
        api.CATEGORIES = (res.data || []).map(c => c.NAME);
        return api.CATEGORIES;
    },

    // ════════════════════════════════════════════════════════════════════════════
    //  NGO NAMESPACE  (api.ngo.xxx)
    // ════════════════════════════════════════════════════════════════════════════

    ngo: {

        register: async ({ orgName, email, password, category, city, mission, phone }) => {
            await _req('/auth/register/ngo', {
                method: 'POST', headers: _noAuthHeaders(),
                body: JSON.stringify({ name: orgName, email, password, ngo_name: orgName, city, description: mission, phone: phone || null, category: category || null })
            });
            return { success: true, orgName };
        },

        login: async ({ email, password }) => {
            const res = await _req('/auth/login', {
                method: 'POST', headers: _noAuthHeaders(),
                body: JSON.stringify({ email, password })
            });
            if (res.user.role !== 'ngo') throw new Error('This account is not an NGO account.');

            _saveAuth(res.token, res.user);

            // Check approval status
            try {
                const profile = await _req('/ngos/profile', { headers: _authHeaders() });
                if (profile.data.STATUS === 'pending') {
                    _clearAuth();
                    throw new Error('Your account is pending admin verification. You will be notified once approved.');
                }
                if (profile.data.STATUS === 'rejected') {
                    _clearAuth();
                    throw new Error('Your NGO registration was rejected. Please contact support.');
                }
            } catch (e) {
                if (e.message.includes('pending') || e.message.includes('rejected')) throw e;
            }

            return { success: true, orgName: res.user.name };
        },

        logout: () => { _clearAuth(); },

        currentUser: () => {
            const u = _getUser();
            return u && u.role === 'ngo' ? { email: u.email, orgName: u.name, type: 'ngo' } : null;
        },

        currentNgo: () => {
            const u = _getUser();
            return u && u.role === 'ngo' ? { email: u.email, orgName: u.name, type: 'ngo' } : null;
        },

        requireAuth: () => {
            const user = _getUser();
            const token = _getToken();
            if (!token || !user || user.role !== 'ngo') {
                window.location.href = '../pages/login.html';
                return null;
            }
            return { email: user.email, orgName: user.name, type: 'ngo' };
        },

        // ── Profile ───────────────────────────────────────────────────────────────

        getProfile: async () => {
            const res = await _req('/ngos/profile', { headers: _authHeaders() });
            const d = res.data;
            return {
                orgName: d.NGO_NAME,
                email: d.EMAIL,
                city: d.CITY || '',
                mission: d.DESCRIPTION || '',
                category: (d.CATEGORIES || '').split(',')[0]?.trim() || '',
                categories: (d.CATEGORIES || '').split(',').map(s => s.trim()).filter(Boolean),
                phone: '',
                verified: d.STATUS === 'approved',
                status: d.STATUS,
                joinedAt: d.REGISTERED_AT ? new Date(d.REGISTERED_AT).toISOString().split('T')[0] : '—',
                _ngoId: d.NGO_ID,
            };
        },

        updateProfile: async (data) => {
            if (data.category || data.categories) {
                const cats = data.categories || [data.category];
                const catRes = await _req('/categories');
                for (const catName of cats) {
                    const cat = catRes.data.find(c => c.NAME === catName);
                    if (cat) await _req('/ngos/categories', {
                        method: 'POST', headers: _authHeaders(),
                        body: JSON.stringify({ category_id: cat.CATEGORY_ID })
                    }).catch(() => { });
                }
            }
            return { success: true };
        },

        // ── Needs ─────────────────────────────────────────────────────────────────

        getNeeds: async () => {
            const res = await _req('/ngos/needs', { headers: _authHeaders() });
            return (res.data || []).map(n => ({
                id: n.NEED_ID,
                title: n.TITLE,
                description: n.DESCRIPTION || '',
                quantity: n.TARGET_QUANTITY || 1,
                unit: 'units',
                urgency: n.URGENCY_LEVEL,
                status: n.STATUS.charAt(0).toUpperCase() + n.STATUS.slice(1),
                createdAt: n.CREATED_AT ? new Date(n.CREATED_AT).toISOString().split('T')[0] : '—',
                pledged: n.COMMITMENT_COUNT || 0,
                category: n.CATEGORY || '',
            }));
        },

        addNeed: async ({ title, description, quantity, unit, urgency, amountNeeded }) => {
            const profile = await api.ngo.getProfile();
            const catRes = await _req('/categories');
            const cat = catRes.data.find(c => c.NAME === profile.category) || catRes.data[0];
            if (!cat) throw new Error('Please assign a category to your NGO profile first.');

            await _req('/ngos/needs', {
                method: 'POST', headers: _authHeaders(),
                body: JSON.stringify({
                    title,
                    description: description || '',
                    category_id: cat.CATEGORY_ID,
                    urgency_level: urgency || 'medium',
                    target_quantity: quantity || amountNeeded || 1,
                })
            });
            return { success: true, need: { id: Date.now(), title, status: 'Open', pledged: 0 } };
        },

        updateNeed: async (id, updates) => {
            const body = {};
            if (updates.title) body.title = updates.title;
            if (updates.description) body.description = updates.description;
            if (updates.urgency) body.urgency_level = updates.urgency;
            if (updates.quantity) body.target_quantity = updates.quantity;

            if (updates.status) {
                const s = updates.status.toLowerCase();
                if (s === 'fulfilled' || s === 'closed') {
                    await _req(`/ngos/needs/${id}`, { method: 'DELETE', headers: _authHeaders() });
                    return { success: true };
                }
            }

            if (Object.keys(body).length) {
                await _req(`/ngos/needs/${id}`, {
                    method: 'PUT', headers: _authHeaders(),
                    body: JSON.stringify(body)
                });
            }
            return { success: true };
        },

        deleteNeed: async (id) => {
            await _req(`/ngos/needs/${id}`, { method: 'DELETE', headers: _authHeaders() });
            return { success: true };
        },

        removeNeed: async (id) => api.ngo.deleteNeed(id),

        // ── Documents ─────────────────────────────────────────────────────────────

        uploadDocument: async ({ file_name, doc_type }) => {
            await _req('/ngos/documents', {
                method: 'POST', headers: _authHeaders(),
                body: JSON.stringify({ file_name, file_path: file_name, doc_type: doc_type || 'other' })
            });
            return { success: true };
        },

        getDocuments: async () => {
            const res = await _req('/ngos/documents', { headers: _authHeaders() });
            return (res.data || []).map(d => ({
                id: d.DOC_ID,
                name: d.FILE_PATH,
                type: d.DOC_TYPE || 'other',
                uploadedAt: d.UPLOADED_AT ? new Date(d.UPLOADED_AT).toISOString().split('T')[0] : '—',
            }));
        },

        // ── Stats ─────────────────────────────────────────────────────────────────

        getStats: async () => {
            const [needsRes, donorsRes] = await Promise.all([
                _req('/ngos/needs', { headers: _authHeaders() }),
                _req('/ngos/committed-donors', { headers: _authHeaders() }),
            ]);

            const needs = needsRes.data || [];
            const donors = donorsRes.data || [];

            // Calculate total raised from actual donation amounts
            const totalRaised = donors.reduce((sum, d) => sum + (d.AMOUNT || 0), 0);

            return {
                totalDonors: donors.length,
                totalRaised,
                openNeeds: needs.filter(n => n.STATUS === 'open').length,
                fulfilledNeeds: needs.filter(n => n.STATUS === 'fulfilled').length,
                recentDonors: donors.slice(0, 5).map(d => ({
                    name: d.DONOR_NAME,
                    email: d.DONOR_EMAIL,
                    org: d.NEED_TITLE,
                    amount: d.AMOUNT || 0,
                    date: d.COMMITTED_AT ? new Date(d.COMMITTED_AT).toISOString().split('T')[0] : '—',
                    status: d.COMMITMENT_STATUS,
                })),
            };
        },

        getDonorMatches: async () => {
            const res = await _req('/ngos/committed-donors', { headers: _authHeaders() });
            // Group by donor so each donor row has all their commitments
            const byDonor = {};
            for (const d of (res.data || [])) {
                const key = d.DONOR_ID;
                if (!byDonor[key]) {
                    byDonor[key] = {
                        id: d.DONOR_ID,
                        name: d.DONOR_NAME,
                        email: d.DONOR_EMAIL,
                        preferences: [],
                        locations: [],
                        totalDonated: 0,
                        donations: 0,
                        lastDonation: d.COMMITTED_AT ? new Date(d.COMMITTED_AT).toISOString().split('T')[0] : '—',
                        score: 75,
                        commitments: [],
                    };
                }
                const amt = d.AMOUNT || 0;
                byDonor[key].totalDonated += amt;
                byDonor[key].donations += 1;
                byDonor[key].commitments.push({
                    donationId: d.DONATION_ID,
                    need: d.NEED_TITLE,
                    item: d.ITEM_DESCRIPTION || '',
                    amount: amt,
                    status: d.COMMITMENT_STATUS,
                    lastDonation: d.COMMITTED_AT ? new Date(d.COMMITTED_AT).toISOString().split('T')[0] : '—',
                });
                // Keep most-recent date
                const dt = d.COMMITTED_AT ? new Date(d.COMMITTED_AT).toISOString().split('T')[0] : '';
                if (dt > byDonor[key].lastDonation) byDonor[key].lastDonation = dt;
            }
            const donors = Object.values(byDonor);
            return { matched: donors, others: [] };
        },

    },

    // ════════════════════════════════════════════════════════════════════════════
    //  ADMIN NAMESPACE  (api.admin.xxx)
    // ════════════════════════════════════════════════════════════════════════════

    admin: {

        login: async (email, password) => {
            const res = await _req('/auth/login', {
                method: 'POST', headers: _noAuthHeaders(),
                body: JSON.stringify({ email, password })
            });
            if (res.user.role !== 'admin') throw new Error('This account does not have admin access.');
            _saveAuth(res.token, res.user);
            return { success: true, name: res.user.name || 'Admin' };
        },

        logout: () => { _clearAuth(); },

        requireAuth: () => {
            const user = _getUser();
            const token = _getToken();
            if (!token || !user || user.role !== 'admin') {
                window.location.href = '../pages/login.html';
                return false;
            }
            return true;
        },

        getSummary: async () => {
            const [summaryRes, pendingRes] = await Promise.all([
                _req('/admin/analytics', { headers: _authHeaders() }),
                _req('/admin/ngos/pending', { headers: _authHeaders() }),
            ]);
            const s = summaryRes.data.summary || {};
            const pending = pendingRes.data || [];
            return {
                totalDonors: s.TOTAL_DONORS || 0,
                totalNgos: s.VERIFIED_NGOS || 0,
                registeredNgos: s.VERIFIED_NGOS || 0,
                pendingNgos: pending.length,
                verifiedNgos: s.VERIFIED_NGOS || 0,
                totalDonations: s.TOTAL_COMMITMENTS || 0,
                totalRaised: s.TOTAL_RAISED || 0,
                activeNeeds: s.ACTIVE_NEEDS || 0,
                recentDonations: [],
                donationsByCategory: summaryRes.data.donationsByCategory || [],
            };
        },

        getPendingNgos: async () => {
            const res = await _req('/admin/ngos?status=pending', { headers: _authHeaders() });
            return (res.data || []).map(n => _mapNgo(n));
        },

        // Returns only pending + approved NGOs (excludes rejected).
        // Used by verify.html — rejected NGOs must NOT appear in the pending tab.
        getAllNgos: async () => {
            const [pendingRes, approvedRes] = await Promise.all([
                _req('/admin/ngos?status=pending', { headers: _authHeaders() }),
                _req('/admin/ngos?status=approved', { headers: _authHeaders() }),
            ]);
            const pending = (pendingRes.data || []).map(n => _mapNgo(n));
            const approved = (approvedRes.data || []).map(n => _mapNgo(n));
            return [...pending, ...approved];
        },

        // Returns ALL NGOs including rejected — used by the NGOs management page.
        getAllNgosIncludingRejected: async () => {
            const res = await _req('/admin/ngos', { headers: _authHeaders() });
            return (res.data || []).map(n => _mapNgo(n));
        },

        verifyNgo: async (emailOrId) => {
            const ngo = await _adminFindNgo(emailOrId);
            await _req(`/admin/ngos/${ngo.ngo_id}/verify`, {
                method: 'POST', headers: _authHeaders(),
                body: JSON.stringify({ action: 'approved', remarks: 'Approved via admin portal.' })
            });
            return { success: true };
        },

        rejectNgo: async (emailOrId, remarks) => {
            const ngo = await _adminFindNgo(emailOrId);
            await _req(`/admin/ngos/${ngo.ngo_id}/verify`, {
                method: 'POST', headers: _authHeaders(),
                body: JSON.stringify({ action: 'rejected', remarks: remarks || 'Rejected via admin portal.' })
            });
            return { success: true };
        },

        getAllDonors: async () => {
            const res = await _req('/admin/donors', { headers: _authHeaders() });
            return (res.data || []).map(d => {
                // Deduplicate preferences (LISTAGG can repeat if multiple joins)
                const rawPrefs = (d.PREFERENCES || '').split(',').map(s => s.trim()).filter(Boolean);
                return {
                    id: d.DONOR_ID,
                    name: d.NAME,
                    email: d.EMAIL,
                    preferences: [...new Set(rawPrefs)],
                    locations: [],
                    totalDonated: d.TOTAL_DONATED || 0,
                    donations: d.TOTAL_COMMITMENTS || 0,
                    lastDonation: '—',
                    joinedAt: d.CREATED_AT ? new Date(d.CREATED_AT).toISOString().split('T')[0] : '—',
                    isMock: false,
                };
            });
        },

        getNgoDocuments: async (ngoId) => {
            const res = await _req(`/admin/ngos/${ngoId}/documents`, { headers: _authHeaders() });
            return res.data || [];
        },

        getDonorDonations: async (donorId) => {
            const res = await _req(`/admin/donors/${donorId}/donations`, { headers: _authHeaders() });
            return (res.data || []).map(d => ({
                id: d.DONATION_ID,
                need: d.NEED_TITLE,
                org: d.NGO_NAME,
                item: d.ITEM_DESCRIPTION || '',
                amount: d.AMOUNT || 0,
                status: d.STATUS,
                date: d.COMMITTED_AT ? new Date(d.COMMITTED_AT).toISOString().split('T')[0] : '—',
            }));
        },

    },

};

// ── Admin helpers ─────────────────────────────────────────────────────────────

function _mapNgo(n) {
    return {
        ngo_id: n.NGO_ID,
        email: n.EMAIL || '',
        orgName: n.NGO_NAME,
        city: n.CITY || '—',
        category: n.CATEGORIES || '—',
        phone: n.PHONE || '—',
        mission: n.DESCRIPTION || '',
        verified: n.STATUS === 'approved',
        status: n.STATUS,
        joinedAt: n.REGISTERED_AT ? new Date(n.REGISTERED_AT).toISOString().split('T')[0] : '—',
        verifiedAt: n.STATUS === 'approved' ? '—' : null,
        openNeeds: n.OPEN_NEEDS || 0,
        totalRaised: n.TOTAL_RAISED || 0,
        donorCount: n.DONOR_COUNT || 0,
        isMock: false,
    };
}

async function _adminFindNgo(emailOrId) {
    const res = await _req('/admin/ngos', { headers: _authHeaders() });
    const all = res.data || [];
    const found = all.find(n => n.EMAIL === emailOrId) ||
        all.find(n => String(n.NGO_ID) === String(emailOrId));
    if (!found) throw new Error('NGO not found.');
    return { ngo_id: found.NGO_ID, email: found.EMAIL };
}

// ── Expose globally ───────────────────────────────────────────────────────────
window.api = api;

// Auto-load categories on boot
(async () => { try { await api.loadCategories(); } catch (e) { } })();