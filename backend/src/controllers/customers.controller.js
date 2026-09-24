import * as customerModel from '../models/customer.model.js';

// GET /api/customers
export async function list(req, res, next) {
  try {
    const { search, active } = req.query;
    const rows = await customerModel.list({ search, active });
    res.json({ success: true, data: rows });
  } catch (error) {
    next(error);
  }
}

// GET /api/customers/lookup?q=...  (fast search for the POS)
export async function lookup(req, res, next) {
  try {
    const { q, limit = 50 } = req.query;
    if (!q || q.toString().trim().length === 0) {
      return res.status(400).json({
        success: false,
        message: 'Search query parameter "q" is required',
      });
    }
    const rows = await customerModel.lookup(q, limit);
    res.json({ success: true, data: rows });
  } catch (error) {
    next(error);
  }
}

// GET /api/customers/:id
export async function getById(req, res, next) {
  try {
    const customer = await customerModel.getById(req.params.id);
    if (!customer) {
      return res.status(404).json({ success: false, message: 'Customer not found' });
    }
    res.json({ success: true, data: customer });
  } catch (error) {
    next(error);
  }
}

// POST /api/customers
export async function create(req, res, next) {
  try {
    const storeId = req.user?.storeId;
    if (!storeId) {
      return res.status(400).json({
        success: false,
        message: 'Store ID not found in user session',
      });
    }

    const conflict = await customerModel.findPhoneConflict(storeId, req.body.phone);
    if (conflict) {
      return res.status(409).json({
        success: false,
        message: 'Customer with this phone already exists',
      });
    }

    const customer = await customerModel.create(storeId, req.body);
    res.status(201).json({ success: true, data: customer });
  } catch (error) {
    next(error);
  }
}

// PUT /api/customers/:id  (balance is ledger-derived and never set here)
export async function update(req, res, next) {
  try {
    const storeId = req.user?.storeId;
    if (!storeId) {
      return res.status(400).json({
        success: false,
        message: 'Store ID not found in user session',
      });
    }

    const result = await customerModel.update(req.params.id, storeId, req.body);
    if (result?.error === 'no_fields') {
      return res.status(400).json({ success: false, message: 'No fields to update' });
    }
    if (!result) {
      return res.status(404).json({ success: false, message: 'Customer not found' });
    }
    res.json({ success: true, data: result });
  } catch (error) {
    next(error);
  }
}

// DELETE /api/customers/:id  (soft delete)
export async function remove(req, res, next) {
  try {
    const storeId = req.user?.storeId;
    if (!storeId) {
      return res.status(400).json({
        success: false,
        message: 'Store ID not found in user session',
      });
    }

    const customer = await customerModel.softDelete(req.params.id, storeId);
    if (!customer) {
      return res.status(404).json({ success: false, message: 'Customer not found' });
    }
    res.json({
      success: true,
      data: customer,
      message: 'Customer deleted successfully',
    });
  } catch (error) {
    next(error);
  }
}

// POST /api/customers/:id/pay  — record an udhaar payment via the
// record_customer_payment RPC (ledger-driven, payment-ceiling guarded).
export async function pay(req, res, next) {
  try {
    const storeId = req.user?.storeId;
    if (!storeId) {
      return res.status(400).json({
        success: false,
        message: 'Store ID not found in user session',
      });
    }

    const { amount, payment_method, notes, request_id } = req.body;
    const result = await customerModel.recordPayment({
      user: req.user,
      storeId,
      customerId: req.params.id,
      amount,
      paymentMethod: payment_method,
      notes: notes || null,
      requestId: request_id || null,
    });

    res.json({ success: true, data: result });
  } catch (error) {
    next(error);
  }
}
