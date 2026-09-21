-- Run after 013_rpc_write_sale_payments.sql.
-- Writes the customer ledger entry for a credit sale and enforces the credit
-- limit. The apply_customer_ledger trigger maintains customers.current_balance,
-- so this function only appends the ledger row and reads the new balance back.
BEGIN;

CREATE OR REPLACE FUNCTION private.apply_credit_sale(
  p_store_id uuid,
  p_sale_id uuid,
  p_customer_id uuid,
  p_total numeric,
  p_invoice text,
  p_credit_limit numeric,
  p_customer_name text,
  p_actor uuid
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_balance numeric(12,2);
BEGIN
  INSERT INTO public.customer_transactions
    (store_id, customer_id, transaction_type, amount, reference_id, reference_type,
     description, created_by)
  VALUES
    (p_store_id, p_customer_id, 'credit_sale', p_total, p_sale_id, 'sale',
     'Credit sale ' || p_invoice, p_actor);

  SELECT current_balance INTO v_balance
    FROM public.customers
   WHERE id = p_customer_id;

  IF p_credit_limit > 0 AND v_balance > p_credit_limit THEN
    RAISE EXCEPTION 'credit limit exceeded for % (limit %, would be %)',
      p_customer_name, p_credit_limit, v_balance
      USING ERRCODE = 'P0001';
  END IF;

  RETURN v_balance;
END;
$$;

REVOKE ALL ON FUNCTION private.apply_credit_sale(uuid, uuid, uuid, numeric, text, numeric, text, uuid)
  FROM PUBLIC, anon, authenticated;

COMMIT;
