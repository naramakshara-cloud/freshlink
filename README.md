# FreshLink

FreshLink is a hyperlocal food surplus redistribution system built for the BACSE202 Database Systems course. Hostel messes, canteens, restaurants and households post leftover food, and the system matches each item to a nearby receiver: an NGO, orphanage, old age home, community kitchen, family or animal shelter. The scoring and matching logic is written in SQL and runs inside PostgreSQL with PostGIS. The backend is FastAPI and the frontend is plain HTML, CSS and JavaScript.

## How it works

1. A donor posts surplus food with its category, quantity, preparation time and expiry time.
2. The database caps the expiry at the category's food-safety limit, calculates freshness, urgency and priority, and tries to match the food straight away.
3. The best eligible receiver is offered the food. Only one receiver holds an offer at a time.
4. The receiver accepts or rejects. A rejected offer, or one left unanswered for 15 minutes, goes to the next eligible receiver. A receiver is never offered the same item twice.
5. At pickup, the receiver enters a 4-digit code that only the donor can see. This confirms the handover.
6. The receiver marks the food as delivered, and it counts towards the impact figures.

A background job runs every minute. It expires food that is past its safe time, cancels offers that have timed out, and matches anything still waiting.

## Scoring

All scores range from 0 to 100.

**Safe shelf life.** The time from preparation to whichever comes first: the donor's expiry time, or the preparation time plus the category's safety limit. A donor cannot list cooked rice as good for two days.

**Freshness** is the share of the safe shelf life that is left:

```
freshness = remaining safe shelf life / total safe shelf life * 100
```

**Urgency** is based on the actual hours left, over a 24-hour window:

```
urgency = 100 * (1 - hours_left / 24)        clamped to 0..100
```

**Priority** decides which food is matched first:

```
priority = 0.6 * urgency + 0.4 * (100 - freshness)
```

Freshness alone ranks foods badly when their shelf lives differ. At 4 PM, rice cooked at 10 AM that expires at 6 PM and a packet of biscuits with 42 hours left can both be at 25% freshness. Urgency separates them: the rice scores priority 85 and the biscuits 30. Urgency gets the larger weight because food that expires is lost completely.

**Proximity** is used only to choose between receivers, never to rank food:

```
proximity = 100 * (1 - distance / receiver's pickup range)
```

Keeping distance out of the priority means a nearby but less urgent item cannot be handled before food that is about to spoil.

Freshness bands on the dashboards are green (70 and above), yellow (40 to 69) and red (below 40). Food below freshness 20 is not matched.

In SQL the freshness function is written as `100 * (1 - (e / T)^k)`, where `e` is the hours since preparation and `T` is the safe shelf life. With `k = 1` this is the formula above. Every category uses `k = 1`. The value is kept in the `spoilage_shape` column so a curved decay can be tested later without code changes.

## Matching rules

`match_food_to_receivers()` goes through available food in order of priority, highest first. For each item it picks one receiver that:

- is approved by an admin and active
- is within its own pickup range of the food
- has enough daily capacity left (pending offers count towards it)
- has a fridge, if the food category needs one
- still needs that category today, if it has set food requirements
- has not already rejected the item or let an offer for it time out

Human receivers are always chosen before animal shelters, and animal shelters only receive food the donor marked as safe for animals. Among the remaining receivers, the one with the highest proximity score wins. An advisory lock stops two matching runs from overlapping.

## Roles

**Donors** post food and see their own listings, who each item was matched to, and the pickup code until the food is collected.

**Receivers** see food within their pickup range, accept or reject offers, confirm pickup with the donor's code, and mark food as delivered. They set their pickup range at signup (2 km by default for individuals and families, 5 km for organisations) and can change it on the dashboard, between 0.5 and 20 km. New receivers start as pending and cannot receive food until an admin approves them.

**Admins** approve or reject receivers, manage food categories, can view any receiver's dashboard, and can run matching, expire old listings or reset the demo data.

Each role only sees its own pages. Opening another role's page redirects to the user's own dashboard, and logged-out users are sent to the login page.

## Database

| Project entity | Table |
|---|---|
| Food provider | `donors`, linked to `users` |
| Food donation | `food_listings` |
| NGO / receiver | `receivers` |
| NGO requirement | `receiver_requirements` |
| Food match | `matches`, with every status change logged in `match_history` |
| Pickup schedule | `pickup_schedules` |

`food_categories` holds the food types. Each has a safety limit in hours, a fridge flag, example foods shown to donors, and an active flag. Categories are hidden rather than deleted, because older listings still refer to them.

Default categories:

| Category | Safety limit | Needs fridge |
|---|---|---|
| Cooked Rice & Curries | 6 hours | No |
| Dairy & Sweets | 8 hours | Yes |
| Breads & Rotis | 12 hours | No |
| Fresh Fruits & Veg | 48 hours | No |
| Packaged / Dry Food | 7 days | No |

Main SQL objects:

- Functions: `freshness_score`, `urgency_score`, `food_priority`, `proximity_score`, `requirement_room_kg`, `nearby_listings_for_receiver`, `match_food_to_receivers`, `expire_stale_listings`
- Triggers: setting the safe expiry and pickup code on new listings, keeping listing status and `match_history` in step with matches, and validating pickup schedules
- Views: `v_available_listings`, `v_receiver_capacity_today`, `v_impact_summary`
- Constraints: one active match per listing (partial unique index), and unique category names ignoring case
- GiST spatial indexes on donor, receiver and listing locations

A pickup time has to be before the food's safe expiry and can only be set for a pending or accepted match. Rejecting a match cancels its schedule, picking the food up completes it, and a schedule more than two hours overdue is marked as missed.

## Tech stack

- PostgreSQL 14 or later with PostGIS 3 or later
- Python 3.10 or later, FastAPI and Uvicorn, psycopg2
- bcrypt for password hashing, PyJWT for login tokens stored in an HttpOnly cookie
- HTML, CSS and JavaScript with no framework, plus Leaflet and OpenStreetMap for choosing a location at signup

## Project structure

```
freshlink/
  .env.example            database and JWT settings template
  .gitignore
  README.md
  backend/
    main.py               API, login, permissions, background matching job
    create_admin.py       command-line tool to create an admin account
    test_auth_security.py permission and pickup code tests
    requirements.txt
  database/
    schema.sql            tables, functions, triggers and views
    seed.sql              default food categories
    demo_seed.sql         demo accounts and sample listings
    README.md             notes on the database design
  frontend/
    index.html            home page
    login.html            login with donor and receiver tabs
    signup.html           registration with a map to pick a location
    donor.html, donor.js  donor dashboard
    ngo.html, ngo.js      receiver dashboard
    admin.html, admin.js  receiver approvals and food categories
    impact.html, impact.js
    api.js                shared API calls and helpers
    nav.js                menu and page protection by role
    style.css
```

## Setup

You need PostgreSQL with PostGIS, Python 3.10 or later, and Git.

1. Clone the repository.

   ```
   git clone https://github.com/naramakshara-cloud/freshlink.git
   cd freshlink
   ```

2. Copy `.env.example` to `.env` and fill in your PostgreSQL password and a long random JWT secret.

   ```
   copy .env.example .env
   ```

   On macOS or Linux use `cp` instead of `copy`. Never commit `.env`; it is already in `.gitignore`.

3. Create the database and load the schema, the categories and the demo data.

   ```
   createdb -U postgres freshlink
   psql -U postgres -d freshlink -f database/schema.sql
   psql -U postgres -d freshlink -f database/seed.sql
   psql -U postgres -d freshlink -f database/demo_seed.sql
   ```

4. Install the Python packages.

   ```
   pip install -r backend/requirements.txt
   ```

### Updating an existing database

`schema.sql` and `seed.sql` can be run again on an existing database. They add anything new and do not delete data. `demo_seed.sql` is different: it deletes all users, listings and matches and reloads the demo accounts, so only run it when you want to start over.

## Running

Start the backend from the `backend` folder:

```
cd backend
python -m uvicorn main:app --reload --port 8000
```

Then open http://localhost:8000 in a browser. The backend serves the website as well as the API. Do not open the HTML files directly from the folder: login uses a cookie, which only works when the pages come from the same address as the API.

The API documentation is at http://localhost:8000/docs.

If port 8000 is already in use, an older copy of the backend is probably still running. Stop it, or find it with `netstat -ano | findstr :8000` and end it with `taskkill /PID <number> /F`.

## Demo accounts

Every demo account uses the password `DemoPass123!`.

| Role | Email | Name | Notes |
|---|---|---|---|
| Admin | admin@freshlink.org | System Administrator | |
| Donor | hostel.a@college.edu | Boys Hostel Block A Mess | |
| Donor | canteen@college.edu | Central Canteen | |
| Donor | sharma.home@gmail.com | Sharma Household | |
| Donor | hostel.d@college.edu | Girls Hostel Mess | |
| Receiver | annapurna@trust.org | Annapurna Food Bank | NGO, 80 kg a day, has a fridge |
| Receiver | shelter@hope.org | Hope Shelter | Orphanage, 30 kg a day, needs only cooked food and breads |
| Receiver | jayanagar@kitchen.org | Jayanagar Community Kitchen | 40 kg a day |
| Receiver | paws@animalshelter.org | Paws Animal Rescue | Animal shelter, animal-safe food only |
| Receiver | kumar.family@gmail.com | Kumar Family | Family, 5 kg a day, 2 km range |

All demo locations are in central Bengaluru. Use the matching login tab: donors on "I donate food", receivers on "I receive food", and the admin through the "Admin log in" link.

To create another admin account:

```
python backend/create_admin.py --email you@example.com --password "ChooseAStrongPassword" --name "Your Name" --phone "9876543210"
```

Run it without arguments to be asked for each value.

## Tests

With the backend running, from the project root:

```
python backend/test_auth_security.py
```

The script checks that protected endpoints reject requests without a login, that donors and receivers cannot use admin endpoints, that password hashes are never returned, that the pickup code is only visible to the donor, and that a wrong pickup code is refused. It connects to a database named `freshlink`.

## Settings

These values are at the top of `backend/main.py`:

| Setting | Value | Meaning |
|---|---|---|
| `MATCH_INTERVAL_SECONDS` | 60 | How often the background job runs |
| `PENDING_TIMEOUT_MINUTES` | 15 | How long a receiver has to accept an offer |
| `MIN_RADIUS_KM`, `MAX_RADIUS_KM` | 0.5, 20 | Allowed pickup range |

## Limitations and future work

- Freshness is estimated from time only. Storage temperature, which affects real spoilage, is not recorded.
- The priority weights (0.6 and 0.4) and the 24-hour urgency window are design choices and have not been tuned with real data.
- Receivers cannot yet set their food requirements from the website; this is currently done in the database.
- The pickup schedule rules exist in the database, but the website does not yet let donors and receivers agree on a pickup time.
- Matching is greedy, so the closest eligible receiver can receive most of the food until its capacity is used up.
- Before any public deployment, remove the demo accounts, set a strong `JWT_SECRET`, remove the fallback secret in `main.py` and serve the site over HTTPS.
