import * as saleModel from '../models/sale.model.js';

// GET /api/sales
export async function list(req, res, next) {
  try {
    const { startDate, endDate, customerId, paymentMethod } = req.query;
    const rows = await saleModel.list({
      storeId: req.user?.storeId,
      startDate,
      endDate,
      customerId,
      paymentMethod,
    });
    res.json({ success: true, data: rows });
  } catch (error) {
    next(error);
  }
}

// GET /api/sales/:id  (with line items)
export async function getById(req, res, next) {
  try {
    const sale = await saleModel.getById(req.params.id, req.user?.storeId);
    if (!sale) {
      return res.status(404).json({ success: false, message: 'Sale not found' });
    }
    sale.items = await saleModel.items(sale.id);
    res.json({ success: true, data: sale });
  } catch (error) {
    next(error);
  }
}

// POST /api/sales  — checkout through the create_sale RPC.
export async function create(req, res, next) {
  try {
    const storeId = req.user?.storeId;
    if (!storeId) {
      return res.status(400).json({
        success: false,
        message: 'Store ID not found in user session',
      });
    }

    const { items, payment_method, customer_id, discount_amount, tax_amount, notes, request_id } = req.body;

    const saleResult = await saleModel.createSale({
      user: req.user,
      storeId,
      items,
      paymentMethod: payment_method,
      customerId: customer_id,
      discountAmount: discount_amount,
      taxAmount: tax_amount,
      notes,
      requestId: request_id || null,
    });

    if (!saleResult) {
      return res.status(400).json({ success: false, message: 'Failed to create sale' });
    }

    const saleItems = await saleModel.items(saleResult.sale_id);

    res.status(201).json({
      success: true,
      data: {
        id: saleResult.sale_id,
        invoice_number: saleResult.invoice_number,
        subtotal: parseFloat(saleResult.subtotal),
        discount_amount: parseFloat(saleResult.discount_amount),
        tax_amount: parseFloat(saleResult.tax_amount),
        total_amount: parseFloat(saleResult.total_amount),
        payment_method: saleResult.payment_method,
        payment_status: saleResult.payment_status,
        amount_paid: parseFloat(saleResult.amount_paid),
        items: saleItems,
      },
    });
  } catch (error) {
    next(error);
  }
}

// POST /api/sales/:id/cancel  — cancel_sale RPC (manager+), audited.
export async function cancel(req, res, next) {
  try {
    const storeId = req.user?.storeId;
    if (!storeId) {
      return res.status(400).json({
        success: false,
        message: 'Store ID not found in user session',
      });
    }

    const reason = req.body.reason || 'Cancelled by user';
    const result = await saleModel.cancelSale({
      user: req.user,
      id: req.params.id,
      reason,
      userId: req.user?.id,
    });

    if (!result) {
      return res.status(400).json({ success: false, message: 'Failed to cancel sale' });
    }

    res.json({ success: true, data: result, message: 'Sale cancelled successfully' });
  } catch (error) {
    next(error);
  }
}
