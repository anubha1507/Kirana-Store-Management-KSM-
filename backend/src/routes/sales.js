import { Router } from 'express';
import { body, param } from 'express-validator';
import { authMiddleware } from '../middleware/auth.js';
import { handleValidation } from '../middleware/validate.js';
import * as sales from '../controllers/sales.controller.js';

const router = Router();

router.get('/', authMiddleware, sales.list);
router.get('/:id', authMiddleware, sales.getById);

router.post(
  '/',
  authMiddleware,
  [
    body('items').isArray({ min: 1 }),
    body('items.*.product_id').isUUID(),
    body('items.*.quantity').isFloat({ min: 0.001 }),
    body('items.*.discount').optional().isFloat({ min: 0 }),
    body('payment_method').isIn(['cash', 'upi', 'card', 'credit', 'mixed']),
    body('customer_id').optional({ nullable: true }).isUUID(),
    body('discount_amount').optional().isFloat({ min: 0 }),
    body('tax_amount').optional().isFloat({ min: 0 }),
    body('notes').optional().isString(),
    body('request_id').optional().isUUID(),
  ],
  handleValidation,
  sales.create
);

router.post(
  '/:id/cancel',
  authMiddleware,
  [param('id').isUUID(), body('reason').optional().isString()],
  handleValidation,
  sales.cancel
);

export default router;
