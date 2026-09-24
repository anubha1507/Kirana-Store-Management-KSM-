import { useEffect, useMemo, useState } from 'react';
import { Search, Plus, Minus, Trash2 } from 'lucide-react';
import { useApp } from '../app/store';
import { uid, inr } from '../lib/format';
import { apiGet, apiPost } from '../lib/api';
import type { SaleLine } from '../lib/types';

interface ProductOption {
  id: string;
  name: string;
  selling_price: number;
  stock_quantity: number;
  deleted_at: string | null;
}

interface CustomerOption {
  id: string;
  name: string;
}

export function BillingPage() {
  const { engine, mode, role, refresh, version } = useApp();
  const [query, setQuery] = useState('');
  const [cart, setCart] = useState<SaleLine[]>([]);
  const [paymentMethod, setPaymentMethod] = useState('cash');
  const [customerId, setCustomerId] = useState('');
  const [billDiscount, setBillDiscount] = useState(0);
  const [billTax, setBillTax] = useState(0);
  const [msg, setMsg] = useState('');
  const [bProducts, setBProducts] = useState<ProductOption[] | null>(null);
  const [bCustomers, setBCustomers] = useState<CustomerOption[] | null>(null);
  void version;

  // Backend mode: catalogue + customers come from REST (GET /api/products,
  // GET /api/customers) and refresh after every successful checkout.
  useEffect(() => {
    if (mode !== 'backend') return;
    let alive = true;
    Promise.all([apiGet('products'), apiGet('customers')])
      .then(([p, c]) => {
        if (alive) {
          setBProducts(p as ProductOption[]);
          setBCustomers(c as CustomerOption[]);
        }
      })
      .catch((e) => { if (alive) setMsg((e as Error).message); });
    return () => { alive = false; };
  }, [mode, version]);

  const allProducts: ProductOption[] = mode === 'backend'
    ? (bProducts ?? [])
    : (engine?.state.products ?? []);
  const allCustomers: CustomerOption[] = mode === 'backend'
    ? (bCustomers ?? [])
    : (engine?.state.customers ?? []);

  const products = useMemo(() => {
    const q = query.trim().toLowerCase();
    return allProducts
      .filter((p) => !p.deleted_at && (!q || p.name.toLowerCase().includes(q)))
      .slice(0, 40);
  }, [allProducts, query]);

  const detailed = cart.map((l) => {
    const p = allProducts.find((x) => x.id === l.product_id);
    return { ...l, name: p?.name ?? '?', price: p?.selling_price ?? 0 };
  });
  const subtotal = detailed.reduce((a, l) => a + l.price * l.quantity, 0);
  const total = Math.max(0, subtotal - billDiscount + billTax);

  async function checkout() {
    if (!cart.length) return;
    setMsg('');
    if (mode === 'backend') {
      try {
        // POST /api/sales → create_sale RPC: server-side pricing, stock guard,
        // payment ceiling, credit-limit guard and idempotency via request_id.
        const sale = await apiPost('sales', {
          items: cart.map((l) => ({
            product_id: l.product_id,
            quantity: l.quantity,
            ...(l.discount_amount ? { discount: l.discount_amount } : {}),
          })),
          payment_method: paymentMethod,
          customer_id: customerId || null,
          discount_amount: billDiscount,
          tax_amount: billTax,
          request_id: crypto.randomUUID(),
        });
        setCart([]);
        setMsg(`Bill ${sale.invoice_number} saved: ${inr(sale.total_amount)}`);
        refresh();
      } catch (e) {
        setMsg((e as Error).message);
      }
      return;
    }
    if (!engine) return;
    try {
      const sale = engine.checkout({
        items: cart, payment_method: paymentMethod,
        customer_id: customerId || null,
        discount_amount: billDiscount, tax_amount: billTax,
        request_id: uid('req'),
      });
      setCart([]); setMsg(`Bill ${sale.invoice_number} saved: ${inr(sale.total_amount)}`);
      refresh();
    } catch (e) { setMsg((e as Error).message); }
  }

  // The invoice number is minted server-side in backend mode.
  const nextInvoice = mode === 'demo' && engine ? engine.peekInvoice() : null;

  return (
    <div className="page">
      <div className="page-head"><div><h2>Billing / POS</h2>
      <p className="muted">Role: {role} · prices from catalogue, totals at checkout.</p></div>
      {nextInvoice && <span className="pill">Next: {nextInvoice}</span>}</div>
      {msg && <div className="alert ok">{msg}</div>}
      <div className="grid-2">
        <div className="card"><div className="card-head"><h3>Products</h3>
          <div className="search"><Search size={14} />
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search…" /></div></div>
          <ul className="rows scroll">{products.map((p) => (
            <li key={p.id}><span><strong>{p.name}</strong>
            <small> · {inr(p.selling_price)} · {p.stock_quantity} left</small></span>
            <button className="btn sm" onClick={() => setCart((c) => {
              const f = c.find((l) => l.product_id === p.id);
              return f ? c.map((l) => (l.product_id === p.id ? { ...l, quantity: l.quantity + 1 } : l))
                       : [...c, { product_id: p.id, quantity: 1 }];
            })}><Plus size={13} /> Add</button></li>))}</ul></div>
        <div className="card"><div className="card-head"><h3>Bill ({cart.length})</h3></div>
          <ul className="rows">{detailed.map((l) => (
            <li key={l.product_id}><span><strong>{l.name}</strong>
            <small> · {inr(l.price)} x {l.quantity}</small></span>
            <span className="row-actions">
              <button className="btn icon" onClick={() => setCart((c) => c.map((x) => x.product_id === l.product_id ? { ...x, quantity: Math.max(1, x.quantity - 1) } : x))}><Minus size={12} /></button>
              <button className="btn icon" onClick={() => setCart((c) => c.map((x) => x.product_id === l.product_id ? { ...x, quantity: x.quantity + 1 } : x))}><Plus size={12} /></button>
              <button className="btn icon danger" onClick={() => setCart((c) => c.filter((x) => x.product_id !== l.product_id))}><Trash2 size={12} /></button>
            </span></li>))}</ul>
          <div className="form-grid">
            <label>Payment<select value={paymentMethod} onChange={(e) => setPaymentMethod(e.target.value)}>
              <option value="cash">Cash</option><option value="upi">UPI</option>
              <option value="card">Card</option><option value="credit">Credit</option></select></label>
            <label>Customer<select value={customerId} onChange={(e) => setCustomerId(e.target.value)}>
              <option value="">Walk-in</option>
              {allCustomers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select></label>
            <label>Discount<input type="number" value={billDiscount} onChange={(e) => setBillDiscount(Number(e.target.value))} /></label>
            <label>Tax<input type="number" value={billTax} onChange={(e) => setBillTax(Number(e.target.value))} /></label>
          </div>
          <div className="totals"><div><span>Total</span><strong>{inr(total)}</strong></div></div>
          <button className="btn primary block" onClick={checkout} disabled={!cart.length}>Generate bill</button>
        </div>
      </div>
    </div>
  );
}