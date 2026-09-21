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
