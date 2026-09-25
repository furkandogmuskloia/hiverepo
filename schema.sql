-- HIVE schema
-- pg_dump yerine elle yazildi, restore icin: psql -U hive -d hive -f schema.sql

CREATE TABLE IF NOT EXISTS products (
    id          SERIAL PRIMARY KEY,
    name        TEXT,
    warehouse   TEXT,
    quantity    INTEGER,
    updated_at  TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS movements (
    id          SERIAL PRIMARY KEY,
    product_id  INTEGER REFERENCES products(id),
    delta       INTEGER,
    note        TEXT,
    created_at  TIMESTAMP DEFAULT NOW()
);

-- cron (report.sh) dolduruyor
CREATE TABLE IF NOT EXISTS daily_reports (
    id              SERIAL PRIMARY KEY,
    generated_at    TIMESTAMP DEFAULT NOW(),
    total_products  INTEGER,
    total_quantity  INTEGER
);

INSERT INTO products (name, warehouse, quantity, updated_at) VALUES
    ('Paracetamol 500mg',      'Dublin-A',    1200, NOW()),
    ('Ibuprofen 400mg',        'Dublin-A',    850,  NOW()),
    ('Amoxicillin 250mg',      'Dublin-B',    430,  NOW()),
    ('Insulin Glargine 100IU', 'Frankfurt-1', 75,   NOW()),
    ('Morphine Sulfate 10mg',  'Frankfurt-1', 40,   NOW()),
    ('Sodium Chloride 0.9%',   'London-C',    3000, NOW()),
    ('Ethanol 96%',            'London-C',    500,  NOW()),
    ('Hydrogen Peroxide 3%',   'Dublin-B',    620,  NOW()),
    ('Adrenaline 1mg/ml',      'Frankfurt-1', 90,   NOW()),
    ('Diazepam 5mg',           'Dublin-A',    310,  NOW()),
    ('Formaldehyde 37%',       'London-C',    120,  NOW()),
    ('Ceftriaxone 1g',         'Dublin-B',    260,  NOW()),
    ('Omeprazole 20mg',        'Dublin-A',    980,  NOW()),
    ('Chlorhexidine 2%',       'London-C',    440,  NOW()),
    ('Heparin 5000IU',         'Frankfurt-1', 150,  NOW()),
    ('Lidocaine 2%',           'Dublin-B',    380,  NOW()),
    ('Acetone',                'London-C',    700,  NOW()),
    ('T-Compound (sample)',    'Frankfurt-1', 3,    NOW());
