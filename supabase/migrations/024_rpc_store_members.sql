-- Run after 023_purchase_invoice_unique.sql.
-- ============================================================================
-- RPC: store membership administration
--
-- These four functions complete the member-management surface described in
-- docs/04_rpc_reference.md. They were referenced by the documentation and by
-- the setup guide but were never created (the `-- MEMBERS_ANCHOR` marker in
-- 007_rpc_store_and_members.sql was the placeholder).
--
-- Why functions instead of plain PostgREST writes?
--   * store_members has INSERT/UPDATE/DELETE grants for authenticated, but the
--     guard_store_member_change trigger only blocks the dangerous cases. These
--     RPCs add the checks a trigger cannot express: a target user must actually
--     exist in auth.users (no orphan invitations) and a member cannot lock
--     themselves out.
--   * Every change is written to audit_logs with the acting user, which RLS
--     cannot do on its own.
--
-- Security: SECURITY DEFINER with a pinned search_path, caller identity from
-- auth.uid() only, and every store-scoped id re-validated inside the function.
-- ============================================================================
BEGIN;

-- Adds an existing auth user to a store. The user must already have signed up:
-- invitations are out of scope, so an unknown id fails loudly instead of
-- creating a membership nobody can ever claim.
CREATE OR REPLACE FUNCTION public.add_store_member(
  p_store_id uuid,
  p_user_id uuid,
  p_role public.user_role DEFAULT 'cashier'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_member public.store_members;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'owner');

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'a user id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'user % has no account yet; they must sign up first', p_user_id
      USING ERRCODE = '23503',
            HINT = 'Create the user through Supabase Auth, then add them to the store.';
  END IF;

  IF p_role = 'owner' THEN
    RAISE EXCEPTION 'a store cannot have a second owner' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.store_members (store_id, user_id, role, is_active)
  VALUES (p_store_id, p_user_id, p_role, true)
  ON CONFLICT (store_id, user_id) DO UPDATE
    SET role = EXCLUDED.role,
        is_active = true
  RETURNING * INTO v_member;

  PERFORM private.audit(p_store_id, 'store_member.added', 'store_members', v_member.id,
    NULL,
    jsonb_build_object('user_id', p_user_id, 'role', v_member.role,
                       'is_active', v_member.is_active));

  RETURN to_jsonb(v_member);
END;
$$;

-- Changes a member's role. Promoting to owner is refused by design: ownership
-- transfer needs an operator-run migration (see guard_store_member_change).
CREATE OR REPLACE FUNCTION public.set_store_member_role(
  p_store_id uuid,
  p_member_id uuid,
  p_role public.user_role
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_before public.store_members;
  v_after public.store_members;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'owner');

  IF p_role = 'owner' THEN
    RAISE EXCEPTION 'a store cannot have a second owner' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_before FROM public.store_members
   WHERE id = p_member_id AND store_id = p_store_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member % not found in store %', p_member_id, p_store_id
      USING ERRCODE = '23503';
  END IF;

  UPDATE public.store_members
     SET role = p_role
   WHERE id = p_member_id
  RETURNING * INTO v_after;

  PERFORM private.audit(p_store_id, 'store_member.role_changed', 'store_members',
    v_after.id,
    jsonb_build_object('role', v_before.role),
    jsonb_build_object('role', v_after.role, 'user_id', v_after.user_id));

  RETURN to_jsonb(v_after);
END;
$$;

-- Enables or disables a member's access. Disabling is the soft "remove": the
-- membership and its history stay, but every RLS helper stops matching, so the
-- user immediately loses access to the store.
CREATE OR REPLACE FUNCTION public.set_store_member_active(
  p_store_id uuid,
  p_member_id uuid,
  p_is_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_before public.store_members;
  v_after public.store_members;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'owner');

  IF p_is_active IS NULL THEN
    RAISE EXCEPTION 'is_active is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_before FROM public.store_members
   WHERE id = p_member_id AND store_id = p_store_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member % not found in store %', p_member_id, p_store_id
      USING ERRCODE = '23503';
  END IF;

  -- An owner must not be able to switch off their own access and orphan the
  -- store; another owner would have to do it, and there is only ever one.
  IF NOT p_is_active AND v_before.user_id = v_actor THEN
    RAISE EXCEPTION 'you cannot deactivate your own membership' USING ERRCODE = '42501';
  END IF;

  UPDATE public.store_members
     SET is_active = p_is_active
   WHERE id = p_member_id
  RETURNING * INTO v_after;

  PERFORM private.audit(p_store_id, 'store_member.access_changed', 'store_members',
    v_after.id,
    jsonb_build_object('is_active', v_before.is_active),
    jsonb_build_object('is_active', v_after.is_active, 'user_id', v_after.user_id));

  RETURN to_jsonb(v_after);
END;
$$;

-- Hard-removes a membership. Refuses to remove the owner and refuses to remove
-- the caller, mirroring the store_members_delete_owner RLS policy so the RPC
-- cannot be used to bypass it.
CREATE OR REPLACE FUNCTION public.remove_store_member(
  p_store_id uuid,
  p_member_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_member public.store_members;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'owner');

  SELECT * INTO v_member FROM public.store_members
   WHERE id = p_member_id AND store_id = p_store_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member % not found in store %', p_member_id, p_store_id
      USING ERRCODE = '23503';
  END IF;

  IF v_member.role = 'owner' THEN
    RAISE EXCEPTION 'the store owner membership cannot be removed' USING ERRCODE = '42501';
  END IF;

  IF v_member.user_id = v_actor THEN
    RAISE EXCEPTION 'you cannot remove your own membership' USING ERRCODE = '42501',
      HINT = 'Ask another owner to remove you.';
  END IF;

  DELETE FROM public.store_members WHERE id = p_member_id;

  PERFORM private.audit(p_store_id, 'store_member.removed', 'store_members', p_member_id,
    jsonb_build_object('user_id', v_member.user_id, 'role', v_member.role),
    NULL);

  RETURN jsonb_build_object('member_id', p_member_id, 'removed', true);
END;
$$;

REVOKE ALL ON FUNCTION public.add_store_member(uuid, uuid, public.user_role)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_store_member_role(uuid, uuid, public.user_role)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_store_member_active(uuid, uuid, boolean)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_store_member(uuid, uuid)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.add_store_member(uuid, uuid, public.user_role)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_store_member_role(uuid, uuid, public.user_role)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_store_member_active(uuid, uuid, boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_store_member(uuid, uuid)
  TO authenticated;

COMMIT;