import { useEffect, useMemo, useState } from 'react';
import { useApp, can } from '../app/store';
import { inr } from '../lib/format';
import { applyProductCreate } from '../lib/mutations';
import { apiGet, apiPost } from '../lib/api';

interface ProductRow {
  id: string;
  name: string;
  selling_price: number;
  stock_quantity: number;
  unit: string;
  low_stock_threshold: number;
  deleted_at: string | null;
}

export function ProductsPage() {
  const { engine, mode, role, refresh, version } = useApp();
  const [q, setQ] = useState('');
  const [name, setName] = useState('');
  const [price, setPrice] = useState(100);
  const [stock, setStock] = useState(10);
  const [err, setErr] = useState('');
  const [rows, setRows] = useState<ProductRow[] | null>(null);
  void version;

  // Backend mode: GET /api/products on mount and after every refresh().
  useEffect(() => {
    if (mode !== 'backend') return;
    let alive = true;
    apiGet('products')
      .then((d: ProductRow[]) => { if (alive) setRows(d); })
      .catch((e) => { if (alive) setErr((e as Error).message); });
    return () => { alive = false; };
  }, [mode, version]);

  const list = useMemo(() => {
    const source: ProductRow[] = mode === 'backend'
      ? (rows ?? [])
      : (engine?.state.products ?? []);
    const s = q.trim().toLowerCase();
    return source.filter((p) => !p.deleted_at && (!s || p.name.toLowerCase().includes(s)));
  }, [mode, rows, engine, q]);

  async function create() {
    if (!name.trim()) return;
    setErr('');
    if (mode === 'backend') {
      try {
        await apiPost('products', {
          name: name.trim(),
          selling_price: price,
          stock_quantity: stock,
        });
        setName('');
        refresh();
      } catch (e) {
        setErr((e as Error).message);
      }
      return;
    }
    if (!engine) return;
    try {
      applyProductCreate(engine.state, {
        store_id: engine.state.store.id, name, selling_price: price, stock_quantity: stock,
      });
      setName(''); refresh();
    } catch (e) { setErr((e as Error).message); }
  }

  const editable = can(role, 'products-read') && role !== 'cashier';
  return (
    <div className="page">
      <div className="page-head"><div><h2>Products</h2>
      <p className="muted">{list.length} active · low-stock flagged at threshold.</p></div></div>
      {err && <div className="alert err">{err}</div>}
      {mode === 'backend' && rows === null && !err && <p className="muted">Loading products…</p>}
      {editable && (
        <div className="card"><div className="inline-form">
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder="New product name" />
          <input type="number" value={price} onChange={(e) => setPrice(Number(e.target.value))} placeholder="Price" />
          <input type="number" value={stock} onChange={(e) => setStock(Number(e.target.value))} placeholder="Stock" />
          <button className="btn primary sm" onClick={create} disabled={!name.trim()}>Add product</button>
        </div></div>
      )}
      <div className="card"><div className="card-head"><h3>Catalogue</h3>
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search…" /></div>
        <table className="tbl"><thead><tr><th>Product</th><th>Price</th><th>Stock</th><th>Status</th></tr></thead>
        <tbody>{list.map((p) => (
          <tr key={p.id}><td>{p.name}</td><td>{inr(p.selling_price)}</td>
          <td>{p.stock_quantity} {p.unit}</td>
          <td>{p.stock_quantity <= p.low_stock_threshold ? 'reorder' : 'ok'}</td></tr>))}
        </tbody></table></div>
    </div>
  );
}