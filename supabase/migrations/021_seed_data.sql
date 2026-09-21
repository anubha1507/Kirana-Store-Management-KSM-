-- Run after 020_views.sql. OPTIONAL: development and demo data only.
-- ============================================================================
-- This migration does NOT create auth.users rows. Create a real user through
-- Supabase Auth first (Dashboard > Authentication > Add user, or sign up from
-- the app), then either:
--   * set the owner below by uncommenting v_owner_id, or
--   * run it as-is and the first existing auth user becomes the demo owner.
-- Re-running is safe: the demo store is identified by name and skipped if it
-- already exists.
-- ============================================================================
DO $$
DECLARE
  v_owner_id uuid;
  v_store_id uuid;
  v_category_ids uuid[];
  v_product_ids uuid[];
BEGIN
  -- To pin a specific owner, replace the next line with an explicit id:
  -- v_owner_id := '00000000-0000-0000-0000-000000000000'::uuid;
  SELECT id INTO v_owner_id FROM auth.users ORDER BY created_at LIMIT 1;

  IF v_owner_id IS NULL THEN
    RAISE NOTICE 'Seed skipped: no auth user exists yet. Create a user, then re-run 021_seed_data.sql.';
    RETURN;
  END IF;

  SELECT id INTO v_store_id FROM public.stores WHERE name = 'Demo Kirana Store' LIMIT 1;

  IF v_store_id IS NULL THEN
    INSERT INTO public.stores (name, owner_id, phone, email, address, city, state,
                               pincode, currency, timezone)
    VALUES ('Demo Kirana Store', v_owner_id, '9876543210', 'demo@example.com',
            '12 Main Bazaar Road', 'Pune', 'Maharashtra', '411001', 'INR', 'Asia/Kolkata')
    RETURNING id INTO v_store_id;
  END IF;

  -- Store settings (the bootstrap trigger creates defaults; tune them here).
  UPDATE public.store_settings
     SET invoice_prefix = 'INV',
         enable_gst = true,
         default_tax_rate = 5.00,
         allow_negative_stock = false,
         cashier_can_record_payments = true,
         low_stock_default_threshold = 10
   WHERE store_id = v_store_id;

  -- Categories
  INSERT INTO public.categories (store_id, name, description) VALUES
    (v_store_id, 'Staples',   'Atta, rice, dal, sugar and daily cooking essentials'),
    (v_store_id, 'Snacks',    'Biscuits, namkeen, chips and packaged snacks'),
    (v_store_id, 'Beverages', 'Tea, coffee, juices and soft drinks'),
    (v_store_id, 'Dairy',     'Milk, curd, paneer and butter'),
    (v_store_id, 'Household', 'Soap, detergent and cleaning supplies')
  ON CONFLICT DO NOTHING;

  SELECT array_agg(id ORDER BY name) INTO v_category_ids
    FROM public.categories WHERE store_id = v_store_id;

  -- Products. Opening stock is recorded as a stock movement by the
  -- record_opening_stock trigger, so inventory history is complete from day one.
  INSERT INTO public.products
    (store_id, category_id, name, sku, barcode, cost_price, selling_price,
     stock_quantity, unit, low_stock_threshold)
  VALUES
    (v_store_id, v_category_ids[5], 'Aashirvaad Atta 5kg', 'ATT-5KG', '8901234500011', 210.00, 245.00, 40,  'bag',    10),
    (v_store_id, v_category_ids[5], 'Basmati Rice 1kg',    'RICE-1KG','8901234500028',  95.00, 120.00, 60,  'kg',     15),
    (v_store_id, v_category_ids[5], 'Toor Dal 1kg',        'DAL-TOOR','8901234500035', 130.00, 160.00, 35,  'kg',     10),
    (v_store_id, v_category_ids[3], 'Tata Salt 1kg',       'SALT-1KG','8901234500042',  20.00,  28.00, 80,  'packet', 20),
    (v_store_id, v_category_ids[3], 'Sugar 1kg',           'SUG-1KG', '8901234500059',  40.00,  48.00, 50,  'kg',     15),
    (v_store_id, v_category_ids[4], 'Maggi Noodles 70g',   'MAG-70G', '8901234500066',  12.00,  15.00, 120, 'packet', 24),
    (v_store_id, v_category_ids[4], 'Parle-G Biscuit',     'PAR-G',   '8901234500073',  8.00,   10.00, 150, 'packet', 30),
    (v_store_id, v_category_ids[4], 'Haldiram Bhujia 200g','BHU-200G','8901234500080', 45.00,  55.00, 25,  'packet', 10),
    (v_store_id, v_category_ids[2], 'Tata Tea Gold 500g',  'TEA-500G','8901234500097', 240.00, 285.00, 20,  'packet', 8),
    (v_store_id, v_category_ids[2], 'Amul Butter 500g',    'BUT-500G','8901234500103', 250.00, 275.00, 15,  'packet', 6),
    (v_store_id, v_category_ids[2], 'Amul Taaza Milk 1L',  'MILK-1L', '8901234500110',  58.00,  66.00, 30,  'liter',  12),
    (v_store_id, v_category_ids[1], 'Surf Excel 1kg',      'SURF-1KG','8901234500127', 105.00, 125.00, 30,  'packet', 10),
    (v_store_id, v_category_ids[1], 'Colgate Toothpaste',  'COLG-100','8901234500134',  75.00,  95.00, 22,  'piece',  8),
    (v_store_id, v_category_ids[1], 'Lifebuoy Soap',       'SOAP-100','8901234500141',  32.00,  40.00, 48,  'piece',  12),
    (v_store_id, v_category_ids[5], 'Fortune Sunflower Oil 1L', 'OIL-1L','8901234500158', 140.00, 165.00, 5, 'liter', 10)
  ON CONFLICT DO NOTHING;

  SELECT array_agg(id ORDER BY name) INTO v_product_ids
    FROM public.products WHERE store_id = v_store_id;

  -- Suppliers
  INSERT INTO public.suppliers (store_id, name, phone, email, address, gst_number, notes)
  VALUES
    (v_store_id, 'Sharma Wholesale Traders', '9812345678', 'sales@sharmawholesale.example',
     'Market Yard, Pune', '27ABCDE1234F1Z5', 'Delivers staples every Monday'),
    (v_store_id, 'Krishna Distributors', '9823456789', 'orders@krishnadist.example',
     'Hadapsar, Pune', '27PQRST5678G2Z3', 'FMCG and snacks distributor'),
    (v_store_id, 'Gokul Dairy Supply', '9834567890', NULL,
     'Kothrud, Pune', NULL, 'Daily milk and dairy delivery')
  ON CONFLICT DO NOTHING;

  -- Customers, including one with an outstanding udhaar balance.
  INSERT INTO public.customers (store_id, name, phone, email, address, credit_limit)
  VALUES
    (v_store_id, 'Rahul Sharma', '9900112233', 'rahul@example.com', 'Flat 4, Green Park', 5000),
    (v_store_id, 'Priya Deshmukh', '9900223344', NULL, 'Kalyani Nagar', 3000),
    (v_store_id, 'Amit Kumar', '9900334455', NULL, 'Viman Nagar', 2000),
    (v_store_id, 'Sunita Patil', '9900445566', NULL, 'Baner Road', 0)
  ON CONFLICT DO NOTHING;

  RAISE NOTICE 'Seed complete for store % (%).', v_store_id, 'Demo Kirana Store';
  RAISE NOTICE 'To create demo transactions, call public.create_sale / create_purchase / record_customer_payment as a store member.';
END $$;
