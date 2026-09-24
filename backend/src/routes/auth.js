import { Router } from 'express';
import { body } from 'express-validator';
import { authMiddleware } from '../middleware/auth.js';
import { handleValidation } from '../middleware/validate.js';
import * as auth from '../controllers/auth.controller.js';

const router = Router();

// POST /api/auth/signup — create account + first store
router.post(
  '/signup',
  [
    body('email').isEmail().normalizeEmail(),
    body('password').isString().isLength({ min: 8 }),
    body('fullName').isString().notEmpty(),
    body('role').optional().isIn(['owner', 'manager', 'cashier']),
    body('store_name').optional().isString().trim().isLength({ min: 1, max: 200 }),
  ],
  handleValidation,
  auth.signup
);

// POST /api/auth/login
router.post(
  '/login',
  [
    body('email').isEmail().normalizeEmail(),
    body('password').isString().notEmpty(),
  ],
  handleValidation,
  auth.login
);

// POST /api/auth/logout — client discards its token (stateless JWTs)
router.post('/logout', auth.logout);

// POST /api/auth/refresh — rotate a still-valid token
router.post('/refresh', authMiddleware, auth.refresh);

// GET /api/auth/me — current user
router.get('/me', authMiddleware, auth.me);

// GET /api/auth/validate — token probe
router.get('/validate', auth.validate);

export default router;
