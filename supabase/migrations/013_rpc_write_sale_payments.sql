-- Run after 011_rpc_sale_payment_helper.sql.
-- Inserts payment rows for a non-credit sale. Assumes validate_sale_payments()
-- already returned p_amount_paid.
BEGIN;

CREATE OR REPLACE FUNCTION private.write_sale_payments(
  p_store_id uuid,
  p_sale_id uuid,
  p_method public.payment_method,
  p_payments jsonb,
  p_amount_paid numeric,
  p_actor uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_payment jsonb;
BEGIN
  IF p_method = 'credit' OR COALESCE(p_amount_paid, 0) = 0 THEN
    RETURN;
  END IF;

  IF p_method = 'mixed' THEN
    FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
      INSERT INTO public.payments
        (store_id, sale_id, amount, payment_method, transaction_reference, created_by)
      VALUES
        (p_store_id, p_sale_id, round((v_payment->>'amount')::numeric, 2),
         (v_payment->>'method')::public.payment_method,
         NULLIF(btrim(COALESCE(v_payment->>'reference', '')), ''), p_actor);
    END LOOP;
    RETURN;
  END IF;

  INSERT INTO public.payments
    (store_id, sale_id, amount, payment_method, created_by)
  VALUES
    (p_store_id, p_sale_id, p_amount_paid, p_method, p_actor);
END;
$$;

REVOKE ALL ON FUNCTION private.write_sale_payments(uuid, uuid, public.payment_method, jsonb, numeric, uuid)
  FROM PUBLIC, anon, authenticated;

COMMIT;
