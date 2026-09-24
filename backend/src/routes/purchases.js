import { Router } from 'express';
import { body, param } from 'express-validator';
import { authMiddleware } from '../middleware/auth.js';
import { handleValidation } from '../middleware/validate.js';
import * as purchases from '../controllers/purchases.controller.js';

const router = Router();

router.get('/', authMiddleware, purchases.list);
router.get('/:id', authMiddleware, purchases.getById);

router.post(
  '/',
  authMiddleware,
  [
    body('items').isArray({ min: 1 }),
    body('items.*.product_id').isUUID(),
    body('items.*.quantity').isFloat({ min: 0.001 }),
    body('items.*.unit_cost').isFloat({ min: 0 }),
    body('supplier_id').optional().isUUID(),
    body('invoice_number').optional().isString().trim(),
    body('payment_status').optional().isIn(['paid', 'unpaid', 'partial']),
    body('notes').optional().isString(),
    body('request_id').optional().isUUID(),
  ],
  handleValidation,
  purchases.create
);

router.post(
  '/:id/cancel',
  authMiddleware,
  [param('id').isUUID(), body('reason').optional().isString()],
  handleValidation,
  purchases.cancel
);

export default router;
