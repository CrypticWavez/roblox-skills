"""Roblox (Y-up, -Z forward, studs) <-> Blender (Z-up, -Y forward) conversion."""
import math
from mathutils import Matrix, Vector


def rbx_to_blender_vec(x, y, z):
    return Vector((x, -z, y))


def rbx_rotation_matrix(rx_deg, ry_deg, rz_deg):
    """Roblox CFrame.fromOrientation: R = Ry * Rx * Rz (angles in degrees)."""
    rx, ry, rz = (math.radians(a) for a in (rx_deg, ry_deg, rz_deg))
    Rx = Matrix.Rotation(rx, 3, "X")
    Ry = Matrix.Rotation(ry, 3, "Y")
    Rz = Matrix.Rotation(rz, 3, "Z")
    return Ry @ Rx @ Rz


# Basis change B maps Roblox axes to Blender axes: (x, y, z) -> (x, -z, y)
BASIS = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))


def rbx_to_blender_matrix(pos, rot_deg):
    r = BASIS @ rbx_rotation_matrix(*rot_deg) @ BASIS.transposed()
    m = r.to_4x4()
    m.translation = rbx_to_blender_vec(*pos)
    return m


def rbx_size_to_blender(sx, sy, sz):
    """Local size is expressed in the rotated basis, so axes map the same way (abs)."""
    return Vector((sx, sz, sy))
