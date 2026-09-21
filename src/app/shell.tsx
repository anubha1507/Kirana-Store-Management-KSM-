import { NavLink, useNavigate } from 'react-router-dom';
import {
  LayoutDashboard, ReceiptText, Package, ShoppingCart,
  History, Users, BarChart3, Settings, LogOut, Sun, Moon, Store,
} from 'lucide-react';
import { useApp, can } from './store';

const LINKS = [
  { to: '/', label: 'Dashboard', icon: LayoutDashboard, gate: '' },
  { to: '/billing', label: 'Billing / POS', icon: ReceiptText, gate: 'billing' },
  { to: '/products', label: 'Products', icon: Package, gate: 'products-read' },
  { to: '/purchases', label: 'Purchases', icon: ShoppingCart, gate: 'purchases' },
  { to: '/sales', label: 'Sales', icon: History, gate: 'sales' },
  { to: '/customers', label: 'Customers', icon: Users, gate: 'customers-read' },
  { to: '/reports', label: 'Reports', icon: BarChart3, gate: 'reports' },
  { to: '/settings', label: 'Settings', icon: Settings, gate: 'settings' },
];

export function Shell({ children }: { children: React.ReactNode }) {
  const { user, role, theme, mode, engine, toggleTheme, signOut } = useApp();
  const navigate = useNavigate();

  const visible = LINKS.filter((l) => !l.gate || can(role, l.gate) || role === 'owner');

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark"><Store size={18} /></span>
          <span className="brand-text">
            <strong>{engine?.state.store.name ?? 'Kirana Store'}</strong>
            <small>{mode === 'demo' ? 'Local demo' : 'Supabase'} · {role}</small>
          </span>
        </div>
        <nav className="nav">
          {visible.map((l) => (
            <NavLink key={l.to} to={l.to} end={l.to === '/'} className={({ isActive }) => `nav-link${isActive ? ' active' : ''}`}>
              <l.icon size={17} />
              <span>{l.label}</span>
            </NavLink>
          ))}
        </nav>
        <div className="sidebar-foot">
          <button className="btn ghost sm" onClick={toggleTheme} title="Toggle theme">
            {theme === 'light' ? <Moon size={15} /> : <Sun size={15} />}
            <span>{theme === 'light' ? 'Dark' : 'Light'} mode</span>
          </button>
          <button
            className="btn ghost sm"
            onClick={() => { signOut(); navigate('/login'); }}
          >
            <LogOut size={15} />
            <span>Sign out ({user?.name ?? role})</span>
          </button>
        </div>
      </aside>
      <div className="main">
        <header className="topbar">
          <div className="topbar-title">Kirana Store Management</div>
          <div className="topbar-right">
            <span className="pill">{mode === 'demo' ? 'LOCAL DEMO · localhost' : 'SUPABASE CONNECTED'}</span>
          </div>
        </header>
        <main className="content">{children}</main>
      </div>
    </div>
  );
}
