-- Run after 016_rpc_create_purchase.sql.
-- record_customer_payment(): settle part or all of a customer's outstanding
-- balance (udhaar). The ledger row drives the balance through the
-- apply_customer_ledger trigger, so the balance can never drift from history.
-- Owners and managers may always do this; cashiers only when the store has
-- enabled cashier_can_record_payments.
BEGIN;

CREATE OR REPLACE FUNCTION public.record_customer_payment(
  p_store_id uuid,
  p_customer_id uuid,
  p_amount numeric,
  p_payment_method public.payment_method DEFAULT 'cash',
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
  v_role public.user_role;
  v_result jsonb;
  v_customer public.customers;
  v_amount numeric(12,2);
  v_transaction_id uuid;
  v_balance numeric(12,2);
BEGIN
  v_role := private.assert_store_role(p_store_id, 'cashier');

  IF v_role = 'cashier' THEN
    IF NOT COALESCE((SELECT cashier_can_record_payments
                       FROM public.store_settings WHERE store_id = p_store_id), false) THEN
      RAISE EXCEPTION 'cashiers are not permitted to record payments in store %', p_store_id
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_request_id IS NOT NULL THEN
    SELECT r.result INTO v_result FROM public.rpc_requests r
     WHERE r.store_id = p_store_id AND r.request_id = p_request_id;
    IF v_result IS NOT NULL THEN
      RETURN v_result;
    END IF;
  END IF;

  IF p_payment_method IS NULL OR p_payment_method = 'credit' THEN
    RAISE EXCEPTION 'a payment method other than credit is required'
      USING ERRCODE = '22023';
  END IF;

  v_amount := round(COALESCE(p_amount, 0), 2);
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'payment amount must be greater than zero' USING ERRCODE = '22023';
  END IF;

  -- Lock the customer row so two concurrent payments cannot both read the same
  -- starting balance and overpay.
  SELECT * INTO v_customer
    FROM public.customers
   WHERE id = p_customer_id AND store_id = p_store_id AND deleted_at IS NULL
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'customer % not found in store %', p_customer_id, p_store_id
      USING ERRCODE = '23503';
  END IF;

  IF v_amount > v_customer.current_balance THEN
    RAISE EXCEPTION 'payment (%) exceeds the outstanding balance (%)',
      v_amount, v_customer.current_balance
      USING ERRCODE = 'P0001',
            HINT = 'Record at most the outstanding amount, or add an adjustment first.';
  END IF;

  -- Negative amount reduces the outstanding balance.
  INSERT INTO public.customer_transactions
    (store_id, customer_id, transaction_type, amount, reference_type,
     description, created_by)
  VALUES
    (p_store_id, p_customer_id, 'payment', -v_amount, 'credit_payment',
     COALESCE(NULLIF(btrim(p_notes), ''), 'Payment received via ' || p_payment_method),
     v_actor)
  RETURNING id INTO v_transaction_id;

  INSERT INTO public.credit_payments
    (store_id, customer_id, customer_transaction_id, amount, payment_method,
     notes, created_by)
  VALUES
    (p_store_id, p_customer_id, v_transaction_id, v_amount, p_payment_method,
     p_notes, v_actor);

  SELECT current_balance INTO v_balance FROM public.customers WHERE id = p_customer_id;

  PERFORM private.audit(p_store_id, 'customer_payment.recorded', 'customers', p_customer_id,
    jsonb_build_object('current_balance', v_customer.current_balance),
    jsonb_build_object('current_balance', v_balance, 'amount', v_amount,
                       'payment_method', p_payment_method));

  v_result := jsonb_build_object(
    'customer_id', p_customer_id,
    'amount', v_amount,
    'previous_balance', v_customer.current_balance,
    'current_balance', v_balance,
    'customer_transaction_id', v_transaction_id);

  IF p_request_id IS NOT NULL THEN
    INSERT INTO public.rpc_requests (store_id, request_id, operation, actor_id, payload, result)
    VALUES (p_store_id, p_request_id, 'record_customer_payment', v_actor,
            jsonb_build_object('customer_id', p_customer_id, 'amount', v_amount),
            v_result)
    ON CONFLICT (store_id, request_id) DO NOTHING;
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.record_customer_payment(uuid, uuid, numeric, public.payment_method, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_customer_payment(uuid, uuid, numeric, public.payment_method, text, uuid)
  TO authenticated;

COMMIT;
