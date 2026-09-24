import * as reportModel from '../models/report.model.js';

function storeIdOf(req, res) {
  const storeId = req.user?.storeId;
  if (!storeId) {
    res.status(400).json({
      success: false,
      message: 'Store ID not found in user session',
    });
    return null;
  }
  return storeId;
}

// GET /api/reports/summary — dashboard vitals in one round trip.
export async function summary(req, res, next) {
  try {
    const storeId = storeIdOf(req, res);
    if (!storeId) return;
    const data = await reportModel.summary(storeId);
    res.json({ success: true, data });
  } catch (error) {
    next(error);
  }
}

// GET /api/reports/product-sales — which products earn revenue (view from 020).
export async function productSales(req, res, next) {
  try {
    const storeId = storeIdOf(req, res);
    if (!storeId) return;
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 100, 1), 500);
    const rows = await reportModel.productSales(storeId, limit);
    res.json({ success: true, data: rows });
  } catch (error) {
    next(error);
  }
}

// GET /api/reports/movements — recent stock ledger.
export async function movements(req, res, next) {
  try {
    const storeId = storeIdOf(req, res);
    if (!storeId) return;
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 50, 1), 200);
    const rows = await reportModel.movements(storeId, limit);
    res.json({ success: true, data: rows });
  } catch (error) {
    next(error);
  }
}
