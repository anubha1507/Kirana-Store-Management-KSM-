import { Navigate, Route, Routes } from 'react-router-dom';
import { Shell } from './app/shell';
import { useApp } from './app/store';
import { LoginPage } from './pages/Login';
import { DashboardPage } from './pages/Dashboard';
import { BillingPage } from './pages/Billing';
import { ProductsPage } from './pages/Products';
import { PurchasesPage } from './pages/Purchases';
import { SalesPage } from './pages/Sales';
import { CustomersPage } from './pages/Customers';
import { ReportsPage } from './pages/Reports';
import { SettingsPage } from './pages/Settings';

function Guard({ children }: { children: JSX.Element }) {
  const { user, mode } = useApp();
  if (mode === 'demo' && !user) return <Navigate to="/login" replace />;
  return children;
}

export function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route
        path="/*"
        element={
          <Guard>
            <Shell>
              <Routes>
                <Route index element={<DashboardPage />} />
                <Route path="billing" element={<BillingPage />} />
                <Route path="products" element={<ProductsPage />} />
                <Route path="purchases" element={<PurchasesPage />} />
                <Route path="sales" element={<SalesPage />} />
                <Route path="customers" element={<CustomersPage />} />
                <Route path="reports" element={<ReportsPage />} />
                <Route path="settings" element={<SettingsPage />} />
                <Route path="*" element={<Navigate to="/" replace />} />
              </Routes>
            </Shell>
          </Guard>
        }
      />
    </Routes>
  );
}
