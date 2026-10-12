"""
FreshLink FastAPI Backend with Secure JWT & Role-Based Access Control
Connects the frontend to PostgreSQL + PostGIS database.
"""

from fastapi import FastAPI, HTTPException, Depends, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, EmailStr
from typing import Optional, List
from pathlib import Path
import psycopg2
import psycopg2.extras
import subprocess
import os
import datetime
import bcrypt
import jwt
from dotenv import load_dotenv

# ── Load Environment Variables ────────────────────────────────────────────────
env_path = Path(__file__).resolve().parent.parent / ".env"
load_dotenv(dotenv_path=env_path)
load_dotenv()

JWT_SECRET = os.getenv("JWT_SECRET", "super-secret-freshlink-jwt-key-2026")
JWT_ALGORITHM = "HS256"
JWT_EXPIRE_HOURS = 24

app = FastAPI(title="FreshLink API", version="2.5")

# Support credentials (cookies) in CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "http://localhost:5500", "http://127.0.0.1:5500", "http://localhost:8000", "http://127.0.0.1:8000"],
    allow_origin_regex=".*",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Database Connection ────────────────────────────────────────────────────────
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


# ── Password & Token Helpers ───────────────────────────────────────────────────

def hash_password(password: str) -> str:
    salt = bcrypt.gensalt(rounds=12)
    return bcrypt.hashpw(password.encode("utf-8"), salt).decode("utf-8")

def verify_password(plain_password: str, hashed_password: str) -> bool:
    try:
        return bcrypt.checkpw(plain_password.encode("utf-8"), hashed_password.encode("utf-8"))
    except Exception:
        return False

def create_access_token(data: dict) -> str:
    to_encode = data.copy()
    expire = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=JWT_EXPIRE_HOURS)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, JWT_SECRET, algorithm=JWT_ALGORITHM)

def decode_access_token(token: str) -> dict:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        return payload
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token has expired. Please log in again.")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid authentication token.")


# ── Current User & Role Security Dependencies ──────────────────────────────────

async def get_current_user(request: Request) -> dict:
    # 1. Check HttpOnly cookie first
    token = request.cookies.get("access_token")
    # 2. Check Authorization Bearer header as secondary fallback
    if not token:
        auth_header = request.headers.get("Authorization")
        if auth_header and auth_header.startswith("Bearer "):
            token = auth_header.split(" ", 1)[1]

    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authentication required. Please log in.")

    payload = decode_access_token(token)
    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token claims.")

    user = query(
        "SELECT user_id, email, full_name, phone, role, is_active, created_at FROM users WHERE user_id = %s",
        (user_id,),
        fetch="one"
    )
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found.")
    if not user["is_active"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="User account is deactivated.")

    # Attach profile IDs
    donor = query("SELECT donor_id, name FROM donors WHERE user_id = %s", (user_id,), fetch="one")
    receiver = query("SELECT receiver_id, name, verification_status FROM receivers WHERE user_id = %s", (user_id,), fetch="one")
    user_dict = dict(user)
    user_dict["donor_id"] = donor["donor_id"] if donor else None
    user_dict["receiver_id"] = receiver["receiver_id"] if receiver else None
    user_dict["verification_status"] = receiver["verification_status"] if receiver else None
    return user_dict


def require_role(allowed_roles: List[str]):
    def role_checker(current_user: dict = Depends(get_current_user)) -> dict:
        if current_user["role"] not in allowed_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Access denied. Requires one of roles: {allowed_roles}. Current role: '{current_user['role']}'"
            )
        return current_user
    return role_checker


# ── Pydantic Request/Response Models ───────────────────────────────────────────

class UserSignup(BaseModel):
    email:     str
    password:  str
    full_name: str
    phone:     str
    role:      str  # "donor" | "receiver"

class UserLogin(BaseModel):
    email:    str
    password: str

class ListingCreate(BaseModel):
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

class MatchAction(BaseModel):
    action:      str            # "accepted" | "rejected" | "picked_up" | "completed" | "cancelled"
    pickup_code: Optional[str] = None  # required when action == "picked_up"

class ReceiverApproval(BaseModel):
    verification_status: str  # "approved" | "rejected" | "pending"


# ═══════════════════════════════════════════════════════════════════════════════
# AUTHENTICATION ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════════

@app.post("/auth/signup", status_code=status.HTTP_201_CREATED)
def signup(data: UserSignup, response: Response):
    if data.role not in ("donor", "receiver"):
        raise HTTPException(status_code=400, detail="Signup role must be 'donor' or 'receiver'. Admin accounts must be created by CLI.")
    if len(data.password) < 6:
        raise HTTPException(status_code=400, detail="Password must be at least 6 characters.")

    existing = query("SELECT user_id FROM users WHERE email = %s", (data.email.strip().lower(),), fetch="one")
    if existing:
        raise HTTPException(status_code=400, detail="Email is already registered.")

    pwd_hash = hash_password(data.password)
    new_user = query(
        """
        INSERT INTO users (email, password_hash, full_name, phone, role, is_active)
        VALUES (%s, %s, %s, %s, %s, TRUE)
        RETURNING user_id, email, full_name, phone, role
        """,
        (data.email.strip().lower(), pwd_hash, data.full_name.strip(), data.phone.strip(), data.role),
        fetch="one"
    )

    token = create_access_token({"sub": str(new_user["user_id"]), "role": new_user["role"], "email": new_user["email"]})
    response.set_cookie(
        key="access_token",
        value=token,
        httponly=True,
        max_age=JWT_EXPIRE_HOURS * 3600,
        samesite="lax",
        secure=False,
    )
    return {
        "message": "Signup successful",
        "user": dict(new_user),
        "access_token": token,
    }


@app.post("/auth/login")
def login(data: UserLogin, response: Response):
    user = query(
        "SELECT user_id, email, password_hash, full_name, phone, role, is_active FROM users WHERE email = %s",
        (data.email.strip().lower(),),
        fetch="one"
    )
    if not user or not verify_password(data.password, user["password_hash"]):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid email or password.")
    if not user["is_active"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Account is deactivated.")

    token = create_access_token({"sub": str(user["user_id"]), "role": user["role"], "email": user["email"]})
    response.set_cookie(
        key="access_token",
        value=token,
        httponly=True,
        max_age=JWT_EXPIRE_HOURS * 3600,
        samesite="lax",
        secure=False,
    )
    user_data = dict(user)
    user_data.pop("password_hash", None)
    return {
        "message": "Login successful",
        "user": user_data,
        "access_token": token,
    }


@app.post("/auth/logout")
def logout(response: Response):
    response.delete_cookie(key="access_token")
    return {"message": "Logged out successfully"}


@app.get("/auth/me")
def get_my_profile(current_user: dict = Depends(get_current_user)):
    # Returns the authenticated user profile with linked donor/receiver ids
    profile = current_user.copy()
    profile.pop("password_hash", None)
    return profile


# ═══════════════════════════════════════════════════════════════════════════════
# ADMIN-ONLY ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════════

@app.get("/users")
def list_users(current_user: dict = Depends(require_role(["admin"]))):
    """Admin-only: list all users. Password hashes are strictly omitted."""
    rows = query(
        """
        SELECT user_id, email, full_name, phone, role, is_active, created_at
        FROM users
        ORDER BY user_id ASC
        """
    )
    return [dict(r) for r in rows]


@app.patch("/receivers/{receiver_id}/approval")
def approve_receiver(receiver_id: int, body: ReceiverApproval, current_user: dict = Depends(require_role(["admin"]))):
    """Admin-only: approve, reject, or set pending verification for receivers."""
    if body.verification_status not in ("approved", "rejected", "pending"):
        raise HTTPException(status_code=400, detail="Invalid verification status.")
    receiver = query("SELECT receiver_id, name FROM receivers WHERE receiver_id = %s", (receiver_id,), fetch="one")
    if not receiver:
        raise HTTPException(status_code=404, detail="Receiver not found.")

    query(
        "UPDATE receivers SET verification_status = %s WHERE receiver_id = %s",
        (body.verification_status, receiver_id),
        fetch=None
    )
    return {"receiver_id": receiver_id, "verification_status": body.verification_status, "message": "Status updated"}


@app.post("/matches/run")
def run_matcher(current_user: dict = Depends(require_role(["admin"]))):
    """Admin-only: trigger greedy matching algorithm manually."""
    rows = query("SELECT * FROM match_food_to_receivers()")
    return {"matched": len(rows), "results": [dict(r) for r in rows]}


@app.post("/admin/reset")
def reset_demo_data(current_user: dict = Depends(require_role(["admin"]))):
    """Admin-only: reloads schema.sql, seed.sql, and demo_seed.sql."""
    db_dir = Path(__file__).parent.parent / "database"
    env = os.environ.copy()
    env["PGPASSWORD"] = DB_CONFIG["password"]

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
                detail=f"Error executing {fname}: {result.stderr[:500]}"
            )

    return {"message": "Demo data reset successfully"}


# ═══════════════════════════════════════════════════════════════════════════════
# DONORS & FOOD LISTINGS ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════════

@app.get("/donors")
def list_donors(current_user: dict = Depends(get_current_user)):
    """List donors (authenticated users)."""
    rows = query(
        """
        SELECT donor_id, user_id, name, donor_type, contact_phone, email, address, is_verified
        FROM donors
        ORDER BY name
        """
    )
    return [dict(r) for r in rows]


@app.post("/listings", status_code=status.HTTP_201_CREATED)
def create_listing(body: ListingCreate, current_user: dict = Depends(require_role(["donor", "admin"]))):
    """Donors can only create food listings under their own donor profile."""
    # Find donor profile
    donor = query("SELECT donor_id FROM donors WHERE user_id = %s", (current_user["user_id"],), fetch="one")
    if not donor and current_user["role"] != "admin":
        raise HTTPException(status_code=400, detail="You do not have an active donor profile configured.")

    donor_id = donor["donor_id"] if donor else query("SELECT donor_id FROM donors LIMIT 1", fetch="one")["donor_id"]

    try:
        row = query(
            """
            INSERT INTO food_listings
                (donor_id, category_id, title, description,
                 quantity_kg, servings, prepared_at, expires_at,
                 is_veg, allergens, suitable_for_animals, pickup_instructions)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            RETURNING listing_id, pickup_code
            """,
            (donor_id, body.category_id, body.title, body.description,
             body.quantity_kg, body.servings, body.prepared_at, body.expires_at,
             body.is_veg, body.allergens, body.suitable_for_animals, body.pickup_instructions),
            fetch="one",
        )
        # Note: Pickup code is returned ONLY to the creator donor here!
        return {
            "listing_id": row["listing_id"],
            "pickup_code": row["pickup_code"],
            "message": "Listing created. Keep this 4-digit pickup code safe to confirm handoff."
        }
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/listings/my")
def get_my_listings(current_user: dict = Depends(require_role(["donor", "admin"]))):
    """Donors can view their own listings, including their confidential pickup_code."""
    donor = query("SELECT donor_id FROM donors WHERE user_id = %s", (current_user["user_id"],), fetch="one")
    if not donor and current_user["role"] != "admin":
        return []

    donor_id = donor["donor_id"] if donor else None
    if donor_id:
        rows = query(
            """
            SELECT l.listing_id, l.title, l.quantity_kg, l.servings, l.prepared_at,
                   l.effective_expiry, l.status, l.pickup_code, l.pickup_instructions,
                   c.name AS category
            FROM food_listings l
            JOIN food_categories c ON c.category_id = l.category_id
            WHERE l.donor_id = %s
            ORDER BY l.created_at DESC
            """,
            (donor_id,)
        )
    else:
        # Admin can view all
        rows = query(
            """
            SELECT l.listing_id, l.title, l.quantity_kg, l.servings, l.prepared_at,
                   l.effective_expiry, l.status, l.pickup_code, l.pickup_instructions,
                   c.name AS category
            FROM food_listings l
            JOIN food_categories c ON c.category_id = l.category_id
            ORDER BY l.created_at DESC
            """
        )
    return [dict(r) for r in rows]


# ═══════════════════════════════════════════════════════════════════════════════
# RECEIVERS & FOOD ACCESS ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════════

@app.get("/receivers")
def list_receivers(current_user: dict = Depends(get_current_user)):
    """Receivers/Donors/Admins: view verified receivers."""
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
def receiver_capacity(current_user: dict = Depends(get_current_user)):
    rows = query(
        """
        SELECT receiver_id, name, receiver_type, daily_capacity_kg, committed_kg, remaining_kg
        FROM v_receiver_capacity_today
        """
    )
    return [dict(r) for r in rows]


@app.get("/receivers/my/listings")
def my_nearby_listings(current_user: dict = Depends(require_role(["receiver", "admin"]))):
    """
    Receivers can ONLY view food listings near them.
    SECURITY: The confidential 'pickup_code' is NEVER returned to receivers.
    """
    receiver = query("SELECT receiver_id, verification_status FROM receivers WHERE user_id = %s", (current_user["user_id"],), fetch="one")
    if not receiver and current_user["role"] != "admin":
        raise HTTPException(status_code=400, detail="No receiver profile linked to this account.")

    if receiver and receiver["verification_status"] != "approved" and current_user["role"] != "admin":
        raise HTTPException(status_code=403, detail="Your receiver organization is pending verification approval.")

    rec_id = receiver["receiver_id"] if receiver else query("SELECT receiver_id FROM receivers LIMIT 1", fetch="one")["receiver_id"]

    # Notice: pickup_code is excluded
    rows = query(
        """
        SELECT listing_id, title, category, quantity_kg, hours_left, freshness,
               distance_km, priority, is_veg, suitable_for_animals, pickup_instructions
        FROM nearby_listings_for_receiver(%s)
        """,
        (rec_id,)
    )
    return [dict(r) for r in rows]


@app.get("/receivers/{receiver_id}/listings")
def nearby_listings_endpoint(receiver_id: int, current_user: dict = Depends(get_current_user)):
    """
    Get listings for specific receiver. Receivers can only view their own; admins can view any.
    SECURITY: pickup_code is NEVER included.
    """
    if current_user["role"] == "receiver" and current_user.get("receiver_id") != receiver_id:
        raise HTTPException(status_code=403, detail="Receivers can only view listings within their own radius.")

    rows = query(
        """
        SELECT listing_id, title, category, quantity_kg, hours_left, freshness,
               distance_km, priority, is_veg, suitable_for_animals, pickup_instructions
        FROM nearby_listings_for_receiver(%s)
        """,
        (receiver_id,)
    )
    return [dict(r) for r in rows]


# Compatibility aliases for NGO routes
@app.get("/ngos")
def list_ngos_alias(current_user: dict = Depends(get_current_user)):
    return list_receivers(current_user=current_user)

@app.get("/ngos/capacity")
def ngo_capacity_alias(current_user: dict = Depends(get_current_user)):
    return receiver_capacity(current_user=current_user)

@app.get("/ngos/{ngo_id}/listings")
def nearby_listings_alias(ngo_id: int, current_user: dict = Depends(get_current_user)):
    return nearby_listings_endpoint(receiver_id=ngo_id, current_user=current_user)


# ═══════════════════════════════════════════════════════════════════════════════
# MATCHES & PICKUP VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════

@app.get("/matches")
def list_matches(current_user: dict = Depends(get_current_user)):
    """
    List matches. Receivers only see their own matches; donors see matches for their listings; admins see all.
    SECURITY: pickup_code is only visible to the donor (or admin). Receivers never see it in matches!
    """
    user_role = current_user["role"]
    user_id = current_user["user_id"]

    if user_role == "receiver":
        rec_id = current_user.get("receiver_id")
        rows = query(
            """
            SELECT m.match_id, m.listing_id, m.receiver_id, m.receiver_id AS ngo_id,
                   f.title, f.quantity_kg, f.is_veg, f.suitable_for_animals, f.pickup_instructions,
                   r.name AS receiver_name, r.name AS ngo_name, r.receiver_type,
                   m.priority_score, m.freshness_at_match, m.distance_km,
                   m.status, m.matched_at, m.responded_at, m.picked_up_at, m.delivered_at
            FROM matches m
            JOIN food_listings f ON f.listing_id  = m.listing_id
            JOIN receivers     r ON r.receiver_id = m.receiver_id
            WHERE m.receiver_id = %s
            ORDER BY m.matched_at DESC
            """,
            (rec_id,)
        )
    elif user_role == "donor":
        donor_id = current_user.get("donor_id")
        rows = query(
            """
            SELECT m.match_id, m.listing_id, m.receiver_id, m.receiver_id AS ngo_id,
                   f.title, f.quantity_kg, f.is_veg, f.suitable_for_animals, f.pickup_code, f.pickup_instructions,
                   r.name AS receiver_name, r.name AS ngo_name, r.receiver_type,
                   m.priority_score, m.freshness_at_match, m.distance_km,
                   m.status, m.matched_at, m.responded_at, m.picked_up_at, m.delivered_at
            FROM matches m
            JOIN food_listings f ON f.listing_id  = m.listing_id
            JOIN receivers     r ON r.receiver_id = m.receiver_id
            WHERE f.donor_id = %s
            ORDER BY m.matched_at DESC
            """,
            (donor_id,)
        )
    else:  # admin
        rows = query(
            """
            SELECT m.match_id, m.listing_id, m.receiver_id, m.receiver_id AS ngo_id,
                   f.title, f.quantity_kg, f.is_veg, f.suitable_for_animals, f.pickup_code, f.pickup_instructions,
                   r.name AS receiver_name, r.name AS ngo_name, r.receiver_type,
                   m.priority_score, m.freshness_at_match, m.distance_km,
                   m.status, m.matched_at, m.responded_at, m.picked_up_at, m.delivered_at
            FROM matches m
            JOIN food_listings f ON f.listing_id  = m.listing_id
            JOIN receivers     r ON r.receiver_id = m.receiver_id
            ORDER BY m.matched_at DESC
            """
        )
    return [dict(r) for r in rows]


@app.patch("/matches/{match_id}")
def update_match(match_id: int, body: MatchAction, current_user: dict = Depends(get_current_user)):
    """
    Manage match status.
    - Receivers can only update their own matches.
    - When action == 'picked_up', the receiver MUST provide the valid 4-digit pickup_code!
    """
    valid = ("accepted", "rejected", "picked_up", "completed", "cancelled")
    if body.action not in valid:
        raise HTTPException(status_code=400, detail=f"Invalid action. Must be one of: {valid}")

    match = query(
        """
        SELECT m.match_id, m.listing_id, m.receiver_id, m.status, f.pickup_code
        FROM matches m
        JOIN food_listings f ON f.listing_id = m.listing_id
        WHERE m.match_id = %s
        """,
        (match_id,),
        fetch="one"
    )
    if not match:
        raise HTTPException(status_code=404, detail="Match not found.")

    # Permissions check: receivers can only manage their own match
    if current_user["role"] == "receiver" and current_user.get("receiver_id") != match["receiver_id"]:
        raise HTTPException(status_code=403, detail="You do not have permission to manage this match.")

    # Pickup Code Verification: Receiver must enter the secret donor pickup code to mark picked_up
    if body.action == "picked_up":
        expected_code = match["pickup_code"]
        if not body.pickup_code or body.pickup_code.strip() != str(expected_code).strip():
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Incorrect pickup code. Please obtain the 4-digit pickup code from the food donor."
            )

    try:
        query(
            "UPDATE matches SET status = %s, responded_at = NOW() WHERE match_id = %s",
            (body.action, match_id),
            fetch=None,
        )
        return {"match_id": match_id, "status": body.action, "message": f"Match marked as {body.action} successfully"}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


# ═══════════════════════════════════════════════════════════════════════════════
# PUBLIC / GENERAL METRICS & VIEWS
# ═══════════════════════════════════════════════════════════════════════════════

@app.get("/categories")
def list_categories():
    """Public: food categories with decay limits."""
    rows = query(
        "SELECT category_id, name, requires_refrigeration, decay_rate, max_safe_hours FROM food_categories ORDER BY name"
    )
    return [dict(r) for r in rows]


@app.get("/listings/available")
def available_listings():
    """
    Public live feed view of available surplus food.
    SECURITY: 'pickup_code' is omitted from public view.
    """
    rows = query(
        """
        SELECT listing_id, title, donor_name, donor_type, category,
               quantity_kg, servings, prepared_at, effective_expiry,
               hours_left, freshness, urgency, freshness_band,
               requires_refrigeration, is_veg, allergens, suitable_for_animals,
               pickup_instructions, pickup_window_start, pickup_window_end
        FROM v_available_listings
        ORDER BY hours_left ASC
        """
    )
    return [dict(r) for r in rows]


@app.get("/impact")
def impact_summary():
    """Public impact dashboard summary."""
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


@app.post("/housekeeping/expire")
def expire_stale(current_user: dict = Depends(require_role(["admin"]))):
    """Admin-only housekeeping task."""
    row = query("SELECT * FROM expire_stale_listings()", fetch="one")
    return dict(row)
