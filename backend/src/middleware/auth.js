import { StatusCodes } from 'http-status-codes';
import { verifySessionToken } from '../utils/auth.js';

export function authMiddleware(req, res, next) {
  const header = req.headers.authorization || '';
  const parts = header.split(' ');
  if (parts[0] !== 'Bearer' || !parts[1]) {
    return res.status(StatusCodes.UNAUTHORIZED).json({
      success: false,
      error: 'unauthorized',
      message: 'A valid Bearer token is required.',
    });
  }

  try {
    const payload = verifySessionToken(parts[1]);
    const user = {
      id: payload.sub,
      role: payload.role,
      storeId: payload.storeId || null,
      email: payload.email || null,
    };
    req.backendUser = user;
    // Back-compat: existing CRUD routes read req.user
    req.user = user;
    next();
  } catch (error) {
    return res.status(StatusCodes.UNAUTHORIZED).json({
      success: false,
      error: 'invalid_token',
      message: 'Token is invalid or expired.',
    });
  }
}

export function optionalAuthMiddleware(req, res, next) {
  const header = req.headers.authorization || '';
  const parts = header.split(' ');
  if (parts[0] !== 'Bearer' || !parts[1]) {
    return next();
  }

  try {
    const payload = verifySessionToken(parts[1]);
    const user = {
      id: payload.sub,
      role: payload.role,
      storeId: payload.storeId || null,
      email: payload.email || null,
    };
    req.backendUser = user;
    req.user = user;
  } catch (_error) {
    // Ignore invalid tokens for optional auth
  }

  next();
}

export function requireRole(...roles) {
  return (req, res, next) => {
    const role = req.backendUser?.role || req.user?.role;
    if (!role || !roles.includes(role)) {
      return res.status(StatusCodes.FORBIDDEN).json({
        success: false,
        error: 'forbidden',
        message: 'You do not have permission to perform this action.',
      });
    }
    next();
  };
}

