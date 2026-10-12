# FreshLink Database

PostgreSQL + PostGIS schema for real-time surplus food matching.

## Setup
```bash
createdb freshlink
psql -d freshlink -f schema.sql
psql -d freshlink -f seed.sql
```

## Try it
```sql
SELECT * FROM v_available_listings ORDER BY hours_left;  -- live feed with freshness bands
SELECT * FROM nearby_listings_for_ngo(1);                -- what NGO 1 should pick up first
SELECT * FROM match_food_to_ngos();                      -- run the expiry-aware scheduler
SELECT * FROM v_ngo_capacity_today;                      -- capacity left per NGO
UPDATE matches SET status = 'completed' WHERE match_id = 1;
SELECT * FROM v_impact_summary;                          -- kg saved, rescue rate
SELECT * FROM expire_stale_listings();                   -- housekeeping
```

## Scoring model
| Score | Formula | Meaning |
|---|---|---|
| Freshness | `100 · e^(−k · hours_since_prepared)` | `k` is set per food category |
| Urgency | `100 − hours_left · (100/24)` | 100 = expiring now, 0 = 24h+ left |
| Proximity | `100 · (1 − distance / NGO radius)` | 100 = at the NGO |
| **Priority** | `0.5·urgency + 0.3·freshness + 0.2·proximity` | used for matching |

`effective_expiry` = the earlier of the donor's stated expiry and the
category's food-safety limit (`max_safe_hours`), so a donor can't list
cooked rice as good for 2 days.

## Matching rules
Listings are processed soonest-expiry first. Each goes to the highest-priority
NGO that is active, within its service radius, has enough capacity left today,
can refrigerate if needed, and hasn't already rejected that listing. Rejected or
cancelled matches return food to the pool automatically (via trigger), and every
status change is logged in `match_history`.
