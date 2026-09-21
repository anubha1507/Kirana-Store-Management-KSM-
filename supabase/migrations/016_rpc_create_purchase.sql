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
