-- Run after 010_rpc_customer_lookup.sql.
-- Decides how much of a non-credit sale is paid BEFORE the sales row is
-- written, because sales.payment_status must be correct at insert time.
-- Returns the amount paid: the full total for cash/upi/card, or the sum of the
-- split amounts for a mixed payment.
BEGIN;

CREATE OR REPLACE FUNCTION private.validate_sale_payments(
  p_method public.payment_method,
  p_total numeric,
  p_payments jsonb
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_payment jsonb;
  v_amount numeric;
  v_paid numeric(12,2) := 0;
BEGIN
  IF p_method = 'credit' THEN
    RAISE EXCEPTION 'credit sales are settled through the customer ledger'
      USING ERRCODE = '22023';
  END IF;

  IF p_method = 'mixed' THEN
    IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array'
       OR jsonb_array_length(p_payments) = 0 THEN
      RAISE EXCEPTION 'mixed payment requires a non-empty payments array'
        USING ERRCODE = '22023';
    END IF;

    FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
      IF (v_payment->>'method') IS NULL
         OR (v_payment->>'method') NOT IN ('cash', 'upi', 'card') THEN
        RAISE EXCEPTION 'split payments must use cash, upi or card'
          USING ERRCODE = '22023';
      END IF;

      v_amount := round((v_payment->>'amount')::numeric, 2);
      IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'each split payment amount must be positive'
          USING ERRCODE = '22023';
      END IF;

      v_paid := v_paid + v_amount;
    END LOOP;

    IF v_paid > p_total THEN
      RAISE EXCEPTION 'payments (%) exceed the sale total (%)', v_paid, p_total
        USING ERRCODE = '22023';
    END IF;

    RETURN v_paid;
  END IF;

  RETURN p_total;
END;
$$;

REVOKE ALL ON FUNCTION private.validate_sale_payments(public.payment_method, numeric, jsonb)
  FROM PUBLIC, anon, authenticated;

COMMIT;
