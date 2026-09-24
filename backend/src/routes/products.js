import { Router } from 'express';
import { body } from 'express-validator';
import { authMiddleware } from '../middleware/auth.js';
import { handleValidation } from '../middleware/validate.js';
import * as products from '../controllers/products.controller.js';

const router = Router();

router.get('/', authMiddleware, products.list);

// GET /api/products/lookup?q=... — POS search
router.get('/lookup', authMiddleware, products.lookup);

router.get('/:id', authMiddleware, products.getById);

router.post(
  '/',
  authMiddleware,
  [
    body('name').isString().notEmpty().trim(),
    body('selling_price').isFloat({ min: 0 }),
    body('stock_quantity').isFloat({ min: 0 }),
    body('unit').optional().isString(),
    body('sku').optional().isString().trim(),
    body('barcode').optional().isString().trim(),
    body('category_id').optional().isUUID(),
    body('cost_price').optional().isFloat({ min: 0 }),
    body('low_stock_threshold').optional().isFloat({ min: 0 }),
    body('description').optional().isString(),
  ],
  handleValidation,
  products.create
);

router.put('/:id', authMiddleware, products.update);
router.delete('/:id', authMiddleware, products.remove);

export default router;
