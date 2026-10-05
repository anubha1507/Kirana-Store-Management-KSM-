import { apiPost, apiGet, apiFetch } from './api';
import type { AppRole } from './types';
import { isSupabaseAuthConfigured, supabase } from './supabase';

export interface BackendUser {
  id: string;
  email: string;
  fullName: string;
  role: AppRole;
  avatarUrl: string | null;
}

const DEMO_ROLE_MAP: Record<string, AppRole> = {
  admin: 'owner',
  manager: 'manager',
  staff: 'cashier',
};

export async function loginBackend(email: string, password: string) {
  if (isSupabaseAuthConfigured && supabase) {
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) throw new Error(error.message);
    if (!data.session) throw new Error('Please verify your email before signing in.');
    const body = await exchangeSupabaseSession(data.session.access_token);
    return normalizeUser(body.user);
  }
  const body = await apiPost('auth/login', { email, password });
  const token = body.token as string | undefined;
  if (!token) throw new Error('Backend login succeeded but no token was returned.');
  try {
    localStorage.setItem('ksm-backend-token', token);
  } catch { /* ignore */ }
  return normalizeUser(body.user);
}

export async function signupBackend(email: string, password: string, fullName: string, role: 'owner' | 'manager' | 'cashier' = 'cashier') {
  if (isSupabaseAuthConfigured && supabase) {
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: { data: { full_name: fullName, role } },
    });
    if (error) throw new Error(error.message);
    if (!data.session) throw new Error('Account created. Check your Gmail inbox and verify your email before signing in.');
    const body = await exchangeSupabaseSession(data.session.access_token);
    return normalizeUser(body.user);
  }
  const body = await apiPost('auth/signup', { email, password, fullName, role });
  const token = body.token as string | undefined;
  if (!token) throw new Error('Backend signup succeeded but no token was returned.');
  try {
    localStorage.setItem('ksm-backend-token', token);
  } catch { /* ignore */ }
  return normalizeUser(body.user);
}

export async function refreshBackendToken() {
  const token = getBackendToken();
  if (!token) throw new Error('No backend token to refresh.');
  const body = await apiPost('auth/refresh', {});
  const newToken = body.token as string | undefined;
  if (!newToken) throw new Error('Backend refresh succeeded but no token was returned.');
  try {
    localStorage.setItem('ksm-backend-token', newToken);
  } catch { /* ignore */ }
  return newToken;
}

export async function getMeBackend() {
  const body = await apiGet('auth/me');
  return normalizeUser(body);
}

// POST /api/auth/logout, then discard the token locally. JWTs are stateless,
// so the server simply acknowledges; the credential dies with the client.
export async function logoutBackend(): Promise<void> {
  try {
    if (getBackendToken()) await apiPost('auth/logout', {});
  } catch { /* best-effort — the token is cleared either way */ }
  clearBackendSession();
}

export function getBackendToken() {
  try {
    return localStorage.getItem('ksm-backend-token') || null;
  } catch {
    return null;
  }
}

export function clearBackendSession() {
  try {
    localStorage.removeItem('ksm-backend-token');
  } catch { /* ignore */ }
}

export function normalizeUser(raw: Record<string, unknown> | undefined): BackendUser | null {
  if (!raw) return null;
  const id = raw.id as string | undefined;
  const email = raw.email as string | undefined;
  const fullName = (raw.full_name ?? raw.fullName) as string | undefined;
  const avatarUrl = (raw.avatar_url ?? raw.avatarUrl) as string | null | undefined;
  let role: AppRole = 'cashier';
  if (raw.role && typeof raw.role === 'string') {
    const mapped = DEMO_ROLE_MAP[raw.role];
    if (mapped) role = mapped;
    else if (raw.role === 'owner' || raw.role === 'manager' || raw.role === 'cashier') role = raw.role as AppRole;
  }
  if (!id || !email) return null;
  return {
    id,
    email,
    fullName: fullName ?? email.split('@')[0],
    role,
    avatarUrl: avatarUrl ?? null,
  };
}

async function exchangeSupabaseSession(accessToken: string) {
  return apiFetch('auth/supabase', {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}` },
    body: '{}',
  });
}

export async function resendSignupVerification(email: string) {
  if (!supabase) throw new Error('Supabase Auth is not configured.');
  const { error } = await supabase.auth.resend({ type: 'signup', email });
  if (error) throw new Error(error.message);
}