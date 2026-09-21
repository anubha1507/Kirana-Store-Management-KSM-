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
