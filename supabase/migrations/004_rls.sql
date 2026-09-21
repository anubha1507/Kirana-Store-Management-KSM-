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