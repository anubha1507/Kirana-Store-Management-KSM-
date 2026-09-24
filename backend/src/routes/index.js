import { Router } from 'express';
import authRoutes from './auth.js';
import userRoutes from './users.js';
import salesRoutes from './sales.js';
import productRoutes from './products.js';
import customerRoutes from './customers.js';
import purchaseRoutes from './purchases.js';
import reportRoutes from './reports.js';

export const router = Router();

router.use('/auth', authRoutes);
router.use('/users', userRoutes);
router.use('/sales', salesRoutes);
router.use('/products', productRoutes);
router.use('/customers', customerRoutes);
router.use('/purchases', purchaseRoutes);
router.use('/reports', reportRoutes);

router.get('/ping', (_req, res) => {
  res.json({ ok: true, time: new Date().toISOString() });
});
