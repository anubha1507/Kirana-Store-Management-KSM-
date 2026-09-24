-- KSM consolidated PostgreSQL schema (reference snapshot).
--
-- GENERATED FILE: concatenation of supabase/migrations/*.sql in filename order
-- (the same order validate-db.mjs applies them). Source of truth for history:
-- supabase/migrations/ — edit there, then regenerate.
--
-- Do NOT run this against a database that already has these objects; it is
-- intended for fresh environments and as the canonical schema reference.
-- Migrations included: 28 (001..028).

-- ====================================================================================
-- 001_foundation.sql
-- ====================================================================================
-- Run migrations in numeric order as postgres, on a fresh Supabase project.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TYPE public.user_role AS ENUM ('owner', 'manager', 'cashier');
CREATE TYPE public.payment_method AS ENUM ('cash', 'upi', 'credit', 'card', 'mixed');
CREATE TYPE public.payment_status AS ENUM ('paid', 'pending', 'partial');
CREATE TYPE public.stock_movement_type AS ENUM
  ('purchase', 'sale', 'sale_return', 'purchase_return', 'damage', 'expiry', 'manual_adjustment');
CREATE TYPE public.customer_transaction_type AS ENUM ('credit_sale', 'payment', 'adjustment', 'refund');

-- Domain bounds reject NaN and infinities as well as overflow/negative values.
CREATE DOMAIN public.money_amount AS numeric(12,2)
  CHECK (VALUE >= 0 AND VALUE < 10000000000);
CREATE DOMAIN public.positive_money AS numeric(12,2)
  CHECK (VALUE > 0 AND VALUE < 10000000000);
CREATE DOMAIN public.positive_quantity AS numeric(12,3)
  CHECK (VALUE > 0 AND VALUE < 1000000000);

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text,
  phone text,
  avatar_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.user_roles (
  role public.user_role PRIMARY KEY,
  description text NOT NULL
);
INSERT INTO public.user_roles VALUES
  ('owner', 'Store administration and all operational permissions'),
  ('manager', 'Catalog, purchasing, inventory, customers, sales and reports'),
  ('cashier', 'Restricted lookup, checkout, sales history and permitted payments');

CREATE TABLE public.stores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  phone text, email text, address text, city text, state text,
  pincode text CHECK (pincode IS NULL OR pincode ~ '^[0-9]{6}$'),
  gst_number text CHECK (gst_number IS NULL OR gst_number ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  logo_url text,
  currency text NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
  timezone text NOT NULL DEFAULT 'Asia/Kolkata',
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.store_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.user_role NOT NULL REFERENCES public.user_roles(role),
  is_active boolean NOT NULL DEFAULT true,
  joined_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, user_id)
);
CREATE TABLE public.store_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL UNIQUE REFERENCES public.stores(id) ON DELETE CASCADE,
  invoice_prefix text NOT NULL DEFAULT 'INV' CHECK (invoice_prefix ~ '^[A-Z0-9]{1,12}$'),
  enable_gst boolean NOT NULL DEFAULT false,
  default_tax_rate numeric(5,2) NOT NULL DEFAULT 0 CHECK (default_tax_rate BETWEEN 0 AND 100),
  allow_negative_stock boolean NOT NULL DEFAULT false,
  cashier_can_record_payments boolean NOT NULL DEFAULT false,
  low_stock_default_threshold numeric(12,3) NOT NULL DEFAULT 5
    CHECK (low_stock_default_threshold >= 0 AND low_stock_default_threshold < 1000000000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
-- Concurrency-safe document numbering. One row per store/document type/calendar
-- year. next_document_number() upserts this row with a row lock, so two
-- simultaneous checkouts can never share a number.
CREATE TABLE public.invoice_counters (
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  doc_type text NOT NULL CHECK (doc_type IN ('sale', 'purchase')),
  year integer NOT NULL CHECK (year BETWEEN 2000 AND 9999),
  last_value bigint NOT NULL CHECK (last_value > 0),
  PRIMARY KEY (store_id, doc_type, year)
);
CREATE TABLE public.rpc_requests (
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL,
  operation text NOT NULL,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  payload jsonb NOT NULL,
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, request_id)
);
CREATE TABLE public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpc_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
COMMIT;

-- ====================================================================================
-- 002_catalog.sql
-- ====================================================================================
-- Run after 001_foundation.sql.
BEGIN;

CREATE TABLE public.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
  description text,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  -- Referenced by products via a composite key, so a product cannot be
  -- attached to another store's category.
  UNIQUE (id, store_id)
);

CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  category_id uuid,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  sku text CHECK (sku IS NULL OR (length(btrim(sku)) BETWEEN 1 AND 64 AND sku = btrim(sku))),
  barcode text CHECK (barcode IS NULL OR (length(btrim(barcode)) BETWEEN 4 AND 64 AND barcode = btrim(barcode))),
  description text,
  cost_price public.money_amount NOT NULL DEFAULT 0,
  selling_price public.money_amount NOT NULL,
  stock_quantity numeric(12,3) NOT NULL DEFAULT 0
    CHECK (stock_quantity > -1000000000 AND stock_quantity < 1000000000),
  unit text NOT NULL DEFAULT 'piece'
    CHECK (unit IN ('piece','packet','box','bag','kg','gram','liter','ml','dozen')),
  low_stock_threshold numeric(12,3) NOT NULL DEFAULT 5
    CHECK (low_stock_threshold >= 0 AND low_stock_threshold < 1000000000),
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, store_id),
  CONSTRAINT products_category_same_store_fk
    FOREIGN KEY (category_id, store_id) REFERENCES public.categories (id, store_id) ON DELETE RESTRICT
);

CREATE TABLE public.suppliers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  phone text, email text, address text,
  gst_number text CHECK (gst_number IS NULL OR gst_number ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  notes text,
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, store_id)
);

CREATE TABLE public.customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  phone text, email text, address text,
  credit_limit public.money_amount NOT NULL DEFAULT 0,
  current_balance public.money_amount NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, store_id)
);

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
COMMIT;

-- ====================================================================================
-- 003_transactions.sql
-- ====================================================================================
-- Run after 002_catalog.sql.
BEGIN;

-- ============================================================================
-- PURCHASES
-- Ledger convention: amounts are never negative; totals are enforced.
-- ============================================================================
CREATE TABLE public.purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  supplier_id uuid,
  invoice_number text NOT NULL CHECK (length(btrim(invoice_number)) BETWEEN 1 AND 64),
  subtotal public.money_amount NOT NULL DEFAULT 0,
  tax_amount public.money_amount NOT NULL DEFAULT 0,
  discount_amount public.money_amount NOT NULL DEFAULT 0,
  total_amount public.money_amount NOT NULL,
  payment_status public.payment_status NOT NULL DEFAULT 'paid',
  notes text,
  purchased_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, store_id),
  CONSTRAINT purchases_total_check
    CHECK (total_amount = subtotal + tax_amount - discount_amount),
  CONSTRAINT purchases_supplier_same_store_fk
    FOREIGN KEY (supplier_id, store_id) REFERENCES public.suppliers (id, store_id) ON DELETE RESTRICT
);

CREATE TABLE public.purchase_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  purchase_id uuid NOT NULL,
  product_id uuid NOT NULL,
  quantity public.positive_quantity NOT NULL,
  unit_cost public.money_amount NOT NULL,
  total_cost public.money_amount NOT NULL,
  CONSTRAINT purchase_items_total_check CHECK (total_cost = round(quantity * unit_cost, 2)),
  CONSTRAINT purchase_items_purchase_same_store_fk
    FOREIGN KEY (purchase_id, store_id) REFERENCES public.purchases (id, store_id) ON DELETE CASCADE,
  CONSTRAINT purchase_items_product_same_store_fk
    FOREIGN KEY (product_id, store_id) REFERENCES public.products (id, store_id) ON DELETE RESTRICT
);

-- ============================================================================
-- SALES
-- ============================================================================
CREATE TABLE public.sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  customer_id uuid,
  invoice_number text NOT NULL CHECK (length(btrim(invoice_number)) BETWEEN 1 AND 64),
  subtotal public.money_amount NOT NULL DEFAULT 0,
  discount_amount public.money_amount NOT NULL DEFAULT 0,
  tax_amount public.money_amount NOT NULL DEFAULT 0,
  total_amount public.money_amount NOT NULL,
  payment_method public.payment_method NOT NULL,
  payment_status public.payment_status NOT NULL DEFAULT 'paid',
  notes text,
  cancelled_at timestamptz,
  cancelled_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  cancel_reason text,
  sold_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, store_id),
  UNIQUE (store_id, invoice_number),
  CONSTRAINT sales_total_check CHECK (total_amount = subtotal - discount_amount + tax_amount),
  -- A sale is either active or cancelled; cancellation always carries a reason.
  CONSTRAINT sales_cancellation_check CHECK (
    (cancelled_at IS NULL AND cancel_reason IS NULL) OR
    (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL
      AND length(btrim(cancel_reason)) BETWEEN 3 AND 500)
  ),
  CONSTRAINT sales_customer_same_store_fk
    FOREIGN KEY (customer_id, store_id) REFERENCES public.customers (id, store_id) ON DELETE RESTRICT
);

CREATE TABLE public.sale_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  sale_id uuid NOT NULL,
  product_id uuid NOT NULL,
  product_name text NOT NULL,
  quantity public.positive_quantity NOT NULL,
  unit_price public.money_amount NOT NULL,
  discount_amount public.money_amount NOT NULL DEFAULT 0,
  tax_amount public.money_amount NOT NULL DEFAULT 0,
  total_price public.money_amount NOT NULL,
  CONSTRAINT sale_items_total_check
    CHECK (total_price = round(quantity * unit_price - discount_amount + tax_amount, 2)),
  CONSTRAINT sale_items_sale_same_store_fk
    FOREIGN KEY (sale_id, store_id) REFERENCES public.sales (id, store_id) ON DELETE CASCADE,
  CONSTRAINT sale_items_product_same_store_fk
    FOREIGN KEY (product_id, store_id) REFERENCES public.products (id, store_id) ON DELETE RESTRICT
);

-- ============================================================================
-- PAYMENTS (supports split payment across methods)
-- ============================================================================
CREATE TABLE public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  sale_id uuid NOT NULL,
  amount public.positive_money NOT NULL,
  payment_method public.payment_method NOT NULL,
  transaction_reference text,
  paid_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payments_sale_same_store_fk
    FOREIGN KEY (sale_id, store_id) REFERENCES public.sales (id, store_id) ON DELETE CASCADE,
  -- 'credit' records an unpaid balance, so it may not be used as a payment.
  CONSTRAINT payments_method_check CHECK (payment_method <> 'credit')
);

-- ============================================================================
-- STOCK MOVEMENTS (immutable, signed quantity convention)
-- quantity > 0 = stock added, quantity < 0 = stock removed.
-- previous_quantity + quantity = new_quantity is always enforced.
-- ============================================================================
CREATE TABLE public.stock_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL,
  movement_type public.stock_movement_type NOT NULL,
  quantity numeric(12,3) NOT NULL
    CHECK (quantity <> 0 AND quantity > -1000000000 AND quantity < 1000000000),
  previous_quantity numeric(12,3) NOT NULL,
  new_quantity numeric(12,3) NOT NULL,
  reference_id uuid,
  reference_type text,
  notes text,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stock_movements_balance_check
    CHECK (round(previous_quantity + quantity, 3) = new_quantity),
  CONSTRAINT stock_movements_product_same_store_fk
    FOREIGN KEY (product_id, store_id) REFERENCES public.products (id, store_id) ON DELETE RESTRICT
);

CREATE TABLE public.inventory_adjustments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL,
  movement_type public.stock_movement_type NOT NULL
    CHECK (movement_type IN ('damage', 'expiry', 'manual_adjustment')),
  quantity numeric(12,3) NOT NULL CHECK (quantity <> 0),
  reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
  stock_movement_id uuid NOT NULL REFERENCES public.stock_movements(id) ON DELETE RESTRICT,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_adjustments_product_same_store_fk
    FOREIGN KEY (product_id, store_id) REFERENCES public.products (id, store_id) ON DELETE RESTRICT
);

-- ============================================================================
-- CUSTOMER LEDGER
-- amount > 0 increases the outstanding balance owed by the customer.
-- amount < 0 decreases it (payments, refunds to the customer, write-offs).
-- customers.current_balance is always kept equal to SUM(amount) per customer.
-- ============================================================================
CREATE TABLE public.customer_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL,
  transaction_type public.customer_transaction_type NOT NULL,
  amount numeric(12,2) NOT NULL
    CHECK (amount <> 0 AND amount > -10000000000 AND amount < 10000000000),
  reference_id uuid,
  reference_type text,
  description text,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_transactions_customer_same_store_fk
    FOREIGN KEY (customer_id, store_id) REFERENCES public.customers (id, store_id) ON DELETE RESTRICT,
  -- credit_sale increases what the customer owes.
  -- payment and refund reduce it (a refund here is a credit note against prior
  -- credit purchases: value flowing back to the customer).
  -- adjustment may use either sign and is reserved for supervised corrections.
  CONSTRAINT customer_transactions_sign_check CHECK (
    (transaction_type = 'credit_sale' AND amount > 0) OR
    (transaction_type IN ('payment', 'refund') AND amount < 0) OR
    (transaction_type = 'adjustment')
  )
);

CREATE TABLE public.credit_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL,
  customer_transaction_id uuid NOT NULL
    REFERENCES public.customer_transactions(id) ON DELETE RESTRICT,
  amount public.positive_money NOT NULL,
  payment_method public.payment_method NOT NULL CHECK (payment_method <> 'credit'),
  notes text,
  paid_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT credit_payments_customer_same_store_fk
    FOREIGN KEY (customer_id, store_id) REFERENCES public.customers (id, store_id) ON DELETE RESTRICT
);

ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_payments ENABLE ROW LEVEL SECURITY;
COMMIT;

-- ====================================================================================
-- 004_rls.sql
-- ====================================================================================
-- Run after 003_transactions.sql.
-- ============================================================================
-- SECURITY MODEL
-- 1. Every tenant table carries store_id and is protected by RLS.
-- 2. Membership checks use SECURITY DEFINER helpers owned by postgres, which
--    bypass RLS on store_members and therefore cannot recurse.
-- 3. Financial tables (sales, purchases, payments, ledgers, stock movements)
--    get SELECT policies only. All writes go through the RPCs in
--    005_functions.sql, so a client can never forge totals or stock levels.
-- 4. Privileges are revoked globally and re-granted explicitly so a Supabase
--    convenience grant can never widen access unexpectedly.
-- ============================================================================
BEGIN;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.role_rank(p_role public.user_role)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT CASE p_role
    WHEN 'owner' THEN 3
    WHEN 'manager' THEN 2
    WHEN 'cashier' THEN 1
  END;
$$;

-- Returns the caller's active role in a store, or NULL when not a member.
-- SECURITY DEFINER reads store_members without triggering its own RLS.
CREATE OR REPLACE FUNCTION private.store_role(p_store_id uuid)
RETURNS public.user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT m.role
  FROM public.store_members m
  WHERE m.store_id = p_store_id
    AND m.user_id = auth.uid()
    AND m.is_active
  LIMIT 1;
$$;

-- Membership predicate used throughout RLS.
CREATE OR REPLACE FUNCTION public.is_store_member(p_store_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT private.store_role(p_store_id) IS NOT NULL;
$$;

-- Role predicate with owner > manager > cashier hierarchy.
CREATE OR REPLACE FUNCTION public.has_store_role(p_store_id uuid, p_required_role text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
    WHEN p_required_role NOT IN ('owner', 'manager', 'cashier') THEN false
    ELSE COALESCE(
      private.role_rank(private.store_role(p_store_id)) >=
      private.role_rank(p_required_role::public.user_role),
      false)
  END;
$$;

-- Raises unless the caller holds at least the required role. Used inside RPCs.
CREATE OR REPLACE FUNCTION private.assert_store_role(p_store_id uuid, p_required_role text)
RETURNS public.user_role
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_role public.user_role;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  v_role := private.store_role(p_store_id);
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not a member of store %', p_store_id USING ERRCODE = '42501';
  END IF;
  IF private.role_rank(v_role) < private.role_rank(p_required_role::public.user_role) THEN
    RAISE EXCEPTION 'role % cannot perform this operation in store %', v_role, p_store_id
      USING ERRCODE = '42501';
  END IF;
  RETURN v_role;
END;
$$;

-- Store-scoped advisory lock so concurrent checkouts in one store serialise.
CREATE OR REPLACE FUNCTION private.lock_store(p_store_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT pg_advisory_xact_lock(hashtext('ksm_store'), hashtext(p_store_id::text));
$$;

-- ---------------------------------------------------------------------------
-- Privilege lockdown
-- ---------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Helpers must be executable by signed-in users because RLS expressions are
-- evaluated with the caller's privileges.
GRANT EXECUTE ON FUNCTION public.is_store_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_store_role(uuid, text) TO authenticated;

GRANT SELECT, INSERT, UPDATE ON public.profiles TO authenticated;
GRANT SELECT ON public.user_roles TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.stores TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.store_members TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.store_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.categories TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.products TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.suppliers TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customers TO authenticated;
GRANT SELECT ON public.purchases TO authenticated;
GRANT SELECT ON public.purchase_items TO authenticated;
GRANT SELECT ON public.sales TO authenticated;
GRANT SELECT ON public.sale_items TO authenticated;
GRANT SELECT ON public.payments TO authenticated;
GRANT SELECT ON public.stock_movements TO authenticated;
GRANT SELECT ON public.inventory_adjustments TO authenticated;
GRANT SELECT ON public.customer_transactions TO authenticated;
GRANT SELECT ON public.credit_payments TO authenticated;
GRANT SELECT ON public.audit_logs TO authenticated;
-- invoice_counters and rpc_requests keep zero client privileges.

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
CREATE POLICY profiles_select_self_or_team ON public.profiles
  FOR SELECT TO authenticated
  USING (
    id = auth.uid()
    OR EXISTS (
      SELECT 1
      FROM public.store_members mine
      JOIN public.store_members theirs ON theirs.store_id = mine.store_id
      WHERE mine.user_id = auth.uid()
        AND mine.is_active
        AND theirs.user_id = profiles.id
        AND theirs.is_active
    )
  );

CREATE POLICY profiles_insert_self ON public.profiles
  FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

CREATE POLICY profiles_update_self ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- ---------------------------------------------------------------------------
-- user_roles (read-only reference data)
-- ---------------------------------------------------------------------------
CREATE POLICY user_roles_select_all ON public.user_roles
  FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------------
-- stores
-- ---------------------------------------------------------------------------
CREATE POLICY stores_select_member ON public.stores
  FOR SELECT TO authenticated
  USING (is_store_member(id) OR owner_id = auth.uid());

CREATE POLICY stores_insert_own ON public.stores
  FOR INSERT TO authenticated
  WITH CHECK (owner_id = auth.uid());

CREATE POLICY stores_update_owner ON public.stores
  FOR UPDATE TO authenticated
  USING (has_store_role(id, 'owner'))
  WITH CHECK (has_store_role(id, 'owner'));

-- ---------------------------------------------------------------------------
-- store_members
-- ---------------------------------------------------------------------------
CREATE POLICY store_members_select_self_or_manager ON public.store_members
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR has_store_role(store_id, 'manager'));

CREATE POLICY store_members_insert_owner ON public.store_members
  FOR INSERT TO authenticated
  WITH CHECK (has_store_role(store_id, 'owner'));

CREATE POLICY store_members_update_owner ON public.store_members
  FOR UPDATE TO authenticated
  USING (has_store_role(store_id, 'owner'))
  WITH CHECK (has_store_role(store_id, 'owner'));

-- An owner cannot remove their own membership, which would orphan the store.
CREATE POLICY store_members_delete_owner ON public.store_members
  FOR DELETE TO authenticated
  USING (has_store_role(store_id, 'owner') AND user_id <> auth.uid());

-- ---------------------------------------------------------------------------
-- store_settings
-- ---------------------------------------------------------------------------
CREATE POLICY store_settings_select_member ON public.store_settings
  FOR SELECT TO authenticated
  USING (is_store_member(store_id));

CREATE POLICY store_settings_insert_owner ON public.store_settings
  FOR INSERT TO authenticated
  WITH CHECK (has_store_role(store_id, 'owner'));

CREATE POLICY store_settings_update_owner ON public.store_settings
  FOR UPDATE TO authenticated
  USING (has_store_role(store_id, 'owner'))
  WITH CHECK (has_store_role(store_id, 'owner'));

-- ---------------------------------------------------------------------------
-- categories
-- ---------------------------------------------------------------------------
CREATE POLICY categories_select_member ON public.categories
  FOR SELECT TO authenticated USING (is_store_member(store_id));

CREATE POLICY categories_insert_manager ON public.categories
  FOR INSERT TO authenticated WITH CHECK (has_store_role(store_id, 'manager'));

CREATE POLICY categories_update_manager ON public.categories
  FOR UPDATE TO authenticated
  USING (has_store_role(store_id, 'manager'))
  WITH CHECK (has_store_role(store_id, 'manager'));

CREATE POLICY categories_delete_owner ON public.categories
  FOR DELETE TO authenticated USING (has_store_role(store_id, 'owner'));

-- ---------------------------------------------------------------------------
-- products
-- Managers and owners see the whole catalogue including cost prices.
-- Cashiers see only active, non-deleted products: enough to bill, nothing more.
-- ---------------------------------------------------------------------------
CREATE POLICY products_select_manager_or_active_cashier ON public.products
  FOR SELECT TO authenticated
  USING (
    has_store_role(store_id, 'manager')
    OR (has_store_role(store_id, 'cashier') AND is_active AND deleted_at IS NULL)
  );

CREATE POLICY products_insert_manager ON public.products
  FOR INSERT TO authenticated WITH CHECK (has_store_role(store_id, 'manager'));

CREATE POLICY products_update_manager ON public.products
  FOR UPDATE TO authenticated
  USING (has_store_role(store_id, 'manager'))
  WITH CHECK (has_store_role(store_id, 'manager'));

CREATE POLICY products_delete_owner ON public.products
  FOR DELETE TO authenticated USING (has_store_role(store_id, 'owner'));

-- ---------------------------------------------------------------------------
-- suppliers
-- ---------------------------------------------------------------------------
CREATE POLICY suppliers_select_manager ON public.suppliers
  FOR SELECT TO authenticated USING (has_store_role(store_id, 'manager'));

CREATE POLICY suppliers_insert_manager ON public.suppliers
  FOR INSERT TO authenticated WITH CHECK (has_store_role(store_id, 'manager'));

CREATE POLICY suppliers_update_manager ON public.suppliers
  FOR UPDATE TO authenticated
  USING (has_store_role(store_id, 'manager'))
  WITH CHECK (has_store_role(store_id, 'manager'));

CREATE POLICY suppliers_delete_owner ON public.suppliers
  FOR DELETE TO authenticated USING (has_store_role(store_id, 'owner'));

-- ---------------------------------------------------------------------------
-- customers
-- Cashiers never read this table directly (credit limits and addresses are
-- sensitive). Billing uses the customer_lookup() RPC instead.
-- ---------------------------------------------------------------------------
CREATE POLICY customers_select_manager ON public.customers
  FOR SELECT TO authenticated USING (has_store_role(store_id, 'manager'));

CREATE POLICY customers_insert_manager ON public.customers
  FOR INSERT TO authenticated WITH CHECK (has_store_role(store_id, 'manager'));

CREATE POLICY customers_update_manager ON public.customers
  FOR UPDATE TO authenticated
  USING (has_store_role(store_id, 'manager'))
  WITH CHECK (has_store_role(store_id, 'manager'));

CREATE POLICY customers_delete_owner ON public.customers
  FOR DELETE TO authenticated USING (has_store_role(store_id, 'owner'));

-- ---------------------------------------------------------------------------
-- Read-only financial tables. Writes are RPC-only: no INSERT/UPDATE/DELETE
-- policies exist and the privileges were revoked above.
-- ---------------------------------------------------------------------------
CREATE POLICY purchases_select_manager ON public.purchases
  FOR SELECT TO authenticated USING (has_store_role(store_id, 'manager'));

CREATE POLICY purchase_items_select_manager ON public.purchase_items
  FOR SELECT TO authenticated USING (has_store_role(store_id, 'manager'));

CREATE POLICY sales_select_member ON public.sales
  FOR SELECT TO authenticated USING (is_store_member(store_id));

CREATE POLICY sale_items_select_member ON public.sale_items
  FOR SELECT TO authenticated USING (is_store_member(store_id));

CREATE POLICY payments_select_member ON public.payments
  FOR SELECT TO authenticated USING (is_store_member(store_id));

CREATE POLICY stock_movements_select_manager ON public.stock_movements
  FOR SELECT TO authenticated USING (has_store_role(store_id, 'manager'));

CREATE POLICY inventory_adjustments_select_manager ON public.inventory_adjustments
  FOR SELECT TO authenticated USING (has_store_role(store_id, 'manager'));

CREATE POLICY customer_transactions_select_manager ON public.customer_transactions
  FOR SELECT TO authenticated USING (has_store_role(store_id, 'manager'));

CREATE POLICY credit_payments_select_manager ON public.credit_payments
  FOR SELECT TO authenticated USING (has_store_role(store_id, 'manager'));

-- ---------------------------------------------------------------------------
-- audit_logs: append-only and owner-readable. No write policies exist, so only
-- SECURITY DEFINER code can append, and nobody can edit or delete rows.
-- ---------------------------------------------------------------------------
CREATE POLICY audit_logs_select_owner ON public.audit_logs
  FOR SELECT TO authenticated USING (has_store_role(store_id, 'owner'));

-- invoice_counters and rpc_requests intentionally have RLS enabled with zero
-- policies: unreachable for anon and authenticated through PostgREST.

COMMIT;

-- ====================================================================================
-- 005_trigger_functions.sql
-- ====================================================================================
-- Run after 004_rls.sql.
-- ============================================================================
-- TRIGGER FUNCTIONS
-- These functions enforce invariants that RLS alone cannot express:
--   * stock and customer balances can only move through sanctioned RPCs,
--   * ledger tables are append-only,
--   * every store always has an owner membership and a settings row,
--   * new auth users automatically get a profile.
-- Functions that write to protected tables are SECURITY DEFINER and pin
-- search_path, because supabase_auth_admin (not the client) fires them.
-- ============================================================================
BEGIN;

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION private.block_write()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: rows cannot be updated or deleted', TG_TABLE_NAME
    USING ERRCODE = '55000',
          HINT = 'Create a correcting entry instead of editing history.';
END;
$$;

-- Appends a row to audit_logs for products, customers, members and settings.
-- Stock-driven and balance-driven updates are skipped because the owning RPC
-- already writes a precise business audit entry for those events.
CREATE OR REPLACE FUNCTION private.audit_row_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_old jsonb;
  v_new jsonb;
  v_store uuid;
  v_entity uuid;
BEGIN
  IF current_setting('ksm.allow_stock_change', true) = 'on'
     OR current_setting('ksm.allow_balance_change', true) = 'on' THEN
    RETURN NULL;
  END IF;

  IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD); END IF;
  IF TG_OP <> 'DELETE' THEN v_new := to_jsonb(NEW); END IF;

  IF TG_TABLE_NAME = 'stores' THEN
    v_store := COALESCE((v_new->>'id')::uuid, (v_old->>'id')::uuid);
  ELSE
    v_store := COALESCE((v_new->>'store_id')::uuid, (v_old->>'store_id')::uuid);
  END IF;
  v_entity := COALESCE((v_new->>'id')::uuid, (v_old->>'id')::uuid);

  INSERT INTO public.audit_logs
    (store_id, user_id, action, entity_type, entity_id, old_data, new_data)
  VALUES
    (v_store, auth.uid(), lower(TG_TABLE_NAME) || '.' || lower(TG_OP),
     TG_TABLE_NAME, v_entity, v_old, v_new);

  RETURN NULL;
END;
$$;

-- Single writer for audit entries produced by RPCs.
CREATE OR REPLACE FUNCTION private.audit(
  p_store_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_old_data jsonb DEFAULT NULL,
  p_new_data jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  INSERT INTO public.audit_logs
    (store_id, user_id, action, entity_type, entity_id, old_data, new_data)
  VALUES
    (p_store_id, auth.uid(), p_action, p_entity_type, p_entity_id, p_old_data, p_new_data);
$$;

-- ---------------------------------------------------------------------------
-- Document numbering
-- ---------------------------------------------------------------------------
-- Allocates the next document number for a store and document type using an
-- UPSERT, which takes a row lock. Two concurrent checkouts therefore serialise
-- on this single row and can never receive the same number. The row is also a
-- durable record of "highest issued number" for manual auditing.
CREATE OR REPLACE FUNCTION private.next_document_number(
  p_store_id uuid,
  p_doc_type text,
  p_prefix text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_prefix text;
  v_year integer;
  v_next bigint;
BEGIN
  IF p_doc_type NOT IN ('sale', 'purchase') THEN
    RAISE EXCEPTION 'unsupported document type %', p_doc_type USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(p_prefix, s.invoice_prefix)
    INTO v_prefix
    FROM public.store_settings s
   WHERE s.store_id = p_store_id;
  IF v_prefix IS NULL THEN
    v_prefix := CASE WHEN p_doc_type = 'purchase' THEN 'PUR' ELSE 'INV' END;
  END IF;

  v_year := EXTRACT(
      YEAR FROM (now() AT TIME ZONE COALESCE(
        (SELECT timezone FROM public.stores WHERE id = p_store_id),
        'Asia/Kolkata'))
    )::integer;

  INSERT INTO public.invoice_counters (store_id, doc_type, year, last_value)
  VALUES (p_store_id, p_doc_type, v_year, 1)
  ON CONFLICT (store_id, doc_type, year)
  DO UPDATE SET last_value = public.invoice_counters.last_value + 1
  RETURNING last_value INTO v_next;

  RETURN format('%s-%s-%s', v_prefix, v_year, lpad(v_next::text, 6, '0'));
END;
$$;

-- ---------------------------------------------------------------------------
-- Store bootstrap and ownership protection
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.bootstrap_store()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  INSERT INTO public.store_members (store_id, user_id, role)
  VALUES (NEW.id, NEW.owner_id, 'owner')
  ON CONFLICT (store_id, user_id) DO UPDATE
    SET role = 'owner', is_active = true;

  INSERT INTO public.store_settings (store_id) VALUES (NEW.id)
  ON CONFLICT (store_id) DO NOTHING;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION private.guard_store_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    RAISE EXCEPTION 'store ownership transfer is not supported by this function set'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

-- The owner membership is the anchor of tenant security, so it can never be
-- demoted, deactivated, moved, or deleted.
CREATE OR REPLACE FUNCTION private.guard_store_member_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.role = 'owner' THEN
      RAISE EXCEPTION 'the store owner membership cannot be deleted' USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.role = 'owner' THEN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id
       OR NEW.store_id IS DISTINCT FROM OLD.store_id
       OR NEW.role IS DISTINCT FROM 'owner'::public.user_role
       OR NEW.is_active IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'the store owner membership cannot be changed; ownership transfer needs an operator-run migration'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF NEW.role = 'owner' AND OLD.role <> 'owner' THEN
    RAISE EXCEPTION 'a store cannot have a second owner' USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Inventory integrity
-- ---------------------------------------------------------------------------
-- Opening stock entered at product creation is recorded as a movement so the
-- product's quantity can always be reconstructed from stock_movements.
CREATE OR REPLACE FUNCTION private.record_opening_stock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.stock_quantity <> 0 THEN
    INSERT INTO public.stock_movements
      (store_id, product_id, movement_type, quantity, previous_quantity, new_quantity,
       reference_type, notes, created_by)
    VALUES
      (NEW.store_id, NEW.id, 'manual_adjustment', NEW.stock_quantity, 0, NEW.stock_quantity,
       'opening_stock', 'Opening stock recorded when the product was created', auth.uid());
  END IF;
  RETURN NULL;
END;
$$;

-- Direct UPDATE of products.stock_quantity is refused unless the caller is an
-- RPC that set the transaction-local flag. This is what stops a manager (or a
-- compromised client) from silently editing stock without a movement record.
CREATE OR REPLACE FUNCTION private.guard_product_stock()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.stock_quantity IS DISTINCT FROM OLD.stock_quantity
     AND current_setting('ksm.allow_stock_change', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'stock_quantity cannot be edited directly (attempted % -> %)', OLD.stock_quantity, NEW.stock_quantity
      USING ERRCODE = '55000',
            HINT = 'Use create_purchase, create_sale, adjust_inventory or cancel_sale.';
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Customer balance integrity
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.guard_customer_balance()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.current_balance IS DISTINCT FROM OLD.current_balance
     AND current_setting('ksm.allow_balance_change', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'current_balance cannot be edited directly'
      USING ERRCODE = '55000',
            HINT = 'Balances are derived from customer_transactions.';
  END IF;
  RETURN NEW;
END;
$$;

-- Keeps customers.current_balance exactly equal to the ledger sum. Because the
-- ledger itself is append-only, the balance is always reproducible, and an
-- overdrawn balance is rejected at the moment it would be created.
CREATE OR REPLACE FUNCTION private.apply_customer_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_balance numeric(12,2);
BEGIN
  PERFORM set_config('ksm.allow_balance_change', 'on', true);

  UPDATE public.customers
     SET current_balance = current_balance + NEW.amount
   WHERE id = NEW.customer_id
     AND store_id = NEW.store_id
  RETURNING current_balance INTO v_balance;

  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'customer % does not exist in store %', NEW.customer_id, NEW.store_id
      USING ERRCODE = '23503';
  END IF;

  IF v_balance < 0 THEN
    RAISE EXCEPTION 'ledger entry would overdraft customer % (new balance %)', NEW.customer_id, v_balance
      USING ERRCODE = 'P0001',
            HINT = 'Record a smaller payment or add an adjustment first.';
  END IF;

  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- Immutability guards for financial documents
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.guard_sale_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF TG_OP = 'DELETE' OR current_setting('ksm.allow_sale_cancel', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'sales are immutable' USING ERRCODE = '55000',
      HINT = 'Use cancel_sale() to void a bill with a compensating entry.';
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.store_id IS DISTINCT FROM OLD.store_id
     OR NEW.customer_id IS DISTINCT FROM OLD.customer_id
     OR NEW.invoice_number IS DISTINCT FROM OLD.invoice_number
     OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
     OR NEW.discount_amount IS DISTINCT FROM OLD.discount_amount
     OR NEW.tax_amount IS DISTINCT FROM OLD.tax_amount
     OR NEW.total_amount IS DISTINCT FROM OLD.total_amount
     OR NEW.payment_method IS DISTINCT FROM OLD.payment_method
     OR NEW.sold_at IS DISTINCT FROM OLD.sold_at
     OR NEW.created_by IS DISTINCT FROM OLD.created_by
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'only cancellation bookkeeping may change on a sale'
      USING ERRCODE = '55000';
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION private.guard_purchase_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF TG_OP = 'DELETE' OR current_setting('ksm.allow_purchase_update', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'purchases are immutable' USING ERRCODE = '55000';
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.store_id IS DISTINCT FROM OLD.store_id
     OR NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
     OR NEW.invoice_number IS DISTINCT FROM OLD.invoice_number
     OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
     OR NEW.tax_amount IS DISTINCT FROM OLD.tax_amount
     OR NEW.discount_amount IS DISTINCT FROM OLD.discount_amount
     OR NEW.total_amount IS DISTINCT FROM OLD.total_amount
     OR NEW.purchased_at IS DISTINCT FROM OLD.purchased_at THEN
    RAISE EXCEPTION 'only payment_status and notes may change on a purchase'
      USING ERRCODE = '55000';
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- New auth users get a profile row
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, phone, avatar_url)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name'),
    NEW.raw_user_meta_data->>'phone',
    NEW.raw_user_meta_data->>'avatar_url'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NULL;
END;
$$;

COMMIT;

-- ====================================================================================
-- 006_triggers.sql
-- ====================================================================================
-- Run after 005_trigger_functions.sql.
-- ============================================================================
-- TRIGGER WIRING
-- Ordering notes:
--   * BEFORE triggers run alphabetically, so guard_* triggers are named to run
--     before any trigger that would otherwise mutate the row.
--   * AFTER triggers on the same table also run alphabetically; the audit
--     trigger is named to run last so it observes the final row image.
-- ============================================================================
BEGIN;

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.stores
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.store_settings
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.categories
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.suppliers
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

-- ---------------------------------------------------------------------------
-- Store bootstrap and ownership protection
-- ---------------------------------------------------------------------------
CREATE TRIGGER bootstrap_store AFTER INSERT ON public.stores
  FOR EACH ROW EXECUTE FUNCTION private.bootstrap_store();

CREATE TRIGGER guard_store_update BEFORE UPDATE ON public.stores
  FOR EACH ROW EXECUTE FUNCTION private.guard_store_update();

CREATE TRIGGER guard_store_member_change BEFORE UPDATE OR DELETE ON public.store_members
  FOR EACH ROW EXECUTE FUNCTION private.guard_store_member_change();

-- ---------------------------------------------------------------------------
-- Inventory integrity
-- ---------------------------------------------------------------------------
CREATE TRIGGER record_opening_stock AFTER INSERT ON public.products
  FOR EACH ROW EXECUTE FUNCTION private.record_opening_stock();

CREATE TRIGGER guard_product_stock BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION private.guard_product_stock();

-- ---------------------------------------------------------------------------
-- Customer balance integrity
-- ---------------------------------------------------------------------------
CREATE TRIGGER guard_customer_balance BEFORE UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION private.guard_customer_balance();

CREATE TRIGGER apply_customer_ledger AFTER INSERT ON public.customer_transactions
  FOR EACH ROW EXECUTE FUNCTION private.apply_customer_ledger();

-- ---------------------------------------------------------------------------
-- Financial document immutability
-- ---------------------------------------------------------------------------
CREATE TRIGGER guard_sale_change BEFORE UPDATE OR DELETE ON public.sales
  FOR EACH ROW EXECUTE FUNCTION private.guard_sale_change();

CREATE TRIGGER guard_purchase_change BEFORE UPDATE OR DELETE ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION private.guard_purchase_change();

-- Append-only ledgers and line items.
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.sale_items
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.purchase_items
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.inventory_adjustments
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.customer_transactions
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.credit_payments
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.audit_logs
  FOR EACH ROW EXECUTE FUNCTION private.block_write();

-- ---------------------------------------------------------------------------
-- Audit trail for master data
-- ---------------------------------------------------------------------------
CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE ON public.stores
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change();
CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE ON public.store_members
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change();
CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE ON public.store_settings
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change();
CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE ON public.products
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change();
CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change();

-- ---------------------------------------------------------------------------
-- Supabase Auth integration
-- ---------------------------------------------------------------------------
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.handle_new_user();

COMMIT;


-- ====================================================================================
-- 007_rpc_store_and_members.sql
-- ====================================================================================
-- Run after 006_triggers.sql.
-- ============================================================================
-- RPC: store and membership administration
-- Every function is SECURITY DEFINER with a pinned search_path and derives the
-- caller identity from auth.uid() rather than trusting an argument. EXECUTE is
-- revoked from PUBLIC/anon and granted to authenticated.
-- ============================================================================
BEGIN;

-- Creates a store owned by the caller. The bootstrap_store trigger then adds
-- the owner membership and the default settings row, so a store can never
-- exist without an owner and configuration.
CREATE OR REPLACE FUNCTION public.create_store(
  p_name text,
  p_phone text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_pincode text DEFAULT NULL,
  p_gst_number text DEFAULT NULL,
  p_timezone text DEFAULT 'Asia/Kolkata'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id uuid;
  v_store public.stores;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'store name is required' USING ERRCODE = '22023';
  END IF;

  -- Validate the timezone explicitly: an invalid zone would otherwise fail
  -- later, inside invoice numbering, at the worst possible moment.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names t WHERE t.name = p_timezone) THEN
    RAISE EXCEPTION 'unknown timezone %', p_timezone USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.stores
    (name, owner_id, phone, email, address, city, state, pincode, gst_number, timezone)
  VALUES
    (btrim(p_name), v_user_id, p_phone, p_email, p_address, p_city, p_state,
     p_pincode, p_gst_number, p_timezone)
  RETURNING * INTO v_store;

  RETURN to_jsonb(v_store);
END;
$$;

-- Owner-facing settings update. Named parameters keep the call self-documenting
-- and stop a client from clearing a setting it did not intend to touch.
CREATE OR REPLACE FUNCTION public.update_store_settings(
  p_store_id uuid,
  p_invoice_prefix text DEFAULT NULL,
  p_enable_gst boolean DEFAULT NULL,
  p_default_tax_rate numeric DEFAULT NULL,
  p_allow_negative_stock boolean DEFAULT NULL,
  p_cashier_can_record_payments boolean DEFAULT NULL,
  p_low_stock_default_threshold numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_settings public.store_settings;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'owner');

  UPDATE public.store_settings
     SET invoice_prefix = COALESCE(p_invoice_prefix, invoice_prefix),
         enable_gst = COALESCE(p_enable_gst, enable_gst),
         default_tax_rate = COALESCE(p_default_tax_rate, default_tax_rate),
         allow_negative_stock = COALESCE(p_allow_negative_stock, allow_negative_stock),
         cashier_can_record_payments =
           COALESCE(p_cashier_can_record_payments, cashier_can_record_payments),
         low_stock_default_threshold =
           COALESCE(p_low_stock_default_threshold, low_stock_default_threshold)
   WHERE store_id = p_store_id
  RETURNING * INTO v_settings;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'settings not found for store %', p_store_id USING ERRCODE = '22023';
  END IF;

  RETURN to_jsonb(v_settings);
END;
$$;

-- MEMBERS_ANCHOR

REVOKE ALL ON FUNCTION public.update_store_settings(uuid, text, boolean, numeric, boolean, boolean, numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_store_settings(uuid, text, boolean, numeric, boolean, boolean, numeric)
  TO authenticated;

REVOKE ALL ON FUNCTION public.create_store(text, text, text, text, text, text, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_store(text, text, text, text, text, text, text, text, text)
  TO authenticated;

COMMIT;


-- ====================================================================================
-- 008_rpc_catalog_admin.sql
-- ====================================================================================
-- Run after 007_rpc_store_and_members.sql.
-- Administrative writes that must be validated server side. Members can also
-- insert products/customers directly under RLS, but these RPCs cover the cases
-- that RLS cannot express: category-in-store checks, soft deletion, and stock
-- adjustments that must always leave a movement record.
BEGIN;

-- Soft-deletes a product. Historical sale_items keep the snapshot of the
-- product name and price, so invoices stay readable after removal.
CREATE OR REPLACE FUNCTION public.archive_product(p_store_id uuid, p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_product public.products;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'manager');

  UPDATE public.products
     SET is_active = false,
         deleted_at = now()
   WHERE id = p_product_id
     AND store_id = p_store_id
     AND deleted_at IS NULL
  RETURNING * INTO v_product;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'active product % not found in store %', p_product_id, p_store_id
      USING ERRCODE = '22023';
  END IF;

  RETURN to_jsonb(v_product);
END;
$$;

-- Records damage, expiry or a manual stock correction. The signed quantity is
-- the delta: negative removes stock, positive adds it. A stock movement is
-- always written, so the correction is fully explainable later.
CREATE OR REPLACE FUNCTION public.adjust_inventory(
  p_store_id uuid,
  p_product_id uuid,
  p_movement_type public.stock_movement_type,
  p_quantity numeric,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_previous numeric(12,3);
  v_new numeric(12,3);
  v_allow_negative boolean;
  v_movement_id uuid;
  v_adjustment_id uuid;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'manager');

  IF p_movement_type NOT IN ('damage', 'expiry', 'manual_adjustment') THEN
    RAISE EXCEPTION 'movement type % cannot be used for an adjustment', p_movement_type
      USING ERRCODE = '22023';
  END IF;

  IF p_quantity IS NULL OR p_quantity = 0
     OR p_quantity <= -1000000000 OR p_quantity >= 1000000000 THEN
    RAISE EXCEPTION 'adjustment quantity must be non-zero and within range'
      USING ERRCODE = '22023';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 1 THEN
    RAISE EXCEPTION 'a reason is required for every inventory adjustment'
      USING ERRCODE = '22023';
  END IF;

  SELECT allow_negative_stock INTO v_allow_negative
    FROM public.store_settings WHERE store_id = p_store_id;

  -- Lock the product row: concurrent adjustments must serialise.
  SELECT stock_quantity INTO v_previous
    FROM public.products
   WHERE id = p_product_id AND store_id = p_store_id
   FOR UPDATE;

  IF v_previous IS NULL THEN
    RAISE EXCEPTION 'product % not found in store %', p_product_id, p_store_id
      USING ERRCODE = '23503';
  END IF;

  v_new := round(v_previous + p_quantity, 3);

  IF v_new < 0 AND NOT COALESCE(v_allow_negative, false) THEN
    RAISE EXCEPTION 'adjustment would make stock negative (% -> %)', v_previous, v_new
      USING ERRCODE = 'P0001',
            HINT = 'Enable allow_negative_stock in store settings to permit this.';
  END IF;

  PERFORM set_config('ksm.allow_stock_change', 'on', true);
  UPDATE public.products SET stock_quantity = v_new WHERE id = p_product_id;

  INSERT INTO public.stock_movements
    (store_id, product_id, movement_type, quantity, previous_quantity, new_quantity,
     reference_type, notes, created_by)
  VALUES
    (p_store_id, p_product_id, p_movement_type, p_quantity, v_previous, v_new,
     'inventory_adjustment', btrim(p_reason), auth.uid())
  RETURNING id INTO v_movement_id;

  INSERT INTO public.inventory_adjustments
    (store_id, product_id, movement_type, quantity, reason, stock_movement_id, created_by)
  VALUES
    (p_store_id, p_product_id, p_movement_type, p_quantity, btrim(p_reason),
     v_movement_id, auth.uid())
  RETURNING id INTO v_adjustment_id;

  PERFORM private.audit(p_store_id, 'inventory.adjusted', 'products', p_product_id,
    jsonb_build_object('stock_quantity', v_previous),
    jsonb_build_object('stock_quantity', v_new, 'adjustment_id', v_adjustment_id,
                       'movement_type', p_movement_type, 'reason', btrim(p_reason)));

  RETURN jsonb_build_object(
    'adjustment_id', v_adjustment_id,
    'stock_movement_id', v_movement_id,
    'previous_quantity', v_previous,
    'new_quantity', v_new
  );
END;
$$;

REVOKE ALL ON FUNCTION public.archive_product(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.adjust_inventory(uuid, uuid, public.stock_movement_type, numeric, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.archive_product(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_inventory(uuid, uuid, public.stock_movement_type, numeric, text)
  TO authenticated;

COMMIT;


-- ====================================================================================
-- 009_rpc_product_lookup.sql
-- ====================================================================================
-- Run after 008_rpc_catalog_admin.sql.
-- Billing lookup for products. Cashiers cannot SELECT products directly, so
-- this SECURITY DEFINER function exposes only billing-relevant columns.
BEGIN;

CREATE OR REPLACE FUNCTION public.find_products_for_billing(
  p_store_id uuid,
  p_search text DEFAULT NULL,
  p_category_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 25
)
RETURNS TABLE (
  product_id uuid,
  name text,
  sku text,
  barcode text,
  selling_price numeric,
  stock_quantity numeric,
  unit text,
  category_id uuid,
  is_low_stock boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_term text;
BEGIN
  IF NOT public.is_store_member(p_store_id) THEN
    RAISE EXCEPTION 'not a member of store %', p_store_id USING ERRCODE = '42501';
  END IF;

  v_term := NULLIF(btrim(COALESCE(p_search, '')), '');

  RETURN QUERY
  SELECT p.id, p.name, p.sku, p.barcode, p.selling_price, p.stock_quantity,
         p.unit, p.category_id, (p.stock_quantity <= p.low_stock_threshold)
    FROM public.products p
   WHERE p.store_id = p_store_id
     AND p.is_active
     AND p.deleted_at IS NULL
     AND (p_category_id IS NULL OR p.category_id = p_category_id)
     AND (
       v_term IS NULL
       OR p.name ILIKE '%' || v_term || '%'
       OR p.sku ILIKE v_term || '%'
       OR p.barcode = v_term
     )
   ORDER BY (p.barcode = v_term) DESC NULLS LAST, p.name
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
END;
$$;

REVOKE ALL ON FUNCTION public.find_products_for_billing(uuid, text, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.find_products_for_billing(uuid, text, uuid, integer) TO authenticated;

COMMIT;


-- ====================================================================================
-- 010_rpc_customer_lookup.sql
-- ====================================================================================
-- Run after 009_rpc_product_lookup.sql.
-- Billing lookup for customers. Excludes address and email; includes the
-- credit figures a cashier needs to decide whether credit can be extended.
BEGIN;

CREATE OR REPLACE FUNCTION public.find_customers_for_billing(
  p_store_id uuid,
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 20
)
RETURNS TABLE (
  customer_id uuid,
  name text,
  phone text,
  current_balance numeric,
  credit_limit numeric,
  credit_available numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_term text;
BEGIN
  IF private.store_role(p_store_id) IS NULL THEN
    RAISE EXCEPTION 'not a member of store %', p_store_id USING ERRCODE = '42501';
  END IF;

  v_term := NULLIF(btrim(COALESCE(p_search, '')), '');

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.phone,
         c.current_balance,
         c.credit_limit,
         CASE WHEN c.credit_limit > 0
              THEN GREATEST(c.credit_limit - c.current_balance, 0)
              ELSE NULL END
    FROM public.customers c
   WHERE c.store_id = p_store_id
     AND c.is_active
     AND c.deleted_at IS NULL
     AND (
       v_term IS NULL
       OR c.name ILIKE '%' || v_term || '%'
       OR c.phone ILIKE v_term || '%'
     )
   ORDER BY c.name
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
END;
$$;

REVOKE ALL ON FUNCTION public.find_customers_for_billing(uuid, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.find_customers_for_billing(uuid, text, integer) TO authenticated;

COMMIT;


-- ====================================================================================
-- 011_rpc_sale_payment_helper.sql
-- ====================================================================================
-- Run after 010_rpc_customer_lookup.sql.
-- Decides how much of a non-credit sale is paid BEFORE the sales row is
-- written, because sales.payment_status must be correct at insert time.
-- Returns the amount paid: the full total for cash/upi/card, or the sum of the
-- split amounts for a mixed payment.
BEGIN;

CREATE OR REPLACE FUNCTION private.validate_sale_payments(
  p_method public.payment_method,
  p_total numeric,
  p_payments jsonb
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_payment jsonb;
  v_amount numeric;
  v_paid numeric(12,2) := 0;
BEGIN
  IF p_method = 'credit' THEN
    RAISE EXCEPTION 'credit sales are settled through the customer ledger'
      USING ERRCODE = '22023';
  END IF;

  IF p_method = 'mixed' THEN
    IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array'
       OR jsonb_array_length(p_payments) = 0 THEN
      RAISE EXCEPTION 'mixed payment requires a non-empty payments array'
        USING ERRCODE = '22023';
    END IF;

    FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
      IF (v_payment->>'method') IS NULL
         OR (v_payment->>'method') NOT IN ('cash', 'upi', 'card') THEN
        RAISE EXCEPTION 'split payments must use cash, upi or card'
          USING ERRCODE = '22023';
      END IF;

      v_amount := round((v_payment->>'amount')::numeric, 2);
      IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'each split payment amount must be positive'
          USING ERRCODE = '22023';
      END IF;

      v_paid := v_paid + v_amount;
    END LOOP;

    IF v_paid > p_total THEN
      RAISE EXCEPTION 'payments (%) exceed the sale total (%)', v_paid, p_total
        USING ERRCODE = '22023';
    END IF;

    RETURN v_paid;
  END IF;

  RETURN p_total;
END;
$$;

REVOKE ALL ON FUNCTION private.validate_sale_payments(public.payment_method, numeric, jsonb)
  FROM PUBLIC, anon, authenticated;

COMMIT;


-- ====================================================================================
-- 012_rpc_price_sale_lines.sql
-- ====================================================================================
-- Run after 011_rpc_sale_payment_helper.sql.
-- Prices sale lines from products.selling_price under FOR UPDATE locks and
-- returns {"subtotal", "lines"} without writing anything to the database.
BEGIN;

CREATE OR REPLACE FUNCTION private.price_sale_lines(
  p_store_id uuid,
  p_items jsonb,
  p_allow_negative boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_item record;
  v_product public.products;
  v_prev numeric(12,3);
  v_new numeric(12,3);
  v_line_discount numeric(12,2);
  v_line_total numeric(12,2);
  v_lines jsonb := '[]'::jsonb;
  v_subtotal numeric(12,2) := 0;
BEGIN
  -- ORDER BY product_id gives a deterministic lock order, which avoids
  -- deadlocks between concurrent bills sharing the same products.
  FOR v_item IN
    SELECT (e->>'product_id')::uuid AS product_id,
           SUM((e->>'quantity')::numeric) AS quantity,
           SUM(COALESCE((e->>'discount_amount')::numeric, 0)) AS discount_amount
      FROM jsonb_array_elements(p_items) e
     GROUP BY (e->>'product_id')::uuid
     ORDER BY (e->>'product_id')::uuid
  LOOP
    IF v_item.product_id IS NULL OR v_item.quantity IS NULL
       OR v_item.quantity <= 0 OR v_item.quantity >= 1000000000 THEN
      RAISE EXCEPTION 'every sale item needs a product_id and a positive quantity'
        USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_product
      FROM public.products
     WHERE id = v_item.product_id AND store_id = p_store_id
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'product % not found in store %', v_item.product_id, p_store_id
        USING ERRCODE = '23503';
    END IF;
    IF NOT v_product.is_active OR v_product.deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'product % is not available for sale', v_product.name
        USING ERRCODE = '22023';
    END IF;

    v_prev := v_product.stock_quantity;
    v_new := round(v_prev - v_item.quantity, 3);
    IF v_new < 0 AND NOT COALESCE(p_allow_negative, false) THEN
      RAISE EXCEPTION 'insufficient stock for % (available %, requested %)',
        v_product.name, v_prev, v_item.quantity
        USING ERRCODE = 'P0001';
    END IF;

    v_line_discount := round(COALESCE(v_item.discount_amount, 0), 2);
    v_line_total := round(v_item.quantity * v_product.selling_price - v_line_discount, 2);
    IF v_line_total < 0 THEN
      RAISE EXCEPTION 'line discount exceeds line value for %', v_product.name
        USING ERRCODE = '22023';
    END IF;

    v_subtotal := v_subtotal + v_line_total;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'product_id', v_product.id,
      'product_name', v_product.name,
      'quantity', v_item.quantity,
      'unit_price', v_product.selling_price,
      'discount_amount', v_line_discount,
      'total_price', v_line_total,
      'previous_quantity', v_prev,
      'new_quantity', v_new));
  END LOOP;

  RETURN jsonb_build_object('subtotal', v_subtotal, 'lines', v_lines);
END;
$$;

REVOKE ALL ON FUNCTION private.price_sale_lines(uuid, jsonb, boolean)
  FROM PUBLIC, anon, authenticated;

COMMIT;


-- ====================================================================================
-- 012_rpc_sale_lines.sql
-- ====================================================================================
-- Run after 012_rpc_price_sale_lines.sql.
-- Persists priced sale lines: inserts sale_items, applies the stock delta that
-- the pricing pass computed, and writes one stock_movement per line.
BEGIN;

CREATE OR REPLACE FUNCTION private.persist_sale_lines(
  p_store_id uuid,
  p_sale_id uuid,
  p_lines jsonb,
  p_actor uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_line record;
  v_updated integer;
BEGIN
  PERFORM set_config('ksm.allow_stock_change', 'on', true);

  FOR v_line IN
    SELECT (l->>'product_id')::uuid AS product_id,
           (l->>'product_name')::text AS product_name,
           (l->>'quantity')::numeric AS quantity,
           (l->>'unit_price')::numeric AS unit_price,
           (l->>'discount_amount')::numeric AS discount_amount,
           (l->>'total_price')::numeric AS total_price,
           (l->>'previous_quantity')::numeric AS previous_quantity,
           (l->>'new_quantity')::numeric AS new_quantity
      FROM jsonb_array_elements(p_lines) l
  LOOP
    INSERT INTO public.sale_items
      (store_id, sale_id, product_id, product_name, quantity, unit_price,
       discount_amount, tax_amount, total_price)
    VALUES
      (p_store_id, p_sale_id, v_line.product_id, v_line.product_name, v_line.quantity,
       v_line.unit_price, v_line.discount_amount, 0, v_line.total_price);

    -- Compare-and-set: if another transaction already moved this product
    -- between pricing and persistence, abort instead of overwriting.
    UPDATE public.products
       SET stock_quantity = v_line.new_quantity
     WHERE id = v_line.product_id
       AND store_id = p_store_id
       AND stock_quantity = v_line.previous_quantity;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated <> 1 THEN
      RAISE EXCEPTION 'stock changed concurrently for product %; retry the sale',
        v_line.product_id USING ERRCODE = '40001';
    END IF;

    INSERT INTO public.stock_movements
      (store_id, product_id, movement_type, quantity, previous_quantity, new_quantity,
       reference_id, reference_type, created_by)
    VALUES
      (p_store_id, v_line.product_id, 'sale', -v_line.quantity,
       v_line.previous_quantity, v_line.new_quantity, p_sale_id, 'sale', p_actor);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION private.persist_sale_lines(uuid, uuid, jsonb, uuid)
  FROM PUBLIC, anon, authenticated;

COMMIT;


-- ====================================================================================
-- 013_rpc_write_sale_payments.sql
-- ====================================================================================
-- Run after 011_rpc_sale_payment_helper.sql.
-- Inserts payment rows for a non-credit sale. Assumes validate_sale_payments()
-- already returned p_amount_paid.
BEGIN;

CREATE OR REPLACE FUNCTION private.write_sale_payments(
  p_store_id uuid,
  p_sale_id uuid,
  p_method public.payment_method,
  p_payments jsonb,
  p_amount_paid numeric,
  p_actor uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_payment jsonb;
BEGIN
  IF p_method = 'credit' OR COALESCE(p_amount_paid, 0) = 0 THEN
    RETURN;
  END IF;

  IF p_method = 'mixed' THEN
    FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
      INSERT INTO public.payments
        (store_id, sale_id, amount, payment_method, transaction_reference, created_by)
      VALUES
        (p_store_id, p_sale_id, round((v_payment->>'amount')::numeric, 2),
         (v_payment->>'method')::public.payment_method,
         NULLIF(btrim(COALESCE(v_payment->>'reference', '')), ''), p_actor);
    END LOOP;
    RETURN;
  END IF;

  INSERT INTO public.payments
    (store_id, sale_id, amount, payment_method, created_by)
  VALUES
    (p_store_id, p_sale_id, p_amount_paid, p_method, p_actor);
END;
$$;

REVOKE ALL ON FUNCTION private.write_sale_payments(uuid, uuid, public.payment_method, jsonb, numeric, uuid)
  FROM PUBLIC, anon, authenticated;

COMMIT;


-- ====================================================================================
-- 014_rpc_credit_sale_helper.sql
-- ====================================================================================
-- Run after 013_rpc_write_sale_payments.sql.
-- Writes the customer ledger entry for a credit sale and enforces the credit
-- limit. The apply_customer_ledger trigger maintains customers.current_balance,
-- so this function only appends the ledger row and reads the new balance back.
BEGIN;

CREATE OR REPLACE FUNCTION private.apply_credit_sale(
  p_store_id uuid,
  p_sale_id uuid,
  p_customer_id uuid,
  p_total numeric,
  p_invoice text,
  p_credit_limit numeric,
  p_customer_name text,
  p_actor uuid
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_balance numeric(12,2);
BEGIN
  INSERT INTO public.customer_transactions
    (store_id, customer_id, transaction_type, amount, reference_id, reference_type,
     description, created_by)
  VALUES
    (p_store_id, p_customer_id, 'credit_sale', p_total, p_sale_id, 'sale',
     'Credit sale ' || p_invoice, p_actor);

  SELECT current_balance INTO v_balance
    FROM public.customers
   WHERE id = p_customer_id;

  IF p_credit_limit > 0 AND v_balance > p_credit_limit THEN
    RAISE EXCEPTION 'credit limit exceeded for % (limit %, would be %)',
      p_customer_name, p_credit_limit, v_balance
      USING ERRCODE = 'P0001';
  END IF;

  RETURN v_balance;
END;
$$;

REVOKE ALL ON FUNCTION private.apply_credit_sale(uuid, uuid, uuid, numeric, text, numeric, text, uuid)
  FROM PUBLIC, anon, authenticated;

COMMIT;


-- ====================================================================================
-- 015_rpc_create_sale.sql
-- ====================================================================================
-- Run after 014_rpc_credit_sale_helper.sql.
-- create_sale(): atomic checkout. See README for the full contract.
BEGIN;

CREATE OR REPLACE FUNCTION public.create_sale(
  p_store_id uuid,
  p_items jsonb,
  p_payment_method public.payment_method,
  p_customer_id uuid DEFAULT NULL,
  p_discount_amount numeric DEFAULT 0,
  p_tax_amount numeric DEFAULT 0,
  p_notes text DEFAULT NULL,
  p_payments jsonb DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_result jsonb;
  v_allow_negative boolean;
  v_customer public.customers;
  v_priced jsonb;
  v_subtotal numeric(12,2);
  v_discount numeric(12,2) := round(COALESCE(p_discount_amount, 0), 2);
  v_tax numeric(12,2) := round(COALESCE(p_tax_amount, 0), 2);
  v_total numeric(12,2);
  v_paid numeric(12,2) := 0;
  v_outstanding numeric(12,2) := 0;
  v_status public.payment_status;
  v_sale_id uuid;
  v_invoice text;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'cashier');

  -- Idempotency: a repeated request returns the original result untouched.
  IF p_request_id IS NOT NULL THEN
    SELECT r.result INTO v_result FROM public.rpc_requests r
     WHERE r.store_id = p_store_id AND r.request_id = p_request_id;
    IF v_result IS NOT NULL THEN
      RETURN v_result;
    END IF;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'at least one sale item is required' USING ERRCODE = '22023';
  END IF;
  IF v_discount < 0 OR v_tax < 0 THEN
    RAISE EXCEPTION 'discount and tax cannot be negative' USING ERRCODE = '22023';
  END IF;

  SELECT allow_negative_stock INTO v_allow_negative
    FROM public.store_settings WHERE store_id = p_store_id;

  -- Serialise concurrent checkouts for this store.
  PERFORM private.lock_store(p_store_id);

  IF p_customer_id IS NOT NULL THEN
    SELECT * INTO v_customer FROM public.customers
     WHERE id = p_customer_id AND store_id = p_store_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'customer % not found in store %', p_customer_id, p_store_id
        USING ERRCODE = '23503';
    END IF;
  END IF;

  IF p_payment_method = 'credit' AND p_customer_id IS NULL THEN
    RAISE EXCEPTION 'a credit sale requires a customer' USING ERRCODE = '22023';
  END IF;

  -- Price every line from the catalogue under row locks.
  v_priced := private.price_sale_lines(p_store_id, p_items, v_allow_negative);
  v_subtotal := (v_priced->>'subtotal')::numeric(12,2);
  v_total := round(v_subtotal - v_discount + v_tax, 2);
  IF v_total < 0 THEN
    RAISE EXCEPTION 'sale total cannot be negative' USING ERRCODE = '22023';
  END IF;

  IF p_payment_method = 'credit' THEN
    v_paid := 0;
  ELSE
    v_paid := private.validate_sale_payments(p_payment_method, v_total, p_payments);
  END IF;

  -- Anything not settled now becomes customer credit, so it must have an owner.
  v_outstanding := round(v_total - v_paid, 2);
  v_status := CASE WHEN v_outstanding = 0 THEN 'paid'
                   WHEN v_paid = 0 THEN 'pending'
                   ELSE 'partial' END;

  IF v_outstanding > 0 AND p_customer_id IS NULL THEN
    RAISE EXCEPTION 'an unpaid balance requires a customer' USING ERRCODE = '22023';
  END IF;

  v_invoice := private.next_document_number(p_store_id, 'sale');

  INSERT INTO public.sales
    (store_id, customer_id, invoice_number, subtotal, discount_amount, tax_amount,
     total_amount, payment_method, payment_status, notes, created_by)
  VALUES
    (p_store_id, p_customer_id, v_invoice, v_subtotal, v_discount, v_tax,
     v_total, p_payment_method, v_status, p_notes, v_actor)
  RETURNING id INTO v_sale_id;

  -- Apply the stock deltas and write sale_items + stock_movements.
  PERFORM private.persist_sale_lines(p_store_id, v_sale_id, v_priced->'lines', v_actor);

  -- Record money received (no-op for credit sales).
  PERFORM private.write_sale_payments(p_store_id, v_sale_id, p_payment_method,
                                      p_payments, v_paid, v_actor);

  -- Whatever was not settled becomes a customer ledger debt.
  IF v_outstanding > 0 THEN
    PERFORM private.apply_credit_sale(p_store_id, v_sale_id, p_customer_id, v_outstanding,
                                      v_invoice, v_customer.credit_limit,
                                      v_customer.name, v_actor);
  END IF;

  PERFORM private.audit(p_store_id, 'sale.created', 'sales', v_sale_id, NULL,
    jsonb_build_object('invoice_number', v_invoice, 'total_amount', v_total,
                       'payment_method', p_payment_method, 'payment_status', v_status));

  v_result := jsonb_build_object(
    'sale_id', v_sale_id,
    'invoice_number', v_invoice,
    'subtotal', v_subtotal,
    'discount_amount', v_discount,
    'tax_amount', v_tax,
    'total_amount', v_total,
    'payment_status', v_status,
    'amount_paid', v_paid);

  IF p_request_id IS NOT NULL THEN
    INSERT INTO public.rpc_requests (store_id, request_id, operation, actor_id, payload, result)
    VALUES (p_store_id, p_request_id, 'create_sale', v_actor, p_items, v_result)
    ON CONFLICT (store_id, request_id) DO NOTHING;
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.create_sale(uuid, jsonb, public.payment_method, uuid, numeric, numeric, text, jsonb, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sale(uuid, jsonb, public.payment_method, uuid, numeric, numeric, text, jsonb, uuid)
  TO authenticated;

COMMIT;


-- ====================================================================================
-- 016_rpc_create_purchase.sql
-- ====================================================================================
-- Run after 015_rpc_create_sale.sql.
-- create_purchase(): receive stock from a supplier. Unit costs come from the
-- caller, but every derived total is recomputed server-side, stock is locked,
-- and one stock_movement is written per line. Retries are idempotent.
BEGIN;

CREATE OR REPLACE FUNCTION public.create_purchase(
  p_store_id uuid,
  p_items jsonb,
  p_supplier_id uuid DEFAULT NULL,
  p_invoice_number text DEFAULT NULL,
  p_payment_status public.payment_status DEFAULT 'paid',
  p_tax_amount numeric DEFAULT 0,
  p_discount_amount numeric DEFAULT 0,
  p_notes text DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_result jsonb;
  v_item record;
  v_product public.products;
  v_prev numeric(12,3);
  v_new numeric(12,3);
  v_unit_cost numeric(12,2);
  v_total_cost numeric(12,2);
  v_subtotal numeric(12,2) := 0;
  v_tax numeric(12,2) := round(COALESCE(p_tax_amount, 0), 2);
  v_discount numeric(12,2) := round(COALESCE(p_discount_amount, 0), 2);
  v_total numeric(12,2);
  v_purchase_id uuid;
  v_number text;
  v_new_cost numeric(12,2);
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'manager');

  IF p_request_id IS NOT NULL THEN
    SELECT r.result INTO v_result FROM public.rpc_requests r
     WHERE r.store_id = p_store_id AND r.request_id = p_request_id;
    IF v_result IS NOT NULL THEN
      RETURN v_result;
    END IF;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'at least one purchase item is required' USING ERRCODE = '22023';
  END IF;
  IF v_tax < 0 OR v_discount < 0 THEN
    RAISE EXCEPTION 'tax and discount cannot be negative' USING ERRCODE = '22023';
  END IF;

  PERFORM private.lock_store(p_store_id);

  IF p_supplier_id IS NOT NULL THEN
    PERFORM 1 FROM public.suppliers s
     WHERE s.id = p_supplier_id AND s.store_id = p_store_id AND s.deleted_at IS NULL;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'supplier % not found in store %', p_supplier_id, p_store_id
        USING ERRCODE = '23503';
    END IF;
  END IF;

  IF p_payment_status IS NULL THEN
    RAISE EXCEPTION 'payment status is required' USING ERRCODE = '22023';
  END IF;

  -- Price the lines first so the header can be inserted with final totals.
  -- ORDER BY product_id gives a deterministic lock order.
  -- Declared as pg_temp.<name> on purpose: search_path is pinned to
  -- pg_catalog, public inside this SECURITY DEFINER function, so an
  -- unqualified name would be ambiguous.
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.ksm_purchase_lines (
    product_id uuid, quantity numeric(12,3), unit_cost numeric(12,2),
    total_cost numeric(12,2), previous_quantity numeric(12,3), new_quantity numeric(12,3)
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.ksm_purchase_lines;

  FOR v_item IN
    SELECT (e->>'product_id')::uuid AS product_id,
           SUM((e->>'quantity')::numeric) AS quantity,
           MAX((e->>'unit_cost')::numeric) AS unit_cost
      FROM jsonb_array_elements(p_items) e
     GROUP BY (e->>'product_id')::uuid
     ORDER BY (e->>'product_id')::uuid
  LOOP
    IF v_item.product_id IS NULL OR v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'every purchase item needs a product_id and a positive quantity'
        USING ERRCODE = '22023';
    END IF;
    IF v_item.unit_cost IS NULL OR v_item.unit_cost < 0 THEN
      RAISE EXCEPTION 'unit cost cannot be negative' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_product FROM public.products
     WHERE id = v_item.product_id AND store_id = p_store_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'product % not found in store %', v_item.product_id, p_store_id
        USING ERRCODE = '23503';
    END IF;

    v_unit_cost := round(v_item.unit_cost, 2);
    v_total_cost := round(v_item.quantity * v_unit_cost, 2);
    v_subtotal := v_subtotal + v_total_cost;
    v_prev := v_product.stock_quantity;
    v_new := round(v_prev + v_item.quantity, 3);

    INSERT INTO pg_temp.ksm_purchase_lines VALUES
      (v_product.id, v_item.quantity, v_unit_cost, v_total_cost, v_prev, v_new);
  END LOOP;

  v_total := round(v_subtotal + v_tax - v_discount, 2);
  IF v_total < 0 THEN
    RAISE EXCEPTION 'purchase total cannot be negative' USING ERRCODE = '22023';
  END IF;

  v_number := COALESCE(NULLIF(btrim(p_invoice_number), ''),
                       private.next_document_number(p_store_id, 'purchase'));

  INSERT INTO public.purchases
    (store_id, supplier_id, invoice_number, subtotal, tax_amount, discount_amount,
     total_amount, payment_status, notes, created_by)
  VALUES
    (p_store_id, p_supplier_id, v_number, v_subtotal, v_tax, v_discount,
     v_total, p_payment_status, p_notes, v_actor)
  RETURNING id INTO v_purchase_id;

  -- Persist line items, increase stock and log movements.
  PERFORM set_config('ksm.allow_stock_change', 'on', true);

  FOR v_item IN
    SELECT product_id, quantity, unit_cost, total_cost, previous_quantity, new_quantity
      FROM pg_temp.ksm_purchase_lines
  LOOP
    INSERT INTO public.purchase_items
      (store_id, purchase_id, product_id, quantity, unit_cost, total_cost)
    VALUES
      (p_store_id, v_purchase_id, v_item.product_id, v_item.quantity,
       v_item.unit_cost, v_item.total_cost);

    UPDATE public.products
       SET stock_quantity = v_item.new_quantity
     WHERE id = v_item.product_id AND store_id = p_store_id;

    INSERT INTO public.stock_movements
      (store_id, product_id, movement_type, quantity, previous_quantity, new_quantity,
       reference_id, reference_type, created_by)
    VALUES
      (p_store_id, v_item.product_id, 'purchase', v_item.quantity,
       v_item.previous_quantity, v_item.new_quantity, v_purchase_id, 'purchase', v_actor);

    -- Keep cost_price current: weighted average of the stock on hand and the
    -- incoming quantity, so profit estimates stay meaningful.
    SELECT cost_price INTO v_new_cost FROM public.products WHERE id = v_item.product_id;
    IF v_item.previous_quantity > 0 THEN
      v_new_cost := round(
        ((v_item.previous_quantity * v_new_cost) + (v_item.quantity * v_item.unit_cost))
        / (v_item.previous_quantity + v_item.quantity), 2);
    ELSE
      v_new_cost := v_item.unit_cost;
    END IF;

    UPDATE public.products
       SET cost_price = v_new_cost
     WHERE id = v_item.product_id;
  END LOOP;

  PERFORM private.audit(p_store_id, 'purchase.created', 'purchases', v_purchase_id, NULL,
    jsonb_build_object('invoice_number', v_number, 'total_amount', v_total,
                       'payment_status', p_payment_status, 'supplier_id', p_supplier_id));

  v_result := jsonb_build_object(
    'purchase_id', v_purchase_id,
    'invoice_number', v_number,
    'subtotal', v_subtotal,
    'tax_amount', v_tax,
    'discount_amount', v_discount,
    'total_amount', v_total,
    'payment_status', p_payment_status);

  IF p_request_id IS NOT NULL THEN
    INSERT INTO public.rpc_requests (store_id, request_id, operation, actor_id, payload, result)
    VALUES (p_store_id, p_request_id, 'create_purchase', v_actor, p_items, v_result)
    ON CONFLICT (store_id, request_id) DO NOTHING;
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.create_purchase(uuid, jsonb, uuid, text, public.payment_status, numeric, numeric, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_purchase(uuid, jsonb, uuid, text, public.payment_status, numeric, numeric, text, uuid)
  TO authenticated;

COMMIT;


-- ====================================================================================
-- 017_rpc_record_customer_payment.sql
-- ====================================================================================
-- Run after 016_rpc_create_purchase.sql.
-- record_customer_payment(): settle part or all of a customer's outstanding
-- balance (udhaar). The ledger row drives the balance through the
-- apply_customer_ledger trigger, so the balance can never drift from history.
-- Owners and managers may always do this; cashiers only when the store has
-- enabled cashier_can_record_payments.
BEGIN;

CREATE OR REPLACE FUNCTION public.record_customer_payment(
  p_store_id uuid,
  p_customer_id uuid,
  p_amount numeric,
  p_payment_method public.payment_method DEFAULT 'cash',
  p_notes text DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_role public.user_role;
  v_result jsonb;
  v_customer public.customers;
  v_amount numeric(12,2);
  v_transaction_id uuid;
  v_balance numeric(12,2);
BEGIN
  v_role := private.assert_store_role(p_store_id, 'cashier');

  IF v_role = 'cashier' THEN
    IF NOT COALESCE((SELECT cashier_can_record_payments
                       FROM public.store_settings WHERE store_id = p_store_id), false) THEN
      RAISE EXCEPTION 'cashiers are not permitted to record payments in store %', p_store_id
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_request_id IS NOT NULL THEN
    SELECT r.result INTO v_result FROM public.rpc_requests r
     WHERE r.store_id = p_store_id AND r.request_id = p_request_id;
    IF v_result IS NOT NULL THEN
      RETURN v_result;
    END IF;
  END IF;

  IF p_payment_method IS NULL OR p_payment_method = 'credit' THEN
    RAISE EXCEPTION 'a payment method other than credit is required'
      USING ERRCODE = '22023';
  END IF;

  v_amount := round(COALESCE(p_amount, 0), 2);
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'payment amount must be greater than zero' USING ERRCODE = '22023';
  END IF;

  -- Lock the customer row so two concurrent payments cannot both read the same
  -- starting balance and overpay.
  SELECT * INTO v_customer
    FROM public.customers
   WHERE id = p_customer_id AND store_id = p_store_id AND deleted_at IS NULL
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'customer % not found in store %', p_customer_id, p_store_id
      USING ERRCODE = '23503';
  END IF;

  IF v_amount > v_customer.current_balance THEN
    RAISE EXCEPTION 'payment (%) exceeds the outstanding balance (%)',
      v_amount, v_customer.current_balance
      USING ERRCODE = 'P0001',
            HINT = 'Record at most the outstanding amount, or add an adjustment first.';
  END IF;

  -- Negative amount reduces the outstanding balance.
  INSERT INTO public.customer_transactions
    (store_id, customer_id, transaction_type, amount, reference_type,
     description, created_by)
  VALUES
    (p_store_id, p_customer_id, 'payment', -v_amount, 'credit_payment',
     COALESCE(NULLIF(btrim(p_notes), ''), 'Payment received via ' || p_payment_method),
     v_actor)
  RETURNING id INTO v_transaction_id;

  INSERT INTO public.credit_payments
    (store_id, customer_id, customer_transaction_id, amount, payment_method,
     notes, created_by)
  VALUES
    (p_store_id, p_customer_id, v_transaction_id, v_amount, p_payment_method,
     p_notes, v_actor);

  SELECT current_balance INTO v_balance FROM public.customers WHERE id = p_customer_id;

  PERFORM private.audit(p_store_id, 'customer_payment.recorded', 'customers', p_customer_id,
    jsonb_build_object('current_balance', v_customer.current_balance),
    jsonb_build_object('current_balance', v_balance, 'amount', v_amount,
                       'payment_method', p_payment_method));

  v_result := jsonb_build_object(
    'customer_id', p_customer_id,
    'amount', v_amount,
    'previous_balance', v_customer.current_balance,
    'current_balance', v_balance,
    'customer_transaction_id', v_transaction_id);

  IF p_request_id IS NOT NULL THEN
    INSERT INTO public.rpc_requests (store_id, request_id, operation, actor_id, payload, result)
    VALUES (p_store_id, p_request_id, 'record_customer_payment', v_actor,
            jsonb_build_object('customer_id', p_customer_id, 'amount', v_amount),
            v_result)
    ON CONFLICT (store_id, request_id) DO NOTHING;
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.record_customer_payment(uuid, uuid, numeric, public.payment_method, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_customer_payment(uuid, uuid, numeric, public.payment_method, text, uuid)
  TO authenticated;

COMMIT;


-- ====================================================================================
-- 018_rpc_cancel_sale.sql
-- ====================================================================================
-- Run after 017_rpc_record_customer_payment.sql.
-- cancel_sale(): voids a bill without deleting history. Line items stay intact
-- for audit; instead we return stock (sale_return movements), reverse any
-- customer credit, and keep received payments on record. Managers and owners
-- only, and every cancellation needs a reason.
BEGIN;

CREATE OR REPLACE FUNCTION public.cancel_sale(
  p_store_id uuid,
  p_sale_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_sale public.sales;
  v_item record;
  v_prev numeric(12,3);
  v_new numeric(12,3);
  v_credit numeric(12,2);
  v_balance numeric(12,2);
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'manager');

  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'a cancellation reason of at least 3 characters is required'
      USING ERRCODE = '22023';
  END IF;

  PERFORM private.lock_store(p_store_id);

  SELECT * INTO v_sale FROM public.sales
   WHERE id = p_sale_id AND store_id = p_store_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sale % not found in store %', p_sale_id, p_store_id
      USING ERRCODE = '23503';
  END IF;
  IF v_sale.cancelled_at IS NOT NULL THEN
    RAISE EXCEPTION 'sale % is already cancelled', v_sale.invoice_number
      USING ERRCODE = '22023';
  END IF;

  -- Return every sold quantity to stock and log a sale_return movement.
  PERFORM set_config('ksm.allow_stock_change', 'on', true);

  FOR v_item IN
    SELECT product_id, quantity FROM public.sale_items
     WHERE sale_id = p_sale_id
     ORDER BY product_id
  LOOP
    SELECT stock_quantity INTO v_prev FROM public.products
     WHERE id = v_item.product_id AND store_id = p_store_id
     FOR UPDATE;

    v_new := round(v_prev + v_item.quantity, 3);

    UPDATE public.products SET stock_quantity = v_new WHERE id = v_item.product_id;

    INSERT INTO public.stock_movements
      (store_id, product_id, movement_type, quantity, previous_quantity, new_quantity,
       reference_id, reference_type, notes, created_by)
    VALUES
      (p_store_id, v_item.product_id, 'sale_return', v_item.quantity, v_prev, v_new,
       p_sale_id, 'sale', 'Cancellation: ' || btrim(p_reason), v_actor);
  END LOOP;

  -- Reverse the credit this bill created, if any.
  SELECT COALESCE(SUM(amount), 0) INTO v_credit
    FROM public.customer_transactions
   WHERE reference_id = p_sale_id
     AND reference_type = 'sale'
     AND transaction_type = 'credit_sale';

  IF v_credit > 0 THEN
    INSERT INTO public.customer_transactions
      (store_id, customer_id, transaction_type, amount, reference_id, reference_type,
       description, created_by)
    VALUES
      (p_store_id, v_sale.customer_id, 'refund', -v_credit, p_sale_id, 'sale',
       'Cancellation of ' || v_sale.invoice_number || ': ' || btrim(p_reason), v_actor);

    SELECT current_balance INTO v_balance FROM public.customers WHERE id = v_sale.customer_id;
  END IF;

  -- Mark the sale cancelled. The guard_sale_change trigger permits exactly this
  -- bookkeeping update and nothing else.
  PERFORM set_config('ksm.allow_sale_cancel', 'on', true);
  UPDATE public.sales
     SET cancelled_at = now(),
         cancelled_by = v_actor,
         cancel_reason = btrim(p_reason),
         payment_status = CASE WHEN v_credit > 0 THEN 'pending' ELSE payment_status END
   WHERE id = p_sale_id;

  PERFORM private.audit(p_store_id, 'sale.cancelled', 'sales', p_sale_id,
    jsonb_build_object('cancelled_at', v_sale.cancelled_at),
    jsonb_build_object('cancelled_at', now(), 'reason', btrim(p_reason)));

  RETURN jsonb_build_object(
    'sale_id', p_sale_id,
    'invoice_number', v_sale.invoice_number,
    'cancelled', true,
    'reason', btrim(p_reason));
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_sale(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sale(uuid, uuid, text) TO authenticated;

COMMIT;


-- ====================================================================================
-- 019_indexes.sql
-- ====================================================================================
-- Run after 018_rpc_cancel_sale.sql.
-- Index strategy: every index below answers a specific query the application
-- actually issues. Uniqueness is enforced with partial indexes so soft-deleted
-- rows do not block reuse of a name, SKU, barcode or phone number.
BEGIN;

-- ---------------------------------------------------------------------------
-- Store-scoped uniqueness (respects soft deletion)
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX categories_store_name_unique
  ON public.categories (store_id, lower(btrim(name)))
  WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX products_store_sku_unique
  ON public.products (store_id, sku)
  WHERE sku IS NOT NULL AND deleted_at IS NULL;

CREATE UNIQUE INDEX products_store_barcode_unique
  ON public.products (store_id, barcode)
  WHERE barcode IS NOT NULL AND deleted_at IS NULL;

CREATE UNIQUE INDEX customers_store_phone_unique
  ON public.customers (store_id, phone)
  WHERE phone IS NOT NULL AND deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- Tenant scoping (every tenant table is filtered by store_id)
-- ---------------------------------------------------------------------------
CREATE INDEX categories_store_idx ON public.categories (store_id) WHERE deleted_at IS NULL;
CREATE INDEX products_store_idx ON public.products (store_id) WHERE deleted_at IS NULL;
CREATE INDEX suppliers_store_idx ON public.suppliers (store_id) WHERE deleted_at IS NULL;
CREATE INDEX customers_store_idx ON public.customers (store_id) WHERE deleted_at IS NULL;
CREATE INDEX store_members_user_idx ON public.store_members (user_id) WHERE is_active;
CREATE INDEX store_members_store_idx ON public.store_members (store_id);
CREATE INDEX audit_logs_store_created_idx ON public.audit_logs (store_id, created_at DESC);
CREATE INDEX rpc_requests_created_idx ON public.rpc_requests (created_at);

-- ---------------------------------------------------------------------------
-- Product search (billing finds products by name, SKU or barcode)
-- ---------------------------------------------------------------------------
-- Trigram index serves the ILIKE '%term%' name search used by the POS.
CREATE INDEX products_name_trgm_idx
  ON public.products USING gin (name gin_trgm_ops)
  WHERE deleted_at IS NULL;

CREATE INDEX products_store_name_idx
  ON public.products (store_id, name)
  WHERE deleted_at IS NULL AND is_active;

-- Low-stock dashboard query: only rows at or below their threshold.
CREATE INDEX products_low_stock_idx
  ON public.products (store_id, stock_quantity)
  WHERE deleted_at IS NULL AND is_active;

CREATE INDEX products_category_idx ON public.products (category_id) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- Sales and billing
-- ---------------------------------------------------------------------------
-- Sales history is always listed newest first within a store.
CREATE INDEX sales_store_sold_at_idx ON public.sales (store_id, sold_at DESC);
CREATE INDEX sales_customer_idx ON public.sales (store_id, customer_id, sold_at DESC)
  WHERE customer_id IS NOT NULL;
-- Daily report filters by sold_at range and payment method.
CREATE INDEX sales_store_method_sold_at_idx
  ON public.sales (store_id, payment_method, sold_at DESC);

CREATE INDEX sale_items_sale_idx ON public.sale_items (sale_id);
CREATE INDEX sale_items_product_idx ON public.sale_items (store_id, product_id);

CREATE INDEX payments_sale_idx ON public.payments (sale_id);
CREATE INDEX payments_store_paid_at_idx ON public.payments (store_id, paid_at DESC);

-- ---------------------------------------------------------------------------
-- Purchases
-- ---------------------------------------------------------------------------
CREATE INDEX purchases_store_purchased_at_idx ON public.purchases (store_id, purchased_at DESC);
CREATE INDEX purchases_supplier_idx
  ON public.purchases (store_id, supplier_id, purchased_at DESC)
  WHERE supplier_id IS NOT NULL;

CREATE INDEX purchase_items_purchase_idx ON public.purchase_items (purchase_id);
CREATE INDEX purchase_items_product_idx ON public.purchase_items (store_id, product_id);

-- ---------------------------------------------------------------------------
-- Inventory ledger and audit reconstruction
-- ---------------------------------------------------------------------------
-- "History for this product, newest first" is the main inventory query.
CREATE INDEX stock_movements_store_product_created_idx
  ON public.stock_movements (store_id, product_id, created_at DESC);
CREATE INDEX stock_movements_reference_idx
  ON public.stock_movements (reference_id)
  WHERE reference_id IS NOT NULL;

CREATE INDEX inventory_adjustments_product_idx
  ON public.inventory_adjustments (store_id, product_id, created_at DESC);
CREATE INDEX inventory_adjustments_movement_idx
  ON public.inventory_adjustments (stock_movement_id);

-- ---------------------------------------------------------------------------
-- Customer ledger
-- ---------------------------------------------------------------------------
CREATE INDEX customer_transactions_customer_created_idx
  ON public.customer_transactions (store_id, customer_id, created_at DESC);
-- Cancellation and reporting lookups by the originating document.
CREATE INDEX customer_transactions_reference_idx
  ON public.customer_transactions (reference_id)
  WHERE reference_id IS NOT NULL;

CREATE INDEX credit_payments_customer_paid_at_idx
  ON public.credit_payments (store_id, customer_id, paid_at DESC);
CREATE INDEX credit_payments_transaction_idx
  ON public.credit_payments (customer_transaction_id);

-- ---------------------------------------------------------------------------
-- Supplier and customer name search
-- ---------------------------------------------------------------------------
CREATE INDEX suppliers_name_trgm_idx
  ON public.suppliers USING gin (name gin_trgm_ops)
  WHERE deleted_at IS NULL;
CREATE INDEX customers_name_trgm_idx
  ON public.customers USING gin (name gin_trgm_ops)
  WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- Foreign keys without a covering index
-- ---------------------------------------------------------------------------
CREATE INDEX purchases_created_by_idx ON public.purchases (created_by);
CREATE INDEX sales_created_by_idx ON public.sales (created_by);

COMMIT;


-- ====================================================================================
-- 020_views.sql
-- ====================================================================================
-- Run after 019_indexes.sql.
-- Reporting views. Every view is created WITH (security_invoker = true) so the
-- caller's RLS policies are applied to the underlying tables: a view can never
-- be used to read another store's data, and cashiers see only what their role
-- allows. Cancelled sales are excluded from revenue figures.
BEGIN;

-- Daily takings split by settlement method.
CREATE OR REPLACE VIEW public.daily_sales_summary
WITH (security_invoker = true) AS
SELECT s.store_id,
       (s.sold_at AT TIME ZONE COALESCE(st.timezone, 'Asia/Kolkata'))::date AS sale_date,
       COUNT(*) AS transaction_count,
       SUM(s.total_amount) AS total_sales,
       SUM(s.discount_amount) AS total_discount,
       SUM(s.tax_amount) AS total_tax,
       COALESCE(SUM(s.total_amount) FILTER (WHERE s.payment_method = 'cash'), 0) AS cash_sales,
       COALESCE(SUM(s.total_amount) FILTER (WHERE s.payment_method = 'upi'), 0) AS upi_sales,
       COALESCE(SUM(s.total_amount) FILTER (WHERE s.payment_method = 'card'), 0) AS card_sales,
       COALESCE(SUM(s.total_amount) FILTER (WHERE s.payment_method = 'credit'), 0) AS credit_sales,
       COALESCE(SUM(s.total_amount) FILTER (WHERE s.payment_method = 'mixed'), 0) AS mixed_sales
  FROM public.sales s
  LEFT JOIN public.stores st ON st.id = s.store_id
 WHERE s.cancelled_at IS NULL
 GROUP BY s.store_id,
          (s.sold_at AT TIME ZONE COALESCE(st.timezone, 'Asia/Kolkata'))::date;

-- Which products actually sell, and how much they earn.
CREATE OR REPLACE VIEW public.product_sales_summary
WITH (security_invoker = true) AS
SELECT si.store_id,
       si.product_id,
       max(si.product_name) AS product_name,
       SUM(si.quantity) AS total_quantity_sold,
       SUM(si.total_price) AS total_revenue,
       COUNT(DISTINCT si.sale_id) AS sale_count,
       max(s.sold_at) AS last_sold_at
  FROM public.sale_items si
  JOIN public.sales s ON s.id = si.sale_id
 WHERE s.cancelled_at IS NULL
 GROUP BY si.store_id, si.product_id;

-- Reorder worklist: active products at or below their threshold.
CREATE OR REPLACE VIEW public.low_stock_products
WITH (security_invoker = true) AS
SELECT p.store_id,
       p.id AS product_id,
       p.name AS product_name,
       p.sku,
       p.stock_quantity,
       p.low_stock_threshold,
       p.unit,
       c.name AS category_name,
       (p.low_stock_threshold - p.stock_quantity) AS shortfall
  FROM public.products p
  LEFT JOIN public.categories c ON c.id = p.category_id
 WHERE p.deleted_at IS NULL
   AND p.is_active
   AND p.stock_quantity <= p.low_stock_threshold;

-- Udhaar collection worklist.
CREATE OR REPLACE VIEW public.customer_outstanding_balances
WITH (security_invoker = true) AS
SELECT c.store_id,
       c.id AS customer_id,
       c.name AS customer_name,
       c.phone,
       c.credit_limit,
       c.current_balance,
       CASE WHEN c.credit_limit > 0
            THEN GREATEST(c.credit_limit - c.current_balance, 0)
            ELSE NULL END AS credit_available,
       (SELECT max(t.created_at) FROM public.customer_transactions t
         WHERE t.customer_id = c.id) AS last_transaction_at
  FROM public.customers c
 WHERE c.deleted_at IS NULL
   AND c.is_active
   AND c.current_balance > 0;

-- Stock on hand valued at the current weighted-average cost.
CREATE OR REPLACE VIEW public.inventory_valuation
WITH (security_invoker = true) AS
SELECT p.store_id,
       SUM(p.stock_quantity * p.cost_price) AS stock_value_at_cost,
       SUM(p.stock_quantity * p.selling_price) AS stock_value_at_retail,
       COUNT(*) FILTER (WHERE p.stock_quantity <= p.low_stock_threshold) AS low_stock_count
  FROM public.products p
 WHERE p.deleted_at IS NULL AND p.is_active
 GROUP BY p.store_id;

GRANT SELECT ON public.daily_sales_summary TO authenticated;
GRANT SELECT ON public.product_sales_summary TO authenticated;
GRANT SELECT ON public.low_stock_products TO authenticated;
GRANT SELECT ON public.customer_outstanding_balances TO authenticated;
GRANT SELECT ON public.inventory_valuation TO authenticated;

COMMIT;


-- ====================================================================================
-- 021_seed_data.sql
-- ====================================================================================
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


-- ====================================================================================
-- 022_payment_ceiling.sql
-- ====================================================================================
-- Run after 021_seed_data.sql.
-- Cross-row rule a CHECK constraint cannot express: payments against one sale
-- may never exceed that sale's total.
BEGIN;

CREATE OR REPLACE FUNCTION private.guard_payment_total()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_total numeric(12,2);
  v_cancelled timestamptz;
  v_paid numeric(12,2);
BEGIN
  -- Lock the sale row so two concurrent payments on one bill serialise and
  -- cannot each pass the ceiling check independently.
  SELECT total_amount, cancelled_at
    INTO v_total, v_cancelled
    FROM public.sales
   WHERE id = NEW.sale_id
   FOR UPDATE;

  IF v_total IS NULL THEN
    RAISE EXCEPTION 'sale % does not exist', NEW.sale_id USING ERRCODE = '23503';
  END IF;

  IF v_cancelled IS NOT NULL THEN
    RAISE EXCEPTION 'cannot take a payment for a cancelled sale' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM public.payments
   WHERE sale_id = NEW.sale_id;

  IF v_paid + NEW.amount > v_total THEN
    RAISE EXCEPTION 'payments for sale % would total %, exceeding the sale total %',
      NEW.sale_id, v_paid + NEW.amount, v_total
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER guard_payment_total BEFORE INSERT ON public.payments
  FOR EACH ROW EXECUTE FUNCTION private.guard_payment_total();

REVOKE ALL ON FUNCTION private.guard_payment_total() FROM PUBLIC, anon, authenticated;

COMMIT;


-- ====================================================================================
-- 023_purchase_invoice_unique.sql
-- ====================================================================================
-- Run after 022_payment_ceiling.sql.
-- A supplier invoice number identifies one delivery from one supplier to one
-- store, so re-entering it is almost always a mistake. NULL supplier_id (a
-- walk-in purchase) maps to the all-zero uuid so those are de-duplicated too.
BEGIN;

CREATE UNIQUE INDEX purchases_supplier_invoice_unique
  ON public.purchases (
    store_id,
    COALESCE(supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
    lower(btrim(invoice_number))
  );

COMMIT;


-- ====================================================================================
-- 024_rpc_store_members.sql
-- ====================================================================================
-- Run after 023_purchase_invoice_unique.sql.
-- ============================================================================
-- RPC: store membership administration
--
-- These four functions complete the member-management surface described in
-- docs/04_rpc_reference.md. They were referenced by the documentation and by
-- the setup guide but were never created (the `-- MEMBERS_ANCHOR` marker in
-- 007_rpc_store_and_members.sql was the placeholder).
--
-- Why functions instead of plain PostgREST writes?
--   * store_members has INSERT/UPDATE/DELETE grants for authenticated, but the
--     guard_store_member_change trigger only blocks the dangerous cases. These
--     RPCs add the checks a trigger cannot express: a target user must actually
--     exist in auth.users (no orphan invitations) and a member cannot lock
--     themselves out.
--   * Every change is written to audit_logs with the acting user, which RLS
--     cannot do on its own.
--
-- Security: SECURITY DEFINER with a pinned search_path, caller identity from
-- auth.uid() only, and every store-scoped id re-validated inside the function.
-- ============================================================================
BEGIN;

-- Adds an existing auth user to a store. The user must already have signed up:
-- invitations are out of scope, so an unknown id fails loudly instead of
-- creating a membership nobody can ever claim.
CREATE OR REPLACE FUNCTION public.add_store_member(
  p_store_id uuid,
  p_user_id uuid,
  p_role public.user_role DEFAULT 'cashier'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_member public.store_members;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'owner');

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'a user id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'user % has no account yet; they must sign up first', p_user_id
      USING ERRCODE = '23503',
            HINT = 'Create the user through Supabase Auth, then add them to the store.';
  END IF;

  IF p_role = 'owner' THEN
    RAISE EXCEPTION 'a store cannot have a second owner' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.store_members (store_id, user_id, role, is_active)
  VALUES (p_store_id, p_user_id, p_role, true)
  ON CONFLICT (store_id, user_id) DO UPDATE
    SET role = EXCLUDED.role,
        is_active = true
  RETURNING * INTO v_member;

  PERFORM private.audit(p_store_id, 'store_member.added', 'store_members', v_member.id,
    NULL,
    jsonb_build_object('user_id', p_user_id, 'role', v_member.role,
                       'is_active', v_member.is_active));

  RETURN to_jsonb(v_member);
END;
$$;

-- Changes a member's role. Promoting to owner is refused by design: ownership
-- transfer needs an operator-run migration (see guard_store_member_change).
CREATE OR REPLACE FUNCTION public.set_store_member_role(
  p_store_id uuid,
  p_member_id uuid,
  p_role public.user_role
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_before public.store_members;
  v_after public.store_members;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'owner');

  IF p_role = 'owner' THEN
    RAISE EXCEPTION 'a store cannot have a second owner' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_before FROM public.store_members
   WHERE id = p_member_id AND store_id = p_store_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member % not found in store %', p_member_id, p_store_id
      USING ERRCODE = '23503';
  END IF;

  UPDATE public.store_members
     SET role = p_role
   WHERE id = p_member_id
  RETURNING * INTO v_after;

  PERFORM private.audit(p_store_id, 'store_member.role_changed', 'store_members',
    v_after.id,
    jsonb_build_object('role', v_before.role),
    jsonb_build_object('role', v_after.role, 'user_id', v_after.user_id));

  RETURN to_jsonb(v_after);
END;
$$;

-- Enables or disables a member's access. Disabling is the soft "remove": the
-- membership and its history stay, but every RLS helper stops matching, so the
-- user immediately loses access to the store.
CREATE OR REPLACE FUNCTION public.set_store_member_active(
  p_store_id uuid,
  p_member_id uuid,
  p_is_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_before public.store_members;
  v_after public.store_members;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'owner');

  IF p_is_active IS NULL THEN
    RAISE EXCEPTION 'is_active is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_before FROM public.store_members
   WHERE id = p_member_id AND store_id = p_store_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member % not found in store %', p_member_id, p_store_id
      USING ERRCODE = '23503';
  END IF;

  -- An owner must not be able to switch off their own access and orphan the
  -- store; another owner would have to do it, and there is only ever one.
  IF NOT p_is_active AND v_before.user_id = v_actor THEN
    RAISE EXCEPTION 'you cannot deactivate your own membership' USING ERRCODE = '42501';
  END IF;

  UPDATE public.store_members
     SET is_active = p_is_active
   WHERE id = p_member_id
  RETURNING * INTO v_after;

  PERFORM private.audit(p_store_id, 'store_member.access_changed', 'store_members',
    v_after.id,
    jsonb_build_object('is_active', v_before.is_active),
    jsonb_build_object('is_active', v_after.is_active, 'user_id', v_after.user_id));

  RETURN to_jsonb(v_after);
END;
$$;

-- Hard-removes a membership. Refuses to remove the owner and refuses to remove
-- the caller, mirroring the store_members_delete_owner RLS policy so the RPC
-- cannot be used to bypass it.
CREATE OR REPLACE FUNCTION public.remove_store_member(
  p_store_id uuid,
  p_member_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_member public.store_members;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'owner');

  SELECT * INTO v_member FROM public.store_members
   WHERE id = p_member_id AND store_id = p_store_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member % not found in store %', p_member_id, p_store_id
      USING ERRCODE = '23503';
  END IF;

  IF v_member.role = 'owner' THEN
    RAISE EXCEPTION 'the store owner membership cannot be removed' USING ERRCODE = '42501';
  END IF;

  IF v_member.user_id = v_actor THEN
    RAISE EXCEPTION 'you cannot remove your own membership' USING ERRCODE = '42501',
      HINT = 'Ask another owner to remove you.';
  END IF;

  DELETE FROM public.store_members WHERE id = p_member_id;

  PERFORM private.audit(p_store_id, 'store_member.removed', 'store_members', p_member_id,
    jsonb_build_object('user_id', v_member.user_id, 'role', v_member.role),
    NULL);

  RETURN jsonb_build_object('member_id', p_member_id, 'removed', true);
END;
$$;

REVOKE ALL ON FUNCTION public.add_store_member(uuid, uuid, public.user_role)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_store_member_role(uuid, uuid, public.user_role)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_store_member_active(uuid, uuid, boolean)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_store_member(uuid, uuid)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.add_store_member(uuid, uuid, public.user_role)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_store_member_role(uuid, uuid, public.user_role)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_store_member_active(uuid, uuid, boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_store_member(uuid, uuid)
  TO authenticated;

COMMIT;

-- ====================================================================================
-- 026_fix_customer_balance_domain.sql
-- ====================================================================================
-- Run after 024_rpc_store_members.sql.
-- Fixes T08.14: cancel_sale() of a credit sale whose reversal would overdraw
-- the customer balance must raise P0001, but it was hitting 23514 instead.
--
-- Root cause: customers.current_balance uses the money_amount domain whose
-- CHECK (VALUE >= 0) fires DURING the UPDATE in apply_customer_ledger's
-- AFTER INSERT trigger â€” before the trigger's own IF v_balance < 0 guard can
-- raise P0001.  The domain and the trigger are fighting over the same invariant.
--
-- Fix: widen the column to plain numeric(12,2) so the trigger owns the
-- non-negative rule and raises the expected SQLSTATE.  Direct edits remain
-- blocked by the guard_customer_balance trigger (only RPCs with the
-- ksm.allow_balance_change bypass flag can touch current_balance), and every
-- balance change still flows through a customer_transactions row whose
-- append-only trigger enforces the check atomically.
BEGIN;

-- The customer_outstanding_balances view (020_views.sql) depends on the
-- current_balance column, so PostgreSQL refuses the ALTER COLUMN ... TYPE
-- while the view exists. Drop and recreate it inside the same transaction:
-- the column type is unchanged conceptually (still a non-negative amount),
-- just freed from the money_amount domain CHECK that fired too early.
DROP VIEW IF EXISTS public.customer_outstanding_balances;

ALTER TABLE public.customers
  ALTER COLUMN current_balance TYPE numeric(12,2),
  ALTER COLUMN current_balance SET DEFAULT 0,
  ALTER COLUMN current_balance SET NOT NULL;

CREATE OR REPLACE FUNCTION private.balance_non_negative_check()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.current_balance < 0 THEN
    RAISE EXCEPTION 'customer current_balance must not be negative'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER balance_non_negative_check
  BEFORE UPDATE OF current_balance ON public.customers
  FOR EACH ROW
  WHEN (current_setting('ksm.allow_balance_change', true) IS DISTINCT FROM 'on')
  EXECUTE FUNCTION private.balance_non_negative_check();

-- Restore the customer_outstanding_balances reporting view that was dropped
-- above so its definition matches the rebuilt column type.
CREATE OR REPLACE VIEW public.customer_outstanding_balances
WITH (security_invoker = true) AS
SELECT c.store_id,
       c.id AS customer_id,
       c.name AS customer_name,
       c.phone,
       c.credit_limit,
       c.current_balance,
       CASE WHEN c.credit_limit > 0
            THEN GREATEST(c.credit_limit - c.current_balance, 0)
            ELSE NULL END AS credit_available,
       (SELECT max(t.created_at) FROM public.customer_transactions t
         WHERE t.customer_id = c.id) AS last_transaction_at
  FROM public.customers c
 WHERE c.deleted_at IS NULL
   AND c.is_active
   AND c.current_balance > 0;

GRANT SELECT ON public.customer_outstanding_balances TO authenticated;

COMMIT;


-- ====================================================================================
-- 027_backend_users.sql
-- ====================================================================================
-- Backend API users for the Node/Express REST API (backend/).
-- These accounts are independent of Supabase auth.users: the backend hashes
-- passwords with bcrypt and issues its own JWTs (see backend/src/routes/auth.js).
BEGIN;

CREATE TABLE public.backend_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  full_name text NOT NULL,
  password_hash text NOT NULL,
  role public.user_role NOT NULL DEFAULT 'cashier',
  avatar_url text,
  store_id uuid REFERENCES public.stores(id) ON DELETE SET NULL,
  is_active boolean NOT NULL DEFAULT true,
  last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT backend_users_email_key UNIQUE (email)
);

CREATE INDEX backend_users_store_id_idx ON public.backend_users (store_id);

-- RLS with no policies: only the backend's direct PostgreSQL connection
-- (table owner / service role) can read password_hash; PostgREST anon and
-- authenticated roles get nothing.
ALTER TABLE public.backend_users ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.backend_users
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

COMMIT;

-- ====================================================================================
-- 028_backend_auth_bridge.sql
-- ====================================================================================
-- Run after 027_backend_users.sql.
-- Bridge between backend/ REST auth and the Supabase-shaped authorization the
-- business RPCs expect:
--   * backend_users is authenticated by the Express API (bcrypt + JWT);
--   * create_sale / create_store / record_customer_payment ... derive the
--     caller from auth.uid() (i.e. request.jwt.claims set by the backend's
--     withAuth transaction) and require store_members membership, whose FK
--     points at auth.users.
-- So every backend user gets a shadow auth.users row (same id, email, no
-- GoTrue password - PostgREST/GoTrue are never involved; only the backend's
-- direct PostgreSQL connection and these triggers touch it). Membership and
-- store bootstrap rows are created by the existing triggers (bootstrap_store)
-- when the backend calls create_store with the user's claims.
BEGIN;

CREATE OR REPLACE FUNCTION private.sync_backend_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  INSERT INTO auth.users (id, email, aud, role, raw_app_meta_data, raw_user_meta_data)
  VALUES (
    NEW.id,
    NEW.email,
    'authenticated',
    'authenticated',
    jsonb_build_object('provider', 'backend', 'providers', jsonb_build_array('backend')),
    jsonb_build_object('full_name', NEW.full_name, 'backend_user', true)
  )
  ON CONFLICT (id) DO UPDATE
    SET email = EXCLUDED.email,
        raw_user_meta_data = EXCLUDED.raw_user_meta_data,
        updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER sync_backend_auth_user
AFTER INSERT OR UPDATE OF email, full_name ON public.backend_users
FOR EACH ROW EXECUTE FUNCTION private.sync_backend_auth_user();

-- Backfill accounts created before this migration existed.
INSERT INTO auth.users (id, email, aud, role, raw_app_meta_data, raw_user_meta_data)
SELECT id,
       email,
       'authenticated',
       'authenticated',
       jsonb_build_object('provider', 'backend', 'providers', jsonb_build_array('backend')),
       jsonb_build_object('full_name', full_name, 'backend_user', true)
FROM public.backend_users
ON CONFLICT (id) DO UPDATE
  SET email = EXCLUDED.email,
      raw_user_meta_data = EXCLUDED.raw_user_meta_data,
      updated_at = now();

COMMIT;


