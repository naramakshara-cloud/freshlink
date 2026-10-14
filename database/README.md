# FreshLink Database
PostgreSQL 14+ with PostGIS 3+.
## Setup or upgrade
Both commands are safe on an existing database. They never delete data.
```
psql -U postgres -d freshlink -f schema.sql
psql -U postgres -d freshlink -f seed.sql
```
`demo_seed.sql` deletes all users, listings and matches and reloads the demo accounts. Only run it to start over.
## Tables
| Project PDF entity | Table |
|---|---|
| FOOD_PROVIDER | donors (linked to users) |
| FOOD_DONATION | food_listings |
| NGO | receivers (NGOs, shelters, kitchens, families) |
| NGO_REQUIREMENT | receiver_requirements |
| FOOD_MATCH | matches, with match_history as the audit log |
| PICKUP_SCHEDULE | pickup_schedules |
## Scores
**Safe shelf life (T):** the earlier of the donor's expiry time and the category's food-safety limit (`max_safe_hours`).
**Freshness:** `(remaining shelf life ÷ total shelf life) × 100`, the formula from the project PDF. In SQL it is written as `100 × (1 − (e ÷ T)^k)` with `e` the hours since preparation, which is the same thing when `k = 1`. Every category uses `k = 1`. The `spoilage_shape` column holds `k` so a curved decay can be tried later without changing any code.
| Category | k | Safety limit |
|---|---|---|
| Cooked Rice & Curries | 1.0 | 6 h |
| Dairy & Sweets | 1.0 | 8 h |
| Breads & Rotis | 1.0 | 12 h |
| Fresh Fruits & Veg | 1.0 | 48 h |
| Packaged / Dry Food | 1.0 | 168 h |
**Urgency:** `100 × (1 − hours left ÷ 24)`, between 0 and 100.
**Priority:** `0.6 × Urgency + 0.4 × (100 − Freshness)`.
Example at 4 PM: rice cooked at 10 AM that expires at 6 PM scores freshness 25, urgency 91.67, priority 85. Biscuits at 25% freshness with 42 hours left score priority 30, so the rice is handled first even though both are equally fresh.
## Matching rules
Listings are matched in order of priority, highest first. Each goes to one receiver that is approved and active, within its service radius, has enough capacity left today, has a fridge if the food needs one, still needs that category if it has set requirements, and has not already rejected or timed out on this food. Human receivers are chosen before animal shelters, which only receive food marked safe for animals. Among the rest, the closest relative to its service radius wins. Food below freshness 20 is not matched.
## Pickup schedules
A pickup time must be before the food's safe expiry, and only for a pending or accepted match. Rejecting or cancelling a match cancels its schedule. Picking up completes it. A schedule more than 2 hours overdue is marked missed.
## Food types
Admins manage food types from the Admin panel: name, examples shown to donors, safe hours and whether a fridge is needed. Food types are hidden instead of deleted, because older listings still use them. A new safe-hours value applies to food posted after the change. Names must be unique, ignoring capital letters.
