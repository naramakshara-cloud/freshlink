# FreshLink 🌿

**FreshLink** is a hyperlocal surplus food redistribution system connecting donors (college hostels, canteens, households, restaurants) with verified receivers (NGOs, community kitchens, animal shelters, and individuals/families in need) in real time.

Unlike simple first-come-first-served lists, FreshLink combines:
- **Mathematical freshness decay** (half-life curves per food category)
- **Hard food-safety caps** (`effective_expiry`)
- **PostGIS spatial proximity** (WGS 84 spherical distance)
- **Multi-tiered recipient rules** (human priority, animal shelter diet guards, verification tiers)

---

## 🌟 Architecture & Key Features

### 1. Multi-User Hierarchy & Roles
- **Users (`users`)**: Authenticated profiles with roles `donor`, `receiver`, or `admin`.
- **Donors (`donors`)**: Linked to user accounts. Categorized into `hostel`, `canteen`, `household`, `restaurant`, `event`, and `other`.
- **Receivers (`receivers`)**: Renamed from NGOs to accommodate diverse needs:
  - `individual_or_family` (default daily capacity: 5 kg)
  - `ngo`, `community_kitchen`, `orphanage`, `old_age_home` (default daily capacity: 50 kg)
  - `animal_shelter` (strictly matched only with food marked `suitable_for_animals = TRUE`)
  - **Verification Gates**: Receivers must have `verification_status = 'approved'` and `is_active = TRUE` to receive surplus food.

### 2. Comprehensive Food Listings
Surplus listings track crucial safety and logistical metadata:
- Quantity (kg) & estimated servings.
- Dietary flags: `is_veg` (Boolean) and `allergens` (text notes).
- Animal safety flag: `suitable_for_animals` (Boolean).
- Logistics: `pickup_instructions`, `pickup_code` (random 4-digit verification code), and pickup time window.
- Hard safety constraint: Donor-declared expiration is capped by `category.max_safe_hours` using database triggers.

### 3. Expiry-Aware Scoring & Matching Algorithm

#### Freshness Score
$$S_{\text{freshness}} = 100 \cdot e^{-k \cdot \Delta t_{\text{prepared}}}$$
Clamped to $[0, 100]$, where $k$ is the category's decay rate constant (e.g. $0.15$ for cooked curries, $0.005$ for sealed biscuits).

#### Urgency Score
$$S_{\text{urgency}} = 100 - \left( \Delta t_{\text{effective\_expiry}} \cdot \frac{100}{24} \right)$$
Clamped to $[0, 100]$ across a 24-hour window. Expired or unsafe food is never matched.

#### Proximity Score
$$S_{\text{proximity}} = 100 \cdot \left(1 - \frac{\text{distance}}{\text{receiver radius}}\right)$$
Calculated via PostGIS `ST_Distance` on WGS 84 points (`SRID 4326`).

#### Priority Score
$$\text{Priority} = 0.5 \cdot S_{\text{urgency}} + 0.3 \cdot S_{\text{freshness}} + 0.2 \cdot S_{\text{proximity}}$$

#### Scheduler Matching Rules (`match_food_to_receivers()`)
1. **Concurrency Protection**: Uses `pg_advisory_xact_lock` to prevent race conditions during parallel scheduler runs.
2. **Processing Order**: Soonest `effective_expiry` first, then highest freshness.
3. **Safety & Verification**: Food past its safe consumption limit is skipped. Receivers must be `approved` and active.
4. **Human Priority**: Human receivers receive precedence over animal shelters.
5. **Animal Shelter Guard**: Animal shelters are strictly matched only with food flagged `suitable_for_animals = TRUE`.
6. **Capacity & Refrigeration**: Verifies remaining daily capacity and refrigeration capability before assignment.

---

## 🛠 Tech Stack

- **Database**: PostgreSQL 14+ with **PostGIS 3+** extension
  - Multi-user relational schema without destructive drop commands.
  - Safe migration history in `database/migrations/`.
  - Stored procedures, triggers, GIST spatial indexes, and real-time analytical views.
- **Backend**: **FastAPI** (Python 3.10+) with **Uvicorn**
  - Database connectivity with `psycopg2-binary`.
  - Secure credential isolation via `python-dotenv`.
- **Frontend**: Clean, responsive **HTML5**, **CSS3**, and vanilla **JavaScript (ES6+)**
  - Donor submission portal with dietary, allergen, and animal suitability controls.
  - Receiver dashboard with 🟢🟡🔴 freshness bands, live countdowns, pickup code displays, and match lifecycle buttons (`Accept`, `Reject`, `Mark Picked Up`, `Mark Delivered`).
  - Impact dashboard with real-time KPI metrics and demo reset controls.

---

## 📁 Repository Structure

```
freshlink/
├── .env.example                     <- Template for database credentials
├── .gitignore                       <- Ignores .env and __pycache__
├── README.md                        <- Project overview and guide
├── backend/
│   ├── main.py                      <- FastAPI API server
│   └── requirements.txt             <- Python dependencies
├── database/
│   ├── schema.sql                   <- Safe multi-user schema (no drop statements)
│   ├── seed.sql                     <- Canonical reference data (food categories)
│   ├── demo_seed.sql                <- Demo login accounts, donors, receivers & listings
│   └── migrations/
│       └── 001_initial_schema.sql   <- Versioned initial migration script
└── frontend/
    ├── api.js                       <- Shared API fetch client
    ├── donor.html / donor.js        <- Donor listing portal
    ├── ngo.html / ngo.js            <- Receiver / Shelter dashboard
    ├── impact.html / impact.js      <- Metrics & impact analytics
    └── style.css                    <- Global styling and color bands
```

---

## 🚀 Setup & Installation

### Prerequisites
- [PostgreSQL](https://www.postgresql.org/download/) installed with the **PostGIS** extension.
- [Python 3.10+](https://www.python.org/) installed.
- Git.

### Step 1: Clone Repository
```bash
git clone https://github.com/naramakshara-cloud/freshlink.git
cd freshlink
```

### Step 2: Configure Environment Variables
Copy the template configuration file:

```bash
# Windows PowerShell
Copy-Item .env.example .env

# Linux / macOS
cp .env.example .env
```

Edit `.env` with your PostgreSQL superuser password:
```env
DB_NAME=freshlink
DB_USER=postgres
DB_PASSWORD=your_actual_password_here
DB_HOST=localhost
DB_PORT=5432
```

### Step 3: Initialize Database
Create the database and run the schema and seed scripts:

```bash
# Create the freshlink database
createdb -U postgres freshlink

# 1. Apply multi-user schema
psql -U postgres -d freshlink -f database/schema.sql

# 2. Load permanent categories
psql -U postgres -d freshlink -f database/seed.sql

# 3. Load demo accounts and sample listings
psql -U postgres -d freshlink -f database/demo_seed.sql
```

*(Note: Future database updates should be added as incremental scripts in `database/migrations/`).*

### Step 4: Install Dependencies
```bash
pip install -r backend/requirements.txt
```

---

## 🏃 Running the Application

### 1. Launch the Backend Server
From the repository root:
```bash
python -m uvicorn backend.main:app --reload --port 8000
```
Or from the `backend/` directory:
```bash
cd backend
python -m uvicorn main:app --reload --port 8000
```

- Interactive Swagger Documentation: [http://localhost:8000/docs](http://localhost:8000/docs)
- Interactive ReDoc: [http://localhost:8000/redoc](http://localhost:8000/redoc)

### 2. Demo User Accounts (from `demo_seed.sql`)
*Default password for all demo accounts: `DemoPass123!`*

| Role | Email | Name / Organisation | Description |
|---|---|---|---|
| **Admin** | `admin@freshlink.org` | System Administrator | System-wide admin access |
| **Donor** | `hostel.a@college.edu` | Boys Hostel Block A Mess | Hostel mess donor |
| **Donor** | `canteen@college.edu` | Central Canteen | Campus canteen donor |
| **Donor** | `sharma.home@gmail.com` | Sharma Household | Home surplus donor |
| **Receiver** | `annapurna@trust.org` | Annapurna Food Bank | Large NGO (80 kg cap, refrigerated) |
| **Receiver** | `shelter@hope.org` | Hope Shelter | Orphanage (30 kg cap) |
| **Receiver** | `jayanagar@kitchen.org` | Community Kitchen | Community kitchen (40 kg cap) |
| **Receiver** | `paws@animalshelter.org` | Paws Animal Rescue | Animal shelter (animal-safe food only) |
| **Receiver** | `kumar.family@gmail.com` | Kumar Family | Individual/Family (5 kg capacity) |

### 3. Open the Web Frontend
Open the static web pages in your browser:
- **Donor Portal**: Open `frontend/donor.html`
- **Receiver Dashboard**: Open `frontend/ngo.html`
- **Impact & Metrics**: Open `frontend/impact.html`