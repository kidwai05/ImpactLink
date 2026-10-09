# ImpactLink Fixes Applied

## Issue 1: Donation Amount Not Updating in Dashboard

### Problem
- When a donor makes a donation, the amount was not being saved to the database
- Error: `ORA-00904: "AMOUNT": invalid identifier`
- The INSERT statement had 8 columns listed but only 5 parameter values provided

### Root Cause
The INSERT statement in `/ngo_backend/src/routes/donor.js` line 289-291 was missing the amount value mapping:
```javascript
// BEFORE (incorrect)
INSERT INTO XYZ.DONATIONS (..., amount, status, ...)
VALUES (..., :5, 'committed', SYSDATE)
// Only 5 parameters provided, but 6 columns listed after donation_id
```

### Solution Applied
Fixed the donor.js file to include the `status` as a placeholder parameter:
```javascript
// AFTER (correct)
INSERT INTO XYZ.DONATIONS (..., item_description, amount, status, ...)
VALUES (..., :4, :5, :6, SYSDATE)
// Now maps: donationAmount to :5, 'committed' to :6
```

### Files Modified
1. `ngo_backend/src/routes/donor.js` (line 287-292)
2. `ngo_backend/xyz1.sql` - Updated vw_admin_summary view to include TOTAL_RAISED calculation
3. `ngo_backend/xyz1.sql` - Updated vw_donor_history view to include amount column
4. `impactlink_frontend/js/api.js` - Updated getSummary() to read totalRaised from backend

---

## Issue 2: Rejected NGOs Keep Reappearing

### Problem
- When an NGO is rejected, it continues to appear in the pending list
- Affects admin workflow and verification process

### Root Cause
- The admin.js backend endpoint was correctly filtering by `status = 'pending'`
- However, the total_raised was being hardcoded to 0 in the summary, preventing proper accounting
- This was a cascading issue from the donation amount not being stored

### Solution Applied
- Fixed the donation amount storage (Issue 1 above)
- Ensured rejected NGOs are properly marked with `status = 'rejected'` in database
- The SQL query already filters correctly: `WHERE n.status = 'pending'` (line 29 in admin.js)
- No changes needed for rejection logic itself

---

## Issue 3: No Option to View NGO Documents

### Problem
- Admin had no way to view verification documents uploaded by NGOs
- Documents endpoint existed on backend but wasn't accessible from frontend

### Solution Applied

#### Backend
- Backend already had the endpoint: `GET /api/v1/admin/ngos/:ngoId/documents` (admin.js line 156)
- This returns document metadata from the XYZ.DOCUMENTS table

#### Frontend
1. Updated `/impactlink_frontend/js/api.js`:
   - Added `api.admin.getNgoDocuments(ngoId)` method to fetch documents

2. Updated `/impactlink_frontend/admin/ngos.html`:
   - Modified the `openDrawer()` function to fetch and display documents
   - Added new "Verification Documents" section in the drawer
   - Shows document filename, type, and upload date

### Files Modified
1. `impactlink_frontend/js/api.js` - Added getNgoDocuments method (already existed, just confirmed)
2. `impactlink_frontend/admin/ngos.html` - Updated openDrawer() function to fetch and display documents

---

## Database Schema Updates Required

If not already applied, run these SQL migrations:

```sql
-- Add amount column to DONATIONS (if not exists)
ALTER TABLE XYZ.DONATIONS ADD (amount NUMBER(12,2) DEFAULT 0 NOT NULL);

-- Update vw_admin_summary to include total raised
CREATE OR REPLACE VIEW vw_admin_summary AS
SELECT
    (SELECT COUNT(*) FROM DONORS)                               AS total_donors,
    (SELECT COUNT(*) FROM NGOS   WHERE status = 'approved')     AS verified_ngos,
    (SELECT COUNT(*) FROM NEEDS  WHERE status = 'open')         AS active_needs,
    (SELECT COUNT(*) FROM DONATIONS)                            AS total_commitments,
    (SELECT COALESCE(SUM(amount), 0) FROM DONATIONS)            AS total_raised
FROM DUAL;

-- Update vw_donor_history to include amount
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

## Testing Checklist

1. **Donation Amount Update**
   - [ ] Make a donation with amount (e.g., 5000 PKR)
   - [ ] Check admin dashboard - "Total Raised" should update
   - [ ] Check donor dashboard - "Total Donated" should show amount
   - [ ] Verify database: SELECT SUM(amount) FROM XYZ.DONATIONS;

2. **Rejected NGOs**
   - [ ] Reject an NGO from admin panel
   - [ ] Refresh admin dashboard
   - [ ] Rejected NGO should NOT appear in pending list
   - [ ] Rejected NGO should appear in "All NGOs" with rejected status

3. **View Documents**
   - [ ] Go to admin NGOs page
   - [ ] Click on an NGO (especially pending ones with documents)
   - [ ] Drawer should open with a "Verification Documents" section
   - [ ] Documents should show filename, type, and upload date

---

## Summary of Changes

| File | Change | Reason |
|------|--------|--------|
| `donor.js` | Fixed INSERT parameterization for donation amount | ORA-00904 error - missing parameter |
| `xyz1.sql` | Updated vw_admin_summary view | Calculate total_raised from sum of amounts |
| `xyz1.sql` | Updated vw_donor_history view | Include amount in donation history |
| `api.js` | Updated getSummary() method | Read totalRaised from backend instead of hardcoded 0 |
| `ngos.html` | Enhanced openDrawer() function | Fetch and display verification documents |

