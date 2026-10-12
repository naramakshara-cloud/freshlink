-- =====================================================================
-- FRESHLINK Seed Data: Canonical Reference Data
-- This file contains ONLY permanent system reference data (food categories).
-- For demo users, mock donors/receivers, and sample listings, see demo_seed.sql.
-- =====================================================================

INSERT INTO food_categories (name, decay_rate, max_safe_hours, requires_refrigeration, description) VALUES
('Cooked Rice & Curries', 0.1500,  6, FALSE, 'Hot cooked meals; spoil quickly at room temperature'),
('Breads & Rotis',        0.0800, 12, FALSE, 'Chapati, roti, bread, buns'),
('Dairy & Sweets',        0.1200,  8, TRUE,  'Milk, curd, paneer, milk-based sweets'),
('Fresh Fruits & Veg',    0.0300, 48, FALSE, 'Uncut produce'),
('Packaged / Dry Food',   0.0050, 168, FALSE, 'Sealed snacks, biscuits, dry rations')
ON CONFLICT (name) DO UPDATE SET
    decay_rate = EXCLUDED.decay_rate,
    max_safe_hours = EXCLUDED.max_safe_hours,
    requires_refrigeration = EXCLUDED.requires_refrigeration,
    description = EXCLUDED.description;
