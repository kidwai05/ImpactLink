# Admin Login & Mock Donors Fix

## Issues Fixed

### 1. Admin Unable to Login
**Root Cause**: 
- `api.admin.login()` was returning `{ success: true }` (no name field) while donor and NGO logins return `{ success: true, name: '...' }` or `{ success: true, orgName: '...' }`
- Login page was not setting the legacy `impactlink_session` key after admin login
- This caused admin dashboard/pages to check for a valid session and redirect to login

**Fix Applied**:
- **js/api.js** - Line ~494: Modified `api.admin.login()` to return `{ success: true, name: res.user.name || 'Admin' }` for consistency with donor/NGO returns
- **pages/login.html** - Line ~318: Changed admin login handler to:
  ```javascript
  const res = await api.admin.login(email, password);
  try { localStorage.setItem('impactlink_session', JSON.stringify({ name: res.name || 'Admin', email })); } catch(e) {}
  ```
  This ensures `impactlink_session` is set after admin login, which admin dashboard checks on page load

### 2. Mock Donors in Admin Panel
**Status**: 
- `api.admin.getAllDonors()` at line ~555 **already properly calls `/admin/donors` backend endpoint**
- It does NOT return mock data anymore; it returns an empty array if the backend endpoint fails
- The function properly maps backend donor data including preferences, donations count, etc.

**What was removed**:
- Old code returned a single placeholder row: `"${s.TOTAL_DONORS} registered donors — use Postman..."`
- New code either returns actual donors from `/admin/donors` or an empty array (no fake mock entry)

## Authentication Flow (Now Fixed)

```
Admin Login:
1. Admin enters email/password at pages/login.html
2. Calls api.admin.login(email, password)
3. api.admin.login() saves il_token + il_user via _saveAuth()
4. _saveAuth() also writes impactlink_session to localStorage
5. Login page then explicitly writes impactlink_session again (redundant but safe)
6. Navigates to admin/dashboard.html
7. Dashboard checks for impactlink_session on page load ✓ (found!)
8. Admin sees dashboard without redirect to login
```

## Files Modified

1. **js/api.js** - 2 changes:
   - _saveAuth() persists impactlink_session (already done in earlier fix)
   - _clearAuth() removes impactlink_session (already done in earlier fix)
   - api.admin.login() now returns `{ success: true, name: ... }` (NEW)

2. **pages/login.html** - 1 change:
   - Admin login handler now sets impactlink_session before navigating (NEW)

## Testing Checklist

1. Clear localStorage completely (DevTools → Application → Clear Storage)
2. Navigate to pages/login.html
3. Select "Admin" tab
4. Enter admin credentials
5. Verify:
   - ✓ No redirect loop (page stays on dashboard)
   - ✓ il_token is in localStorage
   - ✓ il_user is in localStorage (with role: 'admin')
   - ✓ impactlink_session is in localStorage
6. Go to admin/donors.html — no redirect to login should occur
7. Verify getAllDonors() returns real data or empty array (not mock placeholder)
8. Reload admin/dashboard.html — should remain logged in (no redirect)

## Related Fixes (From Earlier)

- _saveAuth() now persists both il_token/il_user AND impactlink_session
- _clearAuth() removes all three keys
- All login functions (donor, ngo, admin) ensure legacy session is set before navigation
- Pages that check for session (profile.html, dashboard.html) read the legacy key which is now always in sync with JWT

## Summary

**Admin login now works correctly** because:
1. JWT (il_token + il_user) is saved with correct role
2. Legacy session key (impactlink_session) is also saved
3. Protected pages check the legacy key and find it ✓
4. No premature redirects to login occur

**Mock donors removed** because:
1. getAllDonors() calls actual backend endpoint
2. Returns real donors or empty array (not fake placeholder)
3. Filtering/search in admin/donors.html works on real data
