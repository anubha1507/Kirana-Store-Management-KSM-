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
