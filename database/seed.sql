-- =====================================================================
-- FRESHLINK sample data. Coordinates are around central Bengaluru;
-- replace with your own city. ST_MakePoint takes (longitude, latitude).
-- Food times are relative to NOW() so the demo always works.
-- =====================================================================

INSERT INTO food_categories (name, decay_rate, max_safe_hours, requires_refrigeration, description) VALUES
('Cooked Rice & Curries', 0.1500,  6, FALSE, 'Hot cooked meals; spoil quickly at room temperature'),
('Breads & Rotis',        0.0800, 12, FALSE, 'Chapati, roti, bread, buns'),
('Dairy & Sweets',        0.1200,  8, TRUE,  'Milk, curd, paneer, milk-based sweets'),
('Fresh Fruits & Veg',    0.0300, 48, FALSE, 'Uncut produce'),
('Packaged / Dry Food',   0.0050, 168, FALSE, 'Sealed snacks, biscuits, dry rations');

INSERT INTO donors (name, donor_type, contact_phone, email, address, location, is_verified) VALUES
('Boys Hostel Block A Mess', 'hostel',    '9000000001', 'messA@college.edu',   'Campus Rd, Block A',  ST_MakePoint(77.5946, 12.9716)::geography, TRUE),
('Central Canteen',          'canteen',   '9000000002', 'canteen@college.edu', 'Main Campus',         ST_MakePoint(77.5990, 12.9750)::geography, TRUE),
('Sharma Household',         'household', '9000000003', NULL,                  '4th Cross, Jayanagar', ST_MakePoint(77.5830, 12.9300)::geography, FALSE),
('Girls Hostel Mess',        'hostel',    '9000000004', 'gh@college.edu',      'Campus Rd, Block D',  ST_MakePoint(77.6010, 12.9690)::geography, TRUE);

INSERT INTO ngos (name, contact_phone, email, address, location, service_radius_km, daily_capacity_kg, has_refrigeration) VALUES
('Annapurna Food Bank',   '8000000001', 'hello@annapurna.org', 'MG Road',      ST_MakePoint(77.6070, 12.9750)::geography, 5,  80, TRUE),
('Hope Shelter',          '8000000002', 'hope@shelter.org',    'Shivajinagar', ST_MakePoint(77.6000, 12.9850)::geography, 3,  30, FALSE),
('Jayanagar Community Kitchen', '8000000003', NULL,            'Jayanagar',    ST_MakePoint(77.5800, 12.9250)::geography, 4,  40, FALSE);

INSERT INTO food_listings (donor_id, category_id, title, quantity_kg, servings, prepared_at, expires_at) VALUES
(1, 1, 'Veg pulao and dal (dinner surplus)', 12.0, 40, NOW() - INTERVAL '2 hours',   NOW() + INTERVAL '3 hours'),
(2, 2, 'Chapatis',                            4.0, 60, NOW() - INTERVAL '1 hour',    NOW() + INTERVAL '10 hours'),
(2, 3, 'Paneer curry + curd',                 6.0, 20, NOW() - INTERVAL '30 minutes', NOW() + INTERVAL '6 hours'),
(3, 1, 'Home-cooked sambar rice',             2.5,  8, NOW() - INTERVAL '1 hour',    NOW() + INTERVAL '4 hours'),
(4, 4, 'Bananas and apples',                  8.0, 50, NOW() - INTERVAL '5 hours',   NOW() + INTERVAL '36 hours'),
(4, 5, 'Sealed biscuit packets',              3.0, 30, NOW() - INTERVAL '1 day',     NOW() + INTERVAL '30 days');
