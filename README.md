# FreshLink 🌿

**FreshLink** is a hyperlocal surplus food redistribution system that connects donors (college hostels, canteens, households, restaurants) with nearby NGOs and shelters in real time.

Instead of generic first-come-first-served lists, FreshLink uses **mathematical freshness decay**, **hard food-safety limits**, and **spatial distance calculations (PostGIS)** to prioritize food redistribution before it spoils.

---

## 🌟 Key Features

- **Donor Food Posting**: Donors list surplus meals specifying quantity, servings, preparation time, and stated expiry. Includes dynamic client-side freshness estimations and category validation.
- **NGO Dashboard**:
  - Filter nearby food listings by freshness bands: 🟢 **GREEN** (fresh), 🟡 **YELLOW** (moderate), 🔴 **RED** (expiring soon).
  - Real-time countdown timers ticking down to expiration.
  - One-click **Auto-Match** execution leveraging database-level greedy scheduling.
- **My Matches Lifecycle Management**:
  - Direct status transitions: `pending` → `accepted` / `rejected` → `picked_up` → `completed` (delivered).
  - Rejected matches automatically trigger PostgreSQL database triggers to return safe food back to the active pool.
- **Impact & Metrics Tracking**:
  - Real-time KPI summaries: total completed deliveries, kilograms saved, and overall rescue rate.
  - Environmental equivalence calculations (kg CO₂ emissions avoided and meals provided).
  - Breakdown by donor category with visual charts.
  - Administrative **Reset Demo Data** and **Expire Stale Listings** actions.

---

## 📐 Scoring Model & Matching Algorithm

FreshLink ranks food transfers using an expiry-aware scoring model implemented directly in SQL and PostGIS functions.

### 1. Freshness Score
$$S_{\text{freshness}} = 100 \cdot e^{-k \cdot \Delta t_{\text{prepared}}}$$
- Clamped between $[0, 100]$.
- $k$ is an empirical decay rate constant tailored per food category (e.g., $0.15$ for hot cooked curries vs. $0.005$ for sealed dry goods).

### 2. Urgency Score
$$S_{\text{urgency}} = 100 - \left( \Delta t_{\text{expiry}} \cdot \frac{100}{24} \right)$$
- Normalised across a 24-hour window. Food expiring immediately scores $100$; food with 24h+ remaining scores $0$.
- **`effective_expiry` enforcement**: Handled automatically via database triggers. Computes the earlier timestamp between the donor's declared expiry and the food category's hard food safety ceiling (`max_safe_hours`).

### 3. Proximity Score
$$S_{\text{proximity}} = 100 \cdot \left(1 - \frac{\text{distance}}{\text{NGO service radius}}\right)$$
- Calculated using PostGIS `ST_Distance` on WGS 84 geography points (`SRID 4326`).
- Evaluates to $100$ if located at the NGO's doorstep and $0$ at the boundary of its service zone.

### 4. Priority Score
$$\text{Priority} = 0.5 \cdot S_{\text{urgency}} + 0.3 \cdot S_{\text{freshness}} + 0.2 \cdot S_{\text{proximity}}$$

### 5. Matching Rules (`match_food_to_ngos()`)
1. **Advisory Lock**: Runs inside transactional advisory locks (`pg_advisory_xact_lock`) to avoid race conditions.
2. **Order of Processing**: Unmatched food listings are evaluated in order of soonest `effective_expiry` first.
3. **NGO Eligibility**:
   - Must be actively operating (`is_active = TRUE`).
   - Must be within geographic range (`ST_DWithin` using NGO radius).
   - Must possess sufficient daily capacity (`remaining_kg >= listing.quantity_kg`).
   - Must support refrigeration if the food category mandates cold storage.
   - Must not have previously rejected the specific food listing.
4. **Assignment**: The eligible NGO yielding the highest combined priority score receives the match.

---

## 🛠 Tech Stack

- **Database**: PostgreSQL 14+ with **PostGIS 3+** extension
  - Custom types, trigger procedures, spatial GIST indexes, and real-time views (`v_available_listings`, `v_ngo_capacity_today`, `v_impact_summary`).
- **Backend**: **FastAPI** (Python 3.10+) & **Uvicorn**
  - Database connectivity via `psycopg2-binary` (RealDictCursor).
  - Environment variable configuration via `python-dotenv`.
  - CORS middleware support for web clients.
- **Frontend**: Clean, responsive **HTML5**, modern **CSS3**, and vanilla **JavaScript (ES6+)**
  - Zero heavy frontend build tool dependencies.
  - Live interval-driven countdown timers, badge indicators, and dynamic dashboards.

---

## 🚀 Setup & Installation

### Prerequisites
- [PostgreSQL](https://www.postgresql.org/download/) installed with the **PostGIS** extension (available via Application Stack Builder on Windows or `sudo apt install postgresql-postgis` on Linux).
- [Python 3.10+](https://www.python.org/) installed.
- Git.

### Step 1: Clone Repository
```bash
git clone https://github.com/naramakshara-cloud/freshlink.git
cd freshlink
```

### Step 2: Configure Environment Variables
Copy the example environment configuration file to `.env`:

```bash
# On Windows PowerShell
Copy-Item .env.example .env

# On Linux/macOS
cp .env.example .env
```

Open `.env` and fill in your PostgreSQL credentials:
```env
DB_NAME=freshlink
DB_USER=postgres
DB_PASSWORD=your_actual_password_here
DB_HOST=localhost
DB_PORT=5432
```

### Step 3: Set Up Database & PostGIS
Create the database and execute the schema and seed scripts:

```bash
# Create the database
createdb -U postgres freshlink

# Run schema and seed scripts
psql -U postgres -d freshlink -f database/schema.sql
psql -U postgres -d freshlink -f database/seed.sql
```

*(Note: If prompted, enter your PostgreSQL user password).*

### Step 4: Install Python Dependencies
```bash
pip install -r backend/requirements.txt
```

---

## 🏃 Running the Application

### 1. Start the Backend API
Run the FastAPI development server from the repository root:

```bash
python -m uvicorn backend.main:app --reload --port 8000
```
Or navigate to the `backend/` directory:
```bash
cd backend
python -m uvicorn main:app --reload --port 8000
```

The interactive OpenAPI documentation will be accessible at:
- **Swagger UI**: [http://localhost:8000/docs](http://localhost:8000/docs)
- **ReDoc**: [http://localhost:8000/redoc](http://localhost:8000/redoc)

### 2. Open the Frontend
Open the HTML pages in your web browser:
- **Donor Portal**: Open `frontend/donor.html`
- **NGO Dashboard**: Open `frontend/ngo.html`
- **Impact Tracker**: Open `frontend/impact.html`

*(Tip: You can use VS Code's **Live Server** extension or Python's `python -m http.server 3000 --directory frontend` to serve the static frontend files).*

---

## 🧪 Testing the Workflow

1. Navigate to **Post Food** (`donor.html`) and submit a new surplus food listing.
2. Navigate to **NGO Dashboard** (`ngo.html`):
   - Select an NGO (e.g. *Annapurna Food Bank*).
   - Click **⚡ Run Auto-Match** to execute the greedy scheduler.
   - Review pending assignments under **My Matches** and click **✅ Accept**.
   - Advance through the lifecycle: click **🚚 Mark Picked Up**, followed by **✅ Mark Delivered**.
3. Navigate to **Our Impact** (`impact.html`) to watch kilograms saved, delivery metrics, and rescue rates update live.
4. Need a fresh run? Click **🔄 Reset Demo Data** on the Impact page to restore initial seed records.