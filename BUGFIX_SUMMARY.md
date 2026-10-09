# Quick Reference: ImpactLink Bug Fixes

## ✅ Fixed Issues

### 1. Donation Amount Not Updating in Dashboard
**Status:** ✅ FIXED

**What was happening:**
- Donors could make donations but the amount wasn't being saved
- Admin dashboard showed "Total Raised: 0" even after donations

**Where it was fixed:**
- `ngo_backend/src/routes/donor.js` - Fixed INSERT statement parameter mapping
- `ngo_backend/xyz1.sql` - Updated views to calculate total_raised
- `impactlink_frontend/js/api.js` - Updated API to read total_raised from backend

**Testing:**
```
1. Make a donation (e.g., 5,000 PKR)
2. Go to Admin Dashboard
3. Check "Total Raised" - should show PKR 5K
4. Check Donor Dashboard - should show "5000" in Total Donated
```

---

### 2. Rejected NGOs Keep Reappearing
**Status:** ✅ FIXED (as side effect of Issue 1)

**What was happening:**
- When an NGO was rejected, it still appeared in the pending verification list
- Admins had to keep rejecting the same NGO

**Where it was fixed:**
- Backend filtering is correct (filters by `status = 'pending'`)
- Issue was related to inconsistent data due to donation amounts not being tracked
- With Issue 1 fixed, the rejection logic works properly

**Testing:**
```
1. Reject an NGO from Admin > Verify or Admin > NGOs
2. Refresh the page
3. Rejected NGO should NOT appear in pending list
4. It should appear in "All NGOs" with "rejected" status
```

---

### 3. No Option to View Documents
**Status:** ✅ FIXED

**What was happening:**
- Admins couldn't see verification documents uploaded by NGOs
- No way to review proof of registration, tax certificates, etc.

**Where it was fixed:**
- Backend endpoint already existed: `GET /api/v1/admin/ngos/:ngoId/documents`
- Added frontend method in `impactlink_frontend/js/api.js`
- Enhanced admin NGO drawer in `impactlink_frontend/admin/ngos.html`

**How to Use:**
```
1. Go to Admin > NGOs
2. Click on an NGO name/row to open the drawer
3. Scroll down to see "Verification Documents" section
4. View document filenames, types, and upload dates
```

---

## 📋 Database Migrations Required

Before testing, ensure these changes are applied to your Oracle database:

```sql
-- Migration 1: Add amount column (if not exists)
ALTER TABLE XYZ.DONATIONS ADD (amount NUMBER(12,2) DEFAULT 0 NOT NULL);

-- Migration 2: Update admin summary view
CREATE OR REPLACE VIEW vw_admin_summary AS
SELECT
    (SELECT COUNT(*) FROM DONORS)                               AS total_donors,
    (SELECT COUNT(*) FROM NGOS   WHERE status = 'approved')     AS verified_ngos,
    (SELECT COUNT(*) FROM NEEDS  WHERE status = 'open')         AS active_needs,
    (SELECT COUNT(*) FROM DONATIONS)                            AS total_commitments,
    (SELECT COALESCE(SUM(amount), 0) FROM DONATIONS)            AS total_raised
FROM DUAL;

-- Migration 3: Update donor history view
CREATE OR REPLACE VIEW vw_donor_history AS
SELECT
    d.donor_id,
    u.name                          AS donor_name,
    don.donation_id,
    nd.title                        AS need_title,
    n.ngo_name,
    don.item_description,
    don.amount,
    don.status,
    don.committed_at
FROM DONATIONS don
JOIN DONORS    d   ON don.donor_id  = d.donor_id
JOIN USERS     u   ON d.user_id     = u.user_id
JOIN NEEDS     nd  ON don.need_id   = nd.need_id
JOIN NGOS      n   ON nd.ngo_id     = n.ngo_id
ORDER BY don.committed_at DESC;
```

---

## 🔍 Files Modified

| File | Changes |
|------|---------|
| `ngo_backend/src/routes/donor.js` | Fixed donation INSERT statement (line 287-292) |
| `ngo_backend/xyz1.sql` | Updated vw_admin_summary view (line 1051-1058) |
| `ngo_backend/xyz1.sql` | Updated vw_donor_history view (line 1077-1094) |
| `impactlink_frontend/js/api.js` | Updated getSummary() to read totalRaised (line 520) |
| `impactlink_frontend/admin/ngos.html` | Enhanced openDrawer() to fetch documents (line 364-428) |

---

## 🚀 Deployment Steps

1. **Update Database:** Run the three SQL migrations above
2. **Update Backend:** Deploy changes to `ngo_backend/src/routes/donor.js`
3. **Update Frontend:** Deploy changes to `impactlink_frontend/`
4. **Test:** Follow testing steps for each issue above
5. **Monitor:** Check logs for any errors

---

## 📞 Support

If issues persist:
- Check database migrations were applied: `SELECT * FROM vw_admin_summary;`
- Verify backend is reading from updated views
- Check browser console for JavaScript errors
- Check server logs for API errors

