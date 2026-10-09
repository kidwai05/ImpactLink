-- Migration: add amount column to DONATIONS table
-- Run this once against your Oracle DB before deploying the updated backend.

ALTER TABLE XYZ.DONATIONS ADD (amount NUMBER(12,2) DEFAULT 0 NOT NULL);

-- Recreate the donor history view to include amount
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
FROM XYZ.DONATIONS don
JOIN XYZ.DONORS    d   ON don.donor_id  = d.donor_id
JOIN XYZ.USERS     u   ON d.user_id     = u.user_id
JOIN XYZ.NEEDS     nd  ON don.need_id   = nd.need_id
JOIN XYZ.NGOS      n   ON nd.ngo_id     = n.ngo_id
ORDER BY don.committed_at DESC;
