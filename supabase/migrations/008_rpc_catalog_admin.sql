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
