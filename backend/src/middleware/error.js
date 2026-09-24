import { StatusCodes } from 'http-status-codes';

export function errorHandler(err, req, res, next) {
  console.error('Unhandled backend error:', err);

  if (res.headersSent) {
    return next(err);
  }

  const message = err?.message || 'Internal server error';
  const statusCode = (() => {
    if (err?.status || err?.statusCode) return err.status || err.statusCode;
    if (err.type === 'entity.parse.failed') return StatusCodes.BAD_REQUEST;
    if (err.name === 'ValidationError') return StatusCodes.BAD_REQUEST;
    const code = typeof err?.code === 'string' ? err.code : '';
    if (code === '23505') return StatusCodes.CONFLICT;
    if (code === '23503') return StatusCodes.BAD_REQUEST;
    if (code === '22P02') return StatusCodes.BAD_REQUEST;
    if (code === '42501') return StatusCodes.FORBIDDEN;
    // SQL RAISE EXCEPTION rule violations (credit limit, payment ceiling,
    // stock guards, ...) surface as client errors, not server bugs.
    if (/^(22|235|P0001)/.test(code)) return StatusCodes.BAD_REQUEST;
    return StatusCodes.INTERNAL_SERVER_ERROR;
  })();

  res.status(statusCode).json({
    success: false,
    error: statusCode === StatusCodes.INTERNAL_SERVER_ERROR ? 'server_error' : 'bad_request',
    message: statusCode === StatusCodes.INTERNAL_SERVER_ERROR ? 'Something went wrong.' : message,
    ...(process.env.NODE_ENV === 'development' && { stack: err?.stack }),
  });
}

export function notFoundHandler(req, res) {
  res.status(StatusCodes.NOT_FOUND).json({
    success: false,
    error: 'not_found',
    message: `No route matched ${req.method} ${req.originalUrl}`,
  });
}

