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
