import * as purchaseModel from '../models/purchase.model.js';

// GET /api/purchases
export async function list(req, res, next) {
  try {
    const { startDate, endDate, supplierId } = req.query;
    const rows = await purchaseModel.list({
      storeId: req.user?.storeId,
      startDate,
      endDate,
      supplierId,
    });
    res.json({ success: true, data: rows });
  } catch (error) {
    next(error);
  }
}

// GET /api/purchases/:id  (with line items)
export async function getById(req, res, next) {
  try {
    const purchase = await purchaseModel.getById(req.params.id, req.user?.storeId);
    if (!purchase) {
      return res.status(404).json({ success: false, message: 'Purchase not found' });
    }
    purchase.items = await purchaseModel.items(purchase.id);
    res.json({ success: true, data: purchase });
  } catch (error) {
    next(error);
  }
}

// POST /api/purchases  — goods-in through the create_purchase RPC.
export async function create(req, res, next) {
  try {
    const storeId = req.user?.storeId;
    if (!storeId) {
      return res.status(400).json({
        success: false,
        message: 'Store ID not found in user session',
      });
    }

    const { items, supplier_id, invoice_number, payment_status, notes, request_id } = req.body;

    const purchaseResult = await purchaseModel.createPurchase({
      user: req.user,
      storeId,
      items,
      supplierId: supplier_id,
      invoiceNumber: invoice_number,
      paymentStatus: payment_status,
      notes,
      requestId: request_id || null,
    });

    if (!purchaseResult) {
      return res.status(400).json({ success: false, message: 'Failed to create purchase' });
    }

    const purchaseItems = await purchaseModel.items(purchaseResult.purchase_id);

    res.status(201).json({
      success: true,
      data: {
        id: purchaseResult.purchase_id,
        invoice_number: purchaseResult.invoice_number,
        subtotal: parseFloat(purchaseResult.subtotal),
        tax_amount: parseFloat(purchaseResult.tax_amount),
        discount_amount: parseFloat(purchaseResult.discount_amount),
        total_amount: parseFloat(purchaseResult.total_amount),
        payment_status: purchaseResult.payment_status,
        items: purchaseItems,
      },
    });
  } catch (error) {
    next(error);
  }
}

// POST /api/purchases/:id/cancel  (soft cancel with reason, audited)
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
    const purchase = await purchaseModel.cancelPurchase(req.params.id, storeId, reason);

    if (!purchase) {
      return res.status(404).json({
        success: false,
        message: 'Purchase not found or already cancelled',
      });
    }

    res.json({
      success: true,
      data: purchase,
      message: 'Purchase cancelled successfully',
    });
  } catch (error) {
    next(error);
  }
}
