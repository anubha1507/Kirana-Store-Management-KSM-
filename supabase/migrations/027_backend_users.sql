-- Backend API users for the Node/Express REST API (backend/).
-- These accounts are independent of Supabase auth.users: the backend hashes
-- passwords with bcrypt and issues its own JWTs (see backend/src/routes/auth.js).
BEGIN;

CREATE TABLE public.backend_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  full_name text NOT NULL,
  password_hash text NOT NULL,
  role public.user_role NOT NULL DEFAULT 'cashier',
  avatar_url text,
  store_id uuid REFERENCES public.stores(id) ON DELETE SET NULL,
  is_active boolean NOT NULL DEFAULT true,
  last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT backend_users_email_key UNIQUE (email)
);

CREATE INDEX backend_users_store_id_idx ON public.backend_users (store_id);

-- RLS with no policies: only the backend's direct PostgreSQL connection
-- (table owner / service role) can read password_hash; PostgREST anon and
-- authenticated roles get nothing.
ALTER TABLE public.backend_users ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.backend_users
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

COMMIT;