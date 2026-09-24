import * as productModel from '../models/product.model.js';

// GET /api/products
export async function list(req, res, next) {
  try {
    const { search, category, lowStock, active } = req.query;
    const filters = {
      storeId: req.user?.storeId || null,
      search: search || undefined,
      categoryId: category || undefined,
      lowStock: lowStock === 'true' ? true : undefined,
      isActive: active !== undefined ? active === 'true' : undefined,
    };
    const rows = await productModel.list(filters);
    res.json({ success: true, data: rows });
  } catch (error) {
    next(error);
  }
}

// GET /api/products/lookup?q=...  (fast search for the POS)
export async function lookup(req, res, next) {
  try {
    const { q, limit = 50 } = req.query;
    if (!q || q.toString().trim().length === 0) {
      return res.status(400).json({
        success: false,
        message: 'Search query parameter "q" is required',
      });
    }
    const rows = await productModel.lookup(q, limit);
    res.json({ success: true, data: rows });
  } catch (error) {
    next(error);
  }
}

// GET /api/products/:id
export async function getById(req, res, next) {
  try {
    const product = await productModel.getById(req.params.id);
    if (!product) {
      return res.status(404).json({ success: false, message: 'Product not found' });
    }
    res.json({ success: true, data: product });
  } catch (error) {
    next(error);
  }
}

// POST /api/products
export async function create(req, res, next) {
  try {
    const storeId = req.user?.storeId;
    if (!storeId) {
      return res.status(400).json({
        success: false,
        message: 'Store ID not found in user session',
      });
    }

    const conflict = await productModel.findConflict(storeId, req.body.sku, req.body.barcode);
    if (conflict) {
      return res.status(409).json({
        success: false,
        message: 'Product with this SKU or barcode already exists',
      });
    }

    const product = await productModel.create(storeId, req.body);
    res.status(201).json({ success: true, data: product });
  } catch (error) {
    next(error);
  }
}

// PUT /api/products/:id
export async function update(req, res, next) {
  try {
    const storeId = req.user?.storeId;
    if (!storeId) {
      return res.status(400).json({
        success: false,
        message: 'Store ID not found in user session',
      });
    }

    const result = await productModel.update(req.params.id, storeId, req.body);
    if (result?.error === 'no_fields') {
      return res.status(400).json({ success: false, message: 'No fields to update' });
    }
    if (!result) {
      return res.status(404).json({ success: false, message: 'Product not found' });
    }
    res.json({ success: true, data: result });
  } catch (error) {
    next(error);
  }
}

// DELETE /api/products/:id  (soft delete)
export async function remove(req, res, next) {
  try {
    const storeId = req.user?.storeId;
    if (!storeId) {
      return res.status(400).json({
        success: false,
        message: 'Store ID not found in user session',
      });
    }

    const product = await productModel.softDelete(req.params.id, storeId);
    if (!product) {
      return res.status(404).json({ success: false, message: 'Product not found' });
    }
    res.json({
      success: true,
      data: product,
      message: 'Product deleted successfully',
    });
  } catch (error) {
    next(error);
  }
}
