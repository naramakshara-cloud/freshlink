"""
FreshLink FastAPI Backend
Connects the frontend to PostgreSQL + PostGIS database.
Run with: uvicorn main:app --reload --port 8000
"""

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional
from pathlib import Path
import psycopg2
import psycopg2.extras
import subprocess
import os
from dotenv import load_dotenv

# Load environment variables from .env file (checked in root or current dir)
env_path = Path(__file__).resolve().parent.parent / ".env"
load_dotenv(dotenv_path=env_path)
load_dotenv()  # fallback for local execution

app = FastAPI(title="FreshLink API", version="2.0")

# Allow the frontend (any origin during dev) to talk to this server
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Database connection ────────────────────────────────────────────────────────
DB_CONFIG = {
    "dbname":   os.getenv("DB_NAME",     "freshlink"),
    "user":     os.getenv("DB_USER",     "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
    "host":     os.getenv("DB_HOST",     "localhost"),
    "port":     os.getenv("DB_PORT",     "5432"),
}

def get_conn():
    return psycopg2.connect(**DB_CONFIG)

def query(sql: str, params=None, fetch="all"):
    conn = get_conn()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params)
            conn.commit()
            if fetch == "all":
                return cur.fetchall()
            elif fetch == "one":
                return cur.fetchone()
            return None
    finally:
        conn.close()


# ── Pydantic models ────────────────────────────────────────────────────────────

class ListingCreate(BaseModel):
    donor_id:             int
    category_id:          int
    title:                str
    description:          Optional[str] = None
    quantity_kg:          float
    servings:             Optional[int] = None
    prepared_at:          str   # ISO datetime string
    expires_at:           str   # ISO datetime string
    is_veg:               Optional[bool] = True
    allergens:            Optional[str] = None
    suitable_for_animals: Optional[bool] = False
    pickup_instructions:  Optional[str] = None
    pickup_code:          Optional[str] = None

class MatchAction(BaseModel):
    action: str   # "accepted" | "rejected" | "picked_up" | "completed" | "cancelled"


# ── ADMIN & DEMO RESET ─────────────────────────────────────────────────────────

@app.post("/admin/reset")
def reset_demo_data():
    """
    Reset demo data safely by loading schema.sql, seed.sql, and demo_seed.sql.
    Cleans matches/listings and re-inserts fresh demo accounts and listings.
    """
    db_dir = Path(__file__).parent.parent / "database"
    env = os.environ.copy()
    env["PGPASSWORD"] = DB_CONFIG["password"]

    # First clean transient tables to guarantee fresh demo state
    try:
        query("DELETE FROM match_history; DELETE FROM matches; DELETE FROM food_listings; DELETE FROM receivers; DELETE FROM donors; DELETE FROM users;", fetch=None)
    except Exception as e:
        # Ignore if tables are empty or newly initialized
        pass

    for fname in ["schema.sql", "seed.sql", "demo_seed.sql"]:
        fpath = db_dir / fname
        if not fpath.exists():
            continue
        result = subprocess.run(
            [
                "psql",
                "-U", DB_CONFIG["user"],
                "-d", DB_CONFIG["dbname"],
                "-h", DB_CONFIG["host"],
                "-p", str(DB_CONFIG["port"]),
                "-f", str(fpath),
            ],
            env=env,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise HTTPException(
                status_code=500,
                detail=f"Error running {fname}: {result.stderr[:500]}"
            )

    return {"message": "Demo data reset successfully"}


# ── USERS ──────────────────────────────────────────────────────────────────────

@app.get("/users")
def list_users():
    rows = query("SELECT user_id, email, full_name, phone, role, is_active, created_at FROM users ORDER BY user_id")
    return [dict(r) for r in rows]


# ── DONORS ─────────────────────────────────────────────────────────────────────

@app.get("/donors")
def list_donors():
    rows = query("SELECT donor_id, user_id, name, donor_type, contact_phone, email, address, is_verified FROM donors ORDER BY name")
    return [dict(r) for r in rows]


# ── FOOD CATEGORIES ────────────────────────────────────────────────────────────

@app.get("/categories")
def list_categories():
    rows = query(
        "SELECT category_id, name, requires_refrigeration, decay_rate, max_safe_hours FROM food_categories ORDER BY name"
    )
    return [dict(r) for r in rows]


# ── FOOD LISTINGS ──────────────────────────────────────────────────────────────

@app.post("/listings", status_code=201)
def create_listing(body: ListingCreate):
    try:
        row = query(
            """
            INSERT INTO food_listings
                (donor_id, category_id, title, description,
                 quantity_kg, servings, prepared_at, expires_at,
                 is_veg, allergens, suitable_for_animals, pickup_instructions, pickup_code)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            RETURNING listing_id, pickup_code
            """,
            (body.donor_id, body.category_id, body.title, body.description,
             body.quantity_kg, body.servings, body.prepared_at, body.expires_at,
             body.is_veg, body.allergens, body.suitable_for_animals, body.pickup_instructions, body.pickup_code),
            fetch="one",
        )
        return {"listing_id": row["listing_id"], "pickup_code": row["pickup_code"], "message": "Listing created"}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/listings/available")
def available_listings():
    """Live feed used by the Receiver / NGO dashboard."""
    rows = query(
        """
        SELECT listing_id, title, donor_name, donor_type, category,
               quantity_kg, servings, prepared_at, effective_expiry,
               hours_left, freshness, urgency, freshness_band,
               requires_refrigeration, is_veg, allergens, suitable_for_animals,
               pickup_instructions, pickup_code, pickup_window_start, pickup_window_end
        FROM v_available_listings
        ORDER BY hours_left ASC
        """
    )
    return [dict(r) for r in rows]


# ── RECEIVERS (Formerly NGOs) ──────────────────────────────────────────────────

@app.get("/receivers")
def list_receivers():
    rows = query(
        """
        SELECT receiver_id, user_id, name, receiver_type, verification_status,
               address, service_radius_km, daily_capacity_kg, has_refrigeration, is_active
        FROM receivers
        ORDER BY name
        """
    )
    return [dict(r) for r in rows]


@app.get("/receivers/capacity")
def receiver_capacity():
    rows = query(
        """
        SELECT receiver_id, name, receiver_type, daily_capacity_kg, committed_kg, remaining_kg
        FROM v_receiver_capacity_today
        """
    )
    return [dict(r) for r in rows]


@app.get("/receivers/{receiver_id}/listings")
def nearby_listings_for_receiver_endpoint(receiver_id: int):
    """Priority-sorted listings for a specific receiver."""
    rows = query(
        "SELECT * FROM nearby_listings_for_receiver(%s)",
        (receiver_id,)
    )
    return [dict(r) for r in rows]


# Compatibility aliases for NGO routes
@app.get("/ngos")
def list_ngos_alias():
    rows = query(
        """
        SELECT receiver_id AS ngo_id, name, receiver_type, verification_status,
               address, service_radius_km, daily_capacity_kg, has_refrigeration, is_active
        FROM receivers
        ORDER BY name
        """
    )
    return [dict(r) for r in rows]


@app.get("/ngos/capacity")
def ngo_capacity_alias():
    rows = query(
        """
        SELECT receiver_id AS ngo_id, name, daily_capacity_kg, committed_kg, remaining_kg
        FROM v_receiver_capacity_today
        """
    )
    return [dict(r) for r in rows]


@app.get("/ngos/{ngo_id}/listings")
def nearby_listings_alias(ngo_id: int):
    rows = query(
        "SELECT * FROM nearby_listings_for_receiver(%s)",
        (ngo_id,)
    )
    return [dict(r) for r in rows]


# ── MATCHES ────────────────────────────────────────────────────────────────────

@app.post("/matches/run")
def run_matcher():
    """Trigger the expiry-aware greedy scheduler with human prioritization & animal shelter rules."""
    rows = query("SELECT * FROM match_food_to_receivers()")
    return {"matched": len(rows), "results": [dict(r) for r in rows]}


@app.get("/matches")
def list_matches():
    rows = query(
        """
        SELECT m.match_id, m.listing_id, m.receiver_id, m.receiver_id AS ngo_id,
               f.title, f.quantity_kg, f.is_veg, f.suitable_for_animals, f.pickup_code, f.pickup_instructions,
               r.name AS receiver_name, r.name AS ngo_name, r.receiver_type,
               m.priority_score, m.freshness_at_match, m.distance_km,
               m.status, m.matched_at, m.responded_at, m.picked_up_at, m.delivered_at
        FROM matches m
        JOIN food_listings f ON f.listing_id   = m.listing_id
        JOIN receivers     r ON r.receiver_id  = m.receiver_id
        ORDER BY m.matched_at DESC
        """
    )
    return [dict(r) for r in rows]


@app.patch("/matches/{match_id}")
def update_match(match_id: int, body: MatchAction):
    valid = ("accepted", "rejected", "picked_up", "completed", "cancelled")
    if body.action not in valid:
        raise HTTPException(status_code=400, detail=f"Invalid action. Must be one of: {valid}")
    try:
        query(
            "UPDATE matches SET status=%s, responded_at=NOW() WHERE match_id=%s",
            (body.action, match_id),
            fetch=None,
        )
        return {"match_id": match_id, "status": body.action}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


# ── IMPACT ─────────────────────────────────────────────────────────────────────

@app.get("/impact")
def impact_summary():
    rows = query(
        "SELECT donor_type, deliveries, kg_saved, expired, rescue_rate_pct FROM v_impact_summary"
    )
    totals = query(
        """
        SELECT
            COUNT(*) FILTER (WHERE status='delivered')                         AS total_deliveries,
            COALESCE(SUM(quantity_kg) FILTER (WHERE status='delivered'), 0)    AS total_kg_saved,
            COUNT(*) FILTER (WHERE status='expired')                           AS total_expired,
            COUNT(*)                                                            AS total_listings
        FROM food_listings
        """,
        fetch="one",
    )
    return {
        "by_donor_type": [dict(r) for r in rows],
        "totals": dict(totals),
    }


# ── HOUSEKEEPING ───────────────────────────────────────────────────────────────

@app.post("/housekeeping/expire")
def expire_stale():
    row = query("SELECT * FROM expire_stale_listings()", fetch="one")
    return dict(row)
