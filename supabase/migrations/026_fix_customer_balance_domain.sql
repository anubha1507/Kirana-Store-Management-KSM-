-- Run after 024_rpc_store_members.sql.
-- Fixes T08.14: cancel_sale() of a credit sale whose reversal would overdraw
-- the customer balance must raise P0001, but it was hitting 23514 instead.
--
-- Root cause: customers.current_balance uses the money_amount domain whose
-- CHECK (VALUE >= 0) fires DURING the UPDATE in apply_customer_ledger's
-- AFTER INSERT trigger — before the trigger's own IF v_balance < 0 guard can
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
