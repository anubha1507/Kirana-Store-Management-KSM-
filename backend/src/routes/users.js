import { Router } from 'express';
import { authMiddleware } from '../middleware/auth.js';
import * as users from '../controllers/users.controller.js';

const router = Router();

router.get('/', authMiddleware, users.list);
router.get('/:id', authMiddleware, users.getById);
router.put('/:id', authMiddleware, users.update);
router.delete('/:id', authMiddleware, users.remove);

export default router;
