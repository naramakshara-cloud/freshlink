CREATE EXTENSION IF NOT EXISTS postgis;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
        CREATE TYPE user_role AS ENUM ('donor', 'receiver', 'admin');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'donor_type') THEN
        CREATE TYPE donor_type AS ENUM ('hostel', 'canteen', 'household', 'restaurant', 'event', 'other');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'receiver_type') THEN
        CREATE TYPE receiver_type AS ENUM ('individual_or_family', 'ngo', 'animal_shelter', 'orphanage', 'old_age_home', 'community_kitchen');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'verification_status') THEN
        CREATE TYPE verification_status AS ENUM ('pending', 'approved', 'rejected');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'listing_status') THEN
        CREATE TYPE listing_status AS ENUM ('available', 'matched', 'picked_up', 'delivered', 'expired', 'cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'match_status') THEN
        CREATE TYPE match_status AS ENUM ('pending', 'accepted', 'rejected', 'picked_up', 'completed', 'cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pickup_status') THEN
        CREATE TYPE pickup_status AS ENUM ('proposed', 'confirmed', 'completed', 'missed', 'cancelled');
    END IF;
END $$;
CREATE TABLE IF NOT EXISTS users (
    user_id       SERIAL PRIMARY KEY,
    email         VARCHAR(120) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    full_name     VARCHAR(120) NOT NULL,
    phone         VARCHAR(20)  NOT NULL,
    role          user_role    NOT NULL,
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS food_categories (
    category_id            SERIAL PRIMARY KEY,
    name                   VARCHAR(60)  NOT NULL UNIQUE,
    decay_rate             NUMERIC(6,4) NOT NULL DEFAULT 0.1000 CHECK (decay_rate > 0),
    max_safe_hours         NUMERIC(6,2) NOT NULL CHECK (max_safe_hours > 0),
    spoilage_shape         NUMERIC(3,1) NOT NULL DEFAULT 1.0 CHECK (spoilage_shape >= 1),
    requires_refrigeration BOOLEAN      NOT NULL DEFAULT FALSE,
    description            TEXT,
    is_active              BOOLEAN      NOT NULL DEFAULT TRUE
);
ALTER TABLE food_categories ADD COLUMN IF NOT EXISTS spoilage_shape NUMERIC(3,1) NOT NULL DEFAULT 1.0 CHECK (spoilage_shape >= 1);
ALTER TABLE food_categories ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE food_categories ALTER COLUMN decay_rate SET DEFAULT 0.1000;
DO $$ BEGIN
    IF NOT EXISTS (SELECT LOWER(name) FROM food_categories GROUP BY LOWER(name) HAVING COUNT(*) > 1) THEN
        CREATE UNIQUE INDEX IF NOT EXISTS uq_category_name_ci ON food_categories (LOWER(name));
    ELSE
        RAISE NOTICE 'Some food type names differ only in capital letters. Rename them, then run schema.sql again.';
    END IF;
END $$;
UPDATE food_categories SET description = 'Biryani, pulao, plain rice, dal, sambar, rasam, curries, sabzi' WHERE description = 'Hot cooked meals; spoil quickly at room temperature';
UPDATE food_categories SET description = 'Chapati, roti, naan, paratha, puri, bread, buns, pav' WHERE description = 'Chapati, roti, bread, buns';
UPDATE food_categories SET description = 'Milk, curd, buttermilk, paneer dishes, kheer, rasgulla, milk-based sweets' WHERE description = 'Milk, curd, paneer, milk-based sweets';
UPDATE food_categories SET description = 'Whole, uncut fruits and vegetables such as bananas, apples, oranges and tomatoes' WHERE description = 'Uncut produce';
UPDATE food_categories SET description = 'Sealed biscuits, chips, bread packets, and dry rations such as rice, atta and dal' WHERE description = 'Sealed snacks, biscuits, dry rations';
CREATE TABLE IF NOT EXISTS donors (
    donor_id      SERIAL PRIMARY KEY,
    user_id       INT          REFERENCES users(user_id) ON DELETE SET NULL,
    name          VARCHAR(120) NOT NULL,
    donor_type    donor_type   NOT NULL,
    contact_phone VARCHAR(20)  NOT NULL,
    email         VARCHAR(120),
    address       TEXT         NOT NULL,
    location      GEOGRAPHY(POINT, 4326) NOT NULL,
    is_verified   BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS receivers (
    receiver_id         SERIAL PRIMARY KEY,
    user_id             INT                 REFERENCES users(user_id) ON DELETE SET NULL,
    name                VARCHAR(120)        NOT NULL,
    receiver_type       receiver_type       NOT NULL DEFAULT 'ngo',
    verification_status verification_status NOT NULL DEFAULT 'pending',
    contact_phone       VARCHAR(20)         NOT NULL,
    email               VARCHAR(120),
    address             TEXT                NOT NULL,
    location            GEOGRAPHY(POINT, 4326) NOT NULL,
    service_radius_km   NUMERIC(5,2)        NOT NULL DEFAULT 5 CHECK (service_radius_km > 0),
    daily_capacity_kg   NUMERIC(8,2)        NOT NULL DEFAULT 50 CHECK (daily_capacity_kg > 0),
    has_refrigeration   BOOLEAN             NOT NULL DEFAULT FALSE,
    is_active           BOOLEAN             NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);
CREATE OR REPLACE FUNCTION trg_receiver_default_capacity() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.daily_capacity_kg IS NULL OR NEW.daily_capacity_kg = 50 THEN
        IF NEW.receiver_type = 'individual_or_family' THEN
            NEW.daily_capacity_kg := 5.0;
        ELSE
            NEW.daily_capacity_kg := 50.0;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS receiver_default_capacity ON receivers;
CREATE TRIGGER receiver_default_capacity
BEFORE INSERT ON receivers
FOR EACH ROW EXECUTE FUNCTION trg_receiver_default_capacity();
CREATE TABLE IF NOT EXISTS receiver_requirements (
    requirement_id     SERIAL PRIMARY KEY,
    receiver_id        INT          NOT NULL REFERENCES receivers(receiver_id) ON DELETE CASCADE,
    category_id        INT          NOT NULL REFERENCES food_categories(category_id),
    quantity_needed_kg NUMERIC(8,2) NOT NULL CHECK (quantity_needed_kg > 0),
    is_active          BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_receiver_category UNIQUE (receiver_id, category_id)
);
CREATE TABLE IF NOT EXISTS food_listings (
    listing_id             SERIAL PRIMARY KEY,
    donor_id               INT          NOT NULL REFERENCES donors(donor_id) ON DELETE CASCADE,
    category_id            INT          NOT NULL REFERENCES food_categories(category_id),
    title                  VARCHAR(120) NOT NULL,
    description            TEXT,
    quantity_kg            NUMERIC(8,2) NOT NULL CHECK (quantity_kg > 0),
    servings               INT          CHECK (servings > 0),
    prepared_at            TIMESTAMPTZ  NOT NULL,
    expires_at             TIMESTAMPTZ  NOT NULL,
    effective_expiry       TIMESTAMPTZ,
    location               GEOGRAPHY(POINT, 4326),
    status                 listing_status NOT NULL DEFAULT 'available',
    is_veg                 BOOLEAN      NOT NULL DEFAULT TRUE,
    allergens              TEXT,
    suitable_for_animals   BOOLEAN      NOT NULL DEFAULT FALSE,
    pickup_instructions    TEXT,
    pickup_code            VARCHAR(10),
    pickup_window_start    TIMESTAMPTZ,
    pickup_window_end      TIMESTAMPTZ,
    created_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_expiry_after_prep CHECK (expires_at > prepared_at),
    CONSTRAINT chk_prep_not_future   CHECK (prepared_at <= created_at + INTERVAL '5 minutes')
);
CREATE TABLE IF NOT EXISTS matches (
    match_id           SERIAL PRIMARY KEY,
    listing_id         INT          NOT NULL REFERENCES food_listings(listing_id) ON DELETE CASCADE,
    receiver_id        INT          NOT NULL REFERENCES receivers(receiver_id) ON DELETE CASCADE,
    priority_score     NUMERIC(6,2) NOT NULL,
    freshness_at_match NUMERIC(6,2) NOT NULL,
    distance_km        NUMERIC(6,2) NOT NULL,
    status             match_status NOT NULL DEFAULT 'pending',
    matched_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    responded_at       TIMESTAMPTZ,
    picked_up_at       TIMESTAMPTZ,
    delivered_at       TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_one_active_match_per_listing
    ON matches(listing_id)
    WHERE status IN ('pending', 'accepted', 'picked_up');
CREATE TABLE IF NOT EXISTS match_history (
    history_id  SERIAL PRIMARY KEY,
    match_id    INT          NOT NULL REFERENCES matches(match_id) ON DELETE CASCADE,
    old_status  match_status,
    new_status  match_status NOT NULL,
    changed_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS pickup_schedules (
    schedule_id  SERIAL PRIMARY KEY,
    match_id     INT           NOT NULL UNIQUE REFERENCES matches(match_id) ON DELETE CASCADE,
    scheduled_at TIMESTAMPTZ   NOT NULL,
    proposed_by  user_role     NOT NULL,
    status       pickup_status NOT NULL DEFAULT 'proposed',
    notes        TEXT,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    confirmed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_donors_location      ON donors        USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_receivers_location   ON receivers     USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_listings_location    ON food_listings USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_listings_available   ON food_listings (effective_expiry) WHERE status = 'available';
CREATE INDEX IF NOT EXISTS idx_matches_receiver_day ON matches       (receiver_id, matched_at);
CREATE INDEX IF NOT EXISTS idx_requirements_receiver ON receiver_requirements (receiver_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_pickups_time         ON pickup_schedules (scheduled_at);
DROP VIEW IF EXISTS v_impact_summary CASCADE;
DROP VIEW IF EXISTS v_ngo_capacity_today CASCADE;
DROP VIEW IF EXISTS v_receiver_capacity_today CASCADE;
DROP VIEW IF EXISTS v_available_listings CASCADE;
DROP FUNCTION IF EXISTS nearby_listings_for_ngo(INT);
DROP FUNCTION IF EXISTS nearby_listings_for_receiver(INT);
DROP FUNCTION IF EXISTS match_food_to_ngos(NUMERIC);
DROP FUNCTION IF EXISTS match_food_to_receivers(NUMERIC);
DROP FUNCTION IF EXISTS priority_score(NUMERIC, NUMERIC, NUMERIC);
DROP FUNCTION IF EXISTS freshness_score(TIMESTAMPTZ, NUMERIC, TIMESTAMPTZ);
CREATE OR REPLACE FUNCTION freshness_score(
    p_prepared_at      TIMESTAMPTZ,
    p_effective_expiry TIMESTAMPTZ,
    p_shape            NUMERIC,
    p_at               TIMESTAMPTZ DEFAULT NOW()
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT ROUND(GREATEST(0, LEAST(100,
        100 * (1 - POWER(
            LEAST(1, GREATEST(0,
                EXTRACT(EPOCH FROM (p_at - p_prepared_at))
                / NULLIF(EXTRACT(EPOCH FROM (p_effective_expiry - p_prepared_at)), 0)
            )),
            p_shape))
    ))::NUMERIC, 2);
$$;
CREATE OR REPLACE FUNCTION urgency_score(
    p_effective_expiry TIMESTAMPTZ,
    p_at               TIMESTAMPTZ DEFAULT NOW()
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT ROUND(GREATEST(0, LEAST(100,
        100 * (1 - (EXTRACT(EPOCH FROM (p_effective_expiry - p_at)) / 3600.0) / 24)
    ))::NUMERIC, 2);
$$;
CREATE OR REPLACE FUNCTION food_priority(
    p_urgency   NUMERIC,
    p_freshness NUMERIC
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND((0.6 * p_urgency + 0.4 * (100 - p_freshness))::NUMERIC, 2);
$$;
CREATE OR REPLACE FUNCTION proximity_score(
    p_distance_km NUMERIC,
    p_radius_km   NUMERIC
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND(GREATEST(0, 100 * (1 - p_distance_km / NULLIF(p_radius_km, 0)))::NUMERIC, 2);
$$;
CREATE OR REPLACE FUNCTION requirement_room_kg(
    p_receiver_id INT,
    p_category_id INT
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM receiver_requirements q
                         WHERE q.receiver_id = p_receiver_id AND q.is_active) THEN NULL
        ELSE COALESCE((
            SELECT q.quantity_needed_kg - COALESCE((
                SELECT SUM(l.quantity_kg)
                FROM matches m
                JOIN food_listings l ON l.listing_id = m.listing_id
                WHERE m.receiver_id = p_receiver_id
                  AND l.category_id = p_category_id
                  AND m.matched_at >= date_trunc('day', NOW())
                  AND m.status IN ('pending', 'accepted', 'picked_up', 'completed')
            ), 0)
            FROM receiver_requirements q
            WHERE q.receiver_id = p_receiver_id
              AND q.category_id = p_category_id
              AND q.is_active
        ), 0)
    END;
$$;
CREATE OR REPLACE FUNCTION trg_listing_prepare() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_safe_hours NUMERIC;
BEGIN
    IF NEW.location IS NULL THEN
        SELECT location INTO NEW.location FROM donors WHERE donor_id = NEW.donor_id;
    END IF;
    SELECT max_safe_hours INTO v_safe_hours
    FROM food_categories WHERE category_id = NEW.category_id;
    NEW.effective_expiry := LEAST(
        NEW.expires_at,
        NEW.prepared_at + make_interval(secs => v_safe_hours * 3600)
    );
    IF TG_OP = 'INSERT' AND NEW.effective_expiry <= NOW() THEN
        RAISE EXCEPTION 'Listing "%" is already past its safe consumption time', NEW.title;
    END IF;
    IF NEW.pickup_code IS NULL THEN
        NEW.pickup_code := LPAD((FLOOR(RANDOM() * 9000) + 1000)::TEXT, 4, '0');
    END IF;
    IF NEW.pickup_window_start IS NULL THEN
        NEW.pickup_window_start := NEW.prepared_at;
    END IF;
    IF NEW.pickup_window_end IS NULL THEN
        NEW.pickup_window_end := NEW.effective_expiry;
    END IF;
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS listing_prepare ON food_listings;
CREATE TRIGGER listing_prepare
BEFORE INSERT OR UPDATE OF prepared_at, expires_at, category_id, donor_id, location
ON food_listings
FOR EACH ROW EXECUTE FUNCTION trg_listing_prepare();
CREATE OR REPLACE FUNCTION trg_match_status_sync() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;
    INSERT INTO match_history (match_id, old_status, new_status)
    VALUES (NEW.match_id, CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, NEW.status);
    UPDATE food_listings
    SET status = CASE NEW.status
                    WHEN 'pending'   THEN 'matched'::listing_status
                    WHEN 'accepted'  THEN 'matched'::listing_status
                    WHEN 'picked_up' THEN 'picked_up'::listing_status
                    WHEN 'completed' THEN 'delivered'::listing_status
                    ELSE CASE WHEN effective_expiry > NOW()
                              THEN 'available'::listing_status
                              ELSE 'expired'::listing_status END
                 END,
        updated_at = NOW()
    WHERE listing_id = NEW.listing_id;
    IF NEW.status IN ('rejected', 'cancelled') THEN
        UPDATE pickup_schedules SET status = 'cancelled'
        WHERE match_id = NEW.match_id AND status IN ('proposed', 'confirmed');
    ELSIF NEW.status = 'picked_up' THEN
        UPDATE pickup_schedules SET status = 'completed'
        WHERE match_id = NEW.match_id AND status IN ('proposed', 'confirmed');
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS match_status_sync ON matches;
CREATE TRIGGER match_status_sync
AFTER INSERT OR UPDATE OF status ON matches
FOR EACH ROW EXECUTE FUNCTION trg_match_status_sync();
CREATE OR REPLACE FUNCTION trg_pickup_validate() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_expiry TIMESTAMPTZ;
    v_status match_status;
BEGIN
    SELECT l.effective_expiry, m.status INTO v_expiry, v_status
    FROM matches m
    JOIN food_listings l ON l.listing_id = m.listing_id
    WHERE m.match_id = NEW.match_id;
    IF NEW.status IN ('proposed', 'confirmed') THEN
        IF v_status NOT IN ('pending', 'accepted') THEN
            RAISE EXCEPTION 'A pickup can only be scheduled for a pending or accepted match';
        END IF;
        IF NEW.scheduled_at > v_expiry THEN
            RAISE EXCEPTION 'Pickup time must be before the food expires (%)', v_expiry;
        END IF;
        IF TG_OP = 'INSERT' AND NEW.scheduled_at < NOW() - INTERVAL '5 minutes' THEN
            RAISE EXCEPTION 'Pickup time cannot be in the past';
        END IF;
    END IF;
    IF NEW.status = 'confirmed' AND NEW.confirmed_at IS NULL THEN
        NEW.confirmed_at := NOW();
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS pickup_validate ON pickup_schedules;
CREATE TRIGGER pickup_validate
BEFORE INSERT OR UPDATE ON pickup_schedules
FOR EACH ROW EXECUTE FUNCTION trg_pickup_validate();
CREATE VIEW v_available_listings AS
SELECT
    x.*,
    CASE
        WHEN x.freshness >= 70 THEN 'GREEN'
        WHEN x.freshness >= 40 THEN 'YELLOW'
        ELSE 'RED'
    END                                AS freshness_band,
    food_priority(x.urgency, x.freshness) AS priority
FROM (
    SELECT
        l.listing_id,
        l.title,
        d.name                        AS donor_name,
        d.donor_type,
        l.category_id,
        c.name                        AS category,
        l.quantity_kg,
        l.servings,
        l.prepared_at,
        l.effective_expiry,
        ROUND((EXTRACT(EPOCH FROM (l.effective_expiry - NOW())) / 3600.0)::NUMERIC, 2) AS hours_left,
        freshness_score(l.prepared_at, l.effective_expiry, c.spoilage_shape) AS freshness,
        urgency_score(l.effective_expiry)                                    AS urgency,
        c.requires_refrigeration,
        l.is_veg,
        l.allergens,
        l.suitable_for_animals,
        l.pickup_instructions,
        l.pickup_code,
        l.pickup_window_start,
        l.pickup_window_end,
        l.location
    FROM food_listings l
    JOIN donors          d ON d.donor_id    = l.donor_id
    JOIN food_categories c ON c.category_id = l.category_id
    WHERE l.status = 'available'
      AND l.effective_expiry > NOW()
) x;
CREATE VIEW v_receiver_capacity_today AS
SELECT
    r.receiver_id,
    r.name,
    r.receiver_type,
    r.daily_capacity_kg,
    COALESCE(SUM(l.quantity_kg), 0)                       AS committed_kg,
    r.daily_capacity_kg - COALESCE(SUM(l.quantity_kg), 0) AS remaining_kg
FROM receivers r
LEFT JOIN matches m
       ON m.receiver_id = r.receiver_id
      AND m.matched_at >= date_trunc('day', NOW())
      AND m.status IN ('pending', 'accepted', 'picked_up', 'completed')
LEFT JOIN food_listings l ON l.listing_id = m.listing_id
GROUP BY r.receiver_id, r.name, r.receiver_type, r.daily_capacity_kg;
CREATE VIEW v_ngo_capacity_today AS
SELECT receiver_id AS ngo_id, name, daily_capacity_kg, committed_kg, remaining_kg
FROM v_receiver_capacity_today;
CREATE FUNCTION nearby_listings_for_receiver(p_receiver_id INT)
RETURNS TABLE (
    listing_id           INT,
    title                VARCHAR,
    category             VARCHAR,
    quantity_kg          NUMERIC,
    hours_left           NUMERIC,
    freshness            NUMERIC,
    distance_km          NUMERIC,
    priority             NUMERIC,
    is_veg               BOOLEAN,
    suitable_for_animals BOOLEAN,
    pickup_instructions  TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        v.listing_id,
        v.title,
        v.category,
        v.quantity_kg,
        v.hours_left,
        v.freshness,
        ROUND((ST_Distance(v.location, r.location) / 1000.0)::NUMERIC, 2) AS distance_km,
        v.priority,
        v.is_veg,
        v.suitable_for_animals,
        v.pickup_instructions
    FROM v_available_listings v
    JOIN receivers r ON r.receiver_id = p_receiver_id
    WHERE r.is_active
      AND r.verification_status = 'approved'
      AND ST_DWithin(v.location, r.location, r.service_radius_km * 1000)
      AND (NOT v.requires_refrigeration OR r.has_refrigeration)
      AND (r.receiver_type != 'animal_shelter' OR v.suitable_for_animals)
      AND COALESCE(requirement_room_kg(r.receiver_id, v.category_id), 1) > 0
    ORDER BY v.priority DESC, distance_km ASC;
$$;
CREATE FUNCTION nearby_listings_for_ngo(p_ngo_id INT)
RETURNS TABLE (
    listing_id  INT,
    title       VARCHAR,
    category    VARCHAR,
    quantity_kg NUMERIC,
    hours_left  NUMERIC,
    freshness   NUMERIC,
    distance_km NUMERIC,
    priority    NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT listing_id, title, category, quantity_kg, hours_left, freshness, distance_km, priority
    FROM nearby_listings_for_receiver(p_ngo_id);
$$;
CREATE FUNCTION match_food_to_receivers(p_min_freshness NUMERIC DEFAULT 20)
RETURNS TABLE (out_listing_id INT, out_receiver_id INT, out_priority NUMERIC, out_distance_km NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE
    v_listing RECORD;
    v_best    RECORD;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('freshlink_matcher'));
    FOR v_listing IN
        SELECT *
        FROM v_available_listings
        WHERE freshness >= p_min_freshness
        ORDER BY priority DESC, effective_expiry ASC
    LOOP
        SELECT
            r.receiver_id,
            ROUND((ST_Distance(v_listing.location, r.location) / 1000.0)::NUMERIC, 2) AS dist_km,
            proximity_score((ST_Distance(v_listing.location, r.location) / 1000.0)::NUMERIC,
                            r.service_radius_km) AS proximity,
            CASE WHEN r.receiver_type = 'animal_shelter' THEN 0 ELSE 1 END AS is_human
        INTO v_best
        FROM receivers r
        JOIN v_receiver_capacity_today cap ON cap.receiver_id = r.receiver_id
        WHERE r.is_active
          AND r.verification_status = 'approved'
          AND ST_DWithin(v_listing.location, r.location, r.service_radius_km * 1000)
          AND cap.remaining_kg >= v_listing.quantity_kg
          AND (NOT v_listing.requires_refrigeration OR r.has_refrigeration)
          AND (r.receiver_type != 'animal_shelter' OR v_listing.suitable_for_animals)
          AND COALESCE(requirement_room_kg(r.receiver_id, v_listing.category_id), v_listing.quantity_kg) >= v_listing.quantity_kg
          AND NOT EXISTS (
              SELECT 1 FROM matches m
              WHERE m.listing_id = v_listing.listing_id
                AND m.receiver_id = r.receiver_id
                AND m.status IN ('rejected', 'cancelled'))
        ORDER BY is_human DESC, proximity DESC, dist_km ASC
        LIMIT 1;
        IF FOUND THEN
            INSERT INTO matches (listing_id, receiver_id, priority_score, freshness_at_match, distance_km)
            VALUES (v_listing.listing_id, v_best.receiver_id, v_listing.priority, v_listing.freshness, v_best.dist_km);
            out_listing_id  := v_listing.listing_id;
            out_receiver_id := v_best.receiver_id;
            out_priority    := v_listing.priority;
            out_distance_km := v_best.dist_km;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;
CREATE FUNCTION match_food_to_ngos(p_min_freshness NUMERIC DEFAULT 20)
RETURNS TABLE (out_listing_id INT, out_ngo_id INT, out_priority NUMERIC, out_distance_km NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT f.out_listing_id, f.out_receiver_id, f.out_priority, f.out_distance_km
    FROM match_food_to_receivers(p_min_freshness) f;
END;
$$;
CREATE OR REPLACE FUNCTION expire_stale_listings(p_pending_timeout_min INT DEFAULT 30)
RETURNS TABLE (expired_listings INT, cancelled_matches INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_cancelled INT;
    v_expired   INT;
BEGIN
    UPDATE matches m
    SET status = 'cancelled', responded_at = NOW()
    FROM food_listings l
    WHERE l.listing_id = m.listing_id
      AND m.status = 'pending'
      AND (l.effective_expiry <= NOW()
           OR m.matched_at < NOW() - make_interval(mins => p_pending_timeout_min));
    GET DIAGNOSTICS v_cancelled = ROW_COUNT;
    UPDATE food_listings
    SET status = 'expired', updated_at = NOW()
    WHERE status IN ('available', 'matched')
      AND effective_expiry <= NOW()
      AND NOT EXISTS (SELECT 1 FROM matches m
                      WHERE m.listing_id = food_listings.listing_id
                        AND m.status IN ('accepted', 'picked_up'));
    GET DIAGNOSTICS v_expired = ROW_COUNT;
    UPDATE pickup_schedules
    SET status = 'missed'
    WHERE status IN ('proposed', 'confirmed')
      AND scheduled_at < NOW() - INTERVAL '2 hours';
    expired_listings  := v_expired;
    cancelled_matches := v_cancelled;
    RETURN NEXT;
END;
$$;
CREATE VIEW v_impact_summary AS
SELECT
    d.donor_type,
    COUNT(*) FILTER (WHERE l.status = 'delivered')                        AS deliveries,
    COALESCE(SUM(l.quantity_kg) FILTER (WHERE l.status = 'delivered'), 0) AS kg_saved,
    COUNT(*) FILTER (WHERE l.status = 'expired')                          AS expired,
    ROUND(100.0 * COUNT(*) FILTER (WHERE l.status = 'delivered')
          / NULLIF(COUNT(*), 0), 1)                                       AS rescue_rate_pct
FROM food_listings l
JOIN donors d ON d.donor_id = l.donor_id
GROUP BY d.donor_type;
