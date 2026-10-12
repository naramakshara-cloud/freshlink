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

app = FastAPI(title="FreshLink API", version="1.0")

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
    donor_id:    int
    category_id: int
    title:       str
    description: Optional[str] = None
    quantity_kg: float
    servings:    Optional[int] = None
    prepared_at: str   # ISO datetime string
    expires_at:  str   # ISO datetime string

class MatchAction(BaseModel):
    action: str   # "accepted" | "rejected" | "picked_up" | "completed" | "cancelled"


# ── ADMIN ──────────────────────────────────────────────────────────────────────

@app.post("/admin/reset")
def reset_demo_data():
    """
    Drop and recreate all tables (schema.sql), then load sample data (seed.sql).
    Used by the Impact page 'Reset Demo Data' button.
    """
    db_dir = Path(__file__).parent.parent / "database"
    env = os.environ.copy()
    env["PGPASSWORD"] = DB_CONFIG["password"]

    for fname in ["schema.sql", "seed.sql"]:
        result = subprocess.run(
            [
                "psql",
                "-U", DB_CONFIG["user"],
                "-d", DB_CONFIG["dbname"],
                "-h", DB_CONFIG["host"],
                "-p", str(DB_CONFIG["port"]),
                "-f", str(db_dir / fname),
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


# ── DONORS ─────────────────────────────────────────────────────────────────────

@app.get("/donors")
def list_donors():
    rows = query("SELECT donor_id, name, donor_type, address FROM donors ORDER BY name")
    return [dict(r) for r in rows]


# ── FOOD CATEGORIES ────────────────────────────────────────────────────────────

@app.get("/categories")
def list_categories():
    rows = query(
        "SELECT category_id, name, requires_refrigeration FROM food_categories ORDER BY name"
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
                 quantity_kg, servings, prepared_at, expires_at)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
            RETURNING listing_id
            """,
            (body.donor_id, body.category_id, body.title, body.description,
             body.quantity_kg, body.servings, body.prepared_at, body.expires_at),
            fetch="one",
        )
        return {"listing_id": row["listing_id"], "message": "Listing created"}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/listings/available")
def available_listings():
    """Live feed used by the NGO dashboard."""
    rows = query(
        """
        SELECT listing_id, title, donor_name, donor_type, category,
               quantity_kg, servings, prepared_at, effective_expiry,
               hours_left, freshness, urgency, freshness_band,
               requires_refrigeration
        FROM v_available_listings
        ORDER BY hours_left ASC
        """
    )
    return [dict(r) for r in rows]


# ── NGOs ───────────────────────────────────────────────────────────────────────
# IMPORTANT: fixed-path routes (/ngos/capacity) MUST come before
# parameterised routes (/ngos/{ngo_id}/...) to avoid shadowing.

@app.get("/ngos")
def list_ngos():
    rows = query(
        """
        SELECT ngo_id, name, address, service_radius_km,
               daily_capacity_kg, has_refrigeration, is_active
        FROM ngos ORDER BY name
        """
    )
    return [dict(r) for r in rows]


@app.get("/ngos/capacity")      # ← fixed path FIRST
def ngo_capacity():
    rows = query(
        "SELECT ngo_id, name, daily_capacity_kg, committed_kg, remaining_kg FROM v_ngo_capacity_today"
    )
    return [dict(r) for r in rows]


@app.get("/ngos/{ngo_id}/listings")   # ← parameterised path AFTER
def nearby_listings(ngo_id: int):
    """Priority-sorted listings for a specific NGO."""
    rows = query(
        "SELECT * FROM nearby_listings_for_ngo(%s)",
        (ngo_id,)
    )
    return [dict(r) for r in rows]


# ── MATCHES ────────────────────────────────────────────────────────────────────

@app.post("/matches/run")
def run_matcher():
    """Trigger the expiry-aware greedy scheduler."""
    rows = query("SELECT * FROM match_food_to_ngos()")
    return {"matched": len(rows), "results": [dict(r) for r in rows]}


@app.get("/matches")
def list_matches():
    rows = query(
        """
        SELECT m.match_id, m.listing_id, m.ngo_id,
               f.title, f.quantity_kg,
               n.name AS ngo_name,
               m.priority_score, m.freshness_at_match, m.distance_km,
               m.status, m.matched_at, m.responded_at, m.picked_up_at, m.delivered_at
        FROM matches m
        JOIN food_listings f ON f.listing_id = m.listing_id
        JOIN ngos          n ON n.ngo_id      = m.ngo_id
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
