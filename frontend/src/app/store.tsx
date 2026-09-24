import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { isBackendConfigured } from '../lib/api';
import { loginBackend, logoutBackend, signupBackend } from '../lib/auth';
import { DemoEngine } from '../lib/engine';
import { seedDemoWithHistory } from '../lib/demo';
import type { AppRole } from '../lib/types';

// The role gate lives in lib/permissions.ts so the pure rule can be unit-tested
// without React. Re-exported here for the pages that already import it.
export { can } from '../lib/permissions';

interface SessionUser {
  id: string;
  name: string;
  email: string;
  role: AppRole;
}

interface AppContextValue {
  mode: 'demo' | 'backend';
  user: SessionUser | null;
  role: AppRole;
  theme: 'light' | 'dark';
  engine: DemoEngine | null;
  version: number;
  signInDemo: (role: AppRole) => void;
  signInBackend: (email: string, password: string) => Promise<void>;
  signUpBackend: (email: string, password: string, fullName: string, role: AppRole) => Promise<void>;
  signOut: () => void;
  toggleTheme: () => void;
  refresh: () => void;
}

const AppContext = createContext<AppContextValue | null>(null);

const DEMO_USERS: Record<AppRole, SessionUser> = {
  owner: { id: 'demo-owner', name: 'Ramesh Sharma', email: 'owner@demo.local', role: 'owner' },
  manager: { id: 'demo-manager', name: 'Suresh Kumar', email: 'manager@demo.local', role: 'manager' },
  cashier: { id: 'demo-cashier', name: 'Amit Patel', email: 'cashier@demo.local', role: 'cashier' },
};

let sharedEngine: DemoEngine | null = null;
function getEngine(): DemoEngine {
  if (!sharedEngine) sharedEngine = new DemoEngine(seedDemoWithHistory());
  return sharedEngine;
}

function readStoredUser(key: string): SessionUser | null {
  try {
    const raw = localStorage.getItem(key);
    if (raw) {
      const parsed = JSON.parse(raw) as SessionUser;
      if (parsed && (parsed.role === 'owner' || parsed.role === 'manager' || parsed.role === 'cashier')) return parsed;
    }
  } catch { /* ignore */ }
  return null;
}

export function AppProvider({ children }: { children: ReactNode }) {
  // Mode flips to 'backend' when VITE_API_BASE_URL is set (see lib/api.ts).
  const [mode] = useState<'demo' | 'backend'>(isBackendConfigured ? 'backend' : 'demo');
  const [user, setUser] = useState<SessionUser | null>(
    () => readStoredUser('ksm-demo-user') ?? readStoredUser('ksm-backend-user'),
  );
  const [theme, setTheme] = useState<'light' | 'dark'>(() => {
    try {
      return (localStorage.getItem('ksm-theme') as 'light' | 'dark') || 'light';
    } catch {
      return 'light';
    }
  });
  const [version, setVersion] = useState(0);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.colorScheme = theme;
    try {
      localStorage.setItem('ksm-theme', theme);
    } catch { /* ignore */ }
  }, [theme]);

  const signInDemo = useCallback((role: AppRole) => {
    const u = DEMO_USERS[role];
    setUser(u);
    try {
      localStorage.setItem('ksm-demo-user', JSON.stringify(u));
    } catch { /* ignore */ }
  }, []);

  // POST /api/auth/login — token lands in lib/auth.ts, profile in context.
  const signInBackend = useCallback(async (email: string, password: string) => {
    const u = await loginBackend(email, password);
    if (!u) throw new Error('Backend login returned no user.');
    const session: SessionUser = { id: u.id, name: u.fullName, email: u.email, role: u.role };
    setUser(session);
    try {
      localStorage.setItem('ksm-backend-user', JSON.stringify(session));
    } catch { /* ignore */ }
  }, []);

  // POST /api/auth/signup — first account also creates its store server-side.
  const signUpBackend = useCallback(async (email: string, password: string, fullName: string, role: AppRole) => {
    const u = await signupBackend(email, password, fullName, role);
    if (!u) throw new Error('Backend signup returned no user.');
    const session: SessionUser = { id: u.id, name: u.fullName, email: u.email, role: u.role };
    setUser(session);
    try {
      localStorage.setItem('ksm-backend-user', JSON.stringify(session));
    } catch { /* ignore */ }
  }, []);

  const signOut = useCallback(() => {
    setUser(null);
    try {
      localStorage.removeItem('ksm-demo-user');
      localStorage.removeItem('ksm-backend-user');
    } catch { /* ignore */ }
    void logoutBackend(); // POST /api/auth/logout + discard token
  }, []);

  const toggleTheme = useCallback(() => {
    setTheme((t) => (t === 'light' ? 'dark' : 'light'));
  }, []);

  const refresh = useCallback(() => setVersion((v) => v + 1), []);

  const value = useMemo<AppContextValue>(
    () => ({
      mode,
      user,
      role: user?.role ?? 'cashier',
      theme,
      engine: mode === 'demo' ? getEngine() : null,
      version,
      signInDemo,
      signInBackend,
      signUpBackend,
      signOut,
      toggleTheme,
      refresh,
    }),
    [mode, user, theme, version, signInDemo, signInBackend, signUpBackend, signOut, toggleTheme, refresh],
  );

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}

export function useApp(): AppContextValue {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error('useApp must be used inside AppProvider');
  return ctx;
}