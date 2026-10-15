# FreshLink Database

PostgreSQL 14 or later with PostGIS 3 or later.

## Setup or upgrade

Both commands are safe to run on an existing database. They add anything new and never delete data.

```
psql -U postgres -d freshlink -f schema.sql
psql -U postgres -d freshlink -f seed.sql
```

`demo_seed.sql` deletes all users, listings and matches and reloads the demo accounts. Only run it when you want to start over.

## Tables

| Project PDF entity | Table |
|---|---|
| FOOD_PROVIDER | `donors`, linked to `users` |
| FOOD_DONATION | `food_listings` |
| NGO | `receivers` (NGOs, shelters, kitchens, families) |
| NGO_REQUIREMENT | `receiver_requirements` |
| FOOD_MATCH | `matches`, with `match_history` as the audit log |
| PICKUP_SCHEDULE | `pickup_schedules` |

`food_categories` holds the food types and `users` holds login accounts for all three roles.

## Scores

**Safe shelf life (T)** is the time from preparation to whichever comes first: the donor's expiry time or the category's safety limit (`max_safe_hours`).

**Freshness** is `(remaining shelf life / total shelf life) * 100`, the formula from the project PDF. In SQL it is written as `100 * (1 - (e / T)^k)`, where `e` is the hours since preparation. This is the same formula when `k = 1`, and every category uses `k = 1`. The value of `k` is stored in the `spoilage_shape` column so a curved decay can be tried later without changing any code.

| Category | k | Safety limit | Needs fridge |
|---|---|---|---|
| Cooked Rice & Curries | 1.0 | 6 h | No |
| Dairy & Sweets | 1.0 | 8 h | Yes |
| Breads & Rotis | 1.0 | 12 h | No |
| Fresh Fruits & Veg | 1.0 | 48 h | No |
| Packaged / Dry Food | 1.0 | 168 h | No |

**Urgency** is `100 * (1 - hours left / 24)`, kept between 0 and 100.

**Priority** is `0.6 * urgency + 0.4 * (100 - freshness)`.

Example at 4 PM: rice cooked at 10 AM that expires at 6 PM has freshness 25, urgency 91.67 and priority 85. Biscuits at 25% freshness with 42 hours left have priority 30. Both are equally fresh, but the rice is matched first.

**Proximity** is `100 * (1 - distance / pickup range)`. It is only used to choose between receivers for the same item, not to rank food.

## Matching rules

`match_food_to_receivers()` handles available food in order of priority, highest first. Each item goes to one receiver that is approved and active, within its own pickup range, has enough daily capacity left (pending offers count towards it), has a fridge if the food needs one, still needs that category if it has set requirements, and has not already rejected the item or let an offer for it time out. Human receivers are chosen before animal shelters, which only receive food marked safe for animals. Among the rest, the receiver with the highest proximity score wins. Food below freshness 20 is not matched.

`expire_stale_listings()` cancels offers that have not been accepted in time and marks food past its safe expiry as expired. The backend calls it every minute with a 15-minute timeout, then runs matching again.

## Pickup schedules

A pickup time must be before the food's safe expiry and can only be set for a pending or accepted match. Rejecting or cancelling a match cancels its schedule, and picking the food up completes it. A schedule more than 2 hours overdue is marked as missed.

## Food types

Admins manage food types from the Admin panel: the name, example foods shown to donors, the safety limit in hours and whether a fridge is needed. Food types are hidden instead of deleted, because older listings still refer to them. A new safety limit applies to food posted after the change. Names must be unique, ignoring capital letters.
