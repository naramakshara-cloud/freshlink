-- =====================================================================
-- Migration 001: Initial Multi-User Schema
-- Creates users, donors, receivers, listings, matches, and functions.
-- Safe to run on empty database or existing database.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis;

-- 1. Enum Types
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
        CREATE TYPE user_role AS ENUM ('donor', 'receiver', 'admin');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'donor_type') THEN
        CREATE TYPE donor_type AS ENUM ('hostel', 'canteen', 'household', 'restaurant', 'event', 'other');
    ELSE
        ALTER TYPE donor_type ADD VALUE IF NOT EXISTS 'other';
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

-- 2. Users Table
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

-- 3. Food Categories Table
CREATE TABLE IF NOT EXISTS food_categories (
    category_id            SERIAL PRIMARY KEY,
    name                   VARCHAR(60)  NOT NULL UNIQUE,
    decay_rate             NUMERIC(6,4) NOT NULL CHECK (decay_rate > 0),
    max_safe_hours         NUMERIC(6,2) NOT NULL CHECK (max_safe_hours > 0),
    requires_refrigeration BOOLEAN      NOT NULL DEFAULT FALSE,
    description            TEXT
);

-- 4. Donors Table
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

-- 5. Receivers Table (formerly ngos)
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

-- 6. Food Listings
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

-- 7. Matches
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

-- 8. Match History
CREATE TABLE IF NOT EXISTS match_history (
    history_id  SERIAL PRIMARY KEY,
    match_id    INT          NOT NULL REFERENCES matches(match_id) ON DELETE CASCADE,
    old_status  match_status,
    new_status  match_status NOT NULL,
    changed_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_donors_location      ON donors        USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_receivers_location   ON receivers     USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_listings_location    ON food_listings USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_listings_available   ON food_listings (effective_expiry) WHERE status = 'available';
CREATE INDEX IF NOT EXISTS idx_matches_receiver_day ON matches       (receiver_id, matched_at);
