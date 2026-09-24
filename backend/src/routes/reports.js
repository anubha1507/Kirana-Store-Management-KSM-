import { Router } from 'express';
import { authMiddleware } from '../middleware/auth.js';
import * as reports from '../controllers/reports.controller.js';

const router = Router();

// GET /api/reports/summary — today + all-time totals + store vitals
router.get('/summary', authMiddleware, reports.summary);

// GET /api/reports/product-sales — revenue by product (020 view)
router.get('/product-sales', authMiddleware, reports.productSales);

// GET /api/reports/movements — recent stock ledger
router.get('/movements', authMiddleware, reports.movements);

export default router;
