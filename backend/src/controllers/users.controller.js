import * as userModel from '../models/user.model.js';

// GET /api/users
export async function list(_req, res, next) {
  try {
    const rows = await userModel.list();
    res.json({ success: true, data: rows });
  } catch (error) {
    next(error);
  }
}

// GET /api/users/:id
export async function getById(req, res, next) {
  try {
    const user = await userModel.findById(req.params.id);
    if (!user) {
      return res.status(404).json({ success: false, message: 'User not found' });
    }
    res.json({ success: true, data: user });
  } catch (error) {
    next(error);
  }
}

// PUT /api/users/:id
export async function update(req, res, next) {
  try {
    const { fullName, role, avatarUrl } = req.body;
    const user = await userModel.update(req.params.id, { fullName, role, avatarUrl });
    if (!user) {
      return res.status(404).json({ success: false, message: 'User not found' });
    }
    res.json({ success: true, data: user });
  } catch (error) {
    next(error);
  }
}

// DELETE /api/users/:id  (deactivate — accounts are never hard-deleted)
export async function remove(req, res, next) {
  try {
    const { id } = req.params;
    if (id === req.user?.id) {
      return res.status(400).json({ success: false, message: 'Cannot delete your own account' });
    }
    const user = await userModel.deactivate(id);
    if (!user) {
      return res.status(404).json({ success: false, message: 'User not found' });
    }
    res.json({
      success: true,
      data: user,
      message: 'User deactivated successfully',
    });
  } catch (error) {
    next(error);
  }
}
