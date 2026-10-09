SET DEFINE OFF
SET ESCAPE OFF

-- ============================================================
--  ImpactLink Database Schema  |  Oracle XE
--  Schema owner: XYZ
--
--  Execution order:
--    1. TABLE definitions        (parents before children)
--    2. VIEWS                    (depend on final table structure)
--    3. TRIGGER                  (depends on NGOS + NOTIFICATIONS)
--    4. STORED PROCEDURES        (depend on all tables)
--    5. GRANTS                   (to application user: ABC)
--    6. SEED DATA                (clears first; safe to re-run)
--    7. VERIFICATION QUERIES
-- ============================================================


-- ============================================================
--  SECTION 1: TABLE DEFINITIONS
-- ============================================================

-- 1a. USERS — single generalised entity for all roles
CREATE TABLE USERS (
    user_id       NUMBER          PRIMARY KEY,
    name          VARCHAR2(100)   NOT NULL,
    email         VARCHAR2(100)   UNIQUE NOT NULL,
    password_hash VARCHAR2(255)   NOT NULL,
    user_role     VARCHAR2(10)    NOT NULL
                  CHECK (user_role IN ('donor', 'ngo', 'admin')),
    created_at    DATE            DEFAULT SYSDATE
);
CREATE SEQUENCE users_seq      START WITH 1 INCREMENT BY 1;

-- 1b. DONORS — specialisation of USERS (1:1)
CREATE TABLE DONORS (
    donor_id  NUMBER  PRIMARY KEY,
    user_id   NUMBER  NOT NULL UNIQUE REFERENCES USERS(user_id)
);
CREATE SEQUENCE donors_seq     START WITH 1 INCREMENT BY 1;

-- 1c. NGOS — specialisation of USERS (1:1)
CREATE TABLE NGOS (
    ngo_id        NUMBER          PRIMARY KEY,
    user_id       NUMBER          NOT NULL UNIQUE REFERENCES USERS(user_id),
    ngo_name      VARCHAR2(150)   NOT NULL,
    city          VARCHAR2(100),
    description   VARCHAR2(500),
    phone         VARCHAR2(30),
    status        VARCHAR2(10)    DEFAULT 'pending'
                  CHECK (status IN ('pending', 'approved', 'rejected')),
    registered_at DATE            DEFAULT SYSDATE
);
CREATE SEQUENCE ngos_seq       START WITH 1 INCREMENT BY 1;

-- 1d. CATEGORIES — lookup table for cause types
CREATE TABLE CATEGORIES (
    category_id   NUMBER          PRIMARY KEY,
    name          VARCHAR2(100)   NOT NULL UNIQUE,
    description   VARCHAR2(300)
);
CREATE SEQUENCE categories_seq START WITH 1 INCREMENT BY 1;

-- 1e. NGO_CATEGORIES — M:N bridge: NGOS <-> CATEGORIES
CREATE TABLE NGO_CATEGORIES (
    ngo_id        NUMBER  NOT NULL REFERENCES NGOS(ngo_id),
    category_id   NUMBER  NOT NULL REFERENCES CATEGORIES(category_id),
    CONSTRAINT pk_ngo_categories PRIMARY KEY (ngo_id, category_id)
);

-- 1f. DONOR_PREFERENCES — M:N bridge: DONORS <-> CATEGORIES
CREATE TABLE DONOR_PREFERENCES (
    donor_id      NUMBER  NOT NULL REFERENCES DONORS(donor_id),
    category_id   NUMBER  NOT NULL REFERENCES CATEGORIES(category_id),
    CONSTRAINT pk_donor_preferences PRIMARY KEY (donor_id, category_id)
);

-- 1g. DONOR_LOCATIONS — 1:N with DONORS (multiple city/province/country entries)
CREATE TABLE DONOR_LOCATIONS (
    location_id   NUMBER        PRIMARY KEY,
    donor_id      NUMBER        NOT NULL REFERENCES DONORS(donor_id),
    city          VARCHAR2(100),
    province      VARCHAR2(100),
    country       VARCHAR2(100),
    postal_code   VARCHAR2(20)
);
CREATE SEQUENCE locations_seq  START WITH 1 INCREMENT BY 1;

-- 1h. DOCUMENTS — verification documents submitted by NGOs
CREATE TABLE DOCUMENTS (
    doc_id        NUMBER          PRIMARY KEY,
    ngo_id        NUMBER          NOT NULL REFERENCES NGOS(ngo_id),
    file_path     VARCHAR2(500)   NOT NULL,
    doc_type      VARCHAR2(100),
    uploaded_at   DATE            DEFAULT SYSDATE
);
CREATE SEQUENCE documents_seq  START WITH 1 INCREMENT BY 1;

-- 1i. VERIFICATION_LOG — audit trail of every admin approval/rejection
CREATE TABLE VERIFICATION_LOG (
    log_id        NUMBER          PRIMARY KEY,
    ngo_id        NUMBER          NOT NULL REFERENCES NGOS(ngo_id),
    admin_id      NUMBER          NOT NULL REFERENCES USERS(user_id),
    action        VARCHAR2(10)    NOT NULL
                  CHECK (action IN ('approved', 'rejected')),
    remarks       VARCHAR2(300),
    actioned_at   DATE            DEFAULT SYSDATE
);
CREATE SEQUENCE verif_log_seq  START WITH 1 INCREMENT BY 1;

-- 1j. NEEDS — posted by NGOs; the unit donors commit to
CREATE TABLE NEEDS (
    need_id         NUMBER          PRIMARY KEY,
    ngo_id          NUMBER          NOT NULL REFERENCES NGOS(ngo_id),
    category_id     NUMBER          NOT NULL REFERENCES CATEGORIES(category_id),
    title           VARCHAR2(200)   NOT NULL,
    description     VARCHAR2(1000),
    urgency_level   VARCHAR2(10)    DEFAULT 'medium'
                    CHECK (urgency_level IN ('low', 'medium', 'high')),
    target_quantity NUMBER          DEFAULT 1,
    status          VARCHAR2(10)    DEFAULT 'open'
                    CHECK (status IN ('open', 'fulfilled', 'closed')),
    created_at      DATE            DEFAULT SYSDATE
);
CREATE SEQUENCE needs_seq      START WITH 1 INCREMENT BY 1;

-- 1k. DONATIONS — commitment from a donor to a specific need
--     ngo_id denormalised per SRS REQ-DON-01 (derivable via need_id -> NEEDS -> ngo_id).
--     amount records monetary contributions where applicable.
CREATE TABLE DONATIONS (
    donation_id       NUMBER          PRIMARY KEY,
    donor_id          NUMBER          NOT NULL REFERENCES DONORS(donor_id),
    need_id           NUMBER          NOT NULL REFERENCES NEEDS(need_id),
    ngo_id            NUMBER          REFERENCES NGOS(ngo_id),
    item_description  VARCHAR2(300),
    amount            NUMBER(12,2)    DEFAULT 0 NOT NULL,
    status            VARCHAR2(15)    DEFAULT 'committed'
                      CHECK (status IN ('committed', 'completed', 'cancelled')),
    committed_at      DATE            DEFAULT SYSDATE
);
CREATE SEQUENCE donations_seq  START WITH 1 INCREMENT BY 1;

-- 1l. NOTIFICATIONS — in-app messages for donors and NGOs
CREATE TABLE NOTIFICATIONS (
    notif_id    NUMBER          PRIMARY KEY,
    user_id     NUMBER          NOT NULL REFERENCES USERS(user_id),
    notif_type  VARCHAR2(50)    NOT NULL,
    message     VARCHAR2(500)   NOT NULL,
    is_read     NUMBER(1)       DEFAULT 0 CHECK (is_read IN (0, 1)),
    created_at  DATE            DEFAULT SYSDATE
);
CREATE SEQUENCE notif_seq      START WITH 1 INCREMENT BY 1;


-- ============================================================
--  SECTION 2: VIEWS
-- ============================================================

-- View 1: System-wide summary for the Admin dashboard (REQ-ANLYT-01)
CREATE OR REPLACE VIEW vw_admin_summary AS
SELECT
    (SELECT COUNT(*) FROM DONORS)                            AS total_donors,
    (SELECT COUNT(*) FROM NGOS   WHERE status = 'approved') AS verified_ngos,
    (SELECT COUNT(*) FROM NEEDS  WHERE status = 'open')     AS active_needs,
    (SELECT COUNT(*) FROM DONATIONS)                        AS total_commitments,
    (SELECT NVL(SUM(amount), 0) FROM DONATIONS)             AS total_raised
FROM DUAL;

-- View 2: Donation commitments grouped by cause category (REQ-ANLYT-04)
CREATE OR REPLACE VIEW vw_donations_by_category AS
SELECT
    c.name                 AS category,
    COUNT(don.donation_id) AS total_commitments
FROM DONATIONS don
JOIN NEEDS      nd ON don.need_id    = nd.need_id
JOIN CATEGORIES c  ON nd.category_id = c.category_id
GROUP BY c.name;

-- View 3: Open needs with commitment counts, per NGO (REQ-ANLYT-03)
CREATE OR REPLACE VIEW vw_ngo_need_commitments AS
SELECT
    n.ngo_id,
    n.ngo_name,
    nd.need_id,
    nd.title            AS need_title,
    nd.urgency_level,
    COUNT(don.donation_id) AS commitment_count
FROM NGOS n
JOIN NEEDS      nd  ON n.ngo_id   = nd.ngo_id
LEFT JOIN DONATIONS don ON nd.need_id = don.need_id
WHERE nd.status = 'open'
GROUP BY n.ngo_id, n.ngo_name, nd.need_id, nd.title, nd.urgency_level;

-- View 4: Full donation history for a donor (REQ-DON-04)
CREATE OR REPLACE VIEW vw_donor_history AS
SELECT
    d.donor_id,
    u.name              AS donor_name,
    don.donation_id,
    nd.title            AS need_title,
    n.ngo_name,
    don.item_description,
    don.amount,
    don.status,
    don.committed_at
FROM DONATIONS don
JOIN DONORS    d   ON don.donor_id = d.donor_id
JOIN USERS     u   ON d.user_id    = u.user_id
JOIN NEEDS     nd  ON don.need_id  = nd.need_id
JOIN NGOS      n   ON nd.ngo_id    = n.ngo_id
ORDER BY don.committed_at DESC;

-- View 5: Donors who committed to a specific NGO's needs (REQ-DON-05)
CREATE OR REPLACE VIEW vw_ngo_committed_donors AS
SELECT
    n.ngo_id,
    n.ngo_name,
    nd.need_id,
    nd.title            AS need_title,
    d.donor_id,
    u.name              AS donor_name,
    u.email             AS donor_email,
    don.item_description,
    don.amount,
    don.status          AS commitment_status,
    don.committed_at
FROM DONATIONS don
JOIN DONORS    d   ON don.donor_id = d.donor_id
JOIN USERS     u   ON d.user_id    = u.user_id
JOIN NEEDS     nd  ON don.need_id  = nd.need_id
JOIN NGOS      n   ON nd.ngo_id    = n.ngo_id
ORDER BY don.committed_at DESC;


-- ============================================================
--  SECTION 3: TRIGGER
-- ============================================================

-- Fires after NGOS.status is updated to 'approved' or 'rejected'.
-- Automatically inserts a notification for the NGO's contact user.
CREATE OR REPLACE TRIGGER trg_ngo_status_change
AFTER UPDATE OF status ON NGOS
FOR EACH ROW
WHEN (NEW.status IN ('approved', 'rejected'))
DECLARE
    v_message VARCHAR2(300);
BEGIN
    v_message := CASE :NEW.status
        WHEN 'approved' THEN
            'Congratulations! Your NGO registration has been approved. You may now post needs.'
        WHEN 'rejected' THEN
            'Your NGO registration has been rejected. Please review and re-register with updated documentation.'
    END;

    INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
    VALUES (notif_seq.NEXTVAL, :NEW.user_id, 'verification', v_message, 0, SYSDATE);
END;
/


-- ============================================================
--  SECTION 4: STORED PROCEDURES
-- ============================================================

-- 4.1  USER AND ROLE REGISTRATION
-- -------------------------------------------------------

-- Creates a base USERS record. Role-specific record must be created after.
CREATE OR REPLACE PROCEDURE register_user (
    p_name          IN VARCHAR2,
    p_email         IN VARCHAR2,
    p_password_hash IN VARCHAR2,
    p_role          IN VARCHAR2
) AS
BEGIN
    INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
    VALUES (users_seq.NEXTVAL, p_name, p_email, p_password_hash, p_role, SYSDATE);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('User registered: ' || p_name);
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('Error: Email already exists.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/

-- Creates the DONORS specialisation record.
CREATE OR REPLACE PROCEDURE register_donor (
    p_user_id IN NUMBER
) AS
BEGIN
    INSERT INTO DONORS (donor_id, user_id)
    VALUES (donors_seq.NEXTVAL, p_user_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Donor profile created for user_id: ' || p_user_id);
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('Error: Donor profile already exists for this user.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/

-- Creates the NGOS specialisation record. Status defaults to 'pending'.
CREATE OR REPLACE PROCEDURE register_ngo (
    p_user_id     IN NUMBER,
    p_ngo_name    IN VARCHAR2,
    p_city        IN VARCHAR2,
    p_description IN VARCHAR2
) AS
BEGIN
    INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, status)
    VALUES (ngos_seq.NEXTVAL, p_user_id, p_ngo_name, p_city, p_description, 'pending');
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('NGO profile created: ' || p_ngo_name);
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('Error: NGO profile already exists for this user.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/


-- 4.2  LOCATION MANAGEMENT
-- -------------------------------------------------------

-- Adds one location entry for a donor (call multiple times for multiple cities).
CREATE OR REPLACE PROCEDURE add_donor_location (
    p_donor_id    IN NUMBER,
    p_city        IN VARCHAR2,
    p_province    IN VARCHAR2,
    p_country     IN VARCHAR2,
    p_postal_code IN VARCHAR2
) AS
BEGIN
    INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
    VALUES (locations_seq.NEXTVAL, p_donor_id, p_city, p_province, p_country, p_postal_code);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Location added for donor_id: ' || p_donor_id);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/

-- Removes a single donor location by primary key.
CREATE OR REPLACE PROCEDURE remove_donor_location (
    p_location_id IN NUMBER
) AS
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM DONOR_LOCATIONS WHERE location_id = p_location_id;
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Error: Location not found.');
        RETURN;
    END IF;
    DELETE FROM DONOR_LOCATIONS WHERE location_id = p_location_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Location removed: ' || p_location_id);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/


-- 4.3  CATEGORY AND PREFERENCE MANAGEMENT
-- -------------------------------------------------------

-- Inserts a new cause category (admin-only at application level).
CREATE OR REPLACE PROCEDURE add_category (
    p_name        IN VARCHAR2,
    p_description IN VARCHAR2
) AS
BEGIN
    INSERT INTO CATEGORIES (category_id, name, description)
    VALUES (categories_seq.NEXTVAL, p_name, p_description);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Category added: ' || p_name);
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('Error: Category already exists.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/

-- Links one category preference to a donor.
CREATE OR REPLACE PROCEDURE set_donor_preference (
    p_donor_id    IN NUMBER,
    p_category_id IN NUMBER
) AS
BEGIN
    INSERT INTO DONOR_PREFERENCES (donor_id, category_id)
    VALUES (p_donor_id, p_category_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Preference set for donor_id: ' || p_donor_id);
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('Preference already exists for this donor and category.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/

-- Assigns one cause category to an NGO.
CREATE OR REPLACE PROCEDURE set_ngo_category (
    p_ngo_id      IN NUMBER,
    p_category_id IN NUMBER
) AS
BEGIN
    INSERT INTO NGO_CATEGORIES (ngo_id, category_id)
    VALUES (p_ngo_id, p_category_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Category assigned to ngo_id: ' || p_ngo_id);
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('Category already assigned to this NGO.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/


-- 4.4  DOCUMENT AND VERIFICATION MANAGEMENT
-- -------------------------------------------------------

-- Stores a reference to a document uploaded by an NGO.
CREATE OR REPLACE PROCEDURE upload_document (
    p_ngo_id    IN NUMBER,
    p_file_path IN VARCHAR2,
    p_doc_type  IN VARCHAR2
) AS
BEGIN
    INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
    VALUES (documents_seq.NEXTVAL, p_ngo_id, p_file_path, p_doc_type, SYSDATE);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Document uploaded for ngo_id: ' || p_ngo_id);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/

-- Admin approves or rejects an NGO.
-- Updates NGOS.status (fires trg_ngo_status_change) and writes an audit row.
CREATE OR REPLACE PROCEDURE verify_ngo (
    p_ngo_id   IN NUMBER,
    p_admin_id IN NUMBER,
    p_action   IN VARCHAR2,
    p_remarks  IN VARCHAR2
) AS
    v_count NUMBER;
BEGIN
    IF p_action NOT IN ('approved', 'rejected') THEN
        DBMS_OUTPUT.PUT_LINE('Error: Action must be approved or rejected.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_count FROM NGOS WHERE ngo_id = p_ngo_id;
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Error: NGO not found.');
        RETURN;
    END IF;

    UPDATE NGOS SET status = p_action WHERE ngo_id = p_ngo_id;

    INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
    VALUES (verif_log_seq.NEXTVAL, p_ngo_id, p_admin_id, p_action, p_remarks, SYSDATE);

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('NGO ' || p_ngo_id || ' has been ' || p_action || '.');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/


-- 4.5  NEEDS MANAGEMENT
-- -------------------------------------------------------

-- NGO posts a new need. Status defaults to 'open'.
CREATE OR REPLACE PROCEDURE post_need (
    p_ngo_id        IN NUMBER,
    p_category_id   IN NUMBER,
    p_title         IN VARCHAR2,
    p_description   IN VARCHAR2,
    p_urgency_level IN VARCHAR2
) AS
BEGIN
    INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, status, created_at)
    VALUES (needs_seq.NEXTVAL, p_ngo_id, p_category_id, p_title, p_description, p_urgency_level, 'open', SYSDATE);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Need posted: ' || p_title);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/

-- NGO closes or marks a need as fulfilled.
CREATE OR REPLACE PROCEDURE update_need_status (
    p_need_id IN NUMBER,
    p_status  IN VARCHAR2
) AS
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM NEEDS WHERE need_id = p_need_id;
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Error: Need not found.');
        RETURN;
    END IF;
    UPDATE NEEDS SET status = p_status WHERE need_id = p_need_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Need ' || p_need_id || ' updated to: ' || p_status);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/


-- 4.6  MATCHING ENGINE  (SRS REQ-MATCH-01)
-- -------------------------------------------------------
-- Scores each approved NGO against the donor's category
-- preferences and saved locations.
--
-- Formula (components normalised to 100; max score = 100):
--   Location  (weight 0.4): 100 if any donor city == NGO city, else 0
--   Cause     (weight 0.4): (matched categories / total preferences) * 100
--   Urgency   (weight 0.2): best open-need urgency: high=100, medium=40, low=10
CREATE OR REPLACE PROCEDURE match_donor_to_ngos (
    p_donor_id IN NUMBER
) AS
    v_count      NUMBER;
    v_pref_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM DONORS WHERE donor_id = p_donor_id;
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Error: Donor not found.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_pref_count
    FROM DONOR_PREFERENCES WHERE donor_id = p_donor_id;

    IF v_pref_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('No preferences set. Please configure cause preferences first.');
        RETURN;
    END IF;

    FOR rec IN (
        SELECT
            n.ngo_id,
            n.ngo_name,
            n.city,
            MAX(CASE WHEN dl.city = n.city THEN 100 ELSE 0 END) * 0.4
            + (COUNT(DISTINCT CASE WHEN dp.category_id = nc.category_id
                                   THEN dp.category_id END) / v_pref_count * 100) * 0.4
            + MAX(CASE nd.urgency_level
                    WHEN 'high'   THEN 100
                    WHEN 'medium' THEN 40
                    WHEN 'low'    THEN 10
                    ELSE 0
                  END) * 0.2  AS match_score
        FROM NGOS n
        JOIN NGO_CATEGORIES    nc ON n.ngo_id       = nc.ngo_id
        JOIN DONOR_PREFERENCES dp ON dp.category_id = nc.category_id
                                 AND dp.donor_id    = p_donor_id
        JOIN NEEDS             nd ON nd.ngo_id = n.ngo_id AND nd.status = 'open'
        LEFT JOIN DONOR_LOCATIONS dl ON dl.donor_id = p_donor_id
        WHERE n.status = 'approved'
        GROUP BY n.ngo_id, n.ngo_name, n.city
        ORDER BY match_score DESC
    )
    LOOP
        DBMS_OUTPUT.PUT_LINE(
            'NGO: '      || rec.ngo_name ||
            ' | City: '  || rec.city     ||
            ' | Score: ' || ROUND(rec.match_score, 2)
        );
    END LOOP;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END;
/


-- 4.7  DONATIONS  (SRS REQ-DON-01, REQ-DON-02)
-- -------------------------------------------------------

-- Donor commits to a specific need. Notifies both donor and NGO.
CREATE OR REPLACE PROCEDURE make_donation (
    p_donor_id         IN NUMBER,
    p_need_id          IN NUMBER,
    p_item_description IN VARCHAR2
) AS
    v_ngo_id     NGOS.ngo_id%TYPE;
    v_ngo_name   NGOS.ngo_name%TYPE;
    v_need_title NEEDS.title%TYPE;
    v_count      NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM NEEDS WHERE need_id = p_need_id AND status = 'open';
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Error: Need not found or is no longer open.');
        RETURN;
    END IF;

    SELECT n.ngo_id, n.ngo_name, nd.title
    INTO v_ngo_id, v_ngo_name, v_need_title
    FROM NEEDS nd JOIN NGOS n ON nd.ngo_id = n.ngo_id
    WHERE nd.need_id = p_need_id;

    INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, status, committed_at)
    VALUES (donations_seq.NEXTVAL, p_donor_id, p_need_id, v_ngo_id, p_item_description, 'committed', SYSDATE);

    -- Notify donor
    INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
    SELECT notif_seq.NEXTVAL, u.user_id, 'donation',
           'Your commitment to "' || v_need_title || '" at ' || v_ngo_name || ' was recorded.',
           0, SYSDATE
    FROM DONORS d JOIN USERS u ON d.user_id = u.user_id
    WHERE d.donor_id = p_donor_id;

    -- Notify NGO
    INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
    SELECT notif_seq.NEXTVAL, u.user_id, 'donation',
           'A donor has committed to your need: "' || v_need_title || '".',
           0, SYSDATE
    FROM NGOS n JOIN USERS u ON n.user_id = u.user_id
    WHERE n.ngo_id = v_ngo_id;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Donation committed to: ' || v_need_title);
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('Error: Duplicate commitment detected.');
        ROLLBACK;
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/

-- Marks a committed donation as completed or cancelled.
CREATE OR REPLACE PROCEDURE update_donation_status (
    p_donation_id IN NUMBER,
    p_status      IN VARCHAR2
) AS
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM DONATIONS WHERE donation_id = p_donation_id;
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Error: Donation not found.');
        RETURN;
    END IF;
    UPDATE DONATIONS SET status = p_status WHERE donation_id = p_donation_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Donation ' || p_donation_id || ' updated to: ' || p_status);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/


-- 4.8  PROFILE READ PROCEDURES
-- -------------------------------------------------------

-- Returns NGO details with categories as a comma-separated string.
CREATE OR REPLACE PROCEDURE get_ngo_profile (
    p_ngo_id IN NUMBER
) AS
    v_name        NGOS.ngo_name%TYPE;
    v_city        NGOS.city%TYPE;
    v_description NGOS.description%TYPE;
    v_status      NGOS.status%TYPE;
    v_categories  VARCHAR2(500);
BEGIN
    SELECT ngo_name, city, description, status
    INTO v_name, v_city, v_description, v_status
    FROM NGOS WHERE ngo_id = p_ngo_id;

    SELECT LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name)
    INTO v_categories
    FROM NGO_CATEGORIES nc JOIN CATEGORIES c ON nc.category_id = c.category_id
    WHERE nc.ngo_id = p_ngo_id;

    DBMS_OUTPUT.PUT_LINE('Name:        ' || v_name);
    DBMS_OUTPUT.PUT_LINE('City:        ' || v_city);
    DBMS_OUTPUT.PUT_LINE('Description: ' || v_description);
    DBMS_OUTPUT.PUT_LINE('Status:      ' || v_status);
    DBMS_OUTPUT.PUT_LINE('Categories:  ' || NVL(v_categories, 'None assigned'));
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Error: NGO not found.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END;
/

-- Returns donor name, email, cause preferences, and all saved locations.
CREATE OR REPLACE PROCEDURE get_donor_profile (
    p_donor_id IN NUMBER
) AS
    v_name        USERS.name%TYPE;
    v_email       USERS.email%TYPE;
    v_preferences VARCHAR2(500);
BEGIN
    SELECT u.name, u.email INTO v_name, v_email
    FROM DONORS d JOIN USERS u ON d.user_id = u.user_id
    WHERE d.donor_id = p_donor_id;

    SELECT LISTAGG(c.name, ', ') WITHIN GROUP (ORDER BY c.name)
    INTO v_preferences
    FROM DONOR_PREFERENCES dp JOIN CATEGORIES c ON dp.category_id = c.category_id
    WHERE dp.donor_id = p_donor_id;

    DBMS_OUTPUT.PUT_LINE('Name:        ' || v_name);
    DBMS_OUTPUT.PUT_LINE('Email:       ' || v_email);
    DBMS_OUTPUT.PUT_LINE('Preferences: ' || NVL(v_preferences, 'None set'));
    DBMS_OUTPUT.PUT_LINE('--- Locations ---');

    FOR loc IN (
        SELECT city, province, country, postal_code
        FROM DONOR_LOCATIONS WHERE donor_id = p_donor_id
    )
    LOOP
        DBMS_OUTPUT.PUT_LINE(
            loc.city || ', ' || loc.province ||
            ', ' || loc.country || ' (' || loc.postal_code || ')'
        );
    END LOOP;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Error: Donor not found.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END;
/


-- 4.9  NOTIFICATIONS
-- -------------------------------------------------------

-- Generic utility: sends any message to any user.
CREATE OR REPLACE PROCEDURE send_notification (
    p_user_id    IN NUMBER,
    p_notif_type IN VARCHAR2,
    p_message    IN VARCHAR2
) AS
BEGIN
    INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
    VALUES (notif_seq.NEXTVAL, p_user_id, p_notif_type, p_message, 0, SYSDATE);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Notification sent to user_id: ' || p_user_id);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/

-- Marks a single notification as read.
CREATE OR REPLACE PROCEDURE mark_notification_read (
    p_notif_id IN NUMBER
) AS
BEGIN
    UPDATE NOTIFICATIONS SET is_read = 1 WHERE notif_id = p_notif_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Notification ' || p_notif_id || ' marked as read.');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/


-- 4.10 ANALYTICS
-- -------------------------------------------------------

-- Prints donations per category, open needs per NGO, and top 5 donors.
CREATE OR REPLACE PROCEDURE get_analytics AS
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== DONATIONS BY CATEGORY ===');
    FOR rec IN (
        SELECT c.name AS category, COUNT(don.donation_id) AS total_donations
        FROM DONATIONS don
        JOIN NEEDS      nd ON don.need_id    = nd.need_id
        JOIN CATEGORIES c  ON nd.category_id = c.category_id
        GROUP BY c.name
        ORDER BY total_donations DESC
    )
    LOOP
        DBMS_OUTPUT.PUT_LINE('Category: ' || rec.category || ' | Donations: ' || rec.total_donations);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('=== OPEN NEEDS PER NGO ===');
    FOR rec IN (
        SELECT n.ngo_name, COUNT(nd.need_id) AS open_needs
        FROM NGOS n
        LEFT JOIN NEEDS nd ON n.ngo_id = nd.ngo_id AND nd.status = 'open'
        GROUP BY n.ngo_name
        ORDER BY open_needs DESC
    )
    LOOP
        DBMS_OUTPUT.PUT_LINE('NGO: ' || rec.ngo_name || ' | Open Needs: ' || rec.open_needs);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('=== TOP 5 DONORS BY COMMITMENTS ===');
    FOR rec IN (
        SELECT u.name, COUNT(don.donation_id) AS total_commitments
        FROM DONATIONS don
        JOIN DONORS d ON don.donor_id = d.donor_id
        JOIN USERS  u ON d.user_id    = u.user_id
        GROUP BY u.name
        ORDER BY total_commitments DESC
        FETCH FIRST 5 ROWS ONLY
    )
    LOOP
        DBMS_OUTPUT.PUT_LINE('Donor: ' || rec.name || ' | Commitments: ' || rec.total_commitments);
    END LOOP;
END;
/


-- ============================================================
--  SECTION 5: GRANTS
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON CATEGORIES TO abc;
GRANT SELECT, INSERT, UPDATE, DELETE ON USERS       TO abc;
GRANT SELECT, INSERT, UPDATE, DELETE ON NGOS        TO abc;


-- ============================================================
--  SECTION 6: SEED DATA
-- ============================================================

-- Safe to re-run — clears all rows and resets sequences first.
-- NOTE: Passwords stored as plain text for development only.

-- 6a. Delete all rows in dependency order (children before parents)
DELETE FROM NOTIFICATIONS;
DELETE FROM DONATIONS;
DELETE FROM NEEDS;
DELETE FROM DONOR_PREFERENCES;
DELETE FROM NGO_CATEGORIES;
DELETE FROM DONOR_LOCATIONS;
DELETE FROM DOCUMENTS;
DELETE FROM VERIFICATION_LOG;
DELETE FROM DONORS;
DELETE FROM NGOS;
DELETE FROM CATEGORIES;
DELETE FROM USERS;
COMMIT;

-- 6b. Reset sequences
DROP SEQUENCE users_seq;       CREATE SEQUENCE users_seq       START WITH 1 INCREMENT BY 1;
DROP SEQUENCE donors_seq;      CREATE SEQUENCE donors_seq      START WITH 1 INCREMENT BY 1;
DROP SEQUENCE ngos_seq;        CREATE SEQUENCE ngos_seq        START WITH 1 INCREMENT BY 1;
DROP SEQUENCE categories_seq;  CREATE SEQUENCE categories_seq  START WITH 1 INCREMENT BY 1;
DROP SEQUENCE locations_seq;   CREATE SEQUENCE locations_seq   START WITH 1 INCREMENT BY 1;
DROP SEQUENCE documents_seq;   CREATE SEQUENCE documents_seq   START WITH 1 INCREMENT BY 1;
DROP SEQUENCE verif_log_seq;   CREATE SEQUENCE verif_log_seq   START WITH 1 INCREMENT BY 1;
DROP SEQUENCE needs_seq;       CREATE SEQUENCE needs_seq       START WITH 1 INCREMENT BY 1;
DROP SEQUENCE donations_seq;   CREATE SEQUENCE donations_seq   START WITH 1 INCREMENT BY 1;
DROP SEQUENCE notif_seq;       CREATE SEQUENCE notif_seq       START WITH 1 INCREMENT BY 1;

-- 6c. ADMIN USER (user_id = 1)
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Admin User', 'admin@impactlink.com', 'password123', 'admin', SYSDATE);
COMMIT;

-- 6d. DONOR USERS (user_ids 2-101)
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sara Ahmed', 'sara.ahmed1@donor.com', 'password123', 'donor', SYSDATE - 337);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Ali Hassan', 'ali.hassan2@donor.com', 'password123', 'donor', SYSDATE - 67);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Fatima Khan', 'fatima.khan3@donor.com', 'password123', 'donor', SYSDATE - 22);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Omar Ali', 'omar.ali4@donor.com', 'password123', 'donor', SYSDATE - 150);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Zainab Sheikh', 'zainab.sheikh5@donor.com', 'password123', 'donor', SYSDATE - 135);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Hassan Malik', 'hassan.malik6@donor.com', 'password123', 'donor', SYSDATE - 124);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Ayesha Qureshi', 'ayesha.qureshi7@donor.com', 'password123', 'donor', SYSDATE - 81);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Bilal Raza', 'bilal.raza8@donor.com', 'password123', 'donor', SYSDATE - 62);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Hina Siddiqui', 'hina.siddiqui9@donor.com', 'password123', 'donor', SYSDATE - 356);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Kamran Chaudhry', 'kamran.chaudhry10@donor.com', 'password123', 'donor', SYSDATE - 289);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sana Baig', 'sana.baig11@donor.com', 'password123', 'donor', SYSDATE - 54);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Tariq Mirza', 'tariq.mirza12@donor.com', 'password123', 'donor', SYSDATE - 312);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Mehwish Hussain', 'mehwish.hussain13@donor.com', 'password123', 'donor', SYSDATE - 226);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Usman Akhtar', 'usman.akhtar14@donor.com', 'password123', 'donor', SYSDATE - 26);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Nadia Butt', 'nadia.butt15@donor.com', 'password123', 'donor', SYSDATE - 25);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Faisal Rana', 'faisal.rana16@donor.com', 'password123', 'donor', SYSDATE - 57);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Amna Nawaz', 'amna.nawaz17@donor.com', 'password123', 'donor', SYSDATE - 121);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Shahid Abbasi', 'shahid.abbasi18@donor.com', 'password123', 'donor', SYSDATE - 129);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Rabia Javed', 'rabia.javed19@donor.com', 'password123', 'donor', SYSDATE - 268);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Junaid Rizvi', 'junaid.rizvi20@donor.com', 'password123', 'donor', SYSDATE - 318);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Saima Ansari', 'saima.ansari21@donor.com', 'password123', 'donor', SYSDATE - 23);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Adeel Zafar', 'adeel.zafar22@donor.com', 'password123', 'donor', SYSDATE - 297);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Nimra Hashmi', 'nimra.hashmi23@donor.com', 'password123', 'donor', SYSDATE - 111);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Waqas Lodhi', 'waqas.lodhi24@donor.com', 'password123', 'donor', SYSDATE - 342);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Maria Farooq', 'maria.farooq25@donor.com', 'password123', 'donor', SYSDATE - 289);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Imran Gillani', 'imran.gillani26@donor.com', 'password123', 'donor', SYSDATE - 224);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Zobia Bhatti', 'zobia.bhatti27@donor.com', 'password123', 'donor', SYSDATE - 122);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Amir Naqvi', 'amir.naqvi28@donor.com', 'password123', 'donor', SYSDATE - 239);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Kiran Cheema', 'kiran.cheema29@donor.com', 'password123', 'donor', SYSDATE - 311);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Talha Mian', 'talha.mian30@donor.com', 'password123', 'donor', SYSDATE - 152);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Shazia Sajid', 'shazia.sajid31@donor.com', 'password123', 'donor', SYSDATE - 13);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Nabeel Warsi', 'nabeel.warsi32@donor.com', 'password123', 'donor', SYSDATE - 91);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Huma Paracha', 'huma.paracha33@donor.com', 'password123', 'donor', SYSDATE - 226);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Danish Aslam', 'danish.aslam34@donor.com', 'password123', 'donor', SYSDATE - 184);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Saira Durrani', 'saira.durrani35@donor.com', 'password123', 'donor', SYSDATE - 152);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Zahid Bhutto', 'zahid.bhutto36@donor.com', 'password123', 'donor', SYSDATE - 89);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Lubna Tiwana', 'lubna.tiwana37@donor.com', 'password123', 'donor', SYSDATE - 120);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Raza Niazi', 'raza.niazi38@donor.com', 'password123', 'donor', SYSDATE - 182);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sadia Patel', 'sadia.patel39@donor.com', 'password123', 'donor', SYSDATE - 62);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Ahsan Sadiq', 'ahsan.sadiq40@donor.com', 'password123', 'donor', SYSDATE - 57);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Asma Suleman', 'asma.suleman41@donor.com', 'password123', 'donor', SYSDATE - 204);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Khurram Khalid', 'khurram.khalid42@donor.com', 'password123', 'donor', SYSDATE - 59);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Rubab Latif', 'rubab.latif43@donor.com', 'password123', 'donor', SYSDATE - 193);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Naeem Waheed', 'naeem.waheed44@donor.com', 'password123', 'donor', SYSDATE - 186);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Farah Saleem', 'farah.saleem45@donor.com', 'password123', 'donor', SYSDATE - 319);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Javed Rehman', 'javed.rehman46@donor.com', 'password123', 'donor', SYSDATE - 145);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Maryam Sultan', 'maryam.sultan47@donor.com', 'password123', 'donor', SYSDATE - 32);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Shoaib Kashmiri', 'shoaib.kashmiri48@donor.com', 'password123', 'donor', SYSDATE - 245);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Iqra Syed', 'iqra.syed49@donor.com', 'password123', 'donor', SYSDATE - 284);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Hamza Farooqui', 'hamza.farooqui50@donor.com', 'password123', 'donor', SYSDATE - 73);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sundas Ahmed', 'sundas.ahmed51@donor.com', 'password123', 'donor', SYSDATE - 203);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Awais Hassan', 'awais.hassan52@donor.com', 'password123', 'donor', SYSDATE - 50);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Yasmeen Khan', 'yasmeen.khan53@donor.com', 'password123', 'donor', SYSDATE - 292);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Rizwan Ali', 'rizwan.ali54@donor.com', 'password123', 'donor', SYSDATE - 160);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Uzma Sheikh', 'uzma.sheikh55@donor.com', 'password123', 'donor', SYSDATE - 331);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Zafar Malik', 'zafar.malik56@donor.com', 'password123', 'donor', SYSDATE - 326);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sidra Qureshi', 'sidra.qureshi57@donor.com', 'password123', 'donor', SYSDATE - 195);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Wasim Raza', 'wasim.raza58@donor.com', 'password123', 'donor', SYSDATE - 305);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Zara Siddiqui', 'zara.siddiqui59@donor.com', 'password123', 'donor', SYSDATE - 108);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Salman Chaudhry', 'salman.chaudhry60@donor.com', 'password123', 'donor', SYSDATE - 45);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Rida Baig', 'rida.baig61@donor.com', 'password123', 'donor', SYSDATE - 33);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Mohsin Mirza', 'mohsin.mirza62@donor.com', 'password123', 'donor', SYSDATE - 348);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Aisha Hussain', 'aisha.hussain63@donor.com', 'password123', 'donor', SYSDATE - 126);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Babar Akhtar', 'babar.akhtar64@donor.com', 'password123', 'donor', SYSDATE - 158);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Noor Butt', 'noor.butt65@donor.com', 'password123', 'donor', SYSDATE - 50);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Kashan Rana', 'kashan.rana66@donor.com', 'password123', 'donor', SYSDATE - 129);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Layla Nawaz', 'layla.nawaz67@donor.com', 'password123', 'donor', SYSDATE - 61);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Saad Abbasi', 'saad.abbasi68@donor.com', 'password123', 'donor', SYSDATE - 204);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Tehreem Javed', 'tehreem.javed69@donor.com', 'password123', 'donor', SYSDATE - 152);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Waleed Rizvi', 'waleed.rizvi70@donor.com', 'password123', 'donor', SYSDATE - 242);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Faria Ansari', 'faria.ansari71@donor.com', 'password123', 'donor', SYSDATE - 335);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Nadir Zafar', 'nadir.zafar72@donor.com', 'password123', 'donor', SYSDATE - 196);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sobia Hashmi', 'sobia.hashmi73@donor.com', 'password123', 'donor', SYSDATE - 93);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Asif Lodhi', 'asif.lodhi74@donor.com', 'password123', 'donor', SYSDATE - 199);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Dua Farooq', 'dua.farooq75@donor.com', 'password123', 'donor', SYSDATE - 191);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Rehan Gillani', 'rehan.gillani76@donor.com', 'password123', 'donor', SYSDATE - 117);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Maham Bhatti', 'maham.bhatti77@donor.com', 'password123', 'donor', SYSDATE - 353);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Ihsan Naqvi', 'ihsan.naqvi78@donor.com', 'password123', 'donor', SYSDATE - 146);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Areeba Cheema', 'areeba.cheema79@donor.com', 'password123', 'donor', SYSDATE - 359);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Zaman Mian', 'zaman.mian80@donor.com', 'password123', 'donor', SYSDATE - 341);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Aliya Sajid', 'aliya.sajid81@donor.com', 'password123', 'donor', SYSDATE - 46);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Furqan Warsi', 'furqan.warsi82@donor.com', 'password123', 'donor', SYSDATE - 321);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Hira Paracha', 'hira.paracha83@donor.com', 'password123', 'donor', SYSDATE - 335);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sabir Aslam', 'sabir.aslam84@donor.com', 'password123', 'donor', SYSDATE - 97);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Muqadas Durrani', 'muqadas.durrani85@donor.com', 'password123', 'donor', SYSDATE - 283);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Ramiz Bhutto', 'ramiz.bhutto86@donor.com', 'password123', 'donor', SYSDATE - 135);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Tayyba Tiwana', 'tayyba.tiwana87@donor.com', 'password123', 'donor', SYSDATE - 93);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Ehtisham Niazi', 'ehtisham.niazi88@donor.com', 'password123', 'donor', SYSDATE - 246);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sehar Patel', 'sehar.patel89@donor.com', 'password123', 'donor', SYSDATE - 204);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Azan Sadiq', 'azan.sadiq90@donor.com', 'password123', 'donor', SYSDATE - 148);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Madiha Suleman', 'madiha.suleman91@donor.com', 'password123', 'donor', SYSDATE - 337);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Umair Khalid', 'umair.khalid92@donor.com', 'password123', 'donor', SYSDATE - 362);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Bisma Latif', 'bisma.latif93@donor.com', 'password123', 'donor', SYSDATE - 295);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Shahroz Waheed', 'shahroz.waheed94@donor.com', 'password123', 'donor', SYSDATE - 122);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Aimen Saleem', 'aimen.saleem95@donor.com', 'password123', 'donor', SYSDATE - 360);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Haider Rehman', 'haider.rehman96@donor.com', 'password123', 'donor', SYSDATE - 176);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Roshni Sultan', 'roshni.sultan97@donor.com', 'password123', 'donor', SYSDATE - 38);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Fawad Kashmiri', 'fawad.kashmiri98@donor.com', 'password123', 'donor', SYSDATE - 127);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Naila Syed', 'naila.syed99@donor.com', 'password123', 'donor', SYSDATE - 26);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Naveed Farooqui', 'naveed.farooqui100@donor.com', 'password123', 'donor', SYSDATE - 171);
COMMIT;

-- 6e. NGO USERS (user_ids 102-151)
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Edhi Foundation', 'edhifoundati1@ngo.com', 'password123', 'ngo', SYSDATE - 210);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Shaukat Khanum Memorial Hospital', 'shaukatkhanu2@ngo.com', 'password123', 'ngo', SYSDATE - 142);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'The Citizen Foundation', 'thecitizenfo3@ngo.com', 'password123', 'ngo', SYSDATE - 38);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Layton Rahmatulla Benevolent Trust', 'laytonrahmat4@ngo.com', 'password123', 'ngo', SYSDATE - 113);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Akhuwat Foundation', 'akhuwatfound5@ngo.com', 'password123', 'ngo', SYSDATE - 295);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sungi Development Foundation', 'sungidevelop6@ngo.com', 'password123', 'ngo', SYSDATE - 372);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Indus Hospital', 'indushospita7@ngo.com', 'password123', 'ngo', SYSDATE - 166);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Saylani Welfare Trust', 'saylaniwelfa8@ngo.com', 'password123', 'ngo', SYSDATE - 113);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Khidmat Foundation', 'khidmatfound9@ngo.com', 'password123', 'ngo', SYSDATE - 340);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Pakistan Poverty Alleviation Fund', 'pakistanpove10@ngo.com', 'password123', 'ngo', SYSDATE - 260);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Chippa Welfare Association', 'chippawelfar11@ngo.com', 'password123', 'ngo', SYSDATE - 207);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Ansar Burney Trust', 'ansarburneyt12@ngo.com', 'password123', 'ngo', SYSDATE - 334);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Pakistan Sweet Home', 'pakistanswee13@ngo.com', 'password123', 'ngo', SYSDATE - 239);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Hunar Foundation', 'hunarfoundat14@ngo.com', 'password123', 'ngo', SYSDATE - 78);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'TCF — Teacher Training Program', 'tcf—teachert15@ngo.com', 'password123', 'ngo', SYSDATE - 140);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Umang Pakistan', 'umangpakista16@ngo.com', 'password123', 'ngo', SYSDATE - 76);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Greenstar Social Marketing', 'greenstarsoc17@ngo.com', 'password123', 'ngo', SYSDATE - 131);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'SOS Children Villages Pakistan', 'soschildrenv18@ngo.com', 'password123', 'ngo', SYSDATE - 386);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Transparent Hands', 'transparenth19@ngo.com', 'password123', 'ngo', SYSDATE - 292);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Rizq Foundation', 'rizqfoundati20@ngo.com', 'password123', 'ngo', SYSDATE - 280);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'HOPE Welfare Trust', 'hopewelfaret21@ngo.com', 'password123', 'ngo', SYSDATE - 139);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Imkaan Welfare Organization', 'imkaanwelfar22@ngo.com', 'password123', 'ngo', SYSDATE - 387);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Aware Girls', 'awaregirls23@ngo.com', 'password123', 'ngo', SYSDATE - 304);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Strengthening Participatory Organization', 'strengthenin24@ngo.com', 'password123', 'ngo', SYSDATE - 224);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'LEAD Pakistan', 'leadpakistan25@ngo.com', 'password123', 'ngo', SYSDATE - 303);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'WWF Pakistan', 'wwfpakistan26@ngo.com', 'password123', 'ngo', SYSDATE - 209);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Agha Khan Foundation Pakistan', 'aghakhanfoun27@ngo.com', 'password123', 'ngo', SYSDATE - 190);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Human Development Foundation', 'humandevelop28@ngo.com', 'password123', 'ngo', SYSDATE - 117);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Aurat Foundation', 'auratfoundat29@ngo.com', 'password123', 'ngo', SYSDATE - 75);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Rabta Foundation', 'rabtafoundat30@ngo.com', 'password123', 'ngo', SYSDATE - 265);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sahara For Life Trust', 'saharaforlif31@ngo.com', 'password123', 'ngo', SYSDATE - 257);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Pakistan Animal Welfare Society', 'pakistananim32@ngo.com', 'password123', 'ngo', SYSDATE - 51);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Fauget (Animal Aid)', 'fauget(anima33@ngo.com', 'password123', 'ngo', SYSDATE - 391);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Disaster Response Network', 'disasterresp34@ngo.com', 'password123', 'ngo', SYSDATE - 29);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Children''s Global Network', 'childrensglo35@ngo.com', 'password123', 'ngo', SYSDATE - 61);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Al-Khadim Welfare Trust', 'al-khadimwel36@ngo.com', 'password123', 'ngo', SYSDATE - 83);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Noor Welfare Society', 'noorwelfares37@ngo.com', 'password123', 'ngo', SYSDATE - 326);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Green Earth Initiative', 'greenearthin38@ngo.com', 'password123', 'ngo', SYSDATE - 86);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Youth Uplift Foundation', 'youthupliftf39@ngo.com', 'password123', 'ngo', SYSDATE - 353);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Ghar Basao Trust', 'gharbasaotru40@ngo.com', 'password123', 'ngo', SYSDATE - 221);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Roshni Gharana', 'roshnigharan41@ngo.com', 'password123', 'ngo', SYSDATE - 310);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Clean Karachi Movement', 'cleankarachi42@ngo.com', 'password123', 'ngo', SYSDATE - 37);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Bahawalpur Relief Aid', 'bahawalpurre43@ngo.com', 'password123', 'ngo', SYSDATE - 202);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Umeed Pakistan', 'umeedpakista44@ngo.com', 'password123', 'ngo', SYSDATE - 200);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Naya Sawera', 'nayasawera45@ngo.com', 'password123', 'ngo', SYSDATE - 310);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Sahel Welfare', 'sahelwelfare46@ngo.com', 'password123', 'ngo', SYSDATE - 244);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Khushhal Ghar', 'khushhalghar47@ngo.com', 'password123', 'ngo', SYSDATE - 275);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Dastak NGO', 'dastakngo48@ngo.com', 'password123', 'ngo', SYSDATE - 133);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Qadamat Foundation', 'qadamatfound49@ngo.com', 'password123', 'ngo', SYSDATE - 288);
INSERT INTO USERS (user_id, name, email, password_hash, user_role, created_at)
VALUES (users_seq.NEXTVAL, 'Save Balochistan Fund', 'savebalochis50@ngo.com', 'password123', 'ngo', SYSDATE - 10);
COMMIT;

-- 6f. DONORS table (donor_id 1-100 → user_id 2-101)
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 2);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 3);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 4);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 5);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 6);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 7);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 8);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 9);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 10);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 11);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 12);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 13);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 14);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 15);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 16);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 17);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 18);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 19);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 20);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 21);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 22);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 23);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 24);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 25);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 26);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 27);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 28);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 29);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 30);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 31);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 32);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 33);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 34);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 35);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 36);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 37);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 38);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 39);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 40);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 41);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 42);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 43);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 44);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 45);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 46);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 47);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 48);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 49);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 50);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 51);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 52);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 53);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 54);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 55);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 56);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 57);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 58);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 59);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 60);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 61);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 62);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 63);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 64);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 65);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 66);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 67);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 68);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 69);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 70);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 71);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 72);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 73);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 74);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 75);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 76);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 77);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 78);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 79);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 80);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 81);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 82);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 83);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 84);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 85);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 86);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 87);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 88);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 89);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 90);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 91);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 92);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 93);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 94);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 95);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 96);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 97);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 98);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 99);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 100);
INSERT INTO DONORS (donor_id, user_id) VALUES (donors_seq.NEXTVAL, 101);
COMMIT;

-- 6g. NGOS table (ngo_id 1-50 → user_id 102-151)
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (1, 102, 'Edhi Foundation', 'Karachi', 'Pakistan''s largest welfare org - ambulance, shelter, orphan care.', '+92-21-111343434', 'approved', SYSDATE - 63);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (2, 103, 'Shaukat Khanum Memorial Hospital', 'Lahore', 'Free cancer treatment for patients who cannot afford it.', '+92-42-35945100', 'approved', SYSDATE - 279);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (3, 104, 'The Citizen Foundation', 'Karachi', 'Quality schools in underprivileged areas across Pakistan.', '+92-21-111000123', 'approved', SYSDATE - 141);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (4, 105, 'Layton Rahmatulla Benevolent Trust', 'Lahore', 'Free eye care and disability rehabilitation nationwide.', '+92-42-37231280', 'approved', SYSDATE - 179);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (5, 106, 'Akhuwat Foundation', 'Lahore', 'Interest-free microfinance and poverty alleviation programs.', '+92-42-35761999', 'approved', SYSDATE - 62);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (6, 107, 'Sungi Development Foundation', 'Islamabad', 'Rural development, women empowerment, and disaster response.', '+92-51-2278499', 'approved', SYSDATE - 155);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (7, 108, 'Indus Hospital', 'Karachi', 'Free healthcare services for all patients regardless of income.', '+92-21-35112709', 'approved', SYSDATE - 227);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (8, 109, 'Saylani Welfare Trust', 'Karachi', 'Mass meals, vocational training, and medical camps for the poor.', '+92-21-34540628', 'approved', SYSDATE - 85);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (9, 110, 'Khidmat Foundation', 'Islamabad', 'Humanitarian aid, food distribution, and flood relief operations.', '+92-51-8444488', 'approved', SYSDATE - 237);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (10, 111, 'Pakistan Poverty Alleviation Fund', 'Islamabad', 'Microfinance and social mobilisation for rural communities.', '+92-51-9246800', 'approved', SYSDATE - 6);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (11, 112, 'Chippa Welfare Association', 'Karachi', 'Emergency medical services and ambulance network in Sindh.', '+92-21-1020', 'approved', SYSDATE - 139);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (12, 113, 'Ansar Burney Trust', 'Karachi', 'Human rights, missing persons, and prisoner welfare advocacy.', '+92-21-35644456', 'approved', SYSDATE - 261);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (13, 114, 'Pakistan Sweet Home', 'Islamabad', 'Orphan care, education, and shelter for abandoned children.', '+92-51-5400081', 'approved', SYSDATE - 96);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (14, 115, 'Hunar Foundation', 'Karachi', 'Vocational and technical training for underprivileged youth.', '+92-21-34382781', 'approved', SYSDATE - 264);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (15, 116, 'TCF — Teacher Training Program', 'Lahore', 'Professional development and certification for public school teachers.', '+92-42-35765432', 'approved', SYSDATE - 59);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (16, 117, 'Umang Pakistan', 'Lahore', 'Mental health awareness, therapy, and rehabilitation support.', '+92-42-35761122', 'approved', SYSDATE - 157);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (17, 118, 'Greenstar Social Marketing', 'Karachi', 'Family planning and reproductive health outreach in rural Pakistan.', '+92-21-34316060', 'approved', SYSDATE - 264);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (18, 119, 'SOS Children Villages Pakistan', 'Lahore', 'Long-term family-based care for orphaned and abandoned children.', '+92-42-35858585', 'approved', SYSDATE - 106);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (19, 120, 'Transparent Hands', 'Lahore', 'Free surgical procedures for patients unable to afford surgery.', '+92-42-37880409', 'approved', SYSDATE - 83);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (20, 121, 'Rizq Foundation', 'Karachi', 'Food rescue and hunger alleviation through surplus food redistribution.', '+92-21-34156789', 'approved', SYSDATE - 196);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (21, 122, 'HOPE Welfare Trust', 'Karachi', 'Primary healthcare, education, and social welfare for slum communities.', '+92-21-35678901', 'approved', SYSDATE - 87);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (22, 123, 'Imkaan Welfare Organization', 'Multan', 'Skills training, microloans, and livelihood programs in south Punjab.', '+92-61-4556677', 'approved', SYSDATE - 281);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (23, 124, 'Aware Girls', 'Peshawar', 'Women rights, peace-building, and leadership training in KPK.', '+92-91-5703802', 'approved', SYSDATE - 276);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (24, 125, 'Strengthening Participatory Organization', 'Quetta', 'Community development and natural resource management in Balochistan.', '+92-81-2843788', 'approved', SYSDATE - 5);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (25, 126, 'LEAD Pakistan', 'Islamabad', 'Sustainable development, climate policy, and environmental advocacy.', '+92-51-2601118', 'approved', SYSDATE - 170);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (26, 127, 'WWF Pakistan', 'Islamabad', 'Wildlife conservation, marine protection, and ecosystem restoration.', '+92-51-8115191', 'approved', SYSDATE - 255);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (27, 128, 'Agha Khan Foundation Pakistan', 'Karachi', 'Health, education, and rural development across Pakistan.', '+92-21-35232425', 'approved', SYSDATE - 14);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (28, 129, 'Human Development Foundation', 'Karachi', 'Integrated development programs - water, health, and education.', '+92-21-34158090', 'approved', SYSDATE - 62);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (29, 130, 'Aurat Foundation', 'Islamabad', 'Women political participation and gender equality advocacy.', '+92-51-2873032', 'approved', SYSDATE - 190);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (30, 131, 'Rabta Foundation', 'Rawalpindi', 'Blood bank, cancer support, and organ donation awareness.', '+92-51-4577890', 'approved', SYSDATE - 162);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (31, 132, 'Sahara For Life Trust', 'Lahore', 'Thalassemia treatment and blood disorder management centre.', '+92-42-35862666', 'approved', SYSDATE - 127);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (32, 133, 'Pakistan Animal Welfare Society', 'Islamabad', 'Animal rescue, shelter, sterilisation, and anti-cruelty enforcement.', '+92-51-2655027', 'approved', SYSDATE - 34);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (33, 134, 'Fauget (Animal Aid)', 'Karachi', 'Street animal rescue, adoption drives, and veterinary camps.', '+92-21-34567111', 'approved', SYSDATE - 128);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (34, 135, 'Disaster Response Network', 'Islamabad', 'Rapid-response flood and earthquake relief across all provinces.', '+92-51-9990011', 'approved', SYSDATE - 295);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (35, 136, 'Children''s Global Network', 'Karachi', 'Child rights, education access, and nutrition programs.', '+92-21-34120088', 'approved', SYSDATE - 45);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (36, 137, 'Al-Khadim Welfare Trust', 'Lahore', 'Community development, rejected due to incomplete documentation.', '+92-42-11111111', 'rejected', SYSDATE - 48);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (37, 138, 'Noor Welfare Society', 'Quetta', 'Eye care outreach, rejected pending tax registration proof.', '+92-81-9991111', 'rejected', SYSDATE - 253);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (38, 139, 'Green Earth Initiative', 'Peshawar', 'Environmental NGO, rejected - unverified registration certificate.', '+92-91-0001111', 'rejected', SYSDATE - 40);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (39, 140, 'Youth Uplift Foundation', 'Sialkot', 'Youth sports and skills, rejected - missing bank statement.', '+92-52-4440000', 'rejected', SYSDATE - 277);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (40, 141, 'Ghar Basao Trust', 'Hyderabad', 'Shelter for flood affectees, rejected - duplicate application.', '+92-22-2770000', 'rejected', SYSDATE - 69);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (41, 142, 'Roshni Gharana', 'Faisalabad', 'Orphan shelter, rejected - mismatched director information.', '+92-41-8880000', 'rejected', SYSDATE - 70);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (42, 143, 'Clean Karachi Movement', 'Karachi', 'Sanitation drive, rejected - administrative irregularities.', '+92-21-33330000', 'rejected', SYSDATE - 248);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (43, 144, 'Bahawalpur Relief Aid', 'Bahawalpur', 'Disaster relief, rejected - documents expired.', '+92-62-8880000', 'rejected', SYSDATE - 286);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (44, 145, 'Umeed Pakistan', 'Gujranwala', 'Women skill development, pending admin review.', '+92-55-3330000', 'pending', SYSDATE - 89);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (45, 146, 'Naya Sawera', 'Multan', 'Youth literacy and adult education, pending review.', '+92-61-5550000', 'pending', SYSDATE - 140);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (46, 147, 'Sahel Welfare', 'Islamabad', 'Disability support and rehabilitation, pending.', '+92-51-7770000', 'pending', SYSDATE - 275);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (47, 148, 'Khushhal Ghar', 'Lahore', 'Elderly care and old-age homes, pending verification.', '+92-42-9990000', 'pending', SYSDATE - 221);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (48, 149, 'Dastak NGO', 'Karachi', 'Domestic violence shelter and legal aid, pending.', '+92-21-5550000', 'pending', SYSDATE - 113);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (49, 150, 'Qadamat Foundation', 'Rawalpindi', 'Microfinance for women entrepreneurs, pending tax clearance.', '+92-51-2220000', 'pending', SYSDATE - 281);
INSERT INTO NGOS (ngo_id, user_id, ngo_name, city, description, phone, status, registered_at)
VALUES (50, 151, 'Save Balochistan Fund', 'Quetta', 'Flood and drought relief in Balochistan, pending documents.', '+92-81-4440000', 'pending', SYSDATE - 107);
COMMIT;

-- 6h. CATEGORIES
INSERT INTO CATEGORIES (category_id, name, description) VALUES (categories_seq.NEXTVAL, 'Health', 'Medical care, hospitals, mental health support');
INSERT INTO CATEGORIES (category_id, name, description) VALUES (categories_seq.NEXTVAL, 'Education', 'Schools, scholarships, literacy programs');
INSERT INTO CATEGORIES (category_id, name, description) VALUES (categories_seq.NEXTVAL, 'Disaster Relief', 'Flood, earthquake, and emergency response');
INSERT INTO CATEGORIES (category_id, name, description) VALUES (categories_seq.NEXTVAL, 'Food Security', 'Hunger relief, food banks, nutrition programs');
INSERT INTO CATEGORIES (category_id, name, description) VALUES (categories_seq.NEXTVAL, 'Shelter', 'Housing for homeless, refugees, and orphans');
INSERT INTO CATEGORIES (category_id, name, description) VALUES (categories_seq.NEXTVAL, 'Women Empowerment', 'Skills training and support for women');
INSERT INTO CATEGORIES (category_id, name, description) VALUES (categories_seq.NEXTVAL, 'Environment', 'Conservation, climate change, and green initiatives');
INSERT INTO CATEGORIES (category_id, name, description) VALUES (categories_seq.NEXTVAL, 'Poverty Relief', 'Economic support and livelihood programs');
INSERT INTO CATEGORIES (category_id, name, description) VALUES (categories_seq.NEXTVAL, 'Children', 'Child welfare, orphan care, and youth programs');
INSERT INTO CATEGORIES (category_id, name, description) VALUES (categories_seq.NEXTVAL, 'Animal Welfare', 'Animal rescue, shelters, and wildlife protection');
COMMIT;

-- 6i. NGO_CATEGORIES
INSERT INTO NGO_CATEGORIES VALUES (1, 1);
INSERT INTO NGO_CATEGORIES VALUES (1, 3);
INSERT INTO NGO_CATEGORIES VALUES (1, 5);
INSERT INTO NGO_CATEGORIES VALUES (2, 1);
INSERT INTO NGO_CATEGORIES VALUES (3, 2);
INSERT INTO NGO_CATEGORIES VALUES (3, 9);
INSERT INTO NGO_CATEGORIES VALUES (4, 1);
INSERT INTO NGO_CATEGORIES VALUES (5, 8);
INSERT INTO NGO_CATEGORIES VALUES (5, 6);
INSERT INTO NGO_CATEGORIES VALUES (6, 6);
INSERT INTO NGO_CATEGORIES VALUES (6, 3);
INSERT INTO NGO_CATEGORIES VALUES (6, 8);
INSERT INTO NGO_CATEGORIES VALUES (7, 1);
INSERT INTO NGO_CATEGORIES VALUES (8, 4);
INSERT INTO NGO_CATEGORIES VALUES (8, 8);
INSERT INTO NGO_CATEGORIES VALUES (8, 1);
INSERT INTO NGO_CATEGORIES VALUES (9, 3);
INSERT INTO NGO_CATEGORIES VALUES (9, 4);
INSERT INTO NGO_CATEGORIES VALUES (10, 8);
INSERT INTO NGO_CATEGORIES VALUES (11, 1);
INSERT INTO NGO_CATEGORIES VALUES (11, 3);
INSERT INTO NGO_CATEGORIES VALUES (12, 9);
INSERT INTO NGO_CATEGORIES VALUES (12, 1);
INSERT INTO NGO_CATEGORIES VALUES (13, 9);
INSERT INTO NGO_CATEGORIES VALUES (13, 2);
INSERT INTO NGO_CATEGORIES VALUES (13, 5);
INSERT INTO NGO_CATEGORIES VALUES (14, 2);
INSERT INTO NGO_CATEGORIES VALUES (14, 8);
INSERT INTO NGO_CATEGORIES VALUES (15, 2);
INSERT INTO NGO_CATEGORIES VALUES (16, 1);
INSERT INTO NGO_CATEGORIES VALUES (17, 1);
INSERT INTO NGO_CATEGORIES VALUES (17, 6);
INSERT INTO NGO_CATEGORIES VALUES (18, 9);
INSERT INTO NGO_CATEGORIES VALUES (18, 5);
INSERT INTO NGO_CATEGORIES VALUES (19, 1);
INSERT INTO NGO_CATEGORIES VALUES (20, 4);
INSERT INTO NGO_CATEGORIES VALUES (21, 1);
INSERT INTO NGO_CATEGORIES VALUES (21, 2);
INSERT INTO NGO_CATEGORIES VALUES (21, 8);
INSERT INTO NGO_CATEGORIES VALUES (22, 6);
INSERT INTO NGO_CATEGORIES VALUES (22, 8);
INSERT INTO NGO_CATEGORIES VALUES (23, 6);
INSERT INTO NGO_CATEGORIES VALUES (24, 8);
INSERT INTO NGO_CATEGORIES VALUES (24, 7);
INSERT INTO NGO_CATEGORIES VALUES (25, 7);
INSERT INTO NGO_CATEGORIES VALUES (26, 7);
INSERT INTO NGO_CATEGORIES VALUES (26, 10);
INSERT INTO NGO_CATEGORIES VALUES (27, 1);
INSERT INTO NGO_CATEGORIES VALUES (27, 2);
INSERT INTO NGO_CATEGORIES VALUES (27, 8);
INSERT INTO NGO_CATEGORIES VALUES (28, 2);
INSERT INTO NGO_CATEGORIES VALUES (28, 1);
INSERT INTO NGO_CATEGORIES VALUES (28, 8);
INSERT INTO NGO_CATEGORIES VALUES (29, 6);
INSERT INTO NGO_CATEGORIES VALUES (30, 1);
INSERT INTO NGO_CATEGORIES VALUES (31, 1);
INSERT INTO NGO_CATEGORIES VALUES (32, 10);
INSERT INTO NGO_CATEGORIES VALUES (33, 10);
INSERT INTO NGO_CATEGORIES VALUES (34, 3);
INSERT INTO NGO_CATEGORIES VALUES (35, 9);
INSERT INTO NGO_CATEGORIES VALUES (35, 2);
INSERT INTO NGO_CATEGORIES VALUES (35, 4);
INSERT INTO NGO_CATEGORIES VALUES (36, 8);
INSERT INTO NGO_CATEGORIES VALUES (37, 1);
INSERT INTO NGO_CATEGORIES VALUES (38, 7);
INSERT INTO NGO_CATEGORIES VALUES (39, 2);
INSERT INTO NGO_CATEGORIES VALUES (39, 9);
INSERT INTO NGO_CATEGORIES VALUES (40, 5);
INSERT INTO NGO_CATEGORIES VALUES (41, 9);
INSERT INTO NGO_CATEGORIES VALUES (41, 5);
INSERT INTO NGO_CATEGORIES VALUES (42, 7);
INSERT INTO NGO_CATEGORIES VALUES (43, 3);
INSERT INTO NGO_CATEGORIES VALUES (44, 6);
INSERT INTO NGO_CATEGORIES VALUES (44, 8);
INSERT INTO NGO_CATEGORIES VALUES (45, 2);
INSERT INTO NGO_CATEGORIES VALUES (46, 1);
INSERT INTO NGO_CATEGORIES VALUES (46, 9);
INSERT INTO NGO_CATEGORIES VALUES (47, 5);
INSERT INTO NGO_CATEGORIES VALUES (47, 8);
INSERT INTO NGO_CATEGORIES VALUES (48, 6);
INSERT INTO NGO_CATEGORIES VALUES (48, 5);
INSERT INTO NGO_CATEGORIES VALUES (49, 6);
INSERT INTO NGO_CATEGORIES VALUES (49, 8);
INSERT INTO NGO_CATEGORIES VALUES (50, 3);
INSERT INTO NGO_CATEGORIES VALUES (50, 4);
COMMIT;

-- 6j. DONOR_LOCATIONS (every donor gets 1-2 locations)
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 1, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 1, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 2, 'Faisalabad', 'Punjab', 'Pakistan', '38000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 2, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 3, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 3, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 4, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 5, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 5, 'Sialkot', 'Punjab', 'Pakistan', '51310');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 6, 'Sialkot', 'Punjab', 'Pakistan', '51310');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 7, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 8, 'Bahawalpur', 'Punjab', 'Pakistan', '63100');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 9, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 10, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 11, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 11, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 12, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 13, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 13, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 14, 'Bahawalpur', 'Punjab', 'Pakistan', '63100');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 15, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 15, 'Faisalabad', 'Punjab', 'Pakistan', '38000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 16, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 16, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 17, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 18, 'Quetta', 'Balochistan', 'Pakistan', '87300');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 18, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 19, 'Faisalabad', 'Punjab', 'Pakistan', '38000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 19, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 20, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 21, 'Bahawalpur', 'Punjab', 'Pakistan', '63100');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 21, 'Quetta', 'Balochistan', 'Pakistan', '87300');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 22, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 23, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 24, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 24, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 25, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 26, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 26, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 27, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 27, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 28, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 29, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 30, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 31, 'Faisalabad', 'Punjab', 'Pakistan', '38000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 31, 'Bahawalpur', 'Punjab', 'Pakistan', '63100');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 32, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 33, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 34, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 34, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 35, 'Faisalabad', 'Punjab', 'Pakistan', '38000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 35, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 36, 'Bahawalpur', 'Punjab', 'Pakistan', '63100');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 36, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 37, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 37, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 38, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 38, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 39, 'Bahawalpur', 'Punjab', 'Pakistan', '63100');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 40, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 40, 'Bahawalpur', 'Punjab', 'Pakistan', '63100');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 41, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 41, 'Bahawalpur', 'Punjab', 'Pakistan', '63100');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 42, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 43, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 44, 'Sialkot', 'Punjab', 'Pakistan', '51310');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 45, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 46, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 47, 'Sialkot', 'Punjab', 'Pakistan', '51310');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 48, 'Sialkot', 'Punjab', 'Pakistan', '51310');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 49, 'Sialkot', 'Punjab', 'Pakistan', '51310');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 50, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 51, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 51, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 52, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 52, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 53, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 53, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 54, 'Faisalabad', 'Punjab', 'Pakistan', '38000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 54, 'Quetta', 'Balochistan', 'Pakistan', '87300');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 55, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 56, 'Sialkot', 'Punjab', 'Pakistan', '51310');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 56, 'Bahawalpur', 'Punjab', 'Pakistan', '63100');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 57, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 58, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 59, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 59, 'Quetta', 'Balochistan', 'Pakistan', '87300');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 60, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 61, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 61, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 62, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 62, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 63, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 64, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 64, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 65, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 66, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 67, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 68, 'Sialkot', 'Punjab', 'Pakistan', '51310');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 68, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 69, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 69, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 70, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 70, 'Faisalabad', 'Punjab', 'Pakistan', '38000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 71, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 71, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 72, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 72, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 73, 'Quetta', 'Balochistan', 'Pakistan', '87300');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 74, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 75, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 75, 'Faisalabad', 'Punjab', 'Pakistan', '38000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 76, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 76, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 77, 'Lahore', 'Punjab', 'Pakistan', '54000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 78, 'Hyderabad', 'Sindh', 'Pakistan', '71000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 79, 'Quetta', 'Balochistan', 'Pakistan', '87300');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 80, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 81, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 82, 'Quetta', 'Balochistan', 'Pakistan', '87300');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 82, 'Karachi', 'Sindh', 'Pakistan', '75000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 83, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 83, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 84, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 85, 'Quetta', 'Balochistan', 'Pakistan', '87300');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 86, 'Sialkot', 'Punjab', 'Pakistan', '51310');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 86, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 87, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 88, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 89, 'Islamabad', 'ICT', 'Pakistan', '44000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 90, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 90, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 91, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 92, 'Bahawalpur', 'Punjab', 'Pakistan', '63100');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 93, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 94, 'Faisalabad', 'Punjab', 'Pakistan', '38000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 95, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 96, 'Quetta', 'Balochistan', 'Pakistan', '87300');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 96, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 97, 'Rawalpindi', 'Punjab', 'Pakistan', '46000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 98, 'Gujranwala', 'Punjab', 'Pakistan', '52250');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 99, 'Multan', 'Punjab', 'Pakistan', '60000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 100, 'Peshawar', 'KPK', 'Pakistan', '25000');
INSERT INTO DONOR_LOCATIONS (location_id, donor_id, city, province, country, postal_code)
VALUES (locations_seq.NEXTVAL, 100, 'Lahore', 'Punjab', 'Pakistan', '54000');
COMMIT;

-- 6k. DONOR_PREFERENCES (every donor gets 1-3 category preferences)
INSERT INTO DONOR_PREFERENCES VALUES (1, 6);
INSERT INTO DONOR_PREFERENCES VALUES (1, 9);
INSERT INTO DONOR_PREFERENCES VALUES (2, 9);
INSERT INTO DONOR_PREFERENCES VALUES (2, 6);
INSERT INTO DONOR_PREFERENCES VALUES (3, 2);
INSERT INTO DONOR_PREFERENCES VALUES (4, 3);
INSERT INTO DONOR_PREFERENCES VALUES (4, 5);
INSERT INTO DONOR_PREFERENCES VALUES (5, 2);
INSERT INTO DONOR_PREFERENCES VALUES (6, 7);
INSERT INTO DONOR_PREFERENCES VALUES (6, 6);
INSERT INTO DONOR_PREFERENCES VALUES (6, 9);
INSERT INTO DONOR_PREFERENCES VALUES (7, 10);
INSERT INTO DONOR_PREFERENCES VALUES (7, 9);
INSERT INTO DONOR_PREFERENCES VALUES (8, 7);
INSERT INTO DONOR_PREFERENCES VALUES (9, 4);
INSERT INTO DONOR_PREFERENCES VALUES (9, 5);
INSERT INTO DONOR_PREFERENCES VALUES (9, 1);
INSERT INTO DONOR_PREFERENCES VALUES (10, 7);
INSERT INTO DONOR_PREFERENCES VALUES (10, 1);
INSERT INTO DONOR_PREFERENCES VALUES (10, 4);
INSERT INTO DONOR_PREFERENCES VALUES (11, 7);
INSERT INTO DONOR_PREFERENCES VALUES (11, 2);
INSERT INTO DONOR_PREFERENCES VALUES (12, 6);
INSERT INTO DONOR_PREFERENCES VALUES (12, 10);
INSERT INTO DONOR_PREFERENCES VALUES (12, 2);
INSERT INTO DONOR_PREFERENCES VALUES (13, 5);
INSERT INTO DONOR_PREFERENCES VALUES (13, 9);
INSERT INTO DONOR_PREFERENCES VALUES (13, 10);
INSERT INTO DONOR_PREFERENCES VALUES (14, 7);
INSERT INTO DONOR_PREFERENCES VALUES (14, 6);
INSERT INTO DONOR_PREFERENCES VALUES (14, 10);
INSERT INTO DONOR_PREFERENCES VALUES (15, 5);
INSERT INTO DONOR_PREFERENCES VALUES (15, 9);
INSERT INTO DONOR_PREFERENCES VALUES (15, 3);
INSERT INTO DONOR_PREFERENCES VALUES (16, 7);
INSERT INTO DONOR_PREFERENCES VALUES (17, 7);
INSERT INTO DONOR_PREFERENCES VALUES (17, 3);
INSERT INTO DONOR_PREFERENCES VALUES (17, 5);
INSERT INTO DONOR_PREFERENCES VALUES (18, 9);
INSERT INTO DONOR_PREFERENCES VALUES (18, 1);
INSERT INTO DONOR_PREFERENCES VALUES (19, 5);
INSERT INTO DONOR_PREFERENCES VALUES (19, 4);
INSERT INTO DONOR_PREFERENCES VALUES (20, 10);
INSERT INTO DONOR_PREFERENCES VALUES (20, 6);
INSERT INTO DONOR_PREFERENCES VALUES (21, 8);
INSERT INTO DONOR_PREFERENCES VALUES (21, 10);
INSERT INTO DONOR_PREFERENCES VALUES (22, 4);
INSERT INTO DONOR_PREFERENCES VALUES (22, 9);
INSERT INTO DONOR_PREFERENCES VALUES (22, 8);
INSERT INTO DONOR_PREFERENCES VALUES (23, 3);
INSERT INTO DONOR_PREFERENCES VALUES (23, 2);
INSERT INTO DONOR_PREFERENCES VALUES (23, 5);
INSERT INTO DONOR_PREFERENCES VALUES (24, 10);
INSERT INTO DONOR_PREFERENCES VALUES (24, 6);
INSERT INTO DONOR_PREFERENCES VALUES (24, 2);
INSERT INTO DONOR_PREFERENCES VALUES (25, 5);
INSERT INTO DONOR_PREFERENCES VALUES (26, 4);
INSERT INTO DONOR_PREFERENCES VALUES (27, 1);
INSERT INTO DONOR_PREFERENCES VALUES (28, 4);
INSERT INTO DONOR_PREFERENCES VALUES (29, 10);
INSERT INTO DONOR_PREFERENCES VALUES (29, 2);
INSERT INTO DONOR_PREFERENCES VALUES (30, 7);
INSERT INTO DONOR_PREFERENCES VALUES (30, 4);
INSERT INTO DONOR_PREFERENCES VALUES (31, 7);
INSERT INTO DONOR_PREFERENCES VALUES (31, 8);
INSERT INTO DONOR_PREFERENCES VALUES (31, 10);
INSERT INTO DONOR_PREFERENCES VALUES (32, 3);
INSERT INTO DONOR_PREFERENCES VALUES (33, 1);
INSERT INTO DONOR_PREFERENCES VALUES (33, 2);
INSERT INTO DONOR_PREFERENCES VALUES (33, 7);
INSERT INTO DONOR_PREFERENCES VALUES (34, 3);
INSERT INTO DONOR_PREFERENCES VALUES (35, 9);
INSERT INTO DONOR_PREFERENCES VALUES (35, 8);
INSERT INTO DONOR_PREFERENCES VALUES (35, 1);
INSERT INTO DONOR_PREFERENCES VALUES (36, 4);
INSERT INTO DONOR_PREFERENCES VALUES (36, 2);
INSERT INTO DONOR_PREFERENCES VALUES (36, 8);
INSERT INTO DONOR_PREFERENCES VALUES (37, 8);
INSERT INTO DONOR_PREFERENCES VALUES (38, 9);
INSERT INTO DONOR_PREFERENCES VALUES (38, 10);
INSERT INTO DONOR_PREFERENCES VALUES (38, 6);
INSERT INTO DONOR_PREFERENCES VALUES (39, 10);
INSERT INTO DONOR_PREFERENCES VALUES (39, 9);
INSERT INTO DONOR_PREFERENCES VALUES (40, 9);
INSERT INTO DONOR_PREFERENCES VALUES (40, 8);
INSERT INTO DONOR_PREFERENCES VALUES (41, 8);
INSERT INTO DONOR_PREFERENCES VALUES (42, 5);
INSERT INTO DONOR_PREFERENCES VALUES (42, 4);
INSERT INTO DONOR_PREFERENCES VALUES (43, 5);
INSERT INTO DONOR_PREFERENCES VALUES (43, 9);
INSERT INTO DONOR_PREFERENCES VALUES (43, 8);
INSERT INTO DONOR_PREFERENCES VALUES (44, 4);
INSERT INTO DONOR_PREFERENCES VALUES (44, 5);
INSERT INTO DONOR_PREFERENCES VALUES (44, 8);
INSERT INTO DONOR_PREFERENCES VALUES (45, 5);
INSERT INTO DONOR_PREFERENCES VALUES (46, 5);
INSERT INTO DONOR_PREFERENCES VALUES (47, 6);
INSERT INTO DONOR_PREFERENCES VALUES (47, 9);
INSERT INTO DONOR_PREFERENCES VALUES (48, 3);
INSERT INTO DONOR_PREFERENCES VALUES (49, 4);
INSERT INTO DONOR_PREFERENCES VALUES (50, 3);
INSERT INTO DONOR_PREFERENCES VALUES (50, 4);
INSERT INTO DONOR_PREFERENCES VALUES (51, 7);
INSERT INTO DONOR_PREFERENCES VALUES (52, 6);
INSERT INTO DONOR_PREFERENCES VALUES (52, 9);
INSERT INTO DONOR_PREFERENCES VALUES (53, 7);
INSERT INTO DONOR_PREFERENCES VALUES (53, 1);
INSERT INTO DONOR_PREFERENCES VALUES (54, 7);
INSERT INTO DONOR_PREFERENCES VALUES (55, 10);
INSERT INTO DONOR_PREFERENCES VALUES (55, 1);
INSERT INTO DONOR_PREFERENCES VALUES (56, 7);
INSERT INTO DONOR_PREFERENCES VALUES (56, 8);
INSERT INTO DONOR_PREFERENCES VALUES (56, 1);
INSERT INTO DONOR_PREFERENCES VALUES (57, 5);
INSERT INTO DONOR_PREFERENCES VALUES (57, 7);
INSERT INTO DONOR_PREFERENCES VALUES (58, 9);
INSERT INTO DONOR_PREFERENCES VALUES (58, 10);
INSERT INTO DONOR_PREFERENCES VALUES (59, 4);
INSERT INTO DONOR_PREFERENCES VALUES (59, 8);
INSERT INTO DONOR_PREFERENCES VALUES (59, 10);
INSERT INTO DONOR_PREFERENCES VALUES (60, 7);
INSERT INTO DONOR_PREFERENCES VALUES (60, 8);
INSERT INTO DONOR_PREFERENCES VALUES (61, 7);
INSERT INTO DONOR_PREFERENCES VALUES (62, 7);
INSERT INTO DONOR_PREFERENCES VALUES (62, 3);
INSERT INTO DONOR_PREFERENCES VALUES (63, 3);
INSERT INTO DONOR_PREFERENCES VALUES (63, 9);
INSERT INTO DONOR_PREFERENCES VALUES (64, 7);
INSERT INTO DONOR_PREFERENCES VALUES (65, 10);
INSERT INTO DONOR_PREFERENCES VALUES (65, 1);
INSERT INTO DONOR_PREFERENCES VALUES (65, 2);
INSERT INTO DONOR_PREFERENCES VALUES (66, 7);
INSERT INTO DONOR_PREFERENCES VALUES (66, 3);
INSERT INTO DONOR_PREFERENCES VALUES (66, 8);
INSERT INTO DONOR_PREFERENCES VALUES (67, 1);
INSERT INTO DONOR_PREFERENCES VALUES (68, 7);
INSERT INTO DONOR_PREFERENCES VALUES (68, 6);
INSERT INTO DONOR_PREFERENCES VALUES (69, 8);
INSERT INTO DONOR_PREFERENCES VALUES (70, 6);
INSERT INTO DONOR_PREFERENCES VALUES (70, 7);
INSERT INTO DONOR_PREFERENCES VALUES (71, 7);
INSERT INTO DONOR_PREFERENCES VALUES (71, 5);
INSERT INTO DONOR_PREFERENCES VALUES (72, 8);
INSERT INTO DONOR_PREFERENCES VALUES (73, 9);
INSERT INTO DONOR_PREFERENCES VALUES (74, 6);
INSERT INTO DONOR_PREFERENCES VALUES (75, 2);
INSERT INTO DONOR_PREFERENCES VALUES (76, 1);
INSERT INTO DONOR_PREFERENCES VALUES (76, 10);
INSERT INTO DONOR_PREFERENCES VALUES (76, 4);
INSERT INTO DONOR_PREFERENCES VALUES (77, 1);
INSERT INTO DONOR_PREFERENCES VALUES (78, 3);
INSERT INTO DONOR_PREFERENCES VALUES (78, 4);
INSERT INTO DONOR_PREFERENCES VALUES (78, 10);
INSERT INTO DONOR_PREFERENCES VALUES (79, 2);
INSERT INTO DONOR_PREFERENCES VALUES (79, 4);
INSERT INTO DONOR_PREFERENCES VALUES (80, 5);
INSERT INTO DONOR_PREFERENCES VALUES (80, 6);
INSERT INTO DONOR_PREFERENCES VALUES (81, 10);
INSERT INTO DONOR_PREFERENCES VALUES (82, 2);
INSERT INTO DONOR_PREFERENCES VALUES (82, 3);
INSERT INTO DONOR_PREFERENCES VALUES (82, 5);
INSERT INTO DONOR_PREFERENCES VALUES (83, 10);
INSERT INTO DONOR_PREFERENCES VALUES (84, 5);
INSERT INTO DONOR_PREFERENCES VALUES (85, 7);
INSERT INTO DONOR_PREFERENCES VALUES (85, 10);
INSERT INTO DONOR_PREFERENCES VALUES (85, 4);
INSERT INTO DONOR_PREFERENCES VALUES (86, 10);
INSERT INTO DONOR_PREFERENCES VALUES (87, 4);
INSERT INTO DONOR_PREFERENCES VALUES (87, 2);
INSERT INTO DONOR_PREFERENCES VALUES (87, 5);
INSERT INTO DONOR_PREFERENCES VALUES (88, 10);
INSERT INTO DONOR_PREFERENCES VALUES (88, 2);
INSERT INTO DONOR_PREFERENCES VALUES (88, 1);
INSERT INTO DONOR_PREFERENCES VALUES (89, 9);
INSERT INTO DONOR_PREFERENCES VALUES (89, 7);
INSERT INTO DONOR_PREFERENCES VALUES (90, 6);
INSERT INTO DONOR_PREFERENCES VALUES (90, 2);
INSERT INTO DONOR_PREFERENCES VALUES (90, 10);
INSERT INTO DONOR_PREFERENCES VALUES (91, 7);
INSERT INTO DONOR_PREFERENCES VALUES (92, 2);
INSERT INTO DONOR_PREFERENCES VALUES (92, 7);
INSERT INTO DONOR_PREFERENCES VALUES (93, 8);
INSERT INTO DONOR_PREFERENCES VALUES (93, 3);
INSERT INTO DONOR_PREFERENCES VALUES (94, 3);
INSERT INTO DONOR_PREFERENCES VALUES (94, 9);
INSERT INTO DONOR_PREFERENCES VALUES (95, 5);
INSERT INTO DONOR_PREFERENCES VALUES (95, 9);
INSERT INTO DONOR_PREFERENCES VALUES (95, 8);
INSERT INTO DONOR_PREFERENCES VALUES (96, 7);
INSERT INTO DONOR_PREFERENCES VALUES (96, 5);
INSERT INTO DONOR_PREFERENCES VALUES (97, 4);
INSERT INTO DONOR_PREFERENCES VALUES (97, 2);
INSERT INTO DONOR_PREFERENCES VALUES (98, 8);
INSERT INTO DONOR_PREFERENCES VALUES (98, 4);
INSERT INTO DONOR_PREFERENCES VALUES (99, 10);
INSERT INTO DONOR_PREFERENCES VALUES (99, 7);
INSERT INTO DONOR_PREFERENCES VALUES (100, 1);
INSERT INTO DONOR_PREFERENCES VALUES (100, 8);
COMMIT;

-- 6l. DOCUMENTS (approved + rejected NGOs only)
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 1, '/uploads/edhi_foundation_doc1.pdf', 'Registration Certificate', SYSDATE - 171);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 1, '/uploads/edhi_foundation_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 98);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 2, '/uploads/shaukat_khanum_memor_doc1.pdf', 'Registration Certificate', SYSDATE - 254);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 2, '/uploads/shaukat_khanum_memor_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 113);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 3, '/uploads/the_citizen_foundati_doc1.pdf', 'Registration Certificate', SYSDATE - 186);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 3, '/uploads/the_citizen_foundati_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 137);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 4, '/uploads/layton_rahmatulla_be_doc1.pdf', 'Registration Certificate', SYSDATE - 179);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 4, '/uploads/layton_rahmatulla_be_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 148);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 5, '/uploads/akhuwat_foundation_doc1.pdf', 'Registration Certificate', SYSDATE - 146);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 5, '/uploads/akhuwat_foundation_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 289);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 6, '/uploads/sungi_development_fo_doc1.pdf', 'Registration Certificate', SYSDATE - 10);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 6, '/uploads/sungi_development_fo_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 269);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 7, '/uploads/indus_hospital_doc1.pdf', 'Registration Certificate', SYSDATE - 102);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 7, '/uploads/indus_hospital_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 48);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 8, '/uploads/saylani_welfare_trus_doc1.pdf', 'Registration Certificate', SYSDATE - 128);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 8, '/uploads/saylani_welfare_trus_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 213);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 9, '/uploads/khidmat_foundation_doc1.pdf', 'Registration Certificate', SYSDATE - 255);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 9, '/uploads/khidmat_foundation_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 289);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 10, '/uploads/pakistan_poverty_all_doc1.pdf', 'Registration Certificate', SYSDATE - 128);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 10, '/uploads/pakistan_poverty_all_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 248);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 11, '/uploads/chippa_welfare_assoc_doc1.pdf', 'Registration Certificate', SYSDATE - 256);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 11, '/uploads/chippa_welfare_assoc_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 234);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 12, '/uploads/ansar_burney_trust_doc1.pdf', 'Registration Certificate', SYSDATE - 13);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 12, '/uploads/ansar_burney_trust_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 52);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 13, '/uploads/pakistan_sweet_home_doc1.pdf', 'Registration Certificate', SYSDATE - 155);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 13, '/uploads/pakistan_sweet_home_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 118);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 14, '/uploads/hunar_foundation_doc1.pdf', 'Registration Certificate', SYSDATE - 212);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 14, '/uploads/hunar_foundation_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 129);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 15, '/uploads/tcf_—_teacher_traini_doc1.pdf', 'Registration Certificate', SYSDATE - 161);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 15, '/uploads/tcf_—_teacher_traini_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 193);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 16, '/uploads/umang_pakistan_doc1.pdf', 'Registration Certificate', SYSDATE - 247);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 16, '/uploads/umang_pakistan_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 288);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 17, '/uploads/greenstar_social_mar_doc1.pdf', 'Registration Certificate', SYSDATE - 276);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 17, '/uploads/greenstar_social_mar_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 181);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 18, '/uploads/sos_children_village_doc1.pdf', 'Registration Certificate', SYSDATE - 222);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 18, '/uploads/sos_children_village_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 286);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 19, '/uploads/transparent_hands_doc1.pdf', 'Registration Certificate', SYSDATE - 174);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 19, '/uploads/transparent_hands_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 185);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 20, '/uploads/rizq_foundation_doc1.pdf', 'Registration Certificate', SYSDATE - 237);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 20, '/uploads/rizq_foundation_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 143);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 21, '/uploads/hope_welfare_trust_doc1.pdf', 'Registration Certificate', SYSDATE - 161);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 21, '/uploads/hope_welfare_trust_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 133);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 22, '/uploads/imkaan_welfare_organ_doc1.pdf', 'Registration Certificate', SYSDATE - 123);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 22, '/uploads/imkaan_welfare_organ_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 66);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 23, '/uploads/aware_girls_doc1.pdf', 'Registration Certificate', SYSDATE - 103);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 23, '/uploads/aware_girls_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 166);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 24, '/uploads/strengthening_partic_doc1.pdf', 'Registration Certificate', SYSDATE - 66);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 24, '/uploads/strengthening_partic_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 279);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 25, '/uploads/lead_pakistan_doc1.pdf', 'Registration Certificate', SYSDATE - 99);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 25, '/uploads/lead_pakistan_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 103);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 26, '/uploads/wwf_pakistan_doc1.pdf', 'Registration Certificate', SYSDATE - 115);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 26, '/uploads/wwf_pakistan_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 252);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 27, '/uploads/agha_khan_foundation_doc1.pdf', 'Registration Certificate', SYSDATE - 146);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 27, '/uploads/agha_khan_foundation_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 273);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 28, '/uploads/human_development_fo_doc1.pdf', 'Registration Certificate', SYSDATE - 149);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 28, '/uploads/human_development_fo_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 56);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 29, '/uploads/aurat_foundation_doc1.pdf', 'Registration Certificate', SYSDATE - 104);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 29, '/uploads/aurat_foundation_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 156);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 30, '/uploads/rabta_foundation_doc1.pdf', 'Registration Certificate', SYSDATE - 121);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 30, '/uploads/rabta_foundation_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 189);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 31, '/uploads/sahara_for_life_trus_doc1.pdf', 'Registration Certificate', SYSDATE - 96);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 31, '/uploads/sahara_for_life_trus_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 159);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 32, '/uploads/pakistan_animal_welf_doc1.pdf', 'Registration Certificate', SYSDATE - 12);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 32, '/uploads/pakistan_animal_welf_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 278);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 33, '/uploads/fauget_(animal_aid)_doc1.pdf', 'Registration Certificate', SYSDATE - 69);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 33, '/uploads/fauget_(animal_aid)_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 145);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 34, '/uploads/disaster_response_ne_doc1.pdf', 'Registration Certificate', SYSDATE - 28);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 34, '/uploads/disaster_response_ne_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 32);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 35, '/uploads/childrens_global_net_doc1.pdf', 'Registration Certificate', SYSDATE - 288);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 35, '/uploads/childrens_global_net_doc2.pdf', 'Tax Exemption Letter', SYSDATE - 154);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 36, '/uploads/al-khadim_welfare_tr_doc1.pdf', 'Registration Certificate', SYSDATE - 69);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 37, '/uploads/noor_welfare_society_doc1.pdf', 'Registration Certificate', SYSDATE - 256);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 38, '/uploads/green_earth_initiati_doc1.pdf', 'Registration Certificate', SYSDATE - 57);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 39, '/uploads/youth_uplift_foundat_doc1.pdf', 'Registration Certificate', SYSDATE - 11);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 40, '/uploads/ghar_basao_trust_doc1.pdf', 'Registration Certificate', SYSDATE - 298);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 41, '/uploads/roshni_gharana_doc1.pdf', 'Registration Certificate', SYSDATE - 150);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 42, '/uploads/clean_karachi_moveme_doc1.pdf', 'Registration Certificate', SYSDATE - 245);
INSERT INTO DOCUMENTS (doc_id, ngo_id, file_path, doc_type, uploaded_at)
VALUES (documents_seq.NEXTVAL, 43, '/uploads/bahawalpur_relief_ai_doc1.pdf', 'Registration Certificate', SYSDATE - 250);
COMMIT;

-- 6m. VERIFICATION_LOG (admin approves/rejects all non-pending NGOs)
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 1, 1, 'approved', 'All documents verified and in order.', SYSDATE - 113);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 2, 1, 'approved', 'Verified reputable institution with clean audit.', SYSDATE - 88);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 3, 1, 'approved', 'Registration and tax documents confirmed.', SYSDATE - 48);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 4, 1, 'approved', 'Board resolution and bank statement validated.', SYSDATE - 248);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 5, 1, 'approved', 'Field visit confirmed active operations.', SYSDATE - 14);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 6, 1, 'approved', 'Documents cross-checked with SECP database.', SYSDATE - 65);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 7, 1, 'approved', 'Recommended by two reference NGOs.', SYSDATE - 241);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 8, 1, 'approved', 'All documents verified and in order.', SYSDATE - 221);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 9, 1, 'approved', 'Verified reputable institution with clean audit.', SYSDATE - 123);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 10, 1, 'approved', 'Registration and tax documents confirmed.', SYSDATE - 30);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 11, 1, 'approved', 'Board resolution and bank statement validated.', SYSDATE - 211);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 12, 1, 'approved', 'Field visit confirmed active operations.', SYSDATE - 17);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 13, 1, 'approved', 'Documents cross-checked with SECP database.', SYSDATE - 103);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 14, 1, 'approved', 'Recommended by two reference NGOs.', SYSDATE - 126);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 15, 1, 'approved', 'All documents verified and in order.', SYSDATE - 19);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 16, 1, 'approved', 'Verified reputable institution with clean audit.', SYSDATE - 148);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 17, 1, 'approved', 'Registration and tax documents confirmed.', SYSDATE - 162);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 18, 1, 'approved', 'Board resolution and bank statement validated.', SYSDATE - 176);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 19, 1, 'approved', 'Field visit confirmed active operations.', SYSDATE - 14);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 20, 1, 'approved', 'Documents cross-checked with SECP database.', SYSDATE - 39);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 21, 1, 'approved', 'Recommended by two reference NGOs.', SYSDATE - 39);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 22, 1, 'approved', 'All documents verified and in order.', SYSDATE - 208);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 23, 1, 'approved', 'Verified reputable institution with clean audit.', SYSDATE - 145);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 24, 1, 'approved', 'Registration and tax documents confirmed.', SYSDATE - 243);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 25, 1, 'approved', 'Board resolution and bank statement validated.', SYSDATE - 78);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 26, 1, 'approved', 'Field visit confirmed active operations.', SYSDATE - 22);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 27, 1, 'approved', 'Documents cross-checked with SECP database.', SYSDATE - 64);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 28, 1, 'approved', 'Recommended by two reference NGOs.', SYSDATE - 31);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 29, 1, 'approved', 'All documents verified and in order.', SYSDATE - 143);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 30, 1, 'approved', 'Verified reputable institution with clean audit.', SYSDATE - 196);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 31, 1, 'approved', 'Registration and tax documents confirmed.', SYSDATE - 107);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 32, 1, 'approved', 'Board resolution and bank statement validated.', SYSDATE - 156);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 33, 1, 'approved', 'Field visit confirmed active operations.', SYSDATE - 153);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 34, 1, 'approved', 'Documents cross-checked with SECP database.', SYSDATE - 203);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 35, 1, 'approved', 'Recommended by two reference NGOs.', SYSDATE - 159);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 36, 1, 'rejected', 'Registration certificate expired or unverifiable.', SYSDATE - 58);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 37, 1, 'rejected', 'Bank statement mismatch with stated financials.', SYSDATE - 199);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 38, 1, 'rejected', 'Director information inconsistent across documents.', SYSDATE - 134);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 39, 1, 'rejected', 'Duplicate application detected in the system.', SYSDATE - 98);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 40, 1, 'rejected', 'Tax exemption letter not authenticated.', SYSDATE - 116);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 41, 1, 'rejected', 'Missing memorandum of association.', SYSDATE - 114);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 42, 1, 'rejected', 'Field address could not be verified.', SYSDATE - 77);
INSERT INTO VERIFICATION_LOG (log_id, ngo_id, admin_id, action, remarks, actioned_at)
VALUES (verif_log_seq.NEXTVAL, 43, 1, 'rejected', 'Unresolved complaints filed against this entity.', SYSDATE - 151);
COMMIT;

-- 6n. NEEDS (approved NGOs only, 2-4 needs each; some fulfilled/closed)
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 1, 3, 'Flood Relief Supplies', 'Blankets, dry rations, and clean water for flood-affected families.', 'high', 500, 'open', SYSDATE - 26);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 1, 1, 'Mental Health Counselling Fund', 'Sponsor counselling sessions for trauma and anxiety patients.', 'medium', 40, 'closed', SYSDATE - 170);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 1, 1, 'Medicine Fund', 'Antibiotics and essential medicines for underprivileged patients.', 'high', 200, 'closed', SYSDATE - 142);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 2, 1, 'Medical Supplies Drive', 'Surgical gloves, masks, and first-aid kits for rural clinics.', 'high', 500, 'open', SYSDATE - 177);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 2, 1, 'Blood Drive Campaign', 'Seeking voluntary blood donors for hospital blood bank replenishment.', 'medium', 100, 'fulfilled', SYSDATE - 74);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 3, 9, 'Child Nutrition Packs', 'Fortified milk and biscuit packs for malnourished children under five.', 'medium', 350, 'open', SYSDATE - 19);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 3, 2, 'Library Books Donation', 'Textbooks and storybooks to stock three school libraries.', 'low', 200, 'open', SYSDATE - 161);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 3, 2, 'Scholarship Fund', 'Monthly stipends for 20 meritorious but financially weak students.', 'high', 20, 'fulfilled', SYSDATE - 58);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 3, 2, 'Library Books Donation', 'Textbooks and storybooks to stock three school libraries.', 'low', 200, 'open', SYSDATE - 19);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 4, 1, 'Blood Drive Campaign', 'Seeking voluntary blood donors for hospital blood bank replenishment.', 'medium', 100, 'open', SYSDATE - 146);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 4, 1, 'Wheelchair Donation', 'Manual wheelchairs for mobility-impaired patients in rehab centres.', 'medium', 50, 'fulfilled', SYSDATE - 177);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 5, 6, 'Vocational Training Batch', 'Sponsor a 3-month beauty and wellness course for 30 unemployed women.', 'high', 30, 'open', SYSDATE - 127);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 5, 6, 'Stitching and Tailoring Kits', 'Provide complete sewing kits to 80 women starting home-based enterprises.', 'medium', 80, 'open', SYSDATE - 111);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 5, 6, 'Legal Aid Fund', 'Cover legal fees for women seeking protection orders or divorce proceedings.', 'medium', 20, 'closed', SYSDATE - 24);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 6, 8, 'Eid Hamper Distribution', '500 gift hampers for families below the poverty line at Eid.', 'medium', 500, 'open', SYSDATE - 6);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 6, 8, 'Skills Training for Youth', 'Enrol 40 at-risk youth in certified vocational trades.', 'medium', 40, 'open', SYSDATE - 45);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 7, 1, 'Blood Drive Campaign', 'Seeking voluntary blood donors for hospital blood bank replenishment.', 'medium', 100, 'fulfilled', SYSDATE - 150);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 7, 1, 'Mental Health Counselling Fund', 'Sponsor counselling sessions for trauma and anxiety patients.', 'medium', 40, 'open', SYSDATE - 24);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 7, 1, 'Blood Drive Campaign', 'Seeking voluntary blood donors for hospital blood bank replenishment.', 'medium', 100, 'open', SYSDATE - 83);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 8, 4, 'Ramadan Food Parcels', 'Monthly ration bags for 200 low-income families throughout Ramadan.', 'high', 200, 'open', SYSDATE - 178);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 8, 8, 'Skills Training for Youth', 'Enrol 40 at-risk youth in certified vocational trades.', 'medium', 40, 'open', SYSDATE - 103);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 8, 1, 'Medical Supplies Drive', 'Surgical gloves, masks, and first-aid kits for rural clinics.', 'high', 500, 'open', SYSDATE - 81);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 8, 8, 'Skills Training for Youth', 'Enrol 40 at-risk youth in certified vocational trades.', 'medium', 40, 'fulfilled', SYSDATE - 104);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 9, 3, 'Earthquake Debris Clearance', 'Equipment and manpower to clear rubble and restore access roads.', 'medium', 100, 'open', SYSDATE - 49);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 9, 4, 'Food Rescue Boxes', 'Collect surplus food from restaurants for redistribution to shelters.', 'low', 300, 'open', SYSDATE - 161);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 9, 4, 'Ramadan Food Parcels', 'Monthly ration bags for 200 low-income families throughout Ramadan.', 'high', 200, 'closed', SYSDATE - 141);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 9, 3, 'Rescue Boat Fuel Fund', 'Diesel for rescue boats operating in flooded inland districts.', 'high', 50, 'open', SYSDATE - 179);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 10, 8, 'Microloan Seed Fund', 'Seed capital for interest-free loans to 50 small business owners.', 'high', 50, 'open', SYSDATE - 156);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 10, 8, 'Eid Hamper Distribution', '500 gift hampers for families below the poverty line at Eid.', 'medium', 500, 'fulfilled', SYSDATE - 142);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 10, 8, 'Eid Hamper Distribution', '500 gift hampers for families below the poverty line at Eid.', 'medium', 500, 'open', SYSDATE - 58);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 11, 3, 'Flood Relief Supplies', 'Blankets, dry rations, and clean water for flood-affected families.', 'high', 500, 'open', SYSDATE - 40);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 11, 3, 'Rescue Boat Fuel Fund', 'Diesel for rescue boats operating in flooded inland districts.', 'high', 50, 'open', SYSDATE - 70);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 12, 1, 'Wheelchair Donation', 'Manual wheelchairs for mobility-impaired patients in rehab centres.', 'medium', 50, 'closed', SYSDATE - 142);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 12, 9, 'Orphan Sponsorship Programme', 'Monthly sponsorships covering food, education, and healthcare for orphans.', 'high', 60, 'fulfilled', SYSDATE - 154);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 12, 9, 'Winter Clothing Drive', 'Warm jackets, socks, and caps for 400 children in rural communities.', 'high', 400, 'closed', SYSDATE - 107);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 13, 5, 'Refugee Family Housing', 'Temporary housing units for 25 refugee families displaced by conflict.', 'high', 25, 'open', SYSDATE - 73);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 13, 5, 'Refugee Family Housing', 'Temporary housing units for 25 refugee families displaced by conflict.', 'high', 25, 'open', SYSDATE - 149);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 13, 5, 'Refugee Family Housing', 'Temporary housing units for 25 refugee families displaced by conflict.', 'high', 25, 'open', SYSDATE - 115);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 14, 8, 'Skills Training for Youth', 'Enrol 40 at-risk youth in certified vocational trades.', 'medium', 40, 'open', SYSDATE - 140);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 14, 8, 'Skills Training for Youth', 'Enrol 40 at-risk youth in certified vocational trades.', 'medium', 40, 'open', SYSDATE - 49);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 14, 2, 'Computer Lab Equipment', 'Refurbished PCs and UPS units for a computer literacy lab.', 'medium', 25, 'open', SYSDATE - 106);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 14, 2, 'Library Books Donation', 'Textbooks and storybooks to stock three school libraries.', 'low', 200, 'open', SYSDATE - 98);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 15, 2, 'Scholarship Fund', 'Monthly stipends for 20 meritorious but financially weak students.', 'high', 20, 'open', SYSDATE - 33);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 15, 2, 'School Stationery Drive', 'Notebooks, pencils, and geometry sets for 300 primary students.', 'medium', 300, 'open', SYSDATE - 113);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 15, 2, 'Computer Lab Equipment', 'Refurbished PCs and UPS units for a computer literacy lab.', 'medium', 25, 'open', SYSDATE - 4);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 16, 1, 'Wheelchair Donation', 'Manual wheelchairs for mobility-impaired patients in rehab centres.', 'medium', 50, 'open', SYSDATE - 40);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 16, 1, 'Wheelchair Donation', 'Manual wheelchairs for mobility-impaired patients in rehab centres.', 'medium', 50, 'open', SYSDATE - 68);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 16, 1, 'Cancer Medication Fund', 'Chemotherapy drugs for 30 patients who cannot afford treatment.', 'high', 30, 'open', SYSDATE - 167);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 16, 1, 'Blood Drive Campaign', 'Seeking voluntary blood donors for hospital blood bank replenishment.', 'medium', 100, 'open', SYSDATE - 137);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 17, 6, 'Legal Aid Fund', 'Cover legal fees for women seeking protection orders or divorce proceedings.', 'medium', 20, 'open', SYSDATE - 125);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 17, 1, 'Cancer Medication Fund', 'Chemotherapy drugs for 30 patients who cannot afford treatment.', 'high', 30, 'fulfilled', SYSDATE - 162);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 17, 6, 'Stitching and Tailoring Kits', 'Provide complete sewing kits to 80 women starting home-based enterprises.', 'medium', 80, 'open', SYSDATE - 112);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 18, 9, 'Orphan Sponsorship Programme', 'Monthly sponsorships covering food, education, and healthcare for orphans.', 'high', 60, 'fulfilled', SYSDATE - 77);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 18, 9, 'Winter Clothing Drive', 'Warm jackets, socks, and caps for 400 children in rural communities.', 'high', 400, 'open', SYSDATE - 15);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 19, 1, 'Blood Drive Campaign', 'Seeking voluntary blood donors for hospital blood bank replenishment.', 'medium', 100, 'open', SYSDATE - 63);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 19, 1, 'Cancer Medication Fund', 'Chemotherapy drugs for 30 patients who cannot afford treatment.', 'high', 30, 'open', SYSDATE - 47);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 19, 1, 'Medicine Fund', 'Antibiotics and essential medicines for underprivileged patients.', 'high', 200, 'fulfilled', SYSDATE - 98);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 20, 4, 'Daily Langar Programme', 'Sponsor hot meals served at a community kitchen for 500 people daily.', 'medium', 500, 'open', SYSDATE - 37);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 20, 4, 'Daily Langar Programme', 'Sponsor hot meals served at a community kitchen for 500 people daily.', 'medium', 500, 'open', SYSDATE - 118);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 20, 4, 'Food Rescue Boxes', 'Collect surplus food from restaurants for redistribution to shelters.', 'low', 300, 'fulfilled', SYSDATE - 120);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 20, 4, 'Food Rescue Boxes', 'Collect surplus food from restaurants for redistribution to shelters.', 'low', 300, 'open', SYSDATE - 19);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 21, 2, 'Computer Lab Equipment', 'Refurbished PCs and UPS units for a computer literacy lab.', 'medium', 25, 'closed', SYSDATE - 109);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 21, 8, 'Skills Training for Youth', 'Enrol 40 at-risk youth in certified vocational trades.', 'medium', 40, 'open', SYSDATE - 78);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 21, 1, 'Wheelchair Donation', 'Manual wheelchairs for mobility-impaired patients in rehab centres.', 'medium', 50, 'open', SYSDATE - 28);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 22, 8, 'Eid Hamper Distribution', '500 gift hampers for families below the poverty line at Eid.', 'medium', 500, 'open', SYSDATE - 76);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 22, 8, 'Microloan Seed Fund', 'Seed capital for interest-free loans to 50 small business owners.', 'high', 50, 'open', SYSDATE - 169);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 23, 6, 'Stitching and Tailoring Kits', 'Provide complete sewing kits to 80 women starting home-based enterprises.', 'medium', 80, 'open', SYSDATE - 176);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 23, 6, 'Legal Aid Fund', 'Cover legal fees for women seeking protection orders or divorce proceedings.', 'medium', 20, 'open', SYSDATE - 74);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 23, 6, 'Legal Aid Fund', 'Cover legal fees for women seeking protection orders or divorce proceedings.', 'medium', 20, 'open', SYSDATE - 57);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 24, 8, 'Eid Hamper Distribution', '500 gift hampers for families below the poverty line at Eid.', 'medium', 500, 'closed', SYSDATE - 169);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 24, 8, 'Eid Hamper Distribution', '500 gift hampers for families below the poverty line at Eid.', 'medium', 500, 'fulfilled', SYSDATE - 161);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 24, 8, 'Skills Training for Youth', 'Enrol 40 at-risk youth in certified vocational trades.', 'medium', 40, 'open', SYSDATE - 9);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 24, 7, 'Plastic Waste Collection', 'Community plastic drive targeting 2 tonnes of recyclable waste monthly.', 'low', 2000, 'fulfilled', SYSDATE - 76);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 25, 7, 'Tree Plantation Drive', 'Plant 5,000 native saplings in degraded watershed areas.', 'low', 5000, 'closed', SYSDATE - 139);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 25, 7, 'Plastic Waste Collection', 'Community plastic drive targeting 2 tonnes of recyclable waste monthly.', 'low', 2000, 'open', SYSDATE - 70);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 25, 7, 'Solar Panel Installation', 'Install solar panels at 10 community schools to reduce carbon footprint.', 'medium', 10, 'open', SYSDATE - 124);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 26, 10, 'Animal Rescue Van Fuel', 'Monthly fuel fund for a 24/7 animal rescue vehicle in the city.', 'medium', 1, 'open', SYSDATE - 20);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 26, 7, 'Tree Plantation Drive', 'Plant 5,000 native saplings in degraded watershed areas.', 'low', 5000, 'open', SYSDATE - 173);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 26, 10, 'Shelter Dog Food Drive', 'Dry kibble and wet food for 300 dogs at a municipal animal shelter.', 'medium', 300, 'open', SYSDATE - 102);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 27, 2, 'Computer Lab Equipment', 'Refurbished PCs and UPS units for a computer literacy lab.', 'medium', 25, 'fulfilled', SYSDATE - 95);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 27, 8, 'Eid Hamper Distribution', '500 gift hampers for families below the poverty line at Eid.', 'medium', 500, 'open', SYSDATE - 150);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 28, 8, 'Skills Training for Youth', 'Enrol 40 at-risk youth in certified vocational trades.', 'medium', 40, 'fulfilled', SYSDATE - 60);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 28, 1, 'Medical Supplies Drive', 'Surgical gloves, masks, and first-aid kits for rural clinics.', 'high', 500, 'open', SYSDATE - 144);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 28, 1, 'Cancer Medication Fund', 'Chemotherapy drugs for 30 patients who cannot afford treatment.', 'high', 30, 'closed', SYSDATE - 17);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 29, 6, 'Legal Aid Fund', 'Cover legal fees for women seeking protection orders or divorce proceedings.', 'medium', 20, 'open', SYSDATE - 105);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 29, 6, 'Stitching and Tailoring Kits', 'Provide complete sewing kits to 80 women starting home-based enterprises.', 'medium', 80, 'fulfilled', SYSDATE - 10);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 29, 6, 'Vocational Training Batch', 'Sponsor a 3-month beauty and wellness course for 30 unemployed women.', 'high', 30, 'fulfilled', SYSDATE - 61);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 29, 6, 'Vocational Training Batch', 'Sponsor a 3-month beauty and wellness course for 30 unemployed women.', 'high', 30, 'open', SYSDATE - 172);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 30, 1, 'Cancer Medication Fund', 'Chemotherapy drugs for 30 patients who cannot afford treatment.', 'high', 30, 'open', SYSDATE - 40);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 30, 1, 'Mental Health Counselling Fund', 'Sponsor counselling sessions for trauma and anxiety patients.', 'medium', 40, 'fulfilled', SYSDATE - 126);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 30, 1, 'Blood Drive Campaign', 'Seeking voluntary blood donors for hospital blood bank replenishment.', 'medium', 100, 'fulfilled', SYSDATE - 95);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 30, 1, 'Wheelchair Donation', 'Manual wheelchairs for mobility-impaired patients in rehab centres.', 'medium', 50, 'open', SYSDATE - 61);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 31, 1, 'Mental Health Counselling Fund', 'Sponsor counselling sessions for trauma and anxiety patients.', 'medium', 40, 'open', SYSDATE - 166);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 31, 1, 'Medical Supplies Drive', 'Surgical gloves, masks, and first-aid kits for rural clinics.', 'high', 500, 'open', SYSDATE - 49);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 31, 1, 'Wheelchair Donation', 'Manual wheelchairs for mobility-impaired patients in rehab centres.', 'medium', 50, 'fulfilled', SYSDATE - 55);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 32, 10, 'Animal Rescue Van Fuel', 'Monthly fuel fund for a 24/7 animal rescue vehicle in the city.', 'medium', 1, 'open', SYSDATE - 63);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 32, 10, 'Shelter Dog Food Drive', 'Dry kibble and wet food for 300 dogs at a municipal animal shelter.', 'medium', 300, 'closed', SYSDATE - 142);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 32, 10, 'Shelter Dog Food Drive', 'Dry kibble and wet food for 300 dogs at a municipal animal shelter.', 'medium', 300, 'closed', SYSDATE - 60);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 32, 10, 'Animal Rescue Van Fuel', 'Monthly fuel fund for a 24/7 animal rescue vehicle in the city.', 'medium', 1, 'open', SYSDATE - 153);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 33, 10, 'Animal Rescue Van Fuel', 'Monthly fuel fund for a 24/7 animal rescue vehicle in the city.', 'medium', 1, 'open', SYSDATE - 139);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 33, 10, 'Animal Rescue Van Fuel', 'Monthly fuel fund for a 24/7 animal rescue vehicle in the city.', 'medium', 1, 'fulfilled', SYSDATE - 7);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 34, 3, 'Rescue Boat Fuel Fund', 'Diesel for rescue boats operating in flooded inland districts.', 'high', 50, 'open', SYSDATE - 61);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 34, 3, 'Flood Relief Supplies', 'Blankets, dry rations, and clean water for flood-affected families.', 'high', 500, 'fulfilled', SYSDATE - 14);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 35, 4, 'Daily Langar Programme', 'Sponsor hot meals served at a community kitchen for 500 people daily.', 'medium', 500, 'open', SYSDATE - 17);
INSERT INTO NEEDS (need_id, ngo_id, category_id, title, description, urgency_level, target_quantity, status, created_at)
VALUES (needs_seq.NEXTVAL, 35, 2, 'Scholarship Fund', 'Monthly stipends for 20 meritorious but financially weak students.', 'high', 20, 'open', SYSDATE - 132);
COMMIT;

-- 6o. DONATIONS (donors commit to open/fulfilled needs)
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 1, 65, 22, '5 Eid hampers', 2500, 'cancelled', SYSDATE - 6);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 2, 66, 22, 'Seed capital PKR 25000', 15000, 'completed', SYSDATE - 55);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 2, 93, 31, 'Sponsor 2 counselling sessions', 0, 'completed', SYSDATE - 92);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 2, 6, 3, 'Orphan monthly sponsorship PKR 5000', 0, 'committed', SYSDATE - 42);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 3, 11, 4, 'Contribution to medicine fund', 50000, 'cancelled', SYSDATE - 71);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 3, 20, 8, '20 food rescue boxes', 7500, 'completed', SYSDATE - 77);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 4, 66, 22, 'Enrol 2 youth in skills training', 0, 'committed', SYSDATE - 110);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 4, 73, 24, 'Plastic bags for waste drive', 25000, 'committed', SYSDATE - 56);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 4, 88, 29, 'Sponsor 3 women in vocational course', 2500, 'completed', SYSDATE - 44);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 5, 58, 20, 'Sponsor meals for 50 people for 3 days', 7500, 'committed', SYSDATE - 48);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 5, 60, 20, '10 ration bags', 15000, 'committed', SYSDATE - 12);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 5, 16, 6, 'Seed capital PKR 25000', 0, 'completed', SYSDATE - 13);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 5, 47, 16, 'Sponsor 2 counselling sessions', 7500, 'committed', SYSDATE - 72);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 6, 86, 29, 'Legal fee contribution', 25000, 'committed', SYSDATE - 86);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 7, 59, 20, 'Sponsor meals for 50 people for 3 days', 10000, 'committed', SYSDATE - 37);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 8, 52, 17, 'Legal fee contribution', 2500, 'committed', SYSDATE - 85);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 8, 17, 7, '5 wheelchairs', 2500, 'committed', SYSDATE - 45);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 8, 83, 28, 'Blood donation — O+ type', 7500, 'committed', SYSDATE - 98);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 9, 83, 28, 'Blood donation — O+ type', 50000, 'cancelled', SYSDATE - 87);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 9, 34, 12, '50 nutrition packs', 25000, 'committed', SYSDATE - 78);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 9, 61, 20, '20 food rescue boxes', 5000, 'committed', SYSDATE - 24);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 10, 102, 34, 'Fuel for rescue boats', 0, 'committed', SYSDATE - 112);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 10, 46, 16, '20 first-aid kits', 50000, 'completed', SYSDATE - 9);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 10, 50, 17, '5 stitching kits', 0, 'committed', SYSDATE - 96);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 11, 55, 19, '5 wheelchairs', 7500, 'committed', SYSDATE - 48);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 11, 60, 20, 'Sponsor meals for 50 people for 3 days', 7500, 'cancelled', SYSDATE - 77);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 12, 9, 3, 'Sponsor 1 teacher training', 0, 'cancelled', SYSDATE - 7);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 13, 41, 14, 'Monthly stipend for 2 students', 10000, 'completed', SYSDATE - 78);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 14, 60, 20, '10 ration bags', 7500, 'completed', SYSDATE - 15);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 14, 41, 14, '30 storybooks', 50000, 'completed', SYSDATE - 68);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 14, 32, 11, 'Fuel for rescue boats', 0, 'committed', SYSDATE - 51);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 14, 75, 25, 'Plastic bags for waste drive', 0, 'committed', SYSDATE - 27);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 15, 32, 11, 'Fuel for rescue boats', 7500, 'committed', SYSDATE - 1);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 15, 21, 8, 'Enrol 2 youth in skills training', 10000, 'committed', SYSDATE - 17);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 15, 39, 14, 'Enrol 2 youth in skills training', 25000, 'committed', SYSDATE - 65);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 16, 12, 5, 'Sponsor 3 women in vocational course', 0, 'completed', SYSDATE - 118);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 16, 57, 19, '50 surgical gloves boxes', 7500, 'cancelled', SYSDATE - 55);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 16, 8, 3, '1 refurbished PC', 10000, 'completed', SYSDATE - 38);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 17, 58, 20, '10 ration bags', 7500, 'committed', SYSDATE - 103);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 18, 101, 33, 'Fuel fund PKR 10000', 2500, 'completed', SYSDATE - 76);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 18, 53, 18, 'Orphan monthly sponsorship PKR 5000', 25000, 'committed', SYSDATE - 51);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 18, 15, 6, 'Enrol 2 youth in skills training', 7500, 'committed', SYSDATE - 43);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 18, 63, 21, 'Seed capital PKR 25000', 0, 'cancelled', SYSDATE - 82);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 19, 77, 26, '50 kg dry dog food', 2500, 'committed', SYSDATE - 45);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 20, 37, 13, 'Shelter repair materials', 5000, 'committed', SYSDATE - 23);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 20, 17, 7, 'Blood donation — O+ type', 0, 'committed', SYSDATE - 23);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 21, 67, 23, 'Legal fee contribution', 50000, 'cancelled', SYSDATE - 42);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 21, 82, 28, '5 Eid hampers', 7500, 'committed', SYSDATE - 57);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 21, 85, 29, '5 stitching kits', 15000, 'completed', SYSDATE - 81);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 21, 65, 22, 'Enrol 2 youth in skills training', 5000, 'cancelled', SYSDATE - 8);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 22, 73, 24, 'Solar panel donation', 15000, 'committed', SYSDATE - 8);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 22, 12, 5, 'Sponsor 3 women in vocational course', 5000, 'committed', SYSDATE - 83);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 22, 46, 16, '50 surgical gloves boxes', 50000, 'cancelled', SYSDATE - 65);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 23, 67, 23, 'Sponsor 3 women in vocational course', 50000, 'committed', SYSDATE - 42);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 23, 85, 29, 'Legal fee contribution', 15000, 'cancelled', SYSDATE - 20);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 23, 80, 27, '100 notebook sets', 15000, 'committed', SYSDATE - 104);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 23, 8, 3, '30 storybooks', 0, 'cancelled', SYSDATE - 83);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 24, 8, 3, 'Monthly stipend for 2 students', 15000, 'cancelled', SYSDATE - 67);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 24, 38, 13, 'Renovation supplies', 0, 'committed', SYSDATE - 48);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 25, 56, 19, 'Sponsor 2 counselling sessions', 50000, 'committed', SYSDATE - 102);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 25, 59, 20, '20 food rescue boxes', 7500, 'committed', SYSDATE - 43);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 25, 50, 17, '5 stitching kits', 25000, 'completed', SYSDATE - 37);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 26, 105, 35, 'Sponsor 1 teacher training', 7500, 'committed', SYSDATE - 75);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 26, 95, 31, 'Sponsor 2 counselling sessions', 0, 'committed', SYSDATE - 40);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 26, 88, 29, 'Legal fee contribution', 10000, 'committed', SYSDATE - 77);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 27, 46, 16, 'Blood donation — O+ type', 10000, 'committed', SYSDATE - 105);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 28, 96, 32, '50 kg dry dog food', 25000, 'committed', SYSDATE - 83);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 28, 102, 34, 'Labour for debris clearance', 25000, 'committed', SYSDATE - 3);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 29, 46, 16, 'Contribution to medicine fund', 15000, 'committed', SYSDATE - 29);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 29, 28, 10, 'Seed capital PKR 25000', 0, 'committed', SYSDATE - 38);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 29, 32, 11, '30 blankets and food packs', 25000, 'cancelled', SYSDATE - 107);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 30, 95, 31, 'Contribution to medicine fund', 50000, 'committed', SYSDATE - 77);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 31, 23, 8, '5 Eid hampers', 0, 'completed', SYSDATE - 6);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 31, 24, 9, 'Labour for debris clearance', 7500, 'committed', SYSDATE - 57);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 31, 28, 10, '5 Eid hampers', 5000, 'completed', SYSDATE - 30);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 31, 101, 33, '50 kg dry dog food', 2500, 'committed', SYSDATE - 104);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 32, 29, 10, 'Enrol 2 youth in skills training', 15000, 'committed', SYSDATE - 100);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 32, 54, 18, 'Orphan monthly sponsorship PKR 5000', 25000, 'cancelled', SYSDATE - 54);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 32, 99, 32, 'Fuel fund PKR 10000', 2500, 'cancelled', SYSDATE - 18);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 32, 83, 28, 'Contribution to medicine fund', 0, 'completed', SYSDATE - 112);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 33, 80, 27, '1 refurbished PC', 0, 'committed', SYSDATE - 11);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 33, 17, 7, '20 first-aid kits', 5000, 'completed', SYSDATE - 116);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 33, 104, 35, '20 food rescue boxes', 0, 'completed', SYSDATE - 12);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 34, 65, 22, 'Seed capital PKR 25000', 10000, 'committed', SYSDATE - 51);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 34, 51, 17, 'Blood donation — O+ type', 7500, 'committed', SYSDATE - 50);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 35, 54, 18, '20 winter jackets', 0, 'committed', SYSDATE - 120);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 36, 104, 35, '20 food rescue boxes', 7500, 'committed', SYSDATE - 18);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 37, 43, 15, 'Monthly stipend for 2 students', 0, 'completed', SYSDATE - 58);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 38, 13, 5, '5 stitching kits', 5000, 'committed', SYSDATE - 107);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 39, 80, 27, '1 refurbished PC', 10000, 'committed', SYSDATE - 100);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 39, 88, 29, 'Sponsor 3 women in vocational course', 2500, 'committed', SYSDATE - 16);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 40, 37, 13, 'Housing unit contribution', 50000, 'completed', SYSDATE - 9);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 41, 72, 24, '5 Eid hampers', 25000, 'committed', SYSDATE - 81);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 42, 104, 35, 'Sponsor meals for 50 people for 3 days', 10000, 'committed', SYSDATE - 79);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 42, 22, 8, 'Contribution to medicine fund', 2500, 'cancelled', SYSDATE - 54);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 43, 96, 32, '50 kg dry dog food', 7500, 'committed', SYSDATE - 68);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 43, 13, 5, 'Legal fee contribution', 25000, 'cancelled', SYSDATE - 71);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 44, 56, 19, '5 wheelchairs', 0, 'completed', SYSDATE - 48);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 45, 5, 2, 'Contribution to medicine fund', 2500, 'committed', SYSDATE - 99);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 45, 52, 17, 'Legal fee contribution', 7500, 'committed', SYSDATE - 6);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 45, 11, 4, 'Contribution to medicine fund', 25000, 'committed', SYSDATE - 105);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 46, 100, 33, '50 kg dry dog food', 15000, 'committed', SYSDATE - 104);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 46, 67, 23, '5 stitching kits', 0, 'completed', SYSDATE - 5);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 47, 30, 10, 'Enrol 2 youth in skills training', 25000, 'completed', SYSDATE - 105);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 47, 8, 3, '1 refurbished PC', 15000, 'committed', SYSDATE - 5);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 47, 47, 16, 'Sponsor 2 counselling sessions', 2500, 'committed', SYSDATE - 46);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 48, 94, 31, 'Contribution to medicine fund', 5000, 'committed', SYSDATE - 103);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 49, 63, 21, 'Enrol 2 youth in skills training', 7500, 'committed', SYSDATE - 64);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 49, 58, 20, '20 food rescue boxes', 15000, 'committed', SYSDATE - 119);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 49, 64, 21, 'Blood donation — O+ type', 5000, 'committed', SYSDATE - 94);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 50, 13, 5, 'Legal fee contribution', 5000, 'committed', SYSDATE - 14);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 50, 63, 21, 'Seed capital PKR 25000', 7500, 'committed', SYSDATE - 40);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 50, 88, 29, 'Sponsor 3 women in vocational course', 50000, 'completed', SYSDATE - 22);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 50, 28, 10, '5 Eid hampers', 15000, 'committed', SYSDATE - 58);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 51, 52, 17, 'Legal fee contribution', 10000, 'committed', SYSDATE - 82);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 52, 12, 5, 'Legal fee contribution', 10000, 'committed', SYSDATE - 66);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 53, 6, 3, '50 nutrition packs', 15000, 'committed', SYSDATE - 17);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 53, 22, 8, '50 surgical gloves boxes', 2500, 'committed', SYSDATE - 47);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 54, 82, 28, '5 Eid hampers', 15000, 'committed', SYSDATE - 48);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 54, 7, 3, 'Monthly stipend for 2 students', 0, 'cancelled', SYSDATE - 18);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 54, 88, 29, 'Legal fee contribution', 7500, 'completed', SYSDATE - 41);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 54, 23, 8, '5 Eid hampers', 5000, 'committed', SYSDATE - 15);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 55, 28, 10, 'Enrol 2 youth in skills training', 25000, 'completed', SYSDATE - 117);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 56, 40, 14, 'Enrol 2 youth in skills training', 15000, 'committed', SYSDATE - 79);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 57, 101, 33, 'Fuel fund PKR 10000', 0, 'committed', SYSDATE - 58);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 57, 71, 24, 'Seed capital PKR 25000', 15000, 'committed', SYSDATE - 104);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 57, 30, 10, '5 Eid hampers', 7500, 'committed', SYSDATE - 91);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 58, 80, 27, '1 refurbished PC', 5000, 'committed', SYSDATE - 109);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 59, 104, 35, '20 food rescue boxes', 0, 'committed', SYSDATE - 66);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 59, 103, 34, '10 emergency tents', 0, 'committed', SYSDATE - 102);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 60, 37, 13, 'Shelter repair materials', 7500, 'cancelled', SYSDATE - 74);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 60, 72, 24, 'Enrol 2 youth in skills training', 15000, 'cancelled', SYSDATE - 17);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 61, 11, 4, 'Contribution to medicine fund', 10000, 'completed', SYSDATE - 68);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 62, 59, 20, 'Sponsor meals for 50 people for 3 days', 0, 'completed', SYSDATE - 60);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 62, 83, 28, 'Sponsor 2 counselling sessions', 25000, 'committed', SYSDATE - 17);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 62, 12, 5, 'Legal fee contribution', 50000, 'committed', SYSDATE - 99);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 62, 20, 8, '10 ration bags', 10000, 'cancelled', SYSDATE - 117);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 63, 19, 7, 'Blood donation — O+ type', 0, 'committed', SYSDATE - 22);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 64, 48, 16, '20 first-aid kits', 7500, 'cancelled', SYSDATE - 115);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 64, 103, 34, 'Fuel for rescue boats', 0, 'committed', SYSDATE - 26);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 65, 20, 8, '20 food rescue boxes', 25000, 'committed', SYSDATE - 65);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 65, 91, 30, 'Sponsor 2 counselling sessions', 0, 'cancelled', SYSDATE - 75);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 65, 45, 15, 'Sponsor 1 teacher training', 0, 'cancelled', SYSDATE - 93);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 66, 82, 28, 'Seed capital PKR 25000', 0, 'cancelled', SYSDATE - 34);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 66, 8, 3, 'Sponsor 1 teacher training', 50000, 'completed', SYSDATE - 80);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 66, 6, 3, '50 nutrition packs', 0, 'completed', SYSDATE - 114);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 67, 93, 31, '20 first-aid kits', 10000, 'committed', SYSDATE - 59);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 67, 45, 15, '100 notebook sets', 0, 'committed', SYSDATE - 57);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 67, 69, 23, 'Sponsor 3 women in vocational course', 15000, 'completed', SYSDATE - 27);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 68, 88, 29, 'Legal fee contribution', 7500, 'committed', SYSDATE - 52);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 68, 22, 8, '20 first-aid kits', 7500, 'cancelled', SYSDATE - 72);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 68, 47, 16, '50 surgical gloves boxes', 7500, 'committed', SYSDATE - 60);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 69, 41, 14, 'Monthly stipend for 2 students', 2500, 'committed', SYSDATE - 13);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 70, 44, 15, 'Monthly stipend for 2 students', 50000, 'completed', SYSDATE - 32);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 71, 48, 16, 'Sponsor 2 counselling sessions', 7500, 'committed', SYSDATE - 98);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 71, 83, 28, '20 first-aid kits', 15000, 'cancelled', SYSDATE - 60);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 72, 46, 16, '5 wheelchairs', 25000, 'completed', SYSDATE - 31);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 72, 72, 24, 'Seed capital PKR 25000', 50000, 'committed', SYSDATE - 7);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 72, 5, 2, '50 surgical gloves boxes', 5000, 'completed', SYSDATE - 77);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 72, 15, 6, '5 Eid hampers', 15000, 'committed', SYSDATE - 69);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 73, 17, 7, '5 wheelchairs', 0, 'committed', SYSDATE - 94);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 74, 58, 20, 'Sponsor meals for 50 people for 3 days', 0, 'cancelled', SYSDATE - 72);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 74, 53, 18, '20 winter jackets', 7500, 'cancelled', SYSDATE - 37);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 74, 8, 3, '100 notebook sets', 10000, 'cancelled', SYSDATE - 58);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 75, 90, 30, '50 surgical gloves boxes', 0, 'committed', SYSDATE - 51);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 75, 100, 33, 'Vet camp medicines', 7500, 'cancelled', SYSDATE - 47);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 75, 89, 30, '20 first-aid kits', 2500, 'cancelled', SYSDATE - 66);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 76, 73, 24, 'Plastic bags for waste drive', 7500, 'completed', SYSDATE - 67);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 76, 8, 3, 'Monthly stipend for 2 students', 0, 'cancelled', SYSDATE - 115);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 76, 7, 3, '1 refurbished PC', 0, 'committed', SYSDATE - 120);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 76, 21, 8, '5 Eid hampers', 7500, 'committed', SYSDATE - 51);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 77, 86, 29, 'Legal fee contribution', 25000, 'completed', SYSDATE - 91);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 77, 50, 17, 'Legal fee contribution', 5000, 'completed', SYSDATE - 105);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 77, 73, 24, '500 saplings', 7500, 'committed', SYSDATE - 87);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 78, 60, 20, '20 food rescue boxes', 5000, 'committed', SYSDATE - 77);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 79, 40, 14, 'Seed capital PKR 25000', 0, 'cancelled', SYSDATE - 62);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 79, 94, 31, '20 first-aid kits', 25000, 'cancelled', SYSDATE - 100);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 79, 85, 29, 'Sponsor 3 women in vocational course', 0, 'committed', SYSDATE - 5);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 79, 83, 28, 'Blood donation — O+ type', 0, 'committed', SYSDATE - 3);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 80, 47, 16, 'Sponsor 2 counselling sessions', 2500, 'completed', SYSDATE - 65);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 80, 60, 20, '20 food rescue boxes', 15000, 'committed', SYSDATE - 91);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 80, 23, 8, 'Seed capital PKR 25000', 25000, 'committed', SYSDATE - 72);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 80, 59, 20, 'Sponsor meals for 50 people for 3 days', 15000, 'cancelled', SYSDATE - 49);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 81, 27, 9, 'Fuel for rescue boats', 25000, 'committed', SYSDATE - 87);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 81, 66, 22, '5 Eid hampers', 5000, 'cancelled', SYSDATE - 62);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 81, 78, 26, '500 saplings', 2500, 'committed', SYSDATE - 72);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 82, 34, 12, '50 nutrition packs', 2500, 'completed', SYSDATE - 41);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 82, 45, 15, 'Monthly stipend for 2 students', 7500, 'cancelled', SYSDATE - 120);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 82, 43, 15, '30 storybooks', 5000, 'committed', SYSDATE - 74);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 83, 57, 19, '50 surgical gloves boxes', 5000, 'committed', SYSDATE - 45);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 83, 51, 17, '5 wheelchairs', 5000, 'completed', SYSDATE - 28);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 83, 22, 8, '20 first-aid kits', 25000, 'committed', SYSDATE - 120);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 83, 44, 15, '1 refurbished PC', 5000, 'committed', SYSDATE - 14);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 84, 38, 13, 'Renovation supplies', 25000, 'committed', SYSDATE - 82);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 84, 9, 3, 'Sponsor 1 teacher training', 0, 'committed', SYSDATE - 53);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 85, 104, 35, '20 food rescue boxes', 0, 'committed', SYSDATE - 71);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 85, 68, 23, '5 stitching kits', 10000, 'completed', SYSDATE - 62);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 85, 16, 6, '5 Eid hampers', 2500, 'committed', SYSDATE - 42);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 86, 93, 31, 'Sponsor 2 counselling sessions', 50000, 'committed', SYSDATE - 69);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 86, 10, 4, 'Sponsor 2 counselling sessions', 0, 'committed', SYSDATE - 54);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 86, 15, 6, 'Seed capital PKR 25000', 0, 'completed', SYSDATE - 101);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 87, 28, 10, 'Enrol 2 youth in skills training', 50000, 'cancelled', SYSDATE - 14);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 87, 44, 15, '30 storybooks', 5000, 'completed', SYSDATE - 83);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 87, 7, 3, '1 refurbished PC', 25000, 'completed', SYSDATE - 114);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 87, 4, 2, '20 first-aid kits', 25000, 'completed', SYSDATE - 35);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 88, 18, 7, '20 first-aid kits', 15000, 'committed', SYSDATE - 92);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 88, 49, 16, '20 first-aid kits', 0, 'committed', SYSDATE - 102);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 89, 82, 28, 'Seed capital PKR 25000', 50000, 'completed', SYSDATE - 106);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 89, 99, 32, 'Vet camp medicines', 25000, 'committed', SYSDATE - 12);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 89, 29, 10, 'Enrol 2 youth in skills training', 0, 'committed', SYSDATE - 18);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 90, 48, 16, '5 wheelchairs', 2500, 'completed', SYSDATE - 97);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 90, 38, 13, 'Housing unit contribution', 7500, 'committed', SYSDATE - 75);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 90, 1, 1, '30 blankets and food packs', 5000, 'committed', SYSDATE - 89);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 90, 40, 14, 'Seed capital PKR 25000', 0, 'committed', SYSDATE - 60);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 91, 24, 9, 'Fuel for rescue boats', 0, 'committed', SYSDATE - 48);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 91, 58, 20, '20 food rescue boxes', 2500, 'committed', SYSDATE - 18);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 91, 100, 33, 'Vet camp medicines', 0, 'completed', SYSDATE - 96);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 92, 60, 20, 'Sponsor meals for 50 people for 3 days', 25000, 'committed', SYSDATE - 98);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 92, 102, 34, '10 emergency tents', 50000, 'committed', SYSDATE - 68);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 92, 80, 27, 'Monthly stipend for 2 students', 25000, 'committed', SYSDATE - 10);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 93, 10, 4, 'Blood donation — O+ type', 25000, 'committed', SYSDATE - 74);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 94, 25, 9, '20 food rescue boxes', 15000, 'committed', SYSDATE - 88);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 94, 48, 16, '20 first-aid kits', 50000, 'completed', SYSDATE - 12);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 95, 10, 4, '5 wheelchairs', 15000, 'cancelled', SYSDATE - 8);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 95, 66, 22, '5 Eid hampers', 15000, 'committed', SYSDATE - 93);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 95, 20, 8, '10 ration bags', 10000, 'committed', SYSDATE - 105);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 95, 75, 25, '500 saplings', 2500, 'cancelled', SYSDATE - 10);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 96, 61, 20, 'Sponsor meals for 50 people for 3 days', 0, 'cancelled', SYSDATE - 8);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 97, 68, 23, '5 stitching kits', 5000, 'completed', SYSDATE - 24);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 98, 93, 31, 'Contribution to medicine fund', 10000, 'completed', SYSDATE - 112);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 98, 60, 20, 'Sponsor meals for 50 people for 3 days', 10000, 'committed', SYSDATE - 88);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 99, 94, 31, '50 surgical gloves boxes', 0, 'cancelled', SYSDATE - 51);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 99, 51, 17, 'Blood donation — O+ type', 0, 'committed', SYSDATE - 107);
INSERT INTO DONATIONS (donation_id, donor_id, need_id, ngo_id, item_description, amount, status, committed_at)
VALUES (donations_seq.NEXTVAL, 100, 5, 2, 'Contribution to medicine fund', 15000, 'cancelled', SYSDATE - 55);
COMMIT;

-- 6p. NOTIFICATIONS
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 102, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 59);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 103, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 118);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 104, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 40);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 105, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 49);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 106, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 9);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 107, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 158);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 108, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 62);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 109, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 18);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 110, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 153);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 111, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 115);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 112, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 63);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 113, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 103);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 114, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 60);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 115, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 194);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 116, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 36);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 117, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 60);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 118, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 148);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 119, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 61);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 120, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 37);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 121, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 106);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 122, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 71);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 123, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 143);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 124, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 161);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 125, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 143);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 126, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 13);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 127, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 165);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 128, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 135);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 129, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 179);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 130, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 105);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 131, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 77);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 132, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 48);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 133, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 1, SYSDATE - 62);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 134, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 77);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 135, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 119);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 136, 'verification', 'Congratulations! Your NGO registration has been approved. You may now post needs.', 0, SYSDATE - 144);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 137, 'verification', 'Your NGO registration has been rejected. Please review and re-register with updated documentation.', 0, SYSDATE - 106);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 138, 'verification', 'Your NGO registration has been rejected. Please review and re-register with updated documentation.', 0, SYSDATE - 107);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 139, 'verification', 'Your NGO registration has been rejected. Please review and re-register with updated documentation.', 0, SYSDATE - 143);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 140, 'verification', 'Your NGO registration has been rejected. Please review and re-register with updated documentation.', 0, SYSDATE - 136);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 141, 'verification', 'Your NGO registration has been rejected. Please review and re-register with updated documentation.', 0, SYSDATE - 35);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 142, 'verification', 'Your NGO registration has been rejected. Please review and re-register with updated documentation.', 0, SYSDATE - 100);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 143, 'verification', 'Your NGO registration has been rejected. Please review and re-register with updated documentation.', 0, SYSDATE - 63);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 144, 'verification', 'Your NGO registration has been rejected. Please review and re-register with updated documentation.', 0, SYSDATE - 66);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 2, 'donation', 'Your commitment to "Microloan Seed Fund" at Imkaan Welfare Organization was recorded.', 0, SYSDATE - 43);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 123, 'donation', 'A donor has committed to your need: "Microloan Seed Fund".', 1, SYSDATE - 43);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 3, 'donation', 'Your commitment to "Skills Training for Youth" at Imkaan Welfare Organization was recorded.', 0, SYSDATE - 12);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 123, 'donation', 'A donor has committed to your need: "Skills Training for Youth".', 0, SYSDATE - 12);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 3, 'donation', 'Your commitment to "Blood Drive Campaign" at Sahara For Life Trust was recorded.', 0, SYSDATE - 49);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 132, 'donation', 'A donor has committed to your need: "Blood Drive Campaign".', 0, SYSDATE - 49);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 3, 'donation', 'Your commitment to "Winter Clothing Drive" at The Citizen Foundation was recorded.', 0, SYSDATE - 98);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 104, 'donation', 'A donor has committed to your need: "Winter Clothing Drive".', 1, SYSDATE - 98);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 4, 'donation', 'Your commitment to "Medicine Fund" at Layton Rahmatulla Benevolent Trust was recorded.', 1, SYSDATE - 43);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 105, 'donation', 'A donor has committed to your need: "Medicine Fund".', 0, SYSDATE - 43);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 4, 'donation', 'Your commitment to "Ramadan Food Parcels" at Saylani Welfare Trust was recorded.', 0, SYSDATE - 25);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 109, 'donation', 'A donor has committed to your need: "Ramadan Food Parcels".', 1, SYSDATE - 25);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 5, 'donation', 'Your commitment to "Microloan Seed Fund" at Imkaan Welfare Organization was recorded.', 0, SYSDATE - 90);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 123, 'donation', 'A donor has committed to your need: "Microloan Seed Fund".', 1, SYSDATE - 90);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 5, 'donation', 'Your commitment to "Tree Plantation Drive" at Strengthening Participatory Organization was recorded.', 1, SYSDATE - 71);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 125, 'donation', 'A donor has committed to your need: "Tree Plantation Drive".', 1, SYSDATE - 71);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 5, 'donation', 'Your commitment to "Vocational Training Batch" at Aurat Foundation was recorded.', 1, SYSDATE - 60);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 130, 'donation', 'A donor has committed to your need: "Vocational Training Batch".', 1, SYSDATE - 60);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 6, 'donation', 'Your commitment to "Daily Langar Programme" at Rizq Foundation was recorded.', 1, SYSDATE - 47);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 121, 'donation', 'A donor has committed to your need: "Daily Langar Programme".', 1, SYSDATE - 47);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 6, 'donation', 'Your commitment to "Ramadan Food Parcels" at Rizq Foundation was recorded.', 1, SYSDATE - 93);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 121, 'donation', 'A donor has committed to your need: "Ramadan Food Parcels".', 1, SYSDATE - 93);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 6, 'donation', 'Your commitment to "Microloan Seed Fund" at Sungi Development Foundation was recorded.', 1, SYSDATE - 48);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 107, 'donation', 'A donor has committed to your need: "Microloan Seed Fund".', 1, SYSDATE - 48);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 6, 'donation', 'Your commitment to "Medical Supplies Drive" at Umang Pakistan was recorded.', 0, SYSDATE - 73);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 117, 'donation', 'A donor has committed to your need: "Medical Supplies Drive".', 0, SYSDATE - 73);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 7, 'donation', 'Your commitment to "Stitching and Tailoring Kits" at Aurat Foundation was recorded.', 1, SYSDATE - 34);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 130, 'donation', 'A donor has committed to your need: "Stitching and Tailoring Kits".', 1, SYSDATE - 34);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 8, 'donation', 'Your commitment to "Ramadan Food Parcels" at Rizq Foundation was recorded.', 1, SYSDATE - 26);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 121, 'donation', 'A donor has committed to your need: "Ramadan Food Parcels".', 0, SYSDATE - 26);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 9, 'donation', 'Your commitment to "Vocational Training Batch" at Greenstar Social Marketing was recorded.', 0, SYSDATE - 73);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 118, 'donation', 'A donor has committed to your need: "Vocational Training Batch".', 1, SYSDATE - 73);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 9, 'donation', 'Your commitment to "Cancer Medication Fund" at Indus Hospital was recorded.', 1, SYSDATE - 84);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 108, 'donation', 'A donor has committed to your need: "Cancer Medication Fund".', 1, SYSDATE - 84);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 9, 'donation', 'Your commitment to "Wheelchair Donation" at Human Development Foundation was recorded.', 1, SYSDATE - 93);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 129, 'donation', 'A donor has committed to your need: "Wheelchair Donation".', 1, SYSDATE - 93);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 10, 'donation', 'Your commitment to "Medicine Fund" at Human Development Foundation was recorded.', 1, SYSDATE - 94);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 129, 'donation', 'A donor has committed to your need: "Medicine Fund".', 0, SYSDATE - 94);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 10, 'donation', 'Your commitment to "Winter Clothing Drive" at Ansar Burney Trust was recorded.', 1, SYSDATE - 93);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 113, 'donation', 'A donor has committed to your need: "Winter Clothing Drive".', 0, SYSDATE - 93);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 10, 'donation', 'Your commitment to "Food Rescue Boxes" at Rizq Foundation was recorded.', 0, SYSDATE - 83);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 121, 'donation', 'A donor has committed to your need: "Food Rescue Boxes".', 0, SYSDATE - 83);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 11, 'donation', 'Your commitment to "Flood Relief Supplies" at Disaster Response Network was recorded.', 0, SYSDATE - 86);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 135, 'donation', 'A donor has committed to your need: "Flood Relief Supplies".', 0, SYSDATE - 86);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 11, 'donation', 'Your commitment to "Wheelchair Donation" at Umang Pakistan was recorded.', 0, SYSDATE - 18);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 117, 'donation', 'A donor has committed to your need: "Wheelchair Donation".', 0, SYSDATE - 18);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 11, 'donation', 'Your commitment to "Legal Aid Fund" at Greenstar Social Marketing was recorded.', 0, SYSDATE - 20);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 118, 'donation', 'A donor has committed to your need: "Legal Aid Fund".', 0, SYSDATE - 20);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 12, 'donation', 'Your commitment to "Cancer Medication Fund" at Transparent Hands was recorded.', 1, SYSDATE - 59);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 120, 'donation', 'A donor has committed to your need: "Cancer Medication Fund".', 0, SYSDATE - 59);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 12, 'donation', 'Your commitment to "Food Rescue Boxes" at Rizq Foundation was recorded.', 1, SYSDATE - 82);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 121, 'donation', 'A donor has committed to your need: "Food Rescue Boxes".', 1, SYSDATE - 82);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 13, 'donation', 'Your commitment to "School Stationery Drive" at The Citizen Foundation was recorded.', 1, SYSDATE - 1);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 104, 'donation', 'A donor has committed to your need: "School Stationery Drive".', 0, SYSDATE - 1);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 14, 'donation', 'Your commitment to "School Stationery Drive" at Hunar Foundation was recorded.', 1, SYSDATE - 68);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 115, 'donation', 'A donor has committed to your need: "School Stationery Drive".', 1, SYSDATE - 68);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 15, 'donation', 'Your commitment to "Ramadan Food Parcels" at Rizq Foundation was recorded.', 1, SYSDATE - 65);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 121, 'donation', 'A donor has committed to your need: "Ramadan Food Parcels".', 0, SYSDATE - 65);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 15, 'donation', 'Your commitment to "School Stationery Drive" at Hunar Foundation was recorded.', 0, SYSDATE - 13);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 115, 'donation', 'A donor has committed to your need: "School Stationery Drive".', 0, SYSDATE - 13);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 15, 'donation', 'Your commitment to "Emergency Shelter Kits" at Chippa Welfare Association was recorded.', 1, SYSDATE - 80);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 112, 'donation', 'A donor has committed to your need: "Emergency Shelter Kits".', 1, SYSDATE - 80);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 15, 'donation', 'Your commitment to "Solar Panel Installation" at LEAD Pakistan was recorded.', 0, SYSDATE - 51);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 126, 'donation', 'A donor has committed to your need: "Solar Panel Installation".', 1, SYSDATE - 51);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 16, 'donation', 'Your commitment to "Earthquake Debris Clearance" at Chippa Welfare Association was recorded.', 0, SYSDATE - 59);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 112, 'donation', 'A donor has committed to your need: "Earthquake Debris Clearance".', 0, SYSDATE - 59);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 16, 'donation', 'Your commitment to "Skills Training for Youth" at Saylani Welfare Trust was recorded.', 0, SYSDATE - 88);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 109, 'donation', 'A donor has committed to your need: "Skills Training for Youth".', 0, SYSDATE - 88);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 16, 'donation', 'Your commitment to "Microloan Seed Fund" at Hunar Foundation was recorded.', 1, SYSDATE - 52);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 115, 'donation', 'A donor has committed to your need: "Microloan Seed Fund".', 1, SYSDATE - 52);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 17, 'donation', 'Your commitment to "Legal Aid Fund" at Akhuwat Foundation was recorded.', 0, SYSDATE - 61);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 106, 'donation', 'A donor has committed to your need: "Legal Aid Fund".', 0, SYSDATE - 61);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 17, 'donation', 'Your commitment to "Mental Health Counselling Fund" at Transparent Hands was recorded.', 0, SYSDATE - 22);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 120, 'donation', 'A donor has committed to your need: "Mental Health Counselling Fund".', 1, SYSDATE - 22);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 17, 'donation', 'Your commitment to "Scholarship Fund" at The Citizen Foundation was recorded.', 1, SYSDATE - 83);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 104, 'donation', 'A donor has committed to your need: "Scholarship Fund".', 0, SYSDATE - 83);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 18, 'donation', 'Your commitment to "Food Rescue Boxes" at Rizq Foundation was recorded.', 0, SYSDATE - 6);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 121, 'donation', 'A donor has committed to your need: "Food Rescue Boxes".', 0, SYSDATE - 6);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 19, 'donation', 'Your commitment to "Shelter Dog Food Drive" at Fauget (Animal Aid) was recorded.', 1, SYSDATE - 73);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 134, 'donation', 'A donor has committed to your need: "Shelter Dog Food Drive".', 1, SYSDATE - 73);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 19, 'donation', 'Your commitment to "Winter Clothing Drive" at SOS Children Villages Pakistan was recorded.', 1, SYSDATE - 10);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 119, 'donation', 'A donor has committed to your need: "Winter Clothing Drive".', 0, SYSDATE - 10);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 19, 'donation', 'Your commitment to "Microloan Seed Fund" at Sungi Development Foundation was recorded.', 0, SYSDATE - 41);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 107, 'donation', 'A donor has committed to your need: "Microloan Seed Fund".', 0, SYSDATE - 41);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 19, 'donation', 'Your commitment to "Eid Hamper Distribution" at HOPE Welfare Trust was recorded.', 1, SYSDATE - 19);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 122, 'donation', 'A donor has committed to your need: "Eid Hamper Distribution".', 0, SYSDATE - 19);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 20, 'donation', 'Your commitment to "Veterinary Camp Supplies" at WWF Pakistan was recorded.', 0, SYSDATE - 21);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 127, 'donation', 'A donor has committed to your need: "Veterinary Camp Supplies".', 1, SYSDATE - 21);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 21, 'donation', 'Your commitment to "Women Shelter Renovation" at Pakistan Sweet Home was recorded.', 1, SYSDATE - 70);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 114, 'donation', 'A donor has committed to your need: "Women Shelter Renovation".', 1, SYSDATE - 70);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 21, 'donation', 'Your commitment to "Mental Health Counselling Fund" at Indus Hospital was recorded.', 0, SYSDATE - 18);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 108, 'donation', 'A donor has committed to your need: "Mental Health Counselling Fund".', 1, SYSDATE - 18);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 22, 'donation', 'Your commitment to "Stitching and Tailoring Kits" at Aware Girls was recorded.', 1, SYSDATE - 13);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 124, 'donation', 'A donor has committed to your need: "Stitching and Tailoring Kits".', 0, SYSDATE - 13);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 22, 'donation', 'Your commitment to "Microloan Seed Fund" at Human Development Foundation was recorded.', 1, SYSDATE - 44);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 129, 'donation', 'A donor has committed to your need: "Microloan Seed Fund".', 1, SYSDATE - 44);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 22, 'donation', 'Your commitment to "Stitching and Tailoring Kits" at Aurat Foundation was recorded.', 1, SYSDATE - 82);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 130, 'donation', 'A donor has committed to your need: "Stitching and Tailoring Kits".', 1, SYSDATE - 82);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 22, 'donation', 'Your commitment to "Skills Training for Youth" at Imkaan Welfare Organization was recorded.', 1, SYSDATE - 30);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 123, 'donation', 'A donor has committed to your need: "Skills Training for Youth".', 1, SYSDATE - 30);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 23, 'donation', 'Your commitment to "Solar Panel Installation" at Strengthening Participatory Organization was recorded.', 1, SYSDATE - 24);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 125, 'donation', 'A donor has committed to your need: "Solar Panel Installation".', 0, SYSDATE - 24);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 23, 'donation', 'Your commitment to "Legal Aid Fund" at Akhuwat Foundation was recorded.', 0, SYSDATE - 38);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 106, 'donation', 'A donor has committed to your need: "Legal Aid Fund".', 0, SYSDATE - 38);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 23, 'donation', 'Your commitment to "Medical Supplies Drive" at Umang Pakistan was recorded.', 0, SYSDATE - 35);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 117, 'donation', 'A donor has committed to your need: "Medical Supplies Drive".', 1, SYSDATE - 35);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 24, 'donation', 'Your commitment to "Legal Aid Fund" at Aware Girls was recorded.', 0, SYSDATE - 82);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 124, 'donation', 'A donor has committed to your need: "Legal Aid Fund".', 1, SYSDATE - 82);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 24, 'donation', 'Your commitment to "Vocational Training Batch" at Aurat Foundation was recorded.', 0, SYSDATE - 47);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 130, 'donation', 'A donor has committed to your need: "Vocational Training Batch".', 0, SYSDATE - 47);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 24, 'donation', 'Your commitment to "School Stationery Drive" at Agha Khan Foundation Pakistan was recorded.', 1, SYSDATE - 40);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 128, 'donation', 'A donor has committed to your need: "School Stationery Drive".', 1, SYSDATE - 40);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 24, 'donation', 'Your commitment to "Library Books Donation" at The Citizen Foundation was recorded.', 0, SYSDATE - 14);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 104, 'donation', 'A donor has committed to your need: "Library Books Donation".', 0, SYSDATE - 14);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 25, 'donation', 'Your commitment to "Teacher Training Sponsorship" at The Citizen Foundation was recorded.', 1, SYSDATE - 56);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 104, 'donation', 'A donor has committed to your need: "Teacher Training Sponsorship".', 1, SYSDATE - 56);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 25, 'donation', 'Your commitment to "Homeless Shelter Maintenance" at Pakistan Sweet Home was recorded.', 0, SYSDATE - 4);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 114, 'donation', 'A donor has committed to your need: "Homeless Shelter Maintenance".', 1, SYSDATE - 4);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 26, 'donation', 'Your commitment to "Cancer Medication Fund" at Transparent Hands was recorded.', 1, SYSDATE - 12);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 120, 'donation', 'A donor has committed to your need: "Cancer Medication Fund".', 1, SYSDATE - 12);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 26, 'donation', 'Your commitment to "Ramadan Food Parcels" at Rizq Foundation was recorded.', 1, SYSDATE - 38);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 121, 'donation', 'A donor has committed to your need: "Ramadan Food Parcels".', 1, SYSDATE - 38);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 26, 'donation', 'Your commitment to "Stitching and Tailoring Kits" at Greenstar Social Marketing was recorded.', 0, SYSDATE - 93);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 118, 'donation', 'A donor has committed to your need: "Stitching and Tailoring Kits".', 0, SYSDATE - 93);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 27, 'donation', 'Your commitment to "Scholarship Fund" at Children''s Global Network was recorded.', 0, SYSDATE - 22);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 136, 'donation', 'A donor has committed to your need: "Scholarship Fund".', 1, SYSDATE - 22);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 27, 'donation', 'Your commitment to "Blood Drive Campaign" at Sahara For Life Trust was recorded.', 1, SYSDATE - 35);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 132, 'donation', 'A donor has committed to your need: "Blood Drive Campaign".', 0, SYSDATE - 35);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 27, 'donation', 'Your commitment to "Stitching and Tailoring Kits" at Aurat Foundation was recorded.', 1, SYSDATE - 22);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 130, 'donation', 'A donor has committed to your need: "Stitching and Tailoring Kits".', 1, SYSDATE - 22);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 28, 'donation', 'Your commitment to "Wheelchair Donation" at Umang Pakistan was recorded.', 1, SYSDATE - 39);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 117, 'donation', 'A donor has committed to your need: "Wheelchair Donation".', 0, SYSDATE - 39);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 29, 'donation', 'Your commitment to "Veterinary Camp Supplies" at Pakistan Animal Welfare Society was recorded.', 0, SYSDATE - 33);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 133, 'donation', 'A donor has committed to your need: "Veterinary Camp Supplies".', 1, SYSDATE - 33);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 29, 'donation', 'Your commitment to "Emergency Shelter Kits" at Disaster Response Network was recorded.', 0, SYSDATE - 59);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 135, 'donation', 'A donor has committed to your need: "Emergency Shelter Kits".', 0, SYSDATE - 59);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 30, 'donation', 'Your commitment to "Blood Drive Campaign" at Umang Pakistan was recorded.', 1, SYSDATE - 1);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 117, 'donation', 'A donor has committed to your need: "Blood Drive Campaign".', 1, SYSDATE - 1);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 30, 'donation', 'Your commitment to "Eid Hamper Distribution" at Pakistan Poverty Alleviation Fund was recorded.', 1, SYSDATE - 49);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 111, 'donation', 'A donor has committed to your need: "Eid Hamper Distribution".', 1, SYSDATE - 49);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 30, 'donation', 'Your commitment to "Rescue Boat Fuel Fund" at Chippa Welfare Association was recorded.', 0, SYSDATE - 56);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 112, 'donation', 'A donor has committed to your need: "Rescue Boat Fuel Fund".', 1, SYSDATE - 56);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 31, 'donation', 'Your commitment to "Blood Drive Campaign" at Sahara For Life Trust was recorded.', 0, SYSDATE - 78);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 132, 'donation', 'A donor has committed to your need: "Blood Drive Campaign".', 1, SYSDATE - 78);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 32, 'donation', 'Your commitment to "Skills Training for Youth" at Saylani Welfare Trust was recorded.', 1, SYSDATE - 23);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 109, 'donation', 'A donor has committed to your need: "Skills Training for Youth".', 1, SYSDATE - 23);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 32, 'donation', 'Your commitment to "Rescue Boat Fuel Fund" at Khidmat Foundation was recorded.', 1, SYSDATE - 95);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 110, 'donation', 'A donor has committed to your need: "Rescue Boat Fuel Fund".', 0, SYSDATE - 95);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 32, 'donation', 'Your commitment to "Skills Training for Youth" at Pakistan Poverty Alleviation Fund was recorded.', 1, SYSDATE - 49);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 111, 'donation', 'A donor has committed to your need: "Skills Training for Youth".', 1, SYSDATE - 49);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 32, 'donation', 'Your commitment to "Veterinary Camp Supplies" at Fauget (Animal Aid) was recorded.', 0, SYSDATE - 15);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 134, 'donation', 'A donor has committed to your need: "Veterinary Camp Supplies".', 0, SYSDATE - 15);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 33, 'donation', 'Your commitment to "Eid Hamper Distribution" at Pakistan Poverty Alleviation Fund was recorded.', 0, SYSDATE - 99);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 111, 'donation', 'A donor has committed to your need: "Eid Hamper Distribution".', 1, SYSDATE - 99);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 33, 'donation', 'Your commitment to "Child Nutrition Packs" at SOS Children Villages Pakistan was recorded.', 1, SYSDATE - 27);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 119, 'donation', 'A donor has committed to your need: "Child Nutrition Packs".', 1, SYSDATE - 27);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 33, 'donation', 'Your commitment to "Shelter Dog Food Drive" at Pakistan Animal Welfare Society was recorded.', 1, SYSDATE - 9);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 133, 'donation', 'A donor has committed to your need: "Shelter Dog Food Drive".', 1, SYSDATE - 9);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 33, 'donation', 'Your commitment to "Medicine Fund" at Human Development Foundation was recorded.', 1, SYSDATE - 82);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 129, 'donation', 'A donor has committed to your need: "Medicine Fund".', 0, SYSDATE - 82);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 34, 'donation', 'Your commitment to "Library Books Donation" at Agha Khan Foundation Pakistan was recorded.', 0, SYSDATE - 85);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 128, 'donation', 'A donor has committed to your need: "Library Books Donation".', 1, SYSDATE - 85);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 34, 'donation', 'Your commitment to "Wheelchair Donation" at Indus Hospital was recorded.', 1, SYSDATE - 10);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 108, 'donation', 'A donor has committed to your need: "Wheelchair Donation".', 1, SYSDATE - 10);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 34, 'donation', 'Your commitment to "Food Rescue Boxes" at Children''s Global Network was recorded.', 1, SYSDATE - 52);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 136, 'donation', 'A donor has committed to your need: "Food Rescue Boxes".', 0, SYSDATE - 52);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 35, 'donation', 'Your commitment to "Skills Training for Youth" at Imkaan Welfare Organization was recorded.', 0, SYSDATE - 90);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 123, 'donation', 'A donor has committed to your need: "Skills Training for Youth".', 0, SYSDATE - 90);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 35, 'donation', 'Your commitment to "Medicine Fund" at Greenstar Social Marketing was recorded.', 1, SYSDATE - 85);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 118, 'donation', 'A donor has committed to your need: "Medicine Fund".', 0, SYSDATE - 85);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 36, 'donation', 'Your commitment to "Child Nutrition Packs" at SOS Children Villages Pakistan was recorded.', 0, SYSDATE - 79);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 119, 'donation', 'A donor has committed to your need: "Child Nutrition Packs".', 1, SYSDATE - 79);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 37, 'donation', 'Your commitment to "Daily Langar Programme" at Children''s Global Network was recorded.', 0, SYSDATE - 56);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 136, 'donation', 'A donor has committed to your need: "Daily Langar Programme".', 0, SYSDATE - 56);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 38, 'donation', 'Your commitment to "School Stationery Drive" at TCF — Teacher Training Program was recorded.', 0, SYSDATE - 34);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 116, 'donation', 'A donor has committed to your need: "School Stationery Drive".', 0, SYSDATE - 34);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 39, 'donation', 'Your commitment to "Vocational Training Batch" at Akhuwat Foundation was recorded.', 1, SYSDATE - 48);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 106, 'donation', 'A donor has committed to your need: "Vocational Training Batch".', 1, SYSDATE - 48);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 40, 'donation', 'Your commitment to "Computer Lab Equipment" at Agha Khan Foundation Pakistan was recorded.', 0, SYSDATE - 89);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 128, 'donation', 'A donor has committed to your need: "Computer Lab Equipment".', 1, SYSDATE - 89);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 40, 'donation', 'Your commitment to "Stitching and Tailoring Kits" at Aurat Foundation was recorded.', 0, SYSDATE - 62);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 130, 'donation', 'A donor has committed to your need: "Stitching and Tailoring Kits".', 1, SYSDATE - 62);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 41, 'donation', 'Your commitment to "Refugee Family Housing" at Pakistan Sweet Home was recorded.', 0, SYSDATE - 11);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 114, 'donation', 'A donor has committed to your need: "Refugee Family Housing".', 0, SYSDATE - 11);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 42, 'donation', 'Your commitment to "Skills Training for Youth" at Strengthening Participatory Organization was recorded.', 1, SYSDATE - 40);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 125, 'donation', 'A donor has committed to your need: "Skills Training for Youth".', 1, SYSDATE - 40);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 43, 'donation', 'Your commitment to "Ramadan Food Parcels" at Children''s Global Network was recorded.', 1, SYSDATE - 67);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 136, 'donation', 'A donor has committed to your need: "Ramadan Food Parcels".', 1, SYSDATE - 67);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 43, 'donation', 'Your commitment to "Wheelchair Donation" at Saylani Welfare Trust was recorded.', 1, SYSDATE - 13);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 109, 'donation', 'A donor has committed to your need: "Wheelchair Donation".', 1, SYSDATE - 13);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 44, 'donation', 'Your commitment to "Veterinary Camp Supplies" at Pakistan Animal Welfare Society was recorded.', 1, SYSDATE - 9);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 133, 'donation', 'A donor has committed to your need: "Veterinary Camp Supplies".', 0, SYSDATE - 9);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 44, 'donation', 'Your commitment to "Legal Aid Fund" at Akhuwat Foundation was recorded.', 0, SYSDATE - 15);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 106, 'donation', 'A donor has committed to your need: "Legal Aid Fund".', 1, SYSDATE - 15);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 45, 'donation', 'Your commitment to "Mental Health Counselling Fund" at Transparent Hands was recorded.', 0, SYSDATE - 14);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 120, 'donation', 'A donor has committed to your need: "Mental Health Counselling Fund".', 0, SYSDATE - 14);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 46, 'donation', 'Your commitment to "Cancer Medication Fund" at Shaukat Khanum Memorial Hospital was recorded.', 0, SYSDATE - 23);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 103, 'donation', 'A donor has committed to your need: "Cancer Medication Fund".', 1, SYSDATE - 23);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 46, 'donation', 'Your commitment to "Legal Aid Fund" at Greenstar Social Marketing was recorded.', 1, SYSDATE - 55);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 118, 'donation', 'A donor has committed to your need: "Legal Aid Fund".', 0, SYSDATE - 55);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 46, 'donation', 'Your commitment to "Wheelchair Donation" at Layton Rahmatulla Benevolent Trust was recorded.', 0, SYSDATE - 81);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 105, 'donation', 'A donor has committed to your need: "Wheelchair Donation".', 0, SYSDATE - 81);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 47, 'donation', 'Your commitment to "Shelter Dog Food Drive" at Fauget (Animal Aid) was recorded.', 1, SYSDATE - 85);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 134, 'donation', 'A donor has committed to your need: "Shelter Dog Food Drive".', 1, SYSDATE - 85);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 47, 'donation', 'Your commitment to "Stitching and Tailoring Kits" at Aware Girls was recorded.', 0, SYSDATE - 95);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 124, 'donation', 'A donor has committed to your need: "Stitching and Tailoring Kits".', 1, SYSDATE - 95);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 48, 'donation', 'Your commitment to "Eid Hamper Distribution" at Pakistan Poverty Alleviation Fund was recorded.', 1, SYSDATE - 55);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 111, 'donation', 'A donor has committed to your need: "Eid Hamper Distribution".', 0, SYSDATE - 55);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 48, 'donation', 'Your commitment to "Teacher Training Sponsorship" at The Citizen Foundation was recorded.', 1, SYSDATE - 27);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 104, 'donation', 'A donor has committed to your need: "Teacher Training Sponsorship".', 0, SYSDATE - 27);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 48, 'donation', 'Your commitment to "Cancer Medication Fund" at Umang Pakistan was recorded.', 0, SYSDATE - 14);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 117, 'donation', 'A donor has committed to your need: "Cancer Medication Fund".', 1, SYSDATE - 14);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 49, 'donation', 'Your commitment to "Blood Drive Campaign" at Sahara For Life Trust was recorded.', 1, SYSDATE - 26);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 132, 'donation', 'A donor has committed to your need: "Blood Drive Campaign".', 0, SYSDATE - 26);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 50, 'donation', 'Your commitment to "Skills Training for Youth" at HOPE Welfare Trust was recorded.', 1, SYSDATE - 86);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 122, 'donation', 'A donor has committed to your need: "Skills Training for Youth".', 1, SYSDATE - 86);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 50, 'donation', 'Your commitment to "Food Rescue Boxes" at Rizq Foundation was recorded.', 1, SYSDATE - 50);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 121, 'donation', 'A donor has committed to your need: "Food Rescue Boxes".', 0, SYSDATE - 50);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 50, 'donation', 'Your commitment to "Blood Drive Campaign" at HOPE Welfare Trust was recorded.', 1, SYSDATE - 46);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 122, 'donation', 'A donor has committed to your need: "Blood Drive Campaign".', 0, SYSDATE - 46);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 51, 'donation', 'Your commitment to "Legal Aid Fund" at Akhuwat Foundation was recorded.', 1, SYSDATE - 91);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 106, 'donation', 'A donor has committed to your need: "Legal Aid Fund".', 0, SYSDATE - 91);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 51, 'donation', 'Your commitment to "Eid Hamper Distribution" at HOPE Welfare Trust was recorded.', 1, SYSDATE - 18);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 122, 'donation', 'A donor has committed to your need: "Eid Hamper Distribution".', 0, SYSDATE - 18);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 51, 'donation', 'Your commitment to "Stitching and Tailoring Kits" at Aurat Foundation was recorded.', 0, SYSDATE - 40);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 130, 'donation', 'A donor has committed to your need: "Stitching and Tailoring Kits".', 0, SYSDATE - 40);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 51, 'donation', 'Your commitment to "Skills Training for Youth" at Pakistan Poverty Alleviation Fund was recorded.', 0, SYSDATE - 89);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 111, 'donation', 'A donor has committed to your need: "Skills Training for Youth".', 1, SYSDATE - 89);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 52, 'donation', 'Your commitment to "Vocational Training Batch" at Greenstar Social Marketing was recorded.', 0, SYSDATE - 77);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 118, 'donation', 'A donor has committed to your need: "Vocational Training Batch".', 1, SYSDATE - 77);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 53, 'donation', 'Your commitment to "Vocational Training Batch" at Akhuwat Foundation was recorded.', 1, SYSDATE - 24);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 106, 'donation', 'A donor has committed to your need: "Vocational Training Batch".', 0, SYSDATE - 24);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 54, 'donation', 'Your commitment to "Child Nutrition Packs" at The Citizen Foundation was recorded.', 1, SYSDATE - 22);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 104, 'donation', 'A donor has committed to your need: "Child Nutrition Packs".', 1, SYSDATE - 22);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 54, 'donation', 'Your commitment to "Medicine Fund" at Saylani Welfare Trust was recorded.', 1, SYSDATE - 24);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 109, 'donation', 'A donor has committed to your need: "Medicine Fund".', 1, SYSDATE - 24);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 55, 'donation', 'Your commitment to "Eid Hamper Distribution" at Human Development Foundation was recorded.', 1, SYSDATE - 7);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 129, 'donation', 'A donor has committed to your need: "Eid Hamper Distribution".', 0, SYSDATE - 7);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 55, 'donation', 'Your commitment to "Scholarship Fund" at The Citizen Foundation was recorded.', 0, SYSDATE - 18);
INSERT INTO NOTIFICATIONS (notif_id, user_id, notif_type, message, is_read, created_at)
VALUES (notif_seq.NEXTVAL, 104, 'donation', 'A donor has committed to your need: "Scholarship Fund".', 1, SYSDATE - 18);
COMMIT;


-- ============================================================
--  SECTION 7: VERIFICATION QUERIES  (optional — run to confirm)
-- ============================================================

-- Should return zero rows (no invalid objects)
SELECT object_name, object_type, status FROM user_objects WHERE status = 'INVALID';

-- Should show all 12 tables
SELECT table_name FROM user_tables ORDER BY table_name;

-- Should show the trigger as VALID
SELECT trigger_name, status FROM user_triggers;

-- Row counts per table
SELECT 'USERS'             AS tbl, COUNT(*) AS cnt FROM USERS             UNION ALL
SELECT 'DONORS',                   COUNT(*)        FROM DONORS            UNION ALL
SELECT 'NGOS',                     COUNT(*)        FROM NGOS              UNION ALL
SELECT 'CATEGORIES',               COUNT(*)        FROM CATEGORIES        UNION ALL
SELECT 'NGO_CATEGORIES',           COUNT(*)        FROM NGO_CATEGORIES    UNION ALL
SELECT 'DONOR_LOCATIONS',          COUNT(*)        FROM DONOR_LOCATIONS   UNION ALL
SELECT 'DONOR_PREFERENCES',        COUNT(*)        FROM DONOR_PREFERENCES UNION ALL
SELECT 'DOCUMENTS',                COUNT(*)        FROM DOCUMENTS         UNION ALL
SELECT 'NEEDS',                    COUNT(*)        FROM NEEDS             UNION ALL
SELECT 'DONATIONS',                COUNT(*)        FROM DONATIONS         UNION ALL
SELECT 'NOTIFICATIONS',            COUNT(*)        FROM NOTIFICATIONS;