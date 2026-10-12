-- =====================================================================
-- FRESHLINK: Hyperlocal Food Surplus Redistribution Database System
-- Schema Definition (Multi-User, Receiver Hierarchy, Safety Guards)
-- Target: PostgreSQL 14+ with PostGIS 3+
--
-- NOTE: This file does NOT contain DROP TABLE statements so existing
-- data is never deleted. For upgrades, see the migrations/ directory.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis;

-- ---------------------------------------------------------------------
-- 1. ENUM TYPES
-- ---------------------------------------------------------------------
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
        CREATE TYPE user_role AS ENUM ('donor', 'receiver', 'admin');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'donor_type') THEN
        CREATE TYPE donor_type AS ENUM ('hostel', 'canteen', 'household', 'restaurant', 'event', 'other');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'receiver_type') THEN
        CREATE TYPE receiver_type AS ENUM (
            'individual_or_family',
            'ngo',
            'animal_shelter',
            'orphanage',
            'old_age_home',
            'community_kitchen'
        );
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
END $$;

-- ---------------------------------------------------------------------
-- 2. USERS
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 3. FOOD CATEGORIES
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS food_categories (
    category_id            SERIAL PRIMARY KEY,
    name                   VARCHAR(60)  NOT NULL UNIQUE,
    decay_rate             NUMERIC(6,4) NOT NULL CHECK (decay_rate > 0),
    max_safe_hours         NUMERIC(6,2) NOT NULL CHECK (max_safe_hours > 0),
    requires_refrigeration BOOLEAN      NOT NULL DEFAULT FALSE,
    description            TEXT
);

-- ---------------------------------------------------------------------
-- 4. DONORS (linked to users)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 5. RECEIVERS (formerly ngos; individuals/families, shelters, NGOs)
-- ---------------------------------------------------------------------
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

-- Ensure individuals/families get 5kg default and orgs get 50kg default if omitted
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

-- ---------------------------------------------------------------------
-- 6. FOOD LISTINGS (surplus posts)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 7. MATCHES (listing -> receiver assignments)
-- ---------------------------------------------------------------------
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

-- One active match per listing at a time
CREATE UNIQUE INDEX IF NOT EXISTS uq_one_active_match_per_listing
    ON matches(listing_id)
    WHERE status IN ('pending', 'accepted', 'picked_up');

-- ---------------------------------------------------------------------
-- 8. MATCH HISTORY (audit log)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS match_history (
    history_id  SERIAL PRIMARY KEY,
    match_id    INT          NOT NULL REFERENCES matches(match_id) ON DELETE CASCADE,
    old_status  match_status,
    new_status  match_status NOT NULL,
    changed_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------
-- 9. INDEXES
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_donors_location      ON donors        USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_receivers_location   ON receivers     USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_listings_location    ON food_listings USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_listings_available   ON food_listings (effective_expiry) WHERE status = 'available';
CREATE INDEX IF NOT EXISTS idx_matches_receiver_day ON matches       (receiver_id, matched_at);

-- =====================================================================
-- SCORING FUNCTIONS
-- =====================================================================

CREATE OR REPLACE FUNCTION freshness_score(
    p_prepared_at TIMESTAMPTZ,
    p_decay_rate  NUMERIC,
    p_at          TIMESTAMPTZ DEFAULT NOW()
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT ROUND(
        GREATEST(0, LEAST(100,
            100 * EXP(-p_decay_rate *
                GREATEST(0, EXTRACT(EPOCH FROM (p_at - p_prepared_at)) / 3600.0))
        ))::NUMERIC, 2);
$$;

CREATE OR REPLACE FUNCTION urgency_score(
    p_effective_expiry TIMESTAMPTZ,
    p_at               TIMESTAMPTZ DEFAULT NOW()
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT ROUND(GREATEST(0, LEAST(100,
        100 - (EXTRACT(EPOCH FROM (p_effective_expiry - p_at)) / 3600.0) * (100.0 / 24)
    ))::NUMERIC, 2);
$$;

CREATE OR REPLACE FUNCTION proximity_score(
    p_distance_km NUMERIC,
    p_radius_km   NUMERIC
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND(GREATEST(0, 100 * (1 - p_distance_km / NULLIF(p_radius_km, 0)))::NUMERIC, 2);
$$;

-- Combined priority: 50% urgency + 30% freshness + 20% proximity
CREATE OR REPLACE FUNCTION priority_score(
    p_urgency   NUMERIC,
    p_freshness NUMERIC,
    p_proximity NUMERIC
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND((0.5 * p_urgency + 0.3 * p_freshness + 0.2 * p_proximity)::NUMERIC, 2);
$$;

-- =====================================================================
-- TRIGGERS
-- =====================================================================

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

    -- Generate random 4-digit pickup code if not provided
    IF NEW.pickup_code IS NULL THEN
        NEW.pickup_code := LPAD((FLOOR(RANDOM() * 9000) + 1000)::TEXT, 4, '0');
    END IF;

    -- Default pickup window to prepared_at -> effective_expiry if not set
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

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS match_status_sync ON matches;
CREATE TRIGGER match_status_sync
AFTER INSERT OR UPDATE OF status ON matches
FOR EACH ROW EXECUTE FUNCTION trg_match_status_sync();

-- =====================================================================
-- VIEWS
-- =====================================================================

-- Live feed of available food with freshness and time remaining
CREATE OR REPLACE VIEW v_available_listings AS
SELECT
    l.listing_id,
    l.title,
    d.name                        AS donor_name,
    d.donor_type,
    c.name                        AS category,
    l.quantity_kg,
    l.servings,
    l.prepared_at,
    l.effective_expiry,
    ROUND((EXTRACT(EPOCH FROM (l.effective_expiry - NOW())) / 3600.0)::NUMERIC, 2) AS hours_left,
    freshness_score(l.prepared_at, c.decay_rate) AS freshness,
    urgency_score(l.effective_expiry)            AS urgency,
    CASE
        WHEN freshness_score(l.prepared_at, c.decay_rate) >= 70 THEN 'GREEN'
        WHEN freshness_score(l.prepared_at, c.decay_rate) >= 40 THEN 'YELLOW'
        ELSE 'RED'
    END                           AS freshness_band,
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
  AND l.effective_expiry > NOW();

-- Receiver capacity view
CREATE OR REPLACE VIEW v_receiver_capacity_today AS
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

-- Backward compatibility alias for ngo capacity
CREATE OR REPLACE VIEW v_ngo_capacity_today AS
SELECT
    receiver_id       AS ngo_id,
    name,
    daily_capacity_kg,
    committed_kg,
    remaining_kg
FROM v_receiver_capacity_today;

-- =====================================================================
-- CORE OPERATIONS
-- =====================================================================

-- Nearby listings for a receiver
CREATE OR REPLACE FUNCTION nearby_listings_for_receiver(p_receiver_id INT)
RETURNS TABLE (
    listing_id     INT,
    title          VARCHAR,
    category       VARCHAR,
    quantity_kg    NUMERIC,
    hours_left     NUMERIC,
    freshness      NUMERIC,
    distance_km    NUMERIC,
    priority       NUMERIC,
    is_veg         BOOLEAN,
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
        priority_score(
            v.urgency,
            v.freshness,
            proximity_score((ST_Distance(v.location, r.location) / 1000.0)::NUMERIC, r.service_radius_km)
        ) AS priority,
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
    ORDER BY priority DESC, v.hours_left ASC;
$$;

-- Compatibility alias for nearby_listings_for_ngo
CREATE OR REPLACE FUNCTION nearby_listings_for_ngo(p_ngo_id INT)
RETURNS TABLE (
    listing_id     INT,
    title          VARCHAR,
    category       VARCHAR,
    quantity_kg    NUMERIC,
    hours_left     NUMERIC,
    freshness      NUMERIC,
    distance_km    NUMERIC,
    priority       NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT
        listing_id, title, category, quantity_kg, hours_left, freshness, distance_km, priority
    FROM nearby_listings_for_receiver(p_ngo_id);
$$;

-- Expiry-aware scheduler: greedy matching.
-- Rules:
-- 1. Never match expired or unsafe food (v_available_listings enforces effective_expiry > NOW() and freshness >= min)
-- 2. Only approved, active receivers can get food
-- 3. Human receivers get priority (human boost bonus in ordering)
-- 4. Animal shelters ONLY receive food marked suitable_for_animals
CREATE OR REPLACE FUNCTION match_food_to_receivers(p_min_freshness NUMERIC DEFAULT 20)
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
          AND effective_expiry > NOW()
        ORDER BY effective_expiry ASC, freshness DESC
    LOOP
        SELECT
            r.receiver_id,
            ROUND((ST_Distance(v_listing.location, r.location) / 1000.0)::NUMERIC, 2) AS dist_km,
            priority_score(
                v_listing.urgency,
                v_listing.freshness,
                proximity_score((ST_Distance(v_listing.location, r.location) / 1000.0)::NUMERIC,
                                r.service_radius_km)
            ) AS prio,
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
          AND NOT EXISTS (
              SELECT 1 FROM matches m
              WHERE m.listing_id = v_listing.listing_id
                AND m.receiver_id = r.receiver_id
                AND m.status = 'rejected')
        ORDER BY
            is_human DESC,  -- Human receivers get priority over animal shelters
            prio DESC,
            dist_km ASC
        LIMIT 1;

        IF FOUND THEN
            INSERT INTO matches (listing_id, receiver_id, priority_score, freshness_at_match, distance_km)
            VALUES (v_listing.listing_id, v_best.receiver_id, v_best.prio, v_listing.freshness, v_best.dist_km);

            out_listing_id  := v_listing.listing_id;
            out_receiver_id := v_best.receiver_id;
            out_priority    := v_best.prio;
            out_distance_km := v_best.dist_km;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

-- Compatibility alias for match_food_to_ngos
CREATE OR REPLACE FUNCTION match_food_to_ngos(p_min_freshness NUMERIC DEFAULT 20)
RETURNS TABLE (out_listing_id INT, out_ngo_id INT, out_priority NUMERIC, out_distance_km NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT out_listing_id, out_receiver_id, out_priority, out_distance_km
    FROM match_food_to_receivers(p_min_freshness);
END;
$$;

-- Housekeeping
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

    expired_listings  := v_expired;
    cancelled_matches := v_cancelled;
    RETURN NEXT;
END;
$$;

-- =====================================================================
-- REPORTING
-- =====================================================================

CREATE OR REPLACE VIEW v_impact_summary AS
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
