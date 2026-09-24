const API_BASE = (import.meta.env.VITE_API_BASE_URL as string | undefined) || '';
export const isBackendConfigured = Boolean(API_BASE);
// Exposed for Settings/diagnostics so the UI can show which API it talks to.
export const apiBase = API_BASE;

interface FetchOptions {
  method?: string;
  headers?: Record<string, string>;
  body?: string;
}

function headers(): Record<string, string> {
  const h: Record<string, string> = { 'Content-Type': 'application/json' };
  try {
    const token = localStorage.getItem('ksm-backend-token');
    if (token) h['Authorization'] = `Bearer ${token}`;
  } catch { /* ignore */ }
  return h;
}

interface ApiError extends Error {
  status?: number;
  code?: unknown;
  errors?: unknown;
}

export async function apiFetch(path: string, options: FetchOptions = {}): Promise<any> {
  if (!isBackendConfigured) {
    const error = new Error('Backend API is not configured. Set VITE_API_BASE_URL.') as ApiError;
    error.status = 503;
    throw error;
  }
  const url = API_BASE.replace(/\/+$/, '') + '/' + path.replace(/^\/+/, '');
  const res = await fetch(url, { ...options, headers: { ...headers(), ...options.headers } });

  let body: any;
  try {
    body = await res.json();
  } catch {
    body = { success: false, message: res.statusText };
  }

  // Handle new backend response format with success/data structure
  if (!res.ok) {
    const message =
      body?.message ||
      body?.error ||
      body?.details ||
      res.statusText;
    const error = new Error(message) as ApiError;
    error.status = res.status;
    if (body?.error) error.code = body.error;
    if (body?.errors) error.errors = body.errors;
    throw error;
  }

  // Handle success/data format from new backend
  if (body?.success !== undefined) {
    return body.data !== undefined ? body.data : body;
  }

  return body;
}

export async function apiGet(path: string): Promise<any> {
  return apiFetch(path, { method: 'GET' });
}

export async function apiPost(path: string, data: unknown): Promise<any> {
  return apiFetch(path, { method: 'POST', body: JSON.stringify(data) });
}

export async function apiPut(path: string, data: unknown): Promise<any> {
  return apiFetch(path, { method: 'PUT', body: JSON.stringify(data) });
}

export async function apiDelete(path: string): Promise<any> {
  return apiFetch(path, { method: 'DELETE' });
}
