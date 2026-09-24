import { Router } from 'express';
import { body, param } from 'express-validator';
import { authMiddleware } from '../middleware/auth.js';
import { handleValidation } from '../middleware/validate.js';
import * as customers from '../controllers/customers.controller.js';

const router = Router();

router.get('/', authMiddleware, customers.list);

// GET /api/customers/lookup?q=... — POS search
router.get('/lookup', authMiddleware, customers.lookup);

router.get('/:id', authMiddleware, customers.getById);

router.post(
  '/',
  authMiddleware,
  [
    body('name').isString().notEmpty().trim(),
    body('phone').optional().isString().trim(),
    body('email').optional().isEmail(),
    body('address').optional().isString().trim(),
    body('credit_limit').optional().isFloat({ min: 0 }),
  ],
  handleValidation,
  customers.create
);

router.put('/:id', authMiddleware, customers.update);
router.delete('/:id', authMiddleware, customers.remove);

// POST /api/customers/:id/pay — record an udhaar payment (RPC-guarded)
router.post(
  '/:id/pay',
  authMiddleware,
  [
    param('id').isUUID(),
    body('amount').isFloat({ gt: 0 }),
    body('payment_method').optional().isIn(['cash', 'upi', 'card', 'mixed']),
    body('notes').optional().isString(),
    body('request_id').optional().isUUID(),
  ],
  handleValidation,
  customers.pay
);

export default router;
