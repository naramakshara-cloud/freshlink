INSERT INTO food_categories (name, decay_rate, max_safe_hours, spoilage_shape, requires_refrigeration, description) VALUES
('Cooked Rice & Curries', 0.1500,   6, 1.0, FALSE, 'Biryani, pulao, plain rice, dal, sambar, rasam, curries, sabzi'),
('Breads & Rotis',        0.0800,  12, 1.0, FALSE, 'Chapati, roti, naan, paratha, puri, bread, buns, pav'),
('Dairy & Sweets',        0.1200,   8, 1.0, TRUE,  'Milk, curd, buttermilk, paneer dishes, kheer, rasgulla, milk-based sweets'),
('Fresh Fruits & Veg',    0.0300,  48, 1.0, FALSE, 'Whole, uncut fruits and vegetables such as bananas, apples, oranges and tomatoes'),
('Packaged / Dry Food',   0.0050, 168, 1.0, FALSE, 'Sealed biscuits, chips, bread packets, and dry rations such as rice, atta and dal')
ON CONFLICT (name) DO NOTHING;
