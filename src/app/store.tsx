import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { getSupabase } from '../lib/supabase';
import { DemoEngine } from '../lib/engine';
import { seedDemoWithHistory } from '../lib/demo';
import type { AppRole } from '../lib/types';

// The role gate lives in lib/permissions.ts so the pure rule can be unit-tested
// without React. Re-exported here for the pages that already import it.
export { can } from '../lib/permissions';

interface DemoUser {
  id: string;
  name: string;
  email: string;
  role: AppRole;
}

interface AppContextValue {
  mode: 'demo' | 'supabase';
  user: DemoUser | null;
  role: AppRole;
  theme: 'light' | 'dark';
  engine: DemoEngine | null;
  version: number;
  signInDemo: (role: AppRole) => void;
  signOut: () => void;
  toggleTheme: () => void;
  refresh: () => void;
}

const AppContext = createContext<AppContextValue | null>(null);

const DEMO_USERS: Record<AppRole, DemoUser> = {
  owner: { id: 'demo-owner', name: 'Ramesh Sharma', email: 'owner@demo.local', role: 'owner' },
  manager: { id: 'demo-manager', name: 'Suresh Kumar', email: 'manager@demo.local', role: 'manager' },
  cashier: { id: 'demo-cashier', name: 'Amit Patel', email: 'cashier@demo.local', role: 'cashier' },
};

let sharedEngine: DemoEngine | null = null;
function getEngine(): DemoEngine {
  if (!sharedEngine) sharedEngine = new DemoEngine(seedDemoWithHistory());
  return sharedEngine;
}

export function AppProvider({ children }: { children: ReactNode }) {
  const supabase = getSupabase();
  const [mode] = useState<'demo' | 'supabase'>(supabase ? 'supabase' : 'demo');
  const [user, setUser] = useState<DemoUser | null>(() => {
    try {
      const raw = localStorage.getItem('ksm-demo-user');
      if (raw) {
        const parsed = JSON.parse(raw) as DemoUser;
        if (parsed && (parsed.role === 'owner' || parsed.role === 'manager' || parsed.role === 'cashier')) return parsed;
      }
    } catch { /* ignore */ }
    return null;
  });
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

  const signOut = useCallback(() => {
    setUser(null);
    try {
      localStorage.removeItem('ksm-demo-user');
    } catch { /* ignore */ }
    if (supabase) void supabase.auth.signOut();
  }, [supabase]);

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
      signOut,
      toggleTheme,
      refresh,
    }),
    [mode, user, theme, version, signInDemo, signOut, toggleTheme, refresh],
  );

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}

export function useApp(): AppContextValue {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error('useApp must be used inside AppProvider');
  return ctx;
}

