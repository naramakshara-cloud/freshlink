-- =====================================================================
-- FRESHLINK: Hyperlocal Food Surplus Redistribution Database System
-- Real-time surplus food matching using SQL-based freshness decay
-- and expiry-aware scheduling.
--
-- Target: PostgreSQL 14+ with PostGIS 3+
-- Run:    psql -d freshlink -f schema.sql
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis;

-- Clean re-run support (development only)
DROP VIEW     IF EXISTS v_available_listings CASCADE;
DROP TABLE    IF EXISTS match_history, matches, food_listings, ngos, donors, food_categories CASCADE;
DROP TYPE     IF EXISTS donor_type, listing_status, match_status CASCADE;

-- ---------------------------------------------------------------------
-- 1. ENUM TYPES
-- ---------------------------------------------------------------------
CREATE TYPE donor_type     AS ENUM ('hostel', 'canteen', 'household', 'restaurant', 'event');
CREATE TYPE listing_status AS ENUM ('available', 'matched', 'picked_up', 'delivered', 'expired', 'cancelled');
CREATE TYPE match_status   AS ENUM ('pending', 'accepted', 'rejected', 'picked_up', 'completed', 'cancelled');

-- ---------------------------------------------------------------------
-- 2. FOOD CATEGORIES
--    decay_rate     : k in  freshness = 100 * e^(-k * hours_since_prepared)
--    max_safe_hours : hard food-safety limit after preparation
-- ---------------------------------------------------------------------
CREATE TABLE food_categories (
    category_id            SERIAL PRIMARY KEY,
    name                   VARCHAR(60)  NOT NULL UNIQUE,
    decay_rate             NUMERIC(6,4) NOT NULL CHECK (decay_rate > 0),
    max_safe_hours         NUMERIC(6,2) NOT NULL CHECK (max_safe_hours > 0),
    requires_refrigeration BOOLEAN      NOT NULL DEFAULT FALSE,
    description            TEXT
);

-- ---------------------------------------------------------------------
-- 3. DONORS (hostels, canteens, households ...)
-- ---------------------------------------------------------------------
CREATE TABLE donors (
    donor_id      SERIAL PRIMARY KEY,
    name          VARCHAR(120) NOT NULL,
    donor_type    donor_type   NOT NULL,
    contact_phone VARCHAR(20)  NOT NULL,
    email         VARCHAR(120) UNIQUE,
    address       TEXT         NOT NULL,
    location      GEOGRAPHY(POINT, 4326) NOT NULL,
    is_verified   BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------
-- 4. NGOs (receivers)
-- ---------------------------------------------------------------------
CREATE TABLE ngos (
    ngo_id            SERIAL PRIMARY KEY,
    name              VARCHAR(120) NOT NULL,
    contact_phone     VARCHAR(20)  NOT NULL,
    email             VARCHAR(120) UNIQUE,
    address           TEXT         NOT NULL,
    location          GEOGRAPHY(POINT, 4326) NOT NULL,
    service_radius_km NUMERIC(5,2) NOT NULL DEFAULT 5  CHECK (service_radius_km > 0),
    daily_capacity_kg NUMERIC(8,2) NOT NULL DEFAULT 50 CHECK (daily_capacity_kg > 0),
    has_refrigeration BOOLEAN      NOT NULL DEFAULT FALSE,
    is_active         BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------
-- 5. FOOD LISTINGS (surplus posts)
--    effective_expiry = earlier of donor-stated expiry and the
--    category's food-safety limit. Maintained by trigger.
-- ---------------------------------------------------------------------
CREATE TABLE food_listings (
    listing_id       SERIAL PRIMARY KEY,
    donor_id         INT          NOT NULL REFERENCES donors(donor_id) ON DELETE CASCADE,
    category_id      INT          NOT NULL REFERENCES food_categories(category_id),
    title            VARCHAR(120) NOT NULL,
    description      TEXT,
    quantity_kg      NUMERIC(8,2) NOT NULL CHECK (quantity_kg > 0),
    servings         INT          CHECK (servings > 0),
    prepared_at      TIMESTAMPTZ  NOT NULL,
    expires_at       TIMESTAMPTZ  NOT NULL,
    effective_expiry TIMESTAMPTZ,
    location         GEOGRAPHY(POINT, 4326),
    status           listing_status NOT NULL DEFAULT 'available',
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_expiry_after_prep CHECK (expires_at > prepared_at),
    CONSTRAINT chk_prep_not_future   CHECK (prepared_at <= created_at + INTERVAL '5 minutes')
);

-- ---------------------------------------------------------------------
-- 6. MATCHES (listing -> NGO assignments)
-- ---------------------------------------------------------------------
CREATE TABLE matches (
    match_id           SERIAL PRIMARY KEY,
    listing_id         INT          NOT NULL REFERENCES food_listings(listing_id) ON DELETE CASCADE,
    ngo_id             INT          NOT NULL REFERENCES ngos(ngo_id) ON DELETE CASCADE,
    priority_score     NUMERIC(6,2) NOT NULL,
    freshness_at_match NUMERIC(6,2) NOT NULL,
    distance_km        NUMERIC(6,2) NOT NULL,
    status             match_status NOT NULL DEFAULT 'pending',
    matched_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    responded_at       TIMESTAMPTZ,
    picked_up_at       TIMESTAMPTZ,
    delivered_at       TIMESTAMPTZ
);

-- A listing may only have ONE active match at a time
CREATE UNIQUE INDEX uq_one_active_match_per_listing
    ON matches(listing_id)
    WHERE status IN ('pending', 'accepted', 'picked_up');

-- ---------------------------------------------------------------------
-- 7. MATCH HISTORY (audit log of status changes)
-- ---------------------------------------------------------------------
CREATE TABLE match_history (
    history_id  SERIAL PRIMARY KEY,
    match_id    INT          NOT NULL REFERENCES matches(match_id) ON DELETE CASCADE,
    old_status  match_status,
    new_status  match_status NOT NULL,
    changed_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------
-- 8. INDEXES
-- ---------------------------------------------------------------------
CREATE INDEX idx_donors_location    ON donors        USING GIST (location);
CREATE INDEX idx_ngos_location      ON ngos          USING GIST (location);
CREATE INDEX idx_listings_location  ON food_listings USING GIST (location);
CREATE INDEX idx_listings_available ON food_listings (effective_expiry) WHERE status = 'available';
CREATE INDEX idx_matches_ngo_day    ON matches       (ngo_id, matched_at);

-- =====================================================================
-- SCORING FUNCTIONS
-- =====================================================================

-- Freshness decay: 100 * e^(-k * hours elapsed), clamped to [0, 100]
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

-- Urgency: rises linearly from 0 (24h+ left) to 100 (expiring now)
CREATE OR REPLACE FUNCTION urgency_score(
    p_effective_expiry TIMESTAMPTZ,
    p_at               TIMESTAMPTZ DEFAULT NOW()
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT ROUND(GREATEST(0, LEAST(100,
        100 - (EXTRACT(EPOCH FROM (p_effective_expiry - p_at)) / 3600.0) * (100.0 / 24)
    ))::NUMERIC, 2);
$$;

-- Proximity: 100 at the NGO's door, 0 at the edge of its service radius
CREATE OR REPLACE FUNCTION proximity_score(
    p_distance_km NUMERIC,
    p_radius_km   NUMERIC
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND(GREATEST(0, 100 * (1 - p_distance_km / NULLIF(p_radius_km, 0)))::NUMERIC, 2);
$$;

-- Combined priority (weights sum to 1.0; tune for your report)
--   50% urgency  -> food closest to expiry goes first
--   30% freshness-> fresher food is better quality for recipients
--   20% proximity-> shorter trips, faster pickup
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

-- Before insert/update on listings:
--   * default location to the donor's location
--   * compute effective_expiry = LEAST(stated expiry, prepared + safe limit)
--   * reject listings that are already unsafe
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

    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER listing_prepare
BEFORE INSERT OR UPDATE OF prepared_at, expires_at, category_id, donor_id, location
ON food_listings
FOR EACH ROW EXECUTE FUNCTION trg_listing_prepare();

-- After a match changes status: log it and keep the listing in sync
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
                    -- rejected / cancelled: put back in the pool if still safe
                    ELSE CASE WHEN effective_expiry > NOW()
                              THEN 'available'::listing_status
                              ELSE 'expired'::listing_status END
                 END,
        updated_at = NOW()
    WHERE listing_id = NEW.listing_id;

    RETURN NEW;
END;
$$;

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
    l.location
FROM food_listings l
JOIN donors          d ON d.donor_id    = l.donor_id
JOIN food_categories c ON c.category_id = l.category_id
WHERE l.status = 'available'
  AND l.effective_expiry > NOW();

-- NGO's remaining capacity for today
CREATE OR REPLACE VIEW v_ngo_capacity_today AS
SELECT
    n.ngo_id,
    n.name,
    n.daily_capacity_kg,
    COALESCE(SUM(l.quantity_kg), 0)                       AS committed_kg,
    n.daily_capacity_kg - COALESCE(SUM(l.quantity_kg), 0) AS remaining_kg
FROM ngos n
LEFT JOIN matches m
       ON m.ngo_id = n.ngo_id
      AND m.matched_at >= date_trunc('day', NOW())
      AND m.status IN ('pending', 'accepted', 'picked_up', 'completed')
LEFT JOIN food_listings l ON l.listing_id = m.listing_id
GROUP BY n.ngo_id, n.name, n.daily_capacity_kg;

-- =====================================================================
-- CORE OPERATIONS
-- =====================================================================

-- Listings near an NGO, ranked by combined priority
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
        v.listing_id,
        v.title,
        v.category,
        v.quantity_kg,
        v.hours_left,
        v.freshness,
        ROUND((ST_Distance(v.location, n.location) / 1000.0)::NUMERIC, 2) AS distance_km,
        priority_score(
            v.urgency,
            v.freshness,
            proximity_score((ST_Distance(v.location, n.location) / 1000.0)::NUMERIC, n.service_radius_km)
        ) AS priority
    FROM v_available_listings v
    JOIN ngos n ON n.ngo_id = p_ngo_id
    WHERE ST_DWithin(v.location, n.location, n.service_radius_km * 1000)
      AND (NOT v.requires_refrigeration OR n.has_refrigeration)
    ORDER BY priority DESC, v.hours_left ASC;
$$;

-- Expiry-aware scheduler: greedy matching.
-- Processes listings in order of soonest expiry and assigns each to the
-- best-scoring eligible NGO (in range, active, has capacity, can store it).
-- Food below p_min_freshness is skipped as unsuitable.
CREATE OR REPLACE FUNCTION match_food_to_ngos(p_min_freshness NUMERIC DEFAULT 20)
RETURNS TABLE (out_listing_id INT, out_ngo_id INT, out_priority NUMERIC, out_distance_km NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE
    v_listing RECORD;
    v_best    RECORD;
BEGIN
    -- Only one scheduler run at a time (safe if cron and an API call overlap)
    PERFORM pg_advisory_xact_lock(hashtext('freshlink_matcher'));

    FOR v_listing IN
        SELECT *
        FROM v_available_listings
        WHERE freshness >= p_min_freshness
        ORDER BY effective_expiry ASC, freshness DESC
    LOOP
        SELECT
            n.ngo_id,
            ROUND((ST_Distance(v_listing.location, n.location) / 1000.0)::NUMERIC, 2) AS dist_km,
            priority_score(
                v_listing.urgency,
                v_listing.freshness,
                proximity_score((ST_Distance(v_listing.location, n.location) / 1000.0)::NUMERIC,
                                n.service_radius_km)
            ) AS prio
        INTO v_best
        FROM ngos n
        JOIN v_ngo_capacity_today cap ON cap.ngo_id = n.ngo_id
        WHERE n.is_active
          AND ST_DWithin(v_listing.location, n.location, n.service_radius_km * 1000)
          AND cap.remaining_kg >= v_listing.quantity_kg
          AND (NOT v_listing.requires_refrigeration OR n.has_refrigeration)
          -- don't re-offer to an NGO that already rejected this listing
          AND NOT EXISTS (
              SELECT 1 FROM matches m
              WHERE m.listing_id = v_listing.listing_id
                AND m.ngo_id = n.ngo_id
                AND m.status = 'rejected')
        ORDER BY prio DESC, dist_km ASC
        LIMIT 1;

        IF FOUND THEN
            INSERT INTO matches (listing_id, ngo_id, priority_score, freshness_at_match, distance_km)
            VALUES (v_listing.listing_id, v_best.ngo_id, v_best.prio, v_listing.freshness, v_best.dist_km);

            out_listing_id  := v_listing.listing_id;
            out_ngo_id      := v_best.ngo_id;
            out_priority    := v_best.prio;
            out_distance_km := v_best.dist_km;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

-- Housekeeping: expire unsafe listings and cancel stale pending matches.
-- Run every few minutes (see scheduling note at the bottom).
CREATE OR REPLACE FUNCTION expire_stale_listings(p_pending_timeout_min INT DEFAULT 30)
RETURNS TABLE (expired_listings INT, cancelled_matches INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_cancelled INT;
    v_expired   INT;
BEGIN
    -- 1. Cancel matches whose food expired or NGO didn't respond in time
    UPDATE matches m
    SET status = 'cancelled', responded_at = NOW()
    FROM food_listings l
    WHERE l.listing_id = m.listing_id
      AND m.status = 'pending'
      AND (l.effective_expiry <= NOW()
           OR m.matched_at < NOW() - make_interval(mins => p_pending_timeout_min));
    GET DIAGNOSTICS v_cancelled = ROW_COUNT;

    -- 2. Expire anything still available past its safe time
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

-- Impact summary per donor type (useful for dashboards / project report)
CREATE OR REPLACE VIEW v_impact_summary AS
SELECT
    d.donor_type,
    COUNT(*) FILTER (WHERE l.status = 'delivered')                    AS deliveries,
    COALESCE(SUM(l.quantity_kg) FILTER (WHERE l.status = 'delivered'), 0) AS kg_saved,
    COUNT(*) FILTER (WHERE l.status = 'expired')                      AS expired,
    ROUND(100.0 * COUNT(*) FILTER (WHERE l.status = 'delivered')
          / NULLIF(COUNT(*), 0), 1)                                   AS rescue_rate_pct
FROM food_listings l
JOIN donors d ON d.donor_id = l.donor_id
GROUP BY d.donor_type;

-- =====================================================================
-- SCHEDULING NOTE
-- With the pg_cron extension installed you can automate the scheduler:
--   CREATE EXTENSION pg_cron;
--   SELECT cron.schedule('freshlink-expire', '*/5 * * * *',
--                        'SELECT * FROM expire_stale_listings()');
--   SELECT cron.schedule('freshlink-match',  '*/5 * * * *',
--                        'SELECT * FROM match_food_to_ngos()');
-- Otherwise, call these two functions from a backend cron job.
-- =====================================================================
