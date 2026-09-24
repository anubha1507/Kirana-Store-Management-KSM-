import { validationResult } from 'express-validator';

// Shared express-validator result handler. Routes declare their validation
// chains; controllers can then assume the payload is clean.
export function handleValidation(req, res, next) {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({
      success: false,
      message: 'Validation failed',
      errors: errors.array(),
    });
  }
  return next();
}
