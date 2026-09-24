-- Run after 027_backend_users.sql.
-- Bridge between backend/ REST auth and the Supabase-shaped authorization the
-- business RPCs expect:
--   * backend_users is authenticated by the Express API (bcrypt + JWT);
--   * create_sale / create_store / record_customer_payment ... derive the
--     caller from auth.uid() (i.e. request.jwt.claims set by the backend's
--     withAuth transaction) and require store_members membership, whose FK
--     points at auth.users.
-- So every backend user gets a shadow auth.users row (same id, email, no
-- GoTrue password - PostgREST/GoTrue are never involved; only the backend's
-- direct PostgreSQL connection and these triggers touch it). Membership and
-- store bootstrap rows are created by the existing triggers (bootstrap_store)
-- when the backend calls create_store with the user's claims.
BEGIN;

CREATE OR REPLACE FUNCTION private.sync_backend_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  INSERT INTO auth.users (id, email, aud, role, raw_app_meta_data, raw_user_meta_data)
  VALUES (
    NEW.id,
    NEW.email,
    'authenticated',
    'authenticated',
    jsonb_build_object('provider', 'backend', 'providers', jsonb_build_array('backend')),
    jsonb_build_object('full_name', NEW.full_name, 'backend_user', true)
  )
  ON CONFLICT (id) DO UPDATE
    SET email = EXCLUDED.email,
        raw_user_meta_data = EXCLUDED.raw_user_meta_data,
        updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER sync_backend_auth_user
AFTER INSERT OR UPDATE OF email, full_name ON public.backend_users
FOR EACH ROW EXECUTE FUNCTION private.sync_backend_auth_user();

-- Backfill accounts created before this migration existed.
INSERT INTO auth.users (id, email, aud, role, raw_app_meta_data, raw_user_meta_data)
SELECT id,
       email,
       'authenticated',
       'authenticated',
       jsonb_build_object('provider', 'backend', 'providers', jsonb_build_array('backend')),
       jsonb_build_object('full_name', full_name, 'backend_user', true)
FROM public.backend_users
ON CONFLICT (id) DO UPDATE
  SET email = EXCLUDED.email,
      raw_user_meta_data = EXCLUDED.raw_user_meta_data,
      updated_at = now();

COMMIT;
