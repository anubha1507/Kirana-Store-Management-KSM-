-- ============================================================================
-- Kirana Store Management - backend verification suite
-- ============================================================================
-- Purpose
--   Verifies a deployment of supabase/migrations against the security model in
--   docs/03_rls_matrix.md and the RPC contract in docs/04_rpc_reference.md.
--   The README and docs/07_setup.md reference this file; it used to be an empty
--   placeholder.
--
-- How to run
--   * Supabase SQL Editor: paste this whole file and run it once.
--   * Local, without any database install:  npm run validate:db
--
-- Expected result
--   Success. No rows returned.
--   Every assertion is named (T01.1, T07.4, ...). The first failure aborts with
--   a red error naming the assertion, the expected value and the actual value.
--
-- Safety
--   The whole suite runs inside ONE transaction that ends in ROLLBACK, so no
--   test user, store, sale or audit row survives. It is safe to run against a
--   staging project; it is not intended for production.
--
-- What it creates (all rolled back)
--   * a `ksm_test` schema holding the harness tables/functions,
--   * four throwaway auth users (owner, manager, cashier, outsider) with
--     clearly-marked @ksm.test addresses and no usable password,
--   * two stores, plus catalogue, supplier and customer rows.
--
-- Note on auth.users
--   docs/07_setup.md warns against fake auth rows in seed data; this file does
--   create them, deliberately, because role and RLS behaviour cannot be tested
--   without real identities. They are documented and rolled back.
-- ============================================================================
BEGIN;

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
CREATE SCHEMA ksm_test;
GRANT USAGE ON SCHEMA ksm_test TO authenticated;

-- Test context: ids captured by one step and reused by later steps. Readable
-- only by the migration runner, so impersonated roles cannot peek at it.
CREATE TABLE ksm_test.ctx (
  key text PRIMARY KEY,
  value text NOT NULL
);

-- Assertion log. Every check appends a row so a failure report can show what
-- passed before it.
CREATE TABLE ksm_test.results (
  seq serial PRIMARY KEY,
  name text NOT NULL,
  status text NOT NULL,
  detail text
);

-- Switches the session to a user identity, exactly the way PostgREST does it:
-- request.jwt.claims + role authenticated. SET LOCAL is transaction-scoped, so
-- it stays in effect after this function returns.
--
-- SECURITY INVOKER on purpose: PostgreSQL refuses `SET ROLE` inside a
-- SECURITY DEFINER function, and the role switch is the whole point here.
CREATE OR REPLACE FUNCTION ksm_test.act_as(p_user uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text,
                     true);
  EXECUTE 'set local role authenticated';
END;
$$;

-- Back to the migration runner: used before asserting or capturing ids, so the
-- assertions themselves are never subject to RLS. Also INVOKER, for the same
-- reason as act_as().
CREATE OR REPLACE FUNCTION ksm_test.act_as_service()
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  EXECUTE 'reset role';
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

GRANT EXECUTE ON FUNCTION ksm_test.act_as(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION ksm_test.act_as_service() TO authenticated;

CREATE OR REPLACE FUNCTION ksm_test.ctx_set(p_key text, p_value text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, ksm_test AS $$
  INSERT INTO ksm_test.ctx (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
$$;

CREATE OR REPLACE FUNCTION ksm_test.ctx_get(p_key text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, ksm_test AS $$
  SELECT value FROM ksm_test.ctx WHERE key = p_key;
$$;

GRANT EXECUTE ON FUNCTION ksm_test.ctx_set(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION ksm_test.ctx_get(text) TO authenticated;

CREATE OR REPLACE FUNCTION ksm_test.pass(p_name text, p_detail text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, ksm_test AS $$
BEGIN
  INSERT INTO ksm_test.results (name, status, detail) VALUES (p_name, 'pass', p_detail);
END;
$$;

CREATE OR REPLACE FUNCTION ksm_test.fail(p_name text, p_detail text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, ksm_test AS $$
BEGIN
  INSERT INTO ksm_test.results (name, status, detail) VALUES (p_name, 'fail', p_detail);
  RAISE EXCEPTION 'ASSERTION FAILED [%]: %', p_name, p_detail USING ERRCODE = 'P0001';
END;
$$;

-- Equality, with NULL treated as a value: comparing "no store" to "no store"
-- must pass, and comparing "1" to "no store" must fail.
CREATE OR REPLACE FUNCTION ksm_test.assert_true(p_name text, p_ok boolean, p_detail text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, ksm_test AS $$
BEGIN
  IF p_ok IS TRUE THEN
    PERFORM ksm_test.pass(p_name, p_detail);
  ELSE
    PERFORM ksm_test.fail(p_name, COALESCE(p_detail, 'expected true, got false or null'));
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION ksm_test.assert_text(p_name text, p_actual text, p_expected text)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, ksm_test AS $$
BEGIN
  IF p_actual IS NOT DISTINCT FROM p_expected THEN
    PERFORM ksm_test.pass(p_name, 'value = ' || COALESCE(p_actual, '<null>'));
  ELSE
    PERFORM ksm_test.fail(p_name, 'expected ' || COALESCE(p_expected, '<null>')
                               || ', got ' || COALESCE(p_actual, '<null>'));
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION ksm_test.assert_num(p_name text, p_actual numeric, p_expected numeric)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, ksm_test AS $$
BEGIN
  IF p_actual IS NOT DISTINCT FROM p_expected THEN
    PERFORM ksm_test.pass(p_name, 'value = ' || COALESCE(p_actual::text, '<null>'));
  ELSE
    PERFORM ksm_test.fail(p_name, 'expected ' || COALESCE(p_expected::text, '<null>')
                               || ', got ' || COALESCE(p_actual::text, '<null>'));
  END IF;
END;
$$;

-- Asserts that a statement fails with a specific SQLSTATE. Used for the rules
-- that must be impossible to break: cross-store access, forged totals, direct
-- stock edits, negative balances, oversized payments, cancelled-sale edits.
--
-- SECURITY INVOKER on purpose: the probe statement must execute with the
-- session's current role. A SECURITY DEFINER wrapper would run it as the table
-- owner, bypass RLS, and make every isolation check pass for the wrong reason.
CREATE OR REPLACE FUNCTION ksm_test.assert_raises(p_name text, p_sql text, p_code text)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, ksm_test AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = p_code THEN
      PERFORM ksm_test.pass(p_name, 'rejected with SQLSTATE ' || p_code);
      RETURN;
    END IF;
    PERFORM ksm_test.fail(p_name, 'expected SQLSTATE ' || p_code || ', got ' || SQLSTATE
                               || ' (' || SQLERRM || ')');
    RETURN;
  END;
  PERFORM ksm_test.fail(p_name, 'expected SQLSTATE ' || p_code
                             || ' but the statement succeeded');
END;
$$;

-- Runs a scalar query as a given identity and returns the value. This is how
-- RLS visibility is measured. INVOKER, because it switches roles; the caller is
-- the migration runner, which is what makes the elevated assertions possible.
CREATE OR REPLACE FUNCTION ksm_test.probe(p_user uuid, p_sql text)
RETURNS text LANGUAGE plpgsql SET search_path = pg_catalog, ksm_test AS $$
DECLARE
  v_value text;
BEGIN
  PERFORM ksm_test.act_as(p_user);
  EXECUTE p_sql INTO v_value;
  PERFORM ksm_test.act_as_service();
  RETURN COALESCE(v_value, '<null>');
END;
$$;

GRANT EXECUTE ON FUNCTION ksm_test.pass(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION ksm_test.assert_true(text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION ksm_test.assert_text(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION ksm_test.assert_num(text, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION ksm_test.assert_raises(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION ksm_test.probe(uuid, text) TO authenticated;

-- The RPCs set their stock/balance bypass flags with is_local => true, which
-- scopes them to the calling transaction - correct in production, where each
-- RPC is its own transaction. This suite runs in a single transaction, so the
-- flags have to be cleared by hand before asserting that a *direct* edit is
-- still refused.
CREATE OR REPLACE FUNCTION ksm_test.clear_flags()
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  PERFORM set_config('ksm.allow_stock_change', '', true);
  PERFORM set_config('ksm.allow_balance_change', '', true);
  PERFORM set_config('ksm.allow_sale_cancel', '', true);
END;
$$;

GRANT EXECUTE ON FUNCTION ksm_test.clear_flags() TO authenticated;

-- ============================================================================
-- T01 - identities, profile bootstrap and store creation
-- ============================================================================
DO $$
DECLARE
  v_owner    uuid := '11111111-1111-4111-8111-111111111111';
  v_manager  uuid := '22222222-2222-4222-8222-222222222222';
  v_cashier  uuid := '33333333-3333-4333-8333-333333333333';
  v_outsider uuid := '44444444-4444-4444-8444-444444444444';
  v_store_a  uuid;
  v_store_b  uuid;
  v_member   jsonb;
BEGIN
  INSERT INTO auth.users
    (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
     raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES
    (v_owner,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'owner@ksm.test',    'not-a-real-password', now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     jsonb_build_object('full_name', 'Test Owner'), now(), now()),
    (v_manager,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'manager@ksm.test',  'not-a-real-password', now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     jsonb_build_object('full_name', 'Test Manager'), now(), now()),
    (v_cashier,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'cashier@ksm.test',  'not-a-real-password', now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     jsonb_build_object('full_name', 'Test Cashier'), now(), now()),
    (v_outsider, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'outsider@ksm.test', 'not-a-real-password', now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     jsonb_build_object('full_name', 'Test Outsider'), now(), now());

  PERFORM ksm_test.ctx_set('owner', v_owner::text);
  PERFORM ksm_test.ctx_set('manager', v_manager::text);
  PERFORM ksm_test.ctx_set('cashier', v_cashier::text);
  PERFORM ksm_test.ctx_set('outsider', v_outsider::text);

  -- Every signup gets a profile from the on_auth_user_created trigger.
  PERFORM ksm_test.assert_text('T01.1 on_auth_user_created copied full_name into profiles',
    (SELECT full_name FROM public.profiles WHERE id = v_owner), 'Test Owner');
  PERFORM ksm_test.assert_num('T01.2 one profile per auth user',
    (SELECT count(*) FROM public.profiles p JOIN auth.users u ON u.id = p.id
      WHERE u.email LIKE '%@ksm.test'), 4);

  -- Store A: created by the owner, then staff are added through the RPCs from
  -- 024_rpc_store_members.sql.
  PERFORM ksm_test.act_as(v_owner);
  SELECT (public.create_store(
            p_name => 'Test Store A', p_phone => '9876500001', p_city => 'Pune',
            p_state => 'Maharashtra', p_pincode => '411001') ->> 'id')::uuid
    INTO v_store_a;

  SELECT (public.create_store(p_name => 'Test Store B', p_city => 'Nashik') ->> 'id')::uuid
    INTO v_store_b;

  v_member := public.add_store_member(v_store_a, ksm_test.ctx_get('manager')::uuid, 'manager');
  PERFORM ksm_test.ctx_set('member_manager', (v_member->>'id'));
  v_member := public.add_store_member(v_store_a, ksm_test.ctx_get('cashier')::uuid, 'cashier');
  PERFORM ksm_test.ctx_set('member_cashier', (v_member->>'id'));

  -- The outsider is deliberately a member of nothing.
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.ctx_set('store_a', v_store_a::text);
  PERFORM ksm_test.ctx_set('store_b', v_store_b::text);

  PERFORM ksm_test.assert_true('T01.3 create_store returned a store id', v_store_a IS NOT NULL);
  PERFORM ksm_test.assert_num('T01.4 bootstrap_store created the owner membership',
    (SELECT count(*) FROM public.store_members
      WHERE store_id = v_store_a AND user_id = v_owner AND role = 'owner' AND is_active), 1);
  PERFORM ksm_test.assert_num('T01.5 bootstrap_store created the settings row',
    (SELECT count(*) FROM public.store_settings WHERE store_id = v_store_a), 1);
  PERFORM ksm_test.assert_num('T01.6 store A has three active members',
    (SELECT count(*) FROM public.store_members WHERE store_id = v_store_a AND is_active), 3);
  PERFORM ksm_test.assert_num('T01.7 audit_row_change logged the store creation',
    (SELECT count(*) FROM public.audit_logs WHERE store_id = v_store_a AND action = 'stores.insert'), 1);

  -- The membership RPCs derive the caller from auth.uid(), so these two checks
  -- must run with the owner's claims set.
  PERFORM ksm_test.act_as(v_owner);
  PERFORM ksm_test.assert_raises('T01.8 an unknown user cannot be invited',
    format('select public.add_store_member(%L::uuid, %L::uuid, %L)',
           v_store_a, '99999999-9999-4999-8999-999999999999', 'cashier'),
    '23503');
  PERFORM ksm_test.assert_raises('T01.9 a second owner is refused',
    format('select public.add_store_member(%L::uuid, %L::uuid, %L)', v_store_a, v_manager, 'owner'),
    '42501');
  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.assert_raises('T01.10 an anonymous caller cannot create a store',
    'select public.create_store(p_name => ''Anonymous Store'')', '42501');
END $$;

-- ============================================================================
-- T02 - store settings, catalogue and stock integrity guards
-- ============================================================================
DO $$
DECLARE
  v_owner   uuid := ksm_test.ctx_get('owner')::uuid;
  v_manager uuid := ksm_test.ctx_get('manager')::uuid;
  v_store_a uuid := ksm_test.ctx_get('store_a')::uuid;
  v_store_b uuid := ksm_test.ctx_get('store_b')::uuid;
  v_cat_a   uuid;
  v_cat_b   uuid;
  v_atta    uuid;
  v_milk    uuid;
  v_b_product uuid;
  v_settings jsonb;
BEGIN
  PERFORM ksm_test.act_as(v_owner);
  v_settings := public.update_store_settings(
    p_store_id => v_store_a, p_invoice_prefix => 'INV', p_enable_gst => true,
    p_default_tax_rate => 5.00, p_low_stock_default_threshold => 10,
    p_cashier_can_record_payments => true);
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_text('T02.1 owner saved store settings',
    v_settings->>'invoice_prefix', 'INV');
  PERFORM ksm_test.assert_true('T02.2 cashier payment recording was enabled',
    (v_settings->>'cashier_can_record_payments')::boolean);

  PERFORM ksm_test.act_as(v_manager);
  PERFORM ksm_test.assert_raises('T02.3 a manager cannot change store settings',
    format('select public.update_store_settings(%L::uuid, p_enable_gst => false)', v_store_a),
    '42501');
  PERFORM ksm_test.act_as_service();

  -- Catalogue. Manager is the operational role for this.
  PERFORM ksm_test.act_as(v_manager);
  INSERT INTO public.categories (store_id, name, description)
  VALUES (v_store_a, 'Staples', 'Atta, rice, dal and sugar')
  RETURNING id INTO v_cat_a;
  INSERT INTO public.categories (store_id, name) VALUES (v_store_a, 'Dairy')
  RETURNING id INTO v_cat_b;

  INSERT INTO public.products
    (store_id, category_id, name, sku, barcode, cost_price, selling_price,
     stock_quantity, unit, low_stock_threshold)
  VALUES (v_store_a, v_cat_a, 'Aashirvaad Atta 5kg', 'ATT-5KG', '8901234500011',
          90.00, 245.00, 12, 'bag', 4)
  RETURNING id INTO v_atta;

  INSERT INTO public.products
    (store_id, category_id, name, selling_price, stock_quantity, unit)
  VALUES (v_store_a, v_cat_b, 'Amul Taaza Milk 1L', 66.00, 30, 'liter')
  RETURNING id INTO v_milk;

  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.ctx_set('cat_staples', v_cat_a::text);
  PERFORM ksm_test.ctx_set('product_atta', v_atta::text);
  PERFORM ksm_test.ctx_set('product_milk', v_milk::text);

  PERFORM ksm_test.assert_num('T02.4 opening stock was written as a stock movement',
    (SELECT quantity FROM public.stock_movements
      WHERE product_id = v_atta AND reference_type = 'opening_stock'), 12);
  PERFORM ksm_test.assert_num('T02.5 opening movement balances 0 + 12 = 12',
    (SELECT new_quantity FROM public.stock_movements
      WHERE product_id = v_atta AND reference_type = 'opening_stock'), 12);
  PERFORM ksm_test.assert_num('T02.6 product stock reflects the opening quantity',
    (SELECT stock_quantity FROM public.products WHERE id = v_atta), 12);
  PERFORM ksm_test.assert_num('T02.7 audit_row_change logged the product insert',
    (SELECT count(*) FROM public.audit_logs
      WHERE entity_id = v_atta AND action = 'products.insert'), 1);

  -- Store-scoped uniqueness.
  PERFORM ksm_test.assert_raises('T02.8 SKU must be unique inside a store',
    format('insert into public.products (store_id, name, sku, selling_price) '
           || 'values (%L::uuid, ''Duplicate SKU'', ''ATT-5KG'', 10)', v_store_a),
    '23505');
  PERFORM ksm_test.assert_raises('T02.9 barcode must be unique inside a store',
    format('insert into public.products (store_id, name, barcode, selling_price) '
           || 'values (%L::uuid, ''Duplicate Barcode'', ''8901234500011'', 10)', v_store_a),
    '23505');
END $$;

-- ---------------------------------------------------------------------------
-- T02b - the tenant boundary and the "stock only moves through an operation"
--        rule
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_owner     uuid := ksm_test.ctx_get('owner')::uuid;
  v_manager   uuid := ksm_test.ctx_get('manager')::uuid;
  v_cashier   uuid := ksm_test.ctx_get('cashier')::uuid;
  v_store_a   uuid := ksm_test.ctx_get('store_a')::uuid;
  v_store_b   uuid := ksm_test.ctx_get('store_b')::uuid;
  v_cat_a     uuid := ksm_test.ctx_get('cat_staples')::uuid;
  v_atta      uuid := ksm_test.ctx_get('product_atta')::uuid;
  v_b_product uuid;
  v_new_product uuid;
  v_archived  jsonb;
BEGIN
  -- A second product in store B lets every cross-store check below be concrete.
  PERFORM ksm_test.act_as(v_owner);
  INSERT INTO public.products (store_id, name, selling_price, stock_quantity)
  VALUES (v_store_b, 'Store B Rice 1kg', 50.00, 40)
  RETURNING id INTO v_b_product;
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.ctx_set('product_b', v_b_product::text);

  -- Composite foreign keys make a cross-store reference structurally invalid.
  PERFORM ksm_test.assert_raises('T02.10 a product cannot use another store category',
    format('insert into public.products (store_id, category_id, name, selling_price) '
           || 'values (%L::uuid, %L::uuid, ''Cross-store product'', 10)',
           v_store_b, v_cat_a),
    '23503');
  PERFORM ksm_test.assert_raises('T02.11 a sale line cannot reference another store product',
    format('insert into public.sale_items (store_id, sale_id, product_id, product_name, '
           || 'quantity, unit_price, total_price) values (%L::uuid, gen_random_uuid(), '
           || '%L::uuid, ''x'', 1, 1, 1)', v_store_a, v_b_product),
    '23503');

  -- Stock is a derived value: it may only move through a documented operation.
  PERFORM ksm_test.act_as(v_manager);
  PERFORM ksm_test.assert_raises('T02.12 direct stock_quantity edits are refused',
    format('update public.products set stock_quantity = 999 where id = %L::uuid', v_atta),
    '55000');
  PERFORM ksm_test.act_as_service();

  -- RLS refuses the insert itself: a cashier has no INSERT policy on products.
  PERFORM ksm_test.act_as(v_cashier);
  PERFORM ksm_test.assert_raises('T02.13 a cashier cannot create a product',
    format('insert into public.products (store_id, name, selling_price) '
           || 'values (%L::uuid, ''Cashier product'', 10)', v_store_a),
    '42501');
  PERFORM ksm_test.act_as_service();

  -- A manager, by contrast, owns the catalogue.
  PERFORM ksm_test.act_as(v_manager);
  INSERT INTO public.products (store_id, name, selling_price, stock_quantity)
  VALUES (v_store_a, 'Manager created product', 10.00, 5)
  RETURNING id INTO v_new_product;
  v_archived := public.archive_product(v_store_a, v_new_product);
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_num('T02.14 a manager can create a product',
    (SELECT count(*) FROM public.products
      WHERE store_id = v_store_a AND name = 'Manager created product'), 1);
  PERFORM ksm_test.assert_true('T02.15 archiving is a soft delete, not a row removal',
    v_archived IS NOT NULL
    AND (v_archived->>'is_active')::boolean IS FALSE
    AND (v_archived->>'deleted_at') IS NOT NULL);
  PERFORM ksm_test.assert_num('T02.16 the archived product row still exists for history',
    (SELECT count(*) FROM public.products WHERE id = v_new_product), 1);
  PERFORM ksm_test.assert_num('T02.17 the audit trail records the archive',
    (SELECT count(*) FROM public.audit_logs
      WHERE entity_id = v_new_product AND action = 'products.update'), 1);

  PERFORM ksm_test.act_as(v_manager);
  PERFORM ksm_test.assert_raises('T02.18 an already archived product cannot be re-archived',
    format('select public.archive_product(%L::uuid, %L::uuid)', v_store_a, v_new_product),
    '22023');
  PERFORM ksm_test.act_as_service();
END $$;

-- ============================================================================
-- T03 - invoice numbering (PREFIX-YYYY-NNNNNN, per store, per type, per year)
-- ============================================================================
DO $$
DECLARE
  v_store_a uuid := ksm_test.ctx_get('store_a')::uuid;
  v_store_b uuid := ksm_test.ctx_get('store_b')::uuid;
  v_year    text := to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYYY');
  v_number  text;
  v_again   text;
BEGIN
  -- Counters are per store, per document type, per calendar year. The upsert in
  -- private.next_document_number takes a row lock, so two concurrent checkouts
  -- serialise on that row and can never receive the same number.
  v_number := private.next_document_number(v_store_a, 'sale');
  v_again  := private.next_document_number(v_store_a, 'sale');

  PERFORM ksm_test.assert_true('T03.1 sale invoices use PREFIX-YYYY-NNNNNN',
    v_number ~ ('^INV-' || v_year || '-[0-9]{6}$'), 'got ' || v_number);
  PERFORM ksm_test.assert_num('T03.2 the counter increments by exactly one',
    right(v_again, 6)::bigint - right(v_number, 6)::bigint, 1);
  PERFORM ksm_test.assert_true('T03.3 the year comes from the store timezone',
    v_number LIKE 'INV-' || v_year || '-%', 'got ' || v_number);
  PERFORM ksm_test.assert_text('T03.4 numbering is independent per store',
    private.next_document_number(v_store_b, 'sale'), 'INV-' || v_year || '-000001');
  PERFORM ksm_test.assert_text('T03.5 numbering is independent per document type',
    private.next_document_number(v_store_b, 'purchase'), 'INV-' || v_year || '-000001');
  PERFORM ksm_test.assert_num('T03.6 the counter row records the highest number issued',
    (SELECT last_value FROM public.invoice_counters
      WHERE store_id = v_store_a AND doc_type = 'sale' AND year = v_year::integer),
    right(v_again, 6)::bigint);
END $$;

-- ============================================================================
-- T04 - purchasing: stock in, weighted-average cost, idempotency
-- ============================================================================
DO $$
DECLARE
  v_manager  uuid := ksm_test.ctx_get('manager')::uuid;
  v_cashier  uuid := ksm_test.ctx_get('cashier')::uuid;
  v_store_a  uuid := ksm_test.ctx_get('store_a')::uuid;
  v_atta     uuid := ksm_test.ctx_get('product_atta')::uuid;
  v_supplier uuid;
  v_request  uuid := gen_random_uuid();
  v_first    jsonb;
  v_retry    jsonb;
BEGIN
  PERFORM ksm_test.act_as(v_manager);
  INSERT INTO public.suppliers (store_id, name, phone, gst_number)
  VALUES (v_store_a, 'Sharma Wholesale Traders', '9812345678', '27ABCDE1234F1Z5')
  RETURNING id INTO v_supplier;

  -- 12 bags on hand cost 90 each; 10 more arrive at 100 each. Stock must become
  -- 22 and cost_price the weighted average of the two lots.
  v_first := public.create_purchase(
    p_store_id       => v_store_a,
    p_supplier_id    => v_supplier,
    p_items          => jsonb_build_array(jsonb_build_object(
                          'product_id', v_atta, 'quantity', 10, 'unit_cost', 100)),
    p_invoice_number => 'SUP-1001',
    p_payment_status => 'paid',
    p_request_id     => v_request);

  -- The same request id must return the first result and create nothing new:
  -- this is what makes a double-tapped "Record purchase" safe.
  v_retry := public.create_purchase(
    p_store_id       => v_store_a,
    p_supplier_id    => v_supplier,
    p_items          => jsonb_build_array(jsonb_build_object(
                          'product_id', v_atta, 'quantity', 10, 'unit_cost', 100)),
    p_invoice_number => 'SUP-1001',
    p_payment_status => 'paid',
    p_request_id     => v_request);

  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.ctx_set('supplier', v_supplier::text);

  PERFORM ksm_test.assert_text('T04.1 the purchase keeps the supplier invoice number',
    v_first->>'invoice_number', 'SUP-1001');
  PERFORM ksm_test.assert_num('T04.2 purchase subtotal is computed server-side',
    (v_first->>'subtotal')::numeric, 1000.00);
  PERFORM ksm_test.assert_num('T04.3 a purchase increases stock',
    (SELECT stock_quantity FROM public.products WHERE id = v_atta), 22);
  PERFORM ksm_test.assert_num('T04.4 exactly one purchase movement is written',
    (SELECT count(*) FROM public.stock_movements
      WHERE product_id = v_atta AND movement_type = 'purchase'), 1);
  PERFORM ksm_test.assert_num('T04.5 the movement balances 12 + 10 = 22',
    (SELECT new_quantity FROM public.stock_movements
      WHERE product_id = v_atta AND movement_type = 'purchase'), 22);
  PERFORM ksm_test.assert_num('T04.6 cost_price became the weighted average',
    (SELECT cost_price FROM public.products WHERE id = v_atta), 94.55);
  PERFORM ksm_test.assert_num('T04.7 purchase_items total = quantity x unit_cost',
    (SELECT total_cost FROM public.purchase_items WHERE product_id = v_atta), 1000.00);
  PERFORM ksm_test.assert_text('T04.8 a repeated request returns the original purchase',
    v_retry->>'purchase_id', v_first->>'purchase_id');
  PERFORM ksm_test.assert_num('T04.9 a repeated request created no second purchase',
    (SELECT count(*) FROM public.purchases WHERE store_id = v_store_a), 1);
  PERFORM ksm_test.assert_num('T04.10 the audit trail records the purchase',
    (SELECT count(*) FROM public.audit_logs
      WHERE store_id = v_store_a AND action = 'purchase.created'), 1);

  -- The RPC failures below must be raised while acting as a member, otherwise
  -- they would fail earlier on "authentication required" and prove nothing.
  PERFORM ksm_test.act_as(v_manager);
  PERFORM ksm_test.assert_raises('T04.11 a duplicate supplier invoice is refused',
    format('select public.create_purchase(p_store_id => %L::uuid, p_supplier_id => %L::uuid, '
           || 'p_items => jsonb_build_array(jsonb_build_object(''product_id'', %L::uuid, '
           || '''quantity'', 1, ''unit_cost'', 10)), p_invoice_number => ''SUP-1001'')',
           v_store_a, v_supplier, v_atta),
    '23505');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_raises('T04.12 a purchase header cannot carry forged totals',
    format('insert into public.purchases (store_id, invoice_number, subtotal, total_amount) '
           || 'values (%L::uuid, ''FORGED-1'', 100, 500)', v_store_a),
    '23514');
  PERFORM ksm_test.act_as(v_cashier);
  PERFORM ksm_test.assert_raises('T04.13 a cashier cannot create a purchase',
    format('select public.create_purchase(p_store_id => %L::uuid, p_items => '
           || 'jsonb_build_array(jsonb_build_object(''product_id'', %L::uuid, '
           || '''quantity'', 1, ''unit_cost'', 10)))', v_store_a, v_atta),
    '42501');
  PERFORM ksm_test.act_as_service();
END $$;

-- ============================================================================
-- T05 - a cash sale at the till
-- ============================================================================
DO $$
DECLARE
  v_cashier uuid := ksm_test.ctx_get('cashier')::uuid;
  v_store_a uuid := ksm_test.ctx_get('store_a')::uuid;
  v_atta    uuid := ksm_test.ctx_get('product_atta')::uuid;
  v_milk    uuid := ksm_test.ctx_get('product_milk')::uuid;
  v_request uuid := gen_random_uuid();
  v_sale    jsonb;
  v_retry   jsonb;
  v_year    text := to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYYY');
BEGIN
  PERFORM ksm_test.act_as(v_cashier);
  v_sale := public.create_sale(
    p_store_id        => v_store_a,
    p_items           => jsonb_build_array(
                           jsonb_build_object('product_id', v_atta, 'quantity', 2),
                           jsonb_build_object('product_id', v_milk, 'quantity', 3)),
    p_payment_method  => 'cash',
    p_discount_amount => 8,
    p_request_id      => v_request);

  -- Same request id: must return the first bill and create nothing new, which
  -- is what makes a double-tapped "Generate bill" safe.
  v_retry := public.create_sale(
    p_store_id        => v_store_a,
    p_items           => jsonb_build_array(
                           jsonb_build_object('product_id', v_atta, 'quantity', 2),
                           jsonb_build_object('product_id', v_milk, 'quantity', 3)),
    p_payment_method  => 'cash',
    p_discount_amount => 8,
    p_request_id      => v_request);

  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.ctx_set('sale_cash', (v_sale->>'sale_id'));


  PERFORM ksm_test.assert_true('T05.1 the cashier received a numbered invoice',
    (v_sale->>'invoice_number') ~ ('^INV-' || v_year || '-[0-9]{6}$'),
    'got ' || (v_sale->>'invoice_number'));
  PERFORM ksm_test.assert_num('T05.2 subtotal is priced from the catalogue',
    (v_sale->>'subtotal')::numeric, 688.00);
  PERFORM ksm_test.assert_num('T05.3 total = subtotal - discount + tax',
    (v_sale->>'total_amount')::numeric, 680.00);
  PERFORM ksm_test.assert_text('T05.4 a fully settled bill is paid',
    v_sale->>'payment_status', 'paid');
  PERFORM ksm_test.assert_num('T05.5 the settled amount equals the total',
    (v_sale->>'amount_paid')::numeric, 680.00);
  PERFORM ksm_test.assert_num('T05.6 stock was deducted for the first line',
    (SELECT stock_quantity FROM public.products WHERE id = v_atta), 20);
  PERFORM ksm_test.assert_num('T05.7 stock was deducted for the second line',
    (SELECT stock_quantity FROM public.products WHERE id = v_milk), 27);
  PERFORM ksm_test.assert_num('T05.8 one negative sale movement per line',
    (SELECT count(*) FROM public.stock_movements
      WHERE movement_type = 'sale' AND quantity < 0
        AND reference_id = (v_sale->>'sale_id')::uuid), 2);
  PERFORM ksm_test.assert_num('T05.9 sale_items snapshot the product name',
    (SELECT count(*) FROM public.sale_items
      WHERE sale_id = (v_sale->>'sale_id')::uuid
        AND product_name = 'Aashirvaad Atta 5kg'), 1);
  PERFORM ksm_test.assert_num('T05.10 sale_items snapshot the unit price',
    (SELECT unit_price FROM public.sale_items
      WHERE sale_id = (v_sale->>'sale_id')::uuid AND product_id = v_atta), 245.00);
  PERFORM ksm_test.assert_num('T05.11 one payment row was written',
    (SELECT count(*) FROM public.payments WHERE sale_id = (v_sale->>'sale_id')::uuid), 1);
  PERFORM ksm_test.assert_num('T05.12 the audit trail records the sale',
    (SELECT count(*) FROM public.audit_logs WHERE action = 'sale.created'
      AND entity_id = (v_sale->>'sale_id')::uuid), 1);
  PERFORM ksm_test.assert_text('T05.13 a repeated request returns the original sale',
    v_retry->>'sale_id', v_sale->>'sale_id');
  PERFORM ksm_test.assert_num('T05.14 a repeated request created no second sale',
    (SELECT count(*) FROM public.sales WHERE store_id = v_store_a), 1);
END $$;

-- ---------------------------------------------------------------------------
-- T05b - what the till must refuse
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_cashier uuid := ksm_test.ctx_get('cashier')::uuid;
  v_store_a uuid := ksm_test.ctx_get('store_a')::uuid;
  v_store_b uuid := ksm_test.ctx_get('store_b')::uuid;
  v_atta    uuid := ksm_test.ctx_get('product_atta')::uuid;
  v_milk    uuid := ksm_test.ctx_get('product_milk')::uuid;
  v_b_prod  uuid := ksm_test.ctx_get('product_b')::uuid;
BEGIN
  PERFORM ksm_test.act_as(v_cashier);

  PERFORM ksm_test.assert_raises('T05.15 insufficient stock is refused',
    format('select public.create_sale(p_store_id => %L::uuid, p_items => '
           || 'jsonb_build_array(jsonb_build_object(''product_id'', %L::uuid, '
           || '''quantity'', 1000)), p_payment_method => ''cash'')', v_store_a, v_atta),
    'P0001');
  PERFORM ksm_test.assert_raises('T05.16 another store product cannot be billed',
    format('select public.create_sale(p_store_id => %L::uuid, p_items => '
           || 'jsonb_build_array(jsonb_build_object(''product_id'', %L::uuid, '
           || '''quantity'', 1)), p_payment_method => ''cash'')', v_store_a, v_b_prod),
    '23503');
  PERFORM ksm_test.assert_raises('T05.17 a bill needs at least one line',
    format('select public.create_sale(p_store_id => %L::uuid, p_items => ''[]''::jsonb, '
           || 'p_payment_method => ''cash'')', v_store_a),
    '22023');
  PERFORM ksm_test.assert_raises('T05.18 a credit sale requires a customer',
    format('select public.create_sale(p_store_id => %L::uuid, p_items => '
           || 'jsonb_build_array(jsonb_build_object(''product_id'', %L::uuid, '
           || '''quantity'', 1)), p_payment_method => ''credit'')', v_store_a, v_milk),
    '22023');
  PERFORM ksm_test.assert_raises('T05.19 an unpaid remainder requires a customer',
    format('select public.create_sale(p_store_id => %L::uuid, p_items => '
           || 'jsonb_build_array(jsonb_build_object(''product_id'', %L::uuid, '
           || '''quantity'', 1)), p_payment_method => ''mixed'', p_payments => '
           || 'jsonb_build_array(jsonb_build_object(''method'', ''cash'', ''amount'', 10)))',
           v_store_a, v_milk),
    '22023');
  PERFORM ksm_test.assert_raises('T05.20 billing into another store is refused',
    format('select public.create_sale(p_store_id => %L::uuid, p_items => '
           || 'jsonb_build_array(jsonb_build_object(''product_id'', %L::uuid, '
           || '''quantity'', 1)), p_payment_method => ''cash'')', v_store_b, v_milk),
    '42501');
  PERFORM ksm_test.assert_raises('T05.21 split payments may not exceed the total',
    format('select public.create_sale(p_store_id => %L::uuid, p_items => '
           || 'jsonb_build_array(jsonb_build_object(''product_id'', %L::uuid, '
           || '''quantity'', 1)), p_payment_method => ''mixed'', p_payments => '
           || 'jsonb_build_array(jsonb_build_object(''method'', ''cash'', ''amount'', 9999), '
           || 'jsonb_build_object(''method'', ''upi'', ''amount'', 9999)))', v_store_a, v_milk),
    '22023');
  PERFORM ksm_test.assert_raises('T05.22 a credit method cannot appear in split payments',
    format('select public.create_sale(p_store_id => %L::uuid, p_items => '
           || 'jsonb_build_array(jsonb_build_object(''product_id'', %L::uuid, '
           || '''quantity'', 1)), p_payment_method => ''mixed'', p_payments => '
           || 'jsonb_build_array(jsonb_build_object(''method'', ''credit'', ''amount'', 10)))',
           v_store_a, v_milk),
    '22023');
  PERFORM ksm_test.act_as_service();

  -- A bill is never deleted or rewritten: correcting it means cancelling it.
  PERFORM ksm_test.assert_raises('T05.23 a sale cannot be deleted',
    format('delete from public.sales where id = %L::uuid',
           ksm_test.ctx_get('sale_cash')),
    '55000');
  PERFORM ksm_test.assert_raises('T05.24 a sale total cannot be rewritten',
    format('update public.sales set total_amount = 1 where id = %L::uuid',
           ksm_test.ctx_get('sale_cash')),
    '55000');
  PERFORM ksm_test.assert_raises('T05.25 sale line items cannot be edited',
    format('update public.sale_items set quantity = 1, total_price = 245 '
           || 'where sale_id = %L::uuid', ksm_test.ctx_get('sale_cash')),
    '55000');
  PERFORM ksm_test.assert_raises('T05.26 a duplicate invoice number is impossible',
    format('insert into public.sales (store_id, invoice_number, subtotal, total_amount, '
           || 'payment_method) select store_id, invoice_number, 1, 1, ''cash'' '
           || 'from public.sales where id = %L::uuid',
           ksm_test.ctx_get('sale_cash')),
    '23505');
END $$;

-- ============================================================================
-- T06 - udhaar: credit sales, partial settlement and the customer ledger
-- ============================================================================
DO $$
DECLARE
  v_manager uuid := ksm_test.ctx_get('manager')::uuid;
  v_cashier uuid := ksm_test.ctx_get('cashier')::uuid;
  v_store_a uuid := ksm_test.ctx_get('store_a')::uuid;
  v_milk    uuid := ksm_test.ctx_get('product_milk')::uuid;
  v_rahul   uuid;
  v_priya   uuid;
  v_credit  jsonb;
  v_partial jsonb;
BEGIN
  PERFORM ksm_test.act_as(v_manager);
  INSERT INTO public.customers (store_id, name, phone, credit_limit)
  VALUES (v_store_a, 'Rahul Sharma', '9900112233', 1000)
  RETURNING id INTO v_rahul;
  INSERT INTO public.customers (store_id, name, phone, credit_limit)
  VALUES (v_store_a, 'Priya Deshmukh', '9900223344', 100)
  RETURNING id INTO v_priya;
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.ctx_set('customer_rahul', v_rahul::text);
  PERFORM ksm_test.ctx_set('customer_priya', v_priya::text);

  -- Fully unpaid sale: the whole total becomes udhaar.
  PERFORM ksm_test.act_as(v_cashier);
  v_credit := public.create_sale(
    p_store_id       => v_store_a,
    p_items          => jsonb_build_array(jsonb_build_object('product_id', v_milk, 'quantity', 5)),
    p_payment_method => 'credit',
    p_customer_id    => v_rahul);
  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.ctx_set('sale_credit', (v_credit->>'sale_id'));

  PERFORM ksm_test.assert_num('T06.1 a credit sale bills the full total',
    (v_credit->>'total_amount')::numeric, 330.00);
  PERFORM ksm_test.assert_text('T06.2 an unpaid bill is pending',
    v_credit->>'payment_status', 'pending');
  PERFORM ksm_test.assert_num('T06.3 nothing was paid on the credit bill',
    (v_credit->>'amount_paid')::numeric, 0.00);
  PERFORM ksm_test.assert_num('T06.4 a credit sale writes a positive ledger row',
    (SELECT amount FROM public.customer_transactions
      WHERE reference_id = (v_credit->>'sale_id')::uuid AND transaction_type = 'credit_sale'),
    330.00);
  PERFORM ksm_test.assert_num('T06.5 the customer balance equals the udhaar taken',
    (SELECT current_balance FROM public.customers WHERE id = v_rahul), 330.00);

  -- Partly paid sale: only the remainder becomes udhaar.
  PERFORM ksm_test.act_as(v_cashier);
  v_partial := public.create_sale(
    p_store_id       => v_store_a,
    p_items          => jsonb_build_array(jsonb_build_object('product_id', v_milk, 'quantity', 5)),
    p_payment_method => 'mixed',
    p_payments       => jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', 100)),
    p_customer_id    => v_rahul);
  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.ctx_set('sale_partial', (v_partial->>'sale_id'));

  PERFORM ksm_test.assert_text('T06.6 a partly paid bill is partial',
    v_partial->>'payment_status', 'partial');
  PERFORM ksm_test.assert_num('T06.7 partial settlement records the cash received',
    (v_partial->>'amount_paid')::numeric, 100.00);
  PERFORM ksm_test.assert_num('T06.8 only the remainder becomes udhaar',
    (SELECT amount FROM public.customer_transactions
      WHERE reference_id = (v_partial->>'sale_id')::uuid AND transaction_type = 'credit_sale'),
    230.00);
  PERFORM ksm_test.assert_num('T06.9 the balance accumulates the outstanding part',
    (SELECT current_balance FROM public.customers WHERE id = v_rahul), 560.00);
  PERFORM ksm_test.assert_num('T06.10 the balance equals the ledger sum',
    (SELECT COALESCE(sum(amount), 0) FROM public.customer_transactions
      WHERE customer_id = v_rahul),
    (SELECT current_balance FROM public.customers WHERE id = v_rahul));

  -- The RPC rule checks must run with a member's identity; the direct-table
  -- checks below them deliberately run as the migration runner so the
  -- constraint or trigger is what rejects them.
  PERFORM ksm_test.act_as(v_cashier);
  PERFORM ksm_test.assert_raises('T06.11 a credit sale beyond the limit is refused',
    format('select public.create_sale(p_store_id => %L::uuid, p_items => '
           || 'jsonb_build_array(jsonb_build_object(''product_id'', %L::uuid, '
           || '''quantity'', 10)), p_payment_method => ''credit'', p_customer_id => %L::uuid)',
           v_store_a, v_milk, v_priya),
    'P0001');
  PERFORM ksm_test.act_as_service();

  -- A direct ledger write still has to respect the sign convention, and the
  -- balance still cannot be typed in by hand once the RPC's transaction-scoped
  -- bypass flag has been cleared.
  PERFORM ksm_test.clear_flags();
  PERFORM ksm_test.assert_raises('T06.12 a ledger row cannot use the wrong sign',
    format('insert into public.customer_transactions '
           || '(store_id, customer_id, transaction_type, amount) '
           || 'values (%L::uuid, %L::uuid, ''payment'', 50)', v_store_a, v_rahul),
    '23514');
  PERFORM ksm_test.assert_raises('T06.13 the balance cannot be edited directly',
    format('update public.customers set current_balance = 0 where id = %L::uuid', v_rahul),
    '55000');
  PERFORM ksm_test.assert_raises('T06.14 a payment may not exceed its sale total',
    format('insert into public.payments (store_id, sale_id, amount, payment_method) '
           || 'values (%L::uuid, %L::uuid, 99999, ''cash'')',
           v_store_a, v_partial->>'sale_id'),
    'P0001');
END $$;

-- ============================================================================
-- T07 - collecting udhaar: record_customer_payment
-- ============================================================================
DO $$
DECLARE
  v_owner   uuid := ksm_test.ctx_get('owner')::uuid;
  v_manager uuid := ksm_test.ctx_get('manager')::uuid;
  v_cashier uuid := ksm_test.ctx_get('cashier')::uuid;
  v_store_a uuid := ksm_test.ctx_get('store_a')::uuid;
  v_rahul   uuid := ksm_test.ctx_get('customer_rahul')::uuid;
  v_request uuid := gen_random_uuid();
  v_pay     jsonb;
  v_retry   jsonb;
  v_rows    bigint;
BEGIN
  PERFORM ksm_test.act_as(v_manager);
  v_pay := public.record_customer_payment(
    p_store_id       => v_store_a,
    p_customer_id    => v_rahul,
    p_amount         => 200,
    p_payment_method => 'upi',
    p_notes          => 'Paid by UPI',
    p_request_id     => v_request);

  v_retry := public.record_customer_payment(
    p_store_id       => v_store_a,
    p_customer_id    => v_rahul,
    p_amount         => 200,
    p_payment_method => 'upi',
    p_request_id     => v_request);

  -- A cashier may only do this when the store allows it.
  SELECT count(*) INTO v_rows FROM public.credit_payments WHERE customer_id = v_rahul;
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_num('T07.1 the payment reports the previous balance',
    (v_pay->>'previous_balance')::numeric, 560.00);
  PERFORM ksm_test.assert_num('T07.2 the payment reports the new balance',
    (v_pay->>'current_balance')::numeric, 360.00);
  PERFORM ksm_test.assert_num('T07.3 the ledger records a negative payment row',
    (SELECT amount FROM public.customer_transactions
      WHERE id = (v_pay->>'customer_transaction_id')::uuid), -200.00);
  PERFORM ksm_test.assert_num('T07.4 a credit_payments row records the method',
    (SELECT count(*) FROM public.credit_payments
      WHERE customer_id = v_rahul AND payment_method = 'upi' AND amount = 200), 1);
  PERFORM ksm_test.assert_num('T07.5 the balance follows the ledger after payment',
    (SELECT current_balance FROM public.customers WHERE id = v_rahul), 360.00);
  PERFORM ksm_test.assert_text('T07.6 a repeated payment request changes nothing',
    v_retry->>'customer_transaction_id', v_pay->>'customer_transaction_id');
  PERFORM ksm_test.assert_num('T07.7 a repeated payment request wrote one row',
    v_rows, 1);
  PERFORM ksm_test.assert_num('T07.8 the payment is in the audit trail',
    (SELECT count(*) FROM public.audit_logs
      WHERE action = 'customer_payment.recorded' AND entity_id = v_rahul), 1);

  -- Every one of these calls must carry a member identity so the rule under
  -- test is what refuses them, not the missing session.
  PERFORM ksm_test.act_as(v_manager);
  PERFORM ksm_test.assert_raises('T07.9 paying more than the balance is refused',
    format('select public.record_customer_payment(%L::uuid, %L::uuid, 9999)',
           v_store_a, v_rahul),
    'P0001');
  PERFORM ksm_test.assert_raises('T07.10 a zero payment is refused',
    format('select public.record_customer_payment(%L::uuid, %L::uuid, 0)',
           v_store_a, v_rahul),
    '22023');
  PERFORM ksm_test.assert_raises('T07.11 a negative payment is refused',
    format('select public.record_customer_payment(%L::uuid, %L::uuid, -50)',
           v_store_a, v_rahul),
    '22023');
  PERFORM ksm_test.assert_raises('T07.12 credit is not a valid payment method',
    format('select public.record_customer_payment(%L::uuid, %L::uuid, 10, ''credit'')',
           v_store_a, v_rahul),
    '22023');
  PERFORM ksm_test.assert_raises('T07.13 another store customer is refused',
    format('select public.record_customer_payment(%L::uuid, %L::uuid, 10)',
           v_store_a, '99999999-9999-4999-8999-999999999999'),
    '23503');
  PERFORM ksm_test.act_as_service();

  -- The cashier is permitted while cashier_can_record_payments is on ...
  PERFORM ksm_test.act_as(v_cashier);
  v_pay := public.record_customer_payment(v_store_a, v_rahul, 60, 'cash');
  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.assert_num('T07.14 a permitted cashier can record a payment',
    (v_pay->>'current_balance')::numeric, 300.00);

  -- ... and blocked the moment the owner turns it off.
  PERFORM ksm_test.act_as(v_owner);
  PERFORM public.update_store_settings(v_store_a, p_cashier_can_record_payments => false);
  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.act_as(v_cashier);
  PERFORM ksm_test.assert_raises('T07.15 a cashier is refused when the store disallows it',
    format('select public.record_customer_payment(%L::uuid, %L::uuid, 10)',
           v_store_a, v_rahul),
    '42501');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.act_as(v_owner);
  PERFORM public.update_store_settings(v_store_a, p_cashier_can_record_payments => true);
  PERFORM ksm_test.act_as_service();
END $$;

-- ============================================================================
-- T08 - cancelling a bill without destroying history
-- ============================================================================
DO $$
DECLARE
  v_manager uuid := ksm_test.ctx_get('manager')::uuid;
  v_cashier uuid := ksm_test.ctx_get('cashier')::uuid;
  v_store_a uuid := ksm_test.ctx_get('store_a')::uuid;
  v_atta    uuid := ksm_test.ctx_get('product_atta')::uuid;
  v_milk    uuid := ksm_test.ctx_get('product_milk')::uuid;
  v_rahul   uuid := ksm_test.ctx_get('customer_rahul')::uuid;
  v_cash    uuid := ksm_test.ctx_get('sale_cash')::uuid;
  v_credit  uuid := ksm_test.ctx_get('sale_credit')::uuid;
  v_partial uuid := ksm_test.ctx_get('sale_partial')::uuid;
  v_result  jsonb;
BEGIN
  PERFORM ksm_test.act_as(v_cashier);
  PERFORM ksm_test.assert_raises('T08.1 a cashier cannot cancel a bill',
    format('select public.cancel_sale(%L::uuid, %L::uuid, ''wrong item'')', v_store_a, v_cash),
    '42501');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.act_as(v_manager);
  PERFORM ksm_test.assert_raises('T08.2 cancellation needs a reason',
    format('select public.cancel_sale(%L::uuid, %L::uuid, ''ab'')', v_store_a, v_cash),
    '22023');

  -- The cash bill: stock comes back, the money stays on record.
  v_result := public.cancel_sale(v_store_a, v_cash, 'Customer returned the goods');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_true('T08.3 the cancellation is reported',
    (v_result->>'cancelled')::boolean);
  PERFORM ksm_test.assert_num('T08.4 cancelled stock returns to the shelf',
    (SELECT stock_quantity FROM public.products WHERE id = v_atta), 22);
  PERFORM ksm_test.assert_num('T08.5 the second line returns too',
    (SELECT stock_quantity FROM public.products WHERE id = v_milk), 20);
  PERFORM ksm_test.assert_num('T08.6 a sale_return movement is written per line',
    (SELECT count(*) FROM public.stock_movements
      WHERE movement_type = 'sale_return' AND reference_id = v_cash), 2);
  PERFORM ksm_test.assert_num('T08.7 the invoice is still on record',
    (SELECT count(*) FROM public.sales WHERE id = v_cash), 1);
  PERFORM ksm_test.assert_true('T08.8 the bill carries a cancellation stamp',
    (SELECT cancelled_at IS NOT NULL AND cancel_reason = 'Customer returned the goods'
       FROM public.sales WHERE id = v_cash));
  PERFORM ksm_test.assert_num('T08.9 received payments are not deleted',
    (SELECT count(*) FROM public.payments WHERE sale_id = v_cash), 1);
  PERFORM ksm_test.assert_num('T08.10 the line items are preserved for audit',
    (SELECT count(*) FROM public.sale_items WHERE sale_id = v_cash), 2);
  PERFORM ksm_test.assert_num('T08.11 the cancellation is in the audit trail',
    (SELECT count(*) FROM public.audit_logs WHERE action = 'sale.cancelled' AND entity_id = v_cash), 1);

  PERFORM ksm_test.act_as(v_manager);
  PERFORM ksm_test.assert_raises('T08.12 a bill cannot be cancelled twice',
    format('select public.cancel_sale(%L::uuid, %L::uuid, ''duplicate attempt'')', v_store_a, v_cash),
    '22023');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_raises('T08.13 a cancelled bill cannot take a payment',
    format('insert into public.payments (store_id, sale_id, amount, payment_method) '
           || 'values (%L::uuid, %L::uuid, 10, ''cash'')', v_store_a, v_cash),
    '22023');

  -- Cancelling a credit bill reverses the udhaar it created. This one cannot be
  -- reversed any more: the customer already paid part of it, so the refund would
  -- push the ledger below zero and the whole cancellation is rolled back.
  PERFORM ksm_test.act_as(v_manager);
  PERFORM ksm_test.assert_raises('T08.14 a refund that would overdraw the ledger is refused',
    format('select public.cancel_sale(%L::uuid, %L::uuid, ''Attempted reversal'')',
           v_store_a, v_credit),
    'P0001');

  -- The part-paid bill can still be reversed: 300 outstanding, 230 to reverse.
  v_result := public.cancel_sale(v_store_a, v_partial, 'Wrong quantity billed');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_true('T08.15 a part-paid credit bill can be cancelled',
    (v_result->>'cancelled')::boolean);
  PERFORM ksm_test.assert_num('T08.16 cancelling reverses the udhaar it created',
    (SELECT amount FROM public.customer_transactions
      WHERE reference_id = v_partial AND transaction_type = 'refund'), -230.00);
  PERFORM ksm_test.assert_num('T08.17 the balance drops by the reversed amount',
    (SELECT current_balance FROM public.customers WHERE id = v_rahul), 70.00);
  PERFORM ksm_test.assert_num('T08.18 the balance still equals the ledger sum',
    (SELECT COALESCE(sum(amount), 0) FROM public.customer_transactions
      WHERE customer_id = v_rahul), 70.00);
  PERFORM ksm_test.assert_num('T08.19 the returned goods are back on the shelf',
    (SELECT stock_quantity FROM public.products WHERE id = v_milk), 25);
END $$;

-- ============================================================================
-- T09 - inventory adjustments (damage, expiry, manual correction)
-- ============================================================================
DO $$
DECLARE
  v_owner   uuid := ksm_test.ctx_get('owner')::uuid;
  v_manager uuid := ksm_test.ctx_get('manager')::uuid;
  v_cashier uuid := ksm_test.ctx_get('cashier')::uuid;
  v_store_a uuid := ksm_test.ctx_get('store_a')::uuid;
  v_milk    uuid := ksm_test.ctx_get('product_milk')::uuid;
  v_result  jsonb;
BEGIN
  PERFORM ksm_test.act_as(v_manager);
  v_result := public.adjust_inventory(v_store_a, v_milk, 'damage', -2, 'Two pouches leaked');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_num('T09.1 damage reduces stock',
    (SELECT stock_quantity FROM public.products WHERE id = v_milk), 23);
  PERFORM ksm_test.assert_num('T09.2 the adjustment is explainable',
    (SELECT new_quantity FROM public.stock_movements
      WHERE id = (v_result->>'stock_movement_id')::uuid), 23);
  PERFORM ksm_test.assert_num('T09.3 the movement balances 25 - 2 = 23',
    (SELECT previous_quantity FROM public.stock_movements
      WHERE id = (v_result->>'stock_movement_id')::uuid), 25);
  PERFORM ksm_test.assert_num('T09.4 the reason is stored with the adjustment',
    (SELECT count(*) FROM public.inventory_adjustments
      WHERE id = (v_result->>'adjustment_id')::uuid
        AND movement_type = 'damage' AND reason = 'Two pouches leaked'), 1);
  PERFORM ksm_test.assert_num('T09.5 the adjustment is in the audit trail',
    (SELECT count(*) FROM public.audit_logs
      WHERE action = 'inventory.adjusted' AND entity_id = v_milk), 1);

  PERFORM ksm_test.act_as(v_manager);
  PERFORM ksm_test.assert_raises('T09.6 an adjustment cannot make stock negative',
    format('select public.adjust_inventory(%L::uuid, %L::uuid, ''manual_adjustment'', -1000, '
           || '''Stock count correction'')', v_store_a, v_milk),
    'P0001');
  PERFORM ksm_test.assert_raises('T09.7 a sale is not a valid adjustment type',
    format('select public.adjust_inventory(%L::uuid, %L::uuid, ''sale'', -1, ''Wrong type'')',
           v_store_a, v_milk),
    '22023');
  PERFORM ksm_test.assert_raises('T09.8 an adjustment requires a reason',
    format('select public.adjust_inventory(%L::uuid, %L::uuid, ''damage'', -1, ''  '')',
           v_store_a, v_milk),
    '22023');
  PERFORM ksm_test.assert_raises('T09.9 a zero quantity is not an adjustment',
    format('select public.adjust_inventory(%L::uuid, %L::uuid, ''damage'', 0, ''Nothing'')',
           v_store_a, v_milk),
    '22023');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.act_as(v_cashier);
  PERFORM ksm_test.assert_raises('T09.10 a cashier cannot adjust stock',
    format('select public.adjust_inventory(%L::uuid, %L::uuid, ''damage'', -1, ''No rights'')',
           v_store_a, v_milk),
    '42501');
  PERFORM ksm_test.act_as_service();

  -- Ledgers are append-only: a mistake is corrected by a new entry, never by
  -- rewriting history.
  PERFORM ksm_test.assert_raises('T09.11 stock movements cannot be edited',
    format('update public.stock_movements set quantity = 1 where product_id = %L::uuid', v_milk),
    '55000');
  PERFORM ksm_test.assert_raises('T09.12 stock movements cannot be deleted',
    format('delete from public.stock_movements where product_id = %L::uuid', v_milk),
    '55000');
  PERFORM ksm_test.assert_raises('T09.13 adjustments cannot be edited',
    'update public.inventory_adjustments set reason = ''changed''', '55000');
  PERFORM ksm_test.assert_raises('T09.14 audit records cannot be deleted',
    'delete from public.audit_logs', '55000');
  PERFORM ksm_test.assert_raises('T09.15 balances cannot be rewritten through the ledger',
    format('update public.customer_transactions set amount = 0 where customer_id = %L::uuid',
           ksm_test.ctx_get('customer_rahul')),
    '55000');

  -- With allow_negative_stock on, the same call is permitted, and the movement
  -- still balances, so the ledger explains the negative quantity.
  PERFORM ksm_test.act_as(v_owner);
  PERFORM public.update_store_settings(v_store_a, p_allow_negative_stock => true);
  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.act_as(v_manager);
  v_result := public.adjust_inventory(v_store_a, v_milk, 'manual_adjustment', -25,
                                     'Temporary oversell allowed for testing');
  PERFORM public.adjust_inventory(v_store_a, v_milk, 'manual_adjustment', 25,
                                  'Restoring stock after the negative-stock test');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_num('T09.16 allow_negative_stock permits a negative quantity',
    (SELECT new_quantity FROM public.stock_movements
      WHERE id = (v_result->>'stock_movement_id')::uuid), -2);
  PERFORM ksm_test.assert_num('T09.17 stock is restored afterwards',
    (SELECT stock_quantity FROM public.products WHERE id = v_milk), 23);

  PERFORM ksm_test.act_as(v_owner);
  PERFORM public.update_store_settings(v_store_a, p_allow_negative_stock => false);
  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.assert_true('T09.18 allow_negative_stock is switched back off',
    (SELECT NOT allow_negative_stock FROM public.store_settings WHERE store_id = v_store_a));
END $$;

-- ============================================================================
-- T10 - membership administration (024_rpc_store_members.sql)
-- ============================================================================
DO $$
DECLARE
  v_owner    uuid := ksm_test.ctx_get('owner')::uuid;
  v_manager  uuid := ksm_test.ctx_get('manager')::uuid;
  v_cashier  uuid := ksm_test.ctx_get('cashier')::uuid;
  v_outsider uuid := ksm_test.ctx_get('outsider')::uuid;
  v_store_a  uuid := ksm_test.ctx_get('store_a')::uuid;
  v_member   jsonb;
  v_mid      uuid;
  v_cashier_member uuid := ksm_test.ctx_get('member_cashier')::uuid;
BEGIN
  PERFORM ksm_test.act_as(v_manager);
  PERFORM ksm_test.assert_raises('T10.1 a manager cannot invite staff',
    format('select public.add_store_member(%L::uuid, %L::uuid, ''cashier'')',
           v_store_a, v_outsider),
    '42501');
  PERFORM ksm_test.assert_raises('T10.2 a manager cannot change a role',
    format('select public.set_store_member_role(%L::uuid, %L::uuid, ''manager'')',
           v_store_a, v_cashier_member),
    '42501');
  PERFORM ksm_test.assert_raises('T10.3 a manager cannot remove a member',
    format('select public.remove_store_member(%L::uuid, %L::uuid)', v_store_a, v_cashier_member),
    '42501');
  PERFORM ksm_test.act_as_service();

  -- Before being invited, the outsider sees nothing at all.
  PERFORM ksm_test.assert_num('T10.4 an outsider sees no sales before being invited',
    (ksm_test.probe(v_outsider,
      format('select count(*)::text from public.sales where store_id = %L::uuid', v_store_a)))::numeric, 0);

  PERFORM ksm_test.act_as(v_owner);
  v_member := public.add_store_member(v_store_a, v_outsider, 'cashier');
  PERFORM ksm_test.act_as_service();
  v_mid := (v_member->>'id')::uuid;

  PERFORM ksm_test.assert_true('T10.5 the invited user can now see store sales',
    (ksm_test.probe(v_outsider,
      format('select count(*)::text from public.sales where store_id = %L::uuid', v_store_a)))::numeric > 0);
  PERFORM ksm_test.assert_num('T10.6 the audit trail records the invitation',
    (SELECT count(*) FROM public.audit_logs
      WHERE action = 'store_member.added' AND entity_id = v_mid), 1);

  PERFORM ksm_test.act_as(v_owner);
  v_member := public.set_store_member_role(v_store_a, v_mid, 'manager');
  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.assert_text('T10.7 the role can be changed', v_member->>'role', 'manager');
  PERFORM ksm_test.assert_true('T10.8 a promoted manager can read customers',
    (ksm_test.probe(v_outsider,
      format('select count(*)::text from public.customers where store_id = %L::uuid', v_store_a)))::numeric > 0);

  -- Deactivating withdraws access immediately: every RLS helper filters on
  -- is_active, so the same query returns nothing.
  PERFORM ksm_test.act_as(v_owner);
  v_member := public.set_store_member_active(v_store_a, v_mid, false);
  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.assert_true('T10.9 the member is deactivated',
    NOT (v_member->>'is_active')::boolean);
  PERFORM ksm_test.assert_num('T10.10 a deactivated member sees nothing',
    (ksm_test.probe(v_outsider,
      format('select count(*)::text from public.sales where store_id = %L::uuid', v_store_a)))::numeric, 0);
  PERFORM ksm_test.assert_num('T10.11 a deactivated manager sees no customers either',
    (ksm_test.probe(v_outsider,
      format('select count(*)::text from public.customers where store_id = %L::uuid', v_store_a)))::numeric, 0);

  PERFORM ksm_test.act_as(v_owner);
  PERFORM public.set_store_member_active(v_store_a, v_mid, true);
  PERFORM ksm_test.assert_raises('T10.12 the owner membership cannot be removed',
    format('select public.remove_store_member(%L::uuid, '
           || '(select id from public.store_members where store_id = %L::uuid '
           || '  and user_id = %L::uuid))', v_store_a, v_store_a, v_owner),
    '42501');
  PERFORM ksm_test.assert_raises('T10.13 a role change for an unknown member is refused',
    format('select public.set_store_member_role(%L::uuid, %L::uuid, ''cashier'')',
           v_store_a, '99999999-9999-4999-8999-999999999999'),
    '23503');

  v_member := public.remove_store_member(v_store_a, v_mid);
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_true('T10.14 a membership can be removed',
    (v_member->>'removed')::boolean);
  PERFORM ksm_test.assert_num('T10.15 the membership row is gone',
    (SELECT count(*) FROM public.store_members WHERE id = v_mid), 0);
  PERFORM ksm_test.assert_num('T10.16 the removed user loses access',
    (ksm_test.probe(v_outsider,
      format('select count(*)::text from public.sales where store_id = %L::uuid', v_store_a)))::numeric, 0);
  PERFORM ksm_test.assert_num('T10.17 the audit trail records the removal',
    (SELECT count(*) FROM public.audit_logs
      WHERE action = 'store_member.removed' AND entity_id = v_mid), 1);
END $$;

-- ============================================================================
-- T11 - Row Level Security: who can see what
-- ============================================================================
DO $$
DECLARE
  v_owner    uuid := ksm_test.ctx_get('owner')::uuid;
  v_manager  uuid := ksm_test.ctx_get('manager')::uuid;
  v_cashier  uuid := ksm_test.ctx_get('cashier')::uuid;
  v_outsider uuid := ksm_test.ctx_get('outsider')::uuid;
  v_store_a  uuid := ksm_test.ctx_get('store_a')::uuid;
  v_store_b  uuid := ksm_test.ctx_get('store_b')::uuid;
BEGIN
  -- An outsider is a member of nothing: every tenant table is empty for them.
  PERFORM ksm_test.assert_num('T11.1 an outsider sees no stores',
    (ksm_test.probe(v_outsider, 'select count(*)::text from public.stores'))::numeric, 0);
  PERFORM ksm_test.assert_num('T11.2 an outsider sees no products',
    (ksm_test.probe(v_outsider, 'select count(*)::text from public.products'))::numeric, 0);
  PERFORM ksm_test.assert_num('T11.3 an outsider sees no sales',
    (ksm_test.probe(v_outsider, 'select count(*)::text from public.sales'))::numeric, 0);
  PERFORM ksm_test.assert_num('T11.4 an outsider sees no customers',
    (ksm_test.probe(v_outsider, 'select count(*)::text from public.customers'))::numeric, 0);
  PERFORM ksm_test.assert_num('T11.5 an outsider sees no audit log',
    (ksm_test.probe(v_outsider, 'select count(*)::text from public.audit_logs'))::numeric, 0);

  -- A cashier works inside one store and sees the till, not the books.
  PERFORM ksm_test.assert_true('T11.6 a cashier sees their own store sales',
    (ksm_test.probe(v_cashier,
      format('select count(*)::text from public.sales where store_id = %L::uuid', v_store_a)))::numeric > 0);
  PERFORM ksm_test.assert_num('T11.7 a cashier cannot see another store sales',
    (ksm_test.probe(v_cashier,
      format('select count(*)::text from public.sales where store_id = %L::uuid', v_store_b)))::numeric, 0);
  PERFORM ksm_test.assert_num('T11.8 a cashier cannot see another store products',
    (ksm_test.probe(v_cashier,
      format('select count(*)::text from public.products where store_id = %L::uuid', v_store_b)))::numeric, 0);
  PERFORM ksm_test.assert_true('T11.9 a cashier can look up active products to bill',
    (ksm_test.probe(v_cashier,
      format('select count(*)::text from public.products where store_id = %L::uuid '
             || 'and is_active and deleted_at is null', v_store_a)))::numeric > 0);
  PERFORM ksm_test.assert_num('T11.10 a cashier cannot read the customer list',
    (ksm_test.probe(v_cashier,
      format('select count(*)::text from public.customers where store_id = %L::uuid',
             v_store_a)))::numeric, 0);
  PERFORM ksm_test.assert_num('T11.11 a cashier cannot read purchases',
    (ksm_test.probe(v_cashier,
      format('select count(*)::text from public.purchases where store_id = %L::uuid',
             v_store_a)))::numeric, 0);
  PERFORM ksm_test.assert_num('T11.12 a cashier cannot read the stock ledger',
    (ksm_test.probe(v_cashier,
      format('select count(*)::text from public.stock_movements where store_id = %L::uuid',
             v_store_a)))::numeric, 0);
  PERFORM ksm_test.assert_num('T11.13 a cashier cannot read the audit log',
    (ksm_test.probe(v_cashier,
      format('select count(*)::text from public.audit_logs where store_id = %L::uuid',
             v_store_a)))::numeric, 0);

  -- A manager sees the operation but not the audit trail.
  PERFORM ksm_test.assert_true('T11.14 a manager reads customers',
    (ksm_test.probe(v_manager,
      format('select count(*)::text from public.customers where store_id = %L::uuid',
             v_store_a)))::numeric > 0);
  PERFORM ksm_test.assert_true('T11.15 a manager reads the stock ledger',
    (ksm_test.probe(v_manager,
      format('select count(*)::text from public.stock_movements where store_id = %L::uuid',
             v_store_a)))::numeric > 0);
  PERFORM ksm_test.assert_num('T11.16 a manager cannot read the audit log',
    (ksm_test.probe(v_manager,
      format('select count(*)::text from public.audit_logs where store_id = %L::uuid',
             v_store_a)))::numeric, 0);

  -- The owner is the only role that can read the audit trail.
  PERFORM ksm_test.assert_true('T11.17 an owner reads the audit log',
    (ksm_test.probe(v_owner,
      format('select count(*)::text from public.audit_logs where store_id = %L::uuid',
             v_store_a)))::numeric > 0);
END $$;

-- ---------------------------------------------------------------------------
-- T11b - a cashier cannot write around the till
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_cashier uuid := ksm_test.ctx_get('cashier')::uuid;
  v_store_a uuid := ksm_test.ctx_get('store_a')::uuid;
  v_rows    integer;
BEGIN
  -- RLS filters UPDATE as well as SELECT: the statement succeeds but touches no
  -- row, so a cashier cannot reprice anything.
  PERFORM ksm_test.act_as(v_cashier);
  UPDATE public.products SET selling_price = 1 WHERE store_id = v_store_a;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM ksm_test.assert_num('T11.18 a cashier cannot reprice products', v_rows, 0);

  UPDATE public.products SET cost_price = 0 WHERE store_id = v_store_a;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM ksm_test.assert_num('T11.19 a cashier cannot change cost prices', v_rows, 0);

  UPDATE public.customers SET credit_limit = 999999 WHERE store_id = v_store_a;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM ksm_test.assert_num('T11.20 a cashier cannot raise a credit limit', v_rows, 0);

  UPDATE public.store_settings SET invoice_prefix = 'HACK' WHERE store_id = v_store_a;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM ksm_test.assert_num('T11.21 a cashier cannot change store settings', v_rows, 0);
  PERFORM ksm_test.act_as_service();

  -- Privileges are revoked, so the write is refused before a policy is even
  -- consulted: financial data is reachable only through the RPCs.
  PERFORM ksm_test.act_as(v_cashier);
  PERFORM ksm_test.assert_raises('T11.22 nobody writes a sale through PostgREST',
    format('insert into public.sales (store_id, invoice_number, total_amount, payment_method) '
           || 'values (%L::uuid, ''FAKE-1'', 1, ''cash'')', v_store_a),
    '42501');
  PERFORM ksm_test.assert_raises('T11.23 nobody writes a payment through PostgREST',
    format('insert into public.payments (store_id, sale_id, amount, payment_method) '
           || 'values (%L::uuid, %L::uuid, 1, ''cash'')',
           v_store_a, ksm_test.ctx_get('sale_cash')),
    '42501');
  PERFORM ksm_test.assert_raises('T11.24 invoice counters are unreachable',
    'select count(*) from public.invoice_counters', '42501');
  PERFORM ksm_test.assert_raises('T11.25 the idempotency table is unreachable',
    'select count(*) from public.rpc_requests', '42501');
  PERFORM ksm_test.assert_raises('T11.26 the private schema is unreachable',
    'select private.store_role(gen_random_uuid())', '42501');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_true('T11.27 the private helper still works for RLS',
    public.is_store_member(v_store_a) IS NOT TRUE);
END $$;

-- ============================================================================
-- T12 - reporting views (they must inherit the caller's RLS)
-- ============================================================================
DO $$
DECLARE
  v_owner    uuid := ksm_test.ctx_get('owner')::uuid;
  v_manager  uuid := ksm_test.ctx_get('manager')::uuid;
  v_cashier  uuid := ksm_test.ctx_get('cashier')::uuid;
  v_outsider uuid := ksm_test.ctx_get('outsider')::uuid;
  v_store_a  uuid := ksm_test.ctx_get('store_a')::uuid;
  v_milk     uuid := ksm_test.ctx_get('product_milk')::uuid;
  v_today    date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  -- Only the credit sale is still active: the cash bill and the part-paid bill
  -- were cancelled in T08, so they must not appear in the takings.
  PERFORM ksm_test.assert_num('T12.1 daily_sales_summary counts surviving bills',
    (ksm_test.probe(v_manager,
      format('select transaction_count::text from public.daily_sales_summary '
             || 'where store_id = %L::uuid and sale_date = %L::date', v_store_a, v_today)))::numeric,
    1);
  PERFORM ksm_test.assert_num('T12.2 daily takings exclude cancelled bills',
    (ksm_test.probe(v_manager,
      format('select total_sales::text from public.daily_sales_summary '
             || 'where store_id = %L::uuid and sale_date = %L::date', v_store_a, v_today)))::numeric,
    330.00);
  PERFORM ksm_test.assert_num('T12.3 takings are split by settlement method',
    (ksm_test.probe(v_manager,
      format('select credit_sales::text from public.daily_sales_summary '
             || 'where store_id = %L::uuid and sale_date = %L::date', v_store_a, v_today)))::numeric,
    330.00);

  PERFORM ksm_test.assert_num('T12.4 product_sales_summary shows what actually sold',
    (ksm_test.probe(v_manager,
      format('select total_quantity_sold::text from public.product_sales_summary '
             || 'where store_id = %L::uuid and product_id = %L::uuid', v_store_a, v_milk)))::numeric,
    5.000);
  PERFORM ksm_test.assert_num('T12.5 product revenue excludes cancelled lines',
    (ksm_test.probe(v_manager,
      format('select total_revenue::text from public.product_sales_summary '
             || 'where store_id = %L::uuid and product_id = %L::uuid', v_store_a, v_milk)))::numeric,
    330.00);

  PERFORM ksm_test.assert_num('T12.6 customer_outstanding_balances lists udhaar',
    (ksm_test.probe(v_manager,
      format('select current_balance::text from public.customer_outstanding_balances '
             || 'where store_id = %L::uuid', v_store_a)))::numeric, 70.00);
  PERFORM ksm_test.assert_num('T12.7 the collection worklist holds one customer',
    (ksm_test.probe(v_manager,
      format('select count(*)::text from public.customer_outstanding_balances '
             || 'where store_id = %L::uuid', v_store_a)))::numeric, 1);
  PERFORM ksm_test.assert_num('T12.8 inventory_valuation covers the store',
    (ksm_test.probe(v_manager,
      format('select count(*)::text from public.inventory_valuation '
             || 'where store_id = %L::uuid', v_store_a)))::numeric, 1);
END $$;

-- ---------------------------------------------------------------------------
-- T12b - the reorder worklist, and views under RLS
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_owner    uuid := ksm_test.ctx_get('owner')::uuid;
  v_manager  uuid := ksm_test.ctx_get('manager')::uuid;
  v_cashier  uuid := ksm_test.ctx_get('cashier')::uuid;
  v_outsider uuid := ksm_test.ctx_get('outsider')::uuid;
  v_store_a  uuid := ksm_test.ctx_get('store_a')::uuid;
  v_milk     uuid := ksm_test.ctx_get('product_milk')::uuid;
BEGIN
  -- Drop the milk below its threshold (5) and the reorder worklist must show it.
  PERFORM ksm_test.act_as(v_manager);
  PERFORM public.adjust_inventory(v_store_a, v_milk, 'damage', -20, 'Damaged in transit');
  PERFORM ksm_test.act_as_service();

  PERFORM ksm_test.assert_num('T12.9 low_stock_products flags a product at/below threshold',
    (ksm_test.probe(v_manager,
      format('select count(*)::text from public.low_stock_products '
             || 'where store_id = %L::uuid and product_id = %L::uuid', v_store_a, v_milk)))::numeric,
    1);
  PERFORM ksm_test.assert_num('T12.10 the view reports the shortfall',
    (ksm_test.probe(v_manager,
      format('select shortfall::text from public.low_stock_products '
             || 'where store_id = %L::uuid and product_id = %L::uuid', v_store_a, v_milk)))::numeric,
    2.000);

  -- Top the stock up again: the product leaves the worklist.
  PERFORM ksm_test.act_as(v_manager);
  PERFORM public.adjust_inventory(v_store_a, v_milk, 'manual_adjustment', 20,
                                  'Replacement stock received');
  PERFORM ksm_test.act_as_service();
  PERFORM ksm_test.assert_num('T12.11 a restocked product leaves the worklist',
    (ksm_test.probe(v_manager,
      format('select count(*)::text from public.low_stock_products '
             || 'where store_id = %L::uuid and product_id = %L::uuid', v_store_a, v_milk)))::numeric,
    0);

  -- Views are created WITH (security_invoker = true), so they can never be used
  -- to read around RLS.
  PERFORM ksm_test.assert_num('T12.12 a view returns nothing to an outsider',
    (ksm_test.probe(v_outsider,
      'select count(*)::text from public.daily_sales_summary'))::numeric, 0);
  PERFORM ksm_test.assert_num('T12.13 a view returns nothing to an outsider (udhaar)',
    (ksm_test.probe(v_outsider,
      'select count(*)::text from public.customer_outstanding_balances'))::numeric, 0);
  PERFORM ksm_test.assert_num('T12.14 a cashier sees only their own store in the views',
    (ksm_test.probe(v_cashier,
      'select count(*)::text from public.daily_sales_summary'))::numeric, 1);
  PERFORM ksm_test.assert_num('T12.15 an owner sees only their own store in the views',
    (ksm_test.probe(v_owner,
      'select count(*)::text from public.daily_sales_summary'))::numeric, 1);
END $$;

-- ============================================================================
-- Summary and cleanup
-- ============================================================================
DO $$
DECLARE
  v_total  integer;
  v_failed integer;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE status = 'fail')
    INTO v_total, v_failed
    FROM ksm_test.results;

  IF v_failed > 0 THEN
    RAISE EXCEPTION 'KSM backend verification FAILED: % of % assertions failed',
      v_failed, v_total USING ERRCODE = 'P0001';
  END IF;

  -- Notices are visible in psql / `supabase db` output. In the SQL Editor, a
  -- green "Success. No rows returned" is the pass signal and the log below can
  -- only be read in clients that show intermediate result sets.
  RAISE NOTICE 'KSM backend verification passed: % assertions.', v_total;
END $$;

-- Per-assertion log (seq, name, status, detail).
SELECT seq, name, status, detail FROM ksm_test.results ORDER BY seq;

-- Nothing survives: the harness, the four test identities, both stores and all
-- of their sales, purchases, movements, ledger rows and audit entries go away.
ROLLBACK;
