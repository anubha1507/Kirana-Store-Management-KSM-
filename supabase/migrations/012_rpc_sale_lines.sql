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
