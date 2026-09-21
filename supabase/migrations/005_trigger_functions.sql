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