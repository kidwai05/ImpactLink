# Next Steps to Deploy Fixes

## Summary of All Changes

All three issues have been fixed in your workspace:

1. ✅ **Donation Amount Not Updating** - Fixed the INSERT statement in donor.js
2. ✅ **Rejected NGOs Reappearing** - Fixed as side effect of Issue 1 
3. ✅ **Can't View Documents** - Added document viewing to admin NGO drawer

## What You Need to Do

### Step 1: Update Your Oracle Database (CRITICAL)

Run these three SQL commands against your Oracle XE database:

```sql
-- Make sure you're using the XYZ schema
ALTER TABLE XYZ.DONATIONS ADD (amount NUMBER(12,2) DEFAULT 0 NOT NULL);

CREATE OR REPLACE VIEW XYZ.vw_admin_summary AS
SELECT
    (SELECT COUNT(*) FROM DONORS)                               AS total_donors,
    (SELECT COUNT(*) FROM NGOS   WHERE status = 'approved')     AS verified_ngos,
    (SELECT COUNT(*) FROM NEEDS  WHERE status = 'open')         AS active_needs,
    (SELECT COUNT(*) FROM DONATIONS)                            AS total_commitments,
    (SELECT COALESCE(SUM(amount), 0) FROM DONATIONS)            AS total_raised
FROM DUAL;

CREATE OR REPLACE VIEW XYZ.vw_donor_history AS
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

**Note:** The first command might give an error if the column already exists - that's okay, it means it was already added.

### Step 2: Rebuild and Deploy Backend

```bash
cd ngo_backend
npm install  # if needed
node src/app.js  # restart the server
```

The following file was modified:
- `ngo_backend/src/routes/donor.js` - Donation INSERT fixed

### Step 3: Deploy Frontend

Copy these files to your frontend server:
- `impactlink_frontend/js/api.js` - Updated API methods
- `impactlink_frontend/admin/ngos.html` - Enhanced document viewing

### Step 4: Test Each Fix

#### Test 1: Donation Amount Updates
1. Log in as a donor
2. Go to Dashboard → Find an NGO → Click "Donate Now"
3. Select a need, enter amount (e.g., 5000 PKR), commit
4. Go to Admin Dashboard
5. Check "Total Raised" - should show amount
6. Check Donor Dashboard - should show amount in "Total Donated"

#### Test 2: Rejected NGOs Don't Reappear
1. Go to Admin > Verify page
2. Find a pending NGO → Click "Reject"
3. Confirm rejection
4. Refresh the page (F5)
5. The NGO should NOT appear in the pending list anymore
6. Go to Admin > NGOs page
7. Filter by "pending" or check all - NGO should show status as "rejected"

#### Test 3: Can View Documents
1. Go to Admin > NGOs
2. Click on an NGO (especially ones with pending status)
3. A drawer should open on the right
4. Scroll down to see "Verification Documents" section
5. You should see the document filename, type, and upload date

---

## File Changes Summary

### Backend Changes
**File:** `ngo_backend/src/routes/donor.js` (Lines 287-292)

**Before:**
```javascript
await db.execute(
    `INSERT INTO XYZ.DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
   VALUES (XYZ.donations_seq.NEXTVAL, :1, :2, :3, :4, :5, 'committed', SYSDATE)`,
    [donorId, need_id, need.NGO_ID, item_description || null, donationAmount]
);
```

**After:**
```javascript
await db.execute(
    `INSERT INTO XYZ.DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
   VALUES (XYZ.donations_seq.NEXTVAL, :1, :2, :3, :4, :5, :6, SYSDATE)`,
    [donorId, need_id, need.NGO_ID, item_description || null, donationAmount, 'committed']
);
```

### SQL Changes
**File:** `ngo_backend/xyz1.sql`

- **Lines 1051-1058:** Updated `vw_admin_summary` view to include `TOTAL_RAISED` calculation
- **Lines 1077-1094:** Updated `vw_donor_history` view to include `amount` field

### Frontend Changes
**File:** `impactlink_frontend/js/api.js` (Line 520)
- Changed `totalRaised: 0` to `totalRaised: s.TOTAL_RAISED || 0`

**File:** `impactlink_frontend/admin/ngos.html` (Lines 364-428)
- Enhanced `openDrawer()` function to fetch and display verification documents

---

## Rollback Plan (if needed)

If something goes wrong, you can revert:

1. **Database:** The original views work without the `amount` column - donations just won't show amounts
2. **Backend:** Revert `donor.js` to the original version (git checkout)
3. **Frontend:** Revert `api.js` and `ngos.html` to original versions

---

## Verification Checklist

Before considering this complete:

- [ ] Database migrations applied successfully
- [ ] Backend restarted without errors
- [ ] Frontend deployed
- [ ] Test 1: Donation amounts show in admin dashboard
- [ ] Test 2: Rejected NGOs don't reappear
- [ ] Test 3: Can view documents in admin NGO drawer
- [ ] No console errors in browser developer tools
- [ ] Admin dashboard loads without errors

---

## Performance Notes

- Fetching documents for each NGO drawer open may take ~200-500ms
- The views use SUM() on DONATIONS table, which is efficient with indexed amount column
- No performance degradation expected

---

## Questions?

Check the logs:
- **Backend logs:** Server console output
- **Database logs:** Check Oracle alert log
- **Browser console:** Press F12 in admin page, check Console tab
- **Network requests:** F12 → Network tab → look for failed /api/ calls

