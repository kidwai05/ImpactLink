# Bug Fixes Applied: Donor Registration & Profile Resolution

## Summary
Fixed critical bug preventing newly registered donor users from saving preferences. Root cause: newly registered donors didn't have DONORS records created during registration, causing JWT roleId to be null and all subsequent donor operations to fail.

## Files Modified

### 1. src/routes/auth.js
**Changes:**
- **POST /register/donor**: Converted to positional binds; added atomic DONORS record creation with rollback
  - Changed from named binds (`:name`, `:email`, `:hash`) to positional binds (`:1`, `:2`, `:3`)
  - Added `XYZ.` schema prefix to sequences: `users_seq` → `XYZ.users_seq`, `donors_seq` → `XYZ.donors_seq`
  - Ensured DONORS record is created immediately after USERS record
  - Added error handling with rollback if DONORS insertion fails

- **POST /register/ngo**: Similar conversion to positional binds and schema prefixes
  - Changed from named binds to positional binds
  - Added `XYZ.` prefix to `users_seq` and `ngos_seq`

**Result:** New donors now get both USERS and DONORS records created atomically during registration

### 2. src/routes/donor.js
**Helper Function Added:**
- **resolveDonorId(userId)**: New async helper that resolves donorId by querying DONORS table
  - Queries: `SELECT donor_id FROM XYZ.DONORS WHERE user_id = :1`
  - Returns null if no DONORS record exists
  - Replaces incorrect pattern: `const donorId = req.user.roleId`

**Routes Updated (9 total):**

1. **GET /profile**: 
   - Added donorId resolution via helper
   - Added donor profile validation (returns 400 if not found)
   - Converted to positional binds
   - Added schema prefixes to all tables
   - Added debug logging

2. **POST /locations**:
   - Added donorId resolution
   - Added donor profile validation
   - Converted to positional binds
   - Added `XYZ.` prefix and schema-qualified sequence

3. **DELETE /locations/:locationId**:
   - Added donorId resolution and validation
   - Converted to positional binds
   - Added schema prefixes

4. **POST /preferences** (THE KEY FIX):
   - Added donorId resolution
   - Added donor profile validation (returns 400 if not found)
   - Converted to positional binds
   - **This was blocking new donor preference saves**

5. **DELETE /preferences/:categoryId**:
   - Added donorId resolution
   - Converted to positional binds
   - Added schema prefixes

6. **GET /matches**:
   - Added donorId resolution
   - Converted all named binds to positional binds
   - Fixed parameter binding order
   - Maintained correlated subquery for LISTAGG (Oracle 11g compatibility)
   - Added schema prefixes to all tables/views

7. **POST /donations**:
   - Added donorId resolution
   - Converted to positional binds
   - Added `XYZ.` prefix to sequences and tables
   - Maintains notification creation for both donor and NGO

8. **GET /donations**:
   - Added donorId resolution
   - Converted to positional binds
   - Added schema prefix to view: `vw_donor_history` → `XYZ.vw_donor_history`

9. **PATCH /donations/:donationId**:
   - Added donorId resolution
   - Converted to positional binds
   - Added schema prefixes

### 3. src/routes/ngo.js
**Routes Updated (6 total):**

1. **POST /categories**:
   - Fixed schema prefix: `NGO_CATEGORIES` → `XYZ.NGO_CATEGORIES`
   - Converted to positional binds

2. **POST /documents**:
   - Added `XYZ.` prefix to sequence and table
   - Converted to positional binds

3. **GET /needs**:
   - Converted to positional binds

4. **POST /needs**:
   - Changed `needs_seq` → `XYZ.needs_seq`
   - Converted to positional binds
   - Fixed status check to use positional bind

5. **PUT /needs/:needId**:
   - Converted to positional binds (6 parameters for NVL clauses)

6. **DELETE /needs/:needId**:
   - Converted to positional binds

7. **GET /committed-donors**:
   - Added `XYZ.` prefix to view
   - Converted to positional binds

8. **GET /analytics**:
   - Added `XYZ.` prefix to view
   - Converted to positional binds

## Technical Details

### Bind Variable Strategy
- **Positional binds** (`:1`, `:2`, etc.) used throughout for Oracle 11g compatibility
- Positional binds avoid ORA-01745 errors that can occur with named binds
- Arrays passed to `db.execute()` for positional binds: `[value1, value2, ...]`

### Schema Prefix Consistency
- All table, view, and sequence references prefixed with `XYZ.`
- Format: `XYZ.TABLE_NAME`, `XYZ.sequence_name`, `XYZ.view_name`
- Ensures queries resolve in correct schema context

### Safety Checks
- All donor endpoints check if `resolveDonorId()` returns null
- Return 400 status with "Donor profile not found" message if not found
- Prevents silent failures or null reference errors

### Debug Logging Added
- `console.log("JWT:", req.user)` at start of each donor route
- `console.log("Resolved donor_id:", donorId)` after resolution
- Allows troubleshooting of token vs. database discrepancies

## Testing Recommendations

1. **New Donor Registration:**
   - Register new donor via POST /api/v1/auth/register/donor
   - Verify USERS record created
   - Verify DONORS record created (check database)
   - Verify JWT contains correct userId and roleId

2. **Preference Saving:**
   - Login as new donor
   - POST /api/v1/donors/preferences with valid category_id
   - Should succeed (201 status)
   - Check database: verify DONOR_PREFERENCES record created

3. **Profile Access:**
   - GET /api/v1/donors/profile should return complete profile
   - Should include preferences, locations, etc.

4. **Matching Engine:**
   - GET /api/v1/donors/matches should return matching NGOs
   - Filter by city/category should work correctly

5. **Donations:**
   - POST /api/v1/donors/donations should create commitment
   - Notifications should be created for donor and NGO

6. **Seed Users:**
   - Existing seed donor users should continue working
   - No regressions to established functionality

## Files NOT Modified (As per requirements)
- Database schema (xyz1.sql) - no changes needed
- Middleware authentication logic
- Response structures
- Business logic (matching algorithms, etc.)

## Known Limitations
- None identified; fix is minimal and focused on the root cause
