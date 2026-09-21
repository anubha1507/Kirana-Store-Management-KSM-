-- Run after 014_rpc_credit_sale_helper.sql.
-- create_sale(): atomic checkout. See README for the full contract.
BEGIN;

CREATE OR REPLACE FUNCTION public.create_sale(
  p_store_id uuid,
  p_items jsonb,
  p_payment_method public.payment_method,
  p_customer_id uuid DEFAULT NULL,
  p_discount_amount numeric DEFAULT 0,
  p_tax_amount numeric DEFAULT 0,
  p_notes text DEFAULT NULL,
  p_payments jsonb DEFAULT NULL,
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
  v_allow_negative boolean;
  v_customer public.customers;
  v_priced jsonb;
  v_subtotal numeric(12,2);
  v_discount numeric(12,2) := round(COALESCE(p_discount_amount, 0), 2);
  v_tax numeric(12,2) := round(COALESCE(p_tax_amount, 0), 2);
  v_total numeric(12,2);
  v_paid numeric(12,2) := 0;
  v_outstanding numeric(12,2) := 0;
  v_status public.payment_status;
  v_sale_id uuid;
  v_invoice text;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'cashier');

  -- Idempotency: a repeated request returns the original result untouched.
  IF p_request_id IS NOT NULL THEN
    SELECT r.result INTO v_result FROM public.rpc_requests r
     WHERE r.store_id = p_store_id AND r.request_id = p_request_id;
    IF v_result IS NOT NULL THEN
      RETURN v_result;
    END IF;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'at least one sale item is required' USING ERRCODE = '22023';
  END IF;
  IF v_discount < 0 OR v_tax < 0 THEN
    RAISE EXCEPTION 'discount and tax cannot be negative' USING ERRCODE = '22023';
  END IF;

  SELECT allow_negative_stock INTO v_allow_negative
    FROM public.store_settings WHERE store_id = p_store_id;

  -- Serialise concurrent checkouts for this store.
  PERFORM private.lock_store(p_store_id);

  IF p_customer_id IS NOT NULL THEN
    SELECT * INTO v_customer FROM public.customers
     WHERE id = p_customer_id AND store_id = p_store_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'customer % not found in store %', p_customer_id, p_store_id
        USING ERRCODE = '23503';
    END IF;
  END IF;

  IF p_payment_method = 'credit' AND p_customer_id IS NULL THEN
    RAISE EXCEPTION 'a credit sale requires a customer' USING ERRCODE = '22023';
  END IF;

  -- Price every line from the catalogue under row locks.
  v_priced := private.price_sale_lines(p_store_id, p_items, v_allow_negative);
  v_subtotal := (v_priced->>'subtotal')::numeric(12,2);
  v_total := round(v_subtotal - v_discount + v_tax, 2);
  IF v_total < 0 THEN
    RAISE EXCEPTION 'sale total cannot be negative' USING ERRCODE = '22023';
  END IF;

  IF p_payment_method = 'credit' THEN
    v_paid := 0;
  ELSE
    v_paid := private.validate_sale_payments(p_payment_method, v_total, p_payments);
  END IF;

  -- Anything not settled now becomes customer credit, so it must have an owner.
  v_outstanding := round(v_total - v_paid, 2);
  v_status := CASE WHEN v_outstanding = 0 THEN 'paid'
                   WHEN v_paid = 0 THEN 'pending'
                   ELSE 'partial' END;

  IF v_outstanding > 0 AND p_customer_id IS NULL THEN
    RAISE EXCEPTION 'an unpaid balance requires a customer' USING ERRCODE = '22023';
  END IF;

  v_invoice := private.next_document_number(p_store_id, 'sale');

  INSERT INTO public.sales
    (store_id, customer_id, invoice_number, subtotal, discount_amount, tax_amount,
     total_amount, payment_method, payment_status, notes, created_by)
  VALUES
    (p_store_id, p_customer_id, v_invoice, v_subtotal, v_discount, v_tax,
     v_total, p_payment_method, v_status, p_notes, v_actor)
  RETURNING id INTO v_sale_id;

  -- Apply the stock deltas and write sale_items + stock_movements.
  PERFORM private.persist_sale_lines(p_store_id, v_sale_id, v_priced->'lines', v_actor);

  -- Record money received (no-op for credit sales).
  PERFORM private.write_sale_payments(p_store_id, v_sale_id, p_payment_method,
                                      p_payments, v_paid, v_actor);

  -- Whatever was not settled becomes a customer ledger debt.
  IF v_outstanding > 0 THEN
    PERFORM private.apply_credit_sale(p_store_id, v_sale_id, p_customer_id, v_outstanding,
                                      v_invoice, v_customer.credit_limit,
                                      v_customer.name, v_actor);
  END IF;

  PERFORM private.audit(p_store_id, 'sale.created', 'sales', v_sale_id, NULL,
    jsonb_build_object('invoice_number', v_invoice, 'total_amount', v_total,
                       'payment_method', p_payment_method, 'payment_status', v_status));

  v_result := jsonb_build_object(
    'sale_id', v_sale_id,
    'invoice_number', v_invoice,
    'subtotal', v_subtotal,
    'discount_amount', v_discount,
    'tax_amount', v_tax,
    'total_amount', v_total,
    'payment_status', v_status,
    'amount_paid', v_paid);

  IF p_request_id IS NOT NULL THEN
    INSERT INTO public.rpc_requests (store_id, request_id, operation, actor_id, payload, result)
    VALUES (p_store_id, p_request_id, 'create_sale', v_actor, p_items, v_result)
    ON CONFLICT (store_id, request_id) DO NOTHING;
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.create_sale(uuid, jsonb, public.payment_method, uuid, numeric, numeric, text, jsonb, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sale(uuid, jsonb, public.payment_method, uuid, numeric, numeric, text, jsonb, uuid)
  TO authenticated;

COMMIT;
