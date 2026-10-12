-- =====================================================================
-- FRESHLINK Demo Seed Data
-- Demo user accounts for each role (donor, receiver, admin),
-- associated donor and receiver profiles, and sample surplus food listings.
-- Coordinates are in central Bengaluru (WGS 84, SRID 4326).
-- =====================================================================

-- Clean demo data safely before reloading
DELETE FROM match_history;
DELETE FROM matches;
DELETE FROM food_listings;
DELETE FROM receivers;
DELETE FROM donors;
DELETE FROM users;

-- ---------------------------------------------------------------------
-- 1. USERS (Roles: donor, receiver, admin)
-- Password for all demo accounts: 'DemoPass123!'
-- Bcrypt hash generated with bcrypt 5.0.0, salt rounds 12
-- ---------------------------------------------------------------------
INSERT INTO users (email, password_hash, full_name, phone, role, is_active) VALUES
-- Admin
('admin@freshlink.org',    '$2b$12$DL4/nhNVkpzcp0sneYLte./4V9yCEZqCdYINlp4ED1vdqT/HarAn2', 'System Administrator',     '9999990001', 'admin',    TRUE),
-- Donors
('hostel.a@college.edu',   '$2b$12$DL4/nhNVkpzcp0sneYLte./4V9yCEZqCdYINlp4ED1vdqT/HarAn2', 'Boys Hostel A Mess Lead',   '9000000001', 'donor',    TRUE),
('canteen@college.edu',    '$2b$12$DL4/nhNVkpzcp0sneYLte./4V9yCEZqCdYINlp4ED1vdqT/HarAn2', 'Central Canteen Manager',  '9000000002', 'donor',    TRUE),
('sharma.home@gmail.com',  '$2b$12$DL4/nhNVkpzcp0sneYLte./4V9yCEZqCdYINlp4ED1vdqT/HarAn2', 'Ramesh Sharma',             '9000000003', 'donor',    TRUE),
('hostel.d@college.edu',   '$2b$12$DL4/nhNVkpzcp0sneYLte./4V9yCEZqCdYINlp4ED1vdqT/HarAn2', 'Girls Hostel Mess Lead',    '9000000004', 'donor',    TRUE),
-- Receivers
('annapurna@trust.org',    '$2b$12$DL4/nhNVkpzcp0sneYLte./4V9yCEZqCdYINlp4ED1vdqT/HarAn2', 'Annapurna NGO Director',    '8000000001', 'receiver', TRUE),
('shelter@hope.org',       '$2b$12$DL4/nhNVkpzcp0sneYLte./4V9yCEZqCdYINlp4ED1vdqT/HarAn2', 'Hope Shelter Coordinator',  '8000000002', 'receiver', TRUE),
('jayanagar@kitchen.org',  '$2b$12$DL4/nhNVkpzcp0sneYLte./4V9yCEZqCdYINlp4ED1vdqT/HarAn2', 'Community Kitchen Lead',    '8000000003', 'receiver', TRUE),
('paws@animalshelter.org', '$2b$12$DL4/nhNVkpzcp0sneYLte./4V9yCEZqCdYINlp4ED1vdqT/HarAn2', 'Paws Rescue Caretaker',    '8000000004', 'receiver', TRUE),
('kumar.family@gmail.com', '$2b$12$DL4/nhNVkpzcp0sneYLte./4V9yCEZqCdYINlp4ED1vdqT/HarAn2', 'Suresh Kumar (Family)',    '8000000005', 'receiver', TRUE);

-- ---------------------------------------------------------------------
-- 2. DONORS (Linked to users)
-- ---------------------------------------------------------------------
INSERT INTO donors (user_id, name, donor_type, contact_phone, email, address, location, is_verified) VALUES
((SELECT user_id FROM users WHERE email='hostel.a@college.edu'),  'Boys Hostel Block A Mess', 'hostel',    '9000000001', 'hostel.a@college.edu',  'Campus Rd, Block A',   ST_MakePoint(77.5946, 12.9716)::geography, TRUE),
((SELECT user_id FROM users WHERE email='canteen@college.edu'),   'Central Canteen',          'canteen',   '9000000002', 'canteen@college.edu',   'Main Campus',          ST_MakePoint(77.5990, 12.9750)::geography, TRUE),
((SELECT user_id FROM users WHERE email='sharma.home@gmail.com'), 'Sharma Household',         'household', '9000000003', 'sharma.home@gmail.com', '4th Cross, Jayanagar',  ST_MakePoint(77.5830, 12.9300)::geography, FALSE),
((SELECT user_id FROM users WHERE email='hostel.d@college.edu'),  'Girls Hostel Mess',        'hostel',    '9000000004', 'hostel.d@college.edu',  'Campus Rd, Block D',   ST_MakePoint(77.6010, 12.9690)::geography, TRUE);

-- ---------------------------------------------------------------------
-- 3. RECEIVERS (Approved, Pending, and Animal Shelters)
-- ---------------------------------------------------------------------
INSERT INTO receivers (user_id, name, receiver_type, verification_status, contact_phone, email, address, location, service_radius_km, daily_capacity_kg, has_refrigeration, is_active) VALUES
-- Approved large NGO
((SELECT user_id FROM users WHERE email='annapurna@trust.org'),    'Annapurna Food Bank',         'ngo',                  'approved', '8000000001', 'annapurna@trust.org',    'MG Road',       ST_MakePoint(77.6070, 12.9750)::geography, 5, 80, TRUE,  TRUE),
-- Approved shelter
((SELECT user_id FROM users WHERE email='shelter@hope.org'),       'Hope Shelter',                'orphanage',            'approved', '8000000002', 'shelter@hope.org',       'Shivajinagar',  ST_MakePoint(77.6000, 12.9850)::geography, 3, 30, FALSE, TRUE),
-- Approved community kitchen
((SELECT user_id FROM users WHERE email='jayanagar@kitchen.org'),  'Jayanagar Community Kitchen', 'community_kitchen',    'approved', '8000000003', 'jayanagar@kitchen.org',  'Jayanagar',     ST_MakePoint(77.5800, 12.9250)::geography, 4, 40, FALSE, TRUE),
-- Approved animal shelter (only receives suitable_for_animals food)
((SELECT user_id FROM users WHERE email='paws@animalshelter.org'), 'Paws Animal Rescue',         'animal_shelter',       'approved', '8000000004', 'paws@animalshelter.org', 'Koramangala',   ST_MakePoint(77.6200, 12.9350)::geography, 5, 25, FALSE, TRUE),
-- Approved Individual / Family (default small capacity: 5 kg)
((SELECT user_id FROM users WHERE email='kumar.family@gmail.com'), 'Kumar Family',                'individual_or_family', 'approved', '8000000005', 'kumar.family@gmail.com', 'Wilson Garden',  ST_MakePoint(77.5950, 12.9500)::geography, 2, 5,  FALSE, TRUE);

-- ---------------------------------------------------------------------
-- 4. FOOD LISTINGS (Sample surplus food referencing donors by email)
-- ---------------------------------------------------------------------
INSERT INTO food_listings (
    donor_id, category_id, title, description, quantity_kg, servings,
    prepared_at, expires_at, is_veg, allergens, suitable_for_animals,
    pickup_instructions, pickup_code
) VALUES
(
    (SELECT donor_id FROM donors WHERE email='hostel.a@college.edu' LIMIT 1),
    1, 'Veg pulao and dal (dinner surplus)', 'Mild spices, packed in food-grade trays', 12.0, 40,
    NOW() - INTERVAL '2 hours', NOW() + INTERVAL '3 hours', TRUE, NULL, TRUE,
    'Collect from hostel mess backdoor kitchen counter', '4821'
),
(
    (SELECT donor_id FROM donors WHERE email='canteen@college.edu' LIMIT 1),
    2, 'Fresh Chapatis', 'Stacked in insulated foil wrappers', 4.0, 60,
    NOW() - INTERVAL '1 hour', NOW() + INTERVAL '10 hours', TRUE, 'Gluten (wheat)', TRUE,
    'Ask for chef Ramesh at main counter', '1092'
),
(
    (SELECT donor_id FROM donors WHERE email='canteen@college.edu' LIMIT 1),
    3, 'Paneer curry + curd', 'Fresh paneer with yogurt curry', 6.0, 20,
    NOW() - INTERVAL '30 minutes', NOW() + INTERVAL '6 hours', TRUE, 'Dairy (milk, paneer)', FALSE,
    'Please bring insulated cold carrier bag', '9315'
),
(
    (SELECT donor_id FROM donors WHERE email='sharma.home@gmail.com' LIMIT 1),
    1, 'Home-cooked sambar rice', 'Freshly made home meals', 2.5, 8,
    NOW() - INTERVAL '1 hour', NOW() + INTERVAL '4 hours', TRUE, NULL, FALSE,
    'Ring bell at gate #14', '7741'
),
(
    (SELECT donor_id FROM donors WHERE email='hostel.d@college.edu' LIMIT 1),
    4, 'Bananas and apples', 'Whole fresh unpeeled fruits', 8.0, 50,
    NOW() - INTERVAL '5 hours', NOW() + INTERVAL '36 hours', TRUE, NULL, TRUE,
    'Boxes kept near hostel security cabin', '3509'
),
(
    (SELECT donor_id FROM donors WHERE email='hostel.d@college.edu' LIMIT 1),
    5, 'Sealed biscuit packets', 'Intact unopened commercial packs', 3.0, 30,
    NOW() - INTERVAL '1 day', NOW() + INTERVAL '30 days', TRUE, 'Wheat, sugar', TRUE,
    'Ready for pickup at Block D reception', '8820'
);
