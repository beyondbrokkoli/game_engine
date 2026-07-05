-- lua/vmath.lua
local ffi = require("ffi")
local math = require("math")

local vmath = {}

ffi.cdef[[
    typedef struct __attribute__((aligned(16))) { float x, y, z, w; } vec4_t;
    typedef struct __attribute__((aligned(16))) { float m[16]; } mat4_t;
]]

-- [FIX APPLIED] Removed all root-level temp FFI allocations

function vmath.lookAt(eye_x, eye_y, eye_z, center_x, center_y, center_z, out_mat)
    -- Use raw local variables instead of FFI structs
    local fx = center_x - eye_x
    local fy = center_y - eye_y
    local fz = center_z - eye_z

    local f_inv = 1.0 / math.sqrt(fx^2 + fy^2 + fz^2)
    fx = fx * f_inv
    fy = fy * f_inv
    fz = fz * f_inv

    local up_x = 0.0
    local up_y = 1.0
    local up_z = 0.0

    if math.abs(fx) < 0.001 and math.abs(fz) < 0.001 then
        if fy > 0 then up_z = -1.0 else up_z = 1.0 end
        up_y = 0.0
        up_x = 0.0
    end

    local rx = up_y * fz - up_z * fy
    local ry = up_z * fx - up_x * fz
    local rz = up_x * fy - up_y * fx

    local r_inv = 1.0 / math.sqrt(rx^2 + ry^2 + rz^2)
    rx = rx * r_inv
    ry = ry * r_inv
    rz = rz * r_inv

    local ux = fy * rz - fz * ry
    local uy = fz * rx - fx * rz
    local uz = fx * ry - fy * rx

    out_mat.m[0] = rx;  out_mat.m[1] = ux;  out_mat.m[2] = -fx;  out_mat.m[3] = 0.0;
    out_mat.m[4] = ry;  out_mat.m[5] = uy;  out_mat.m[6] = -fy;  out_mat.m[7] = 0.0;
    out_mat.m[8] = rz;  out_mat.m[9] = uz;  out_mat.m[10] = -fz; out_mat.m[11] = 0.0;

    out_mat.m[12] = -(rx*eye_x + ry*eye_y + rz*eye_z)
    out_mat.m[13] = -(ux*eye_x + uy*eye_y + uz*eye_z)
    out_mat.m[14] = (fx*eye_x + fy*eye_y + fz*eye_z)
    out_mat.m[15] = 1.0
end

function vmath.multiply_mat4(a, b, out_mat)
    -- Cache values locally to allow 'out_mat' to be the same pointer as 'a' or 'b'
    -- without causing data corruption mid-calculation.
    local a00 = a.m[0]; local a10 = a.m[4]; local a20 = a.m[8];  local a30 = a.m[12]
    local a01 = a.m[1]; local a11 = a.m[5]; local a21 = a.m[9];  local a31 = a.m[13]
    local a02 = a.m[2]; local a12 = a.m[6]; local a22 = a.m[10]; local a32 = a.m[14]
    local a03 = a.m[3]; local a13 = a.m[7]; local a23 = a.m[11]; local a33 = a.m[15]

    local b00 = b.m[0]; local b10 = b.m[4]; local b20 = b.m[8];  local b30 = b.m[12]
    local b01 = b.m[1]; local b11 = b.m[5]; local b21 = b.m[9];  local b31 = b.m[13]
    local b02 = b.m[2]; local b12 = b.m[6]; local b22 = b.m[10]; local b32 = b.m[14]
    local b03 = b.m[3]; local b13 = b.m[7]; local b23 = b.m[11]; local b33 = b.m[15]

    out_mat.m[0]  = a00*b00 + a10*b01 + a20*b02 + a30*b03
    out_mat.m[1]  = a01*b00 + a11*b01 + a21*b02 + a31*b03
    out_mat.m[2]  = a02*b00 + a12*b01 + a22*b02 + a32*b03
    out_mat.m[3]  = a03*b00 + a13*b01 + a23*b02 + a33*b03

    out_mat.m[4]  = a00*b10 + a10*b11 + a20*b12 + a30*b13
    out_mat.m[5]  = a01*b10 + a11*b11 + a21*b12 + a31*b13
    out_mat.m[6]  = a02*b10 + a12*b11 + a22*b12 + a32*b13
    out_mat.m[7]  = a03*b10 + a13*b11 + a23*b12 + a33*b13

    out_mat.m[8]  = a00*b20 + a10*b21 + a20*b22 + a30*b23
    out_mat.m[9]  = a01*b20 + a11*b21 + a21*b22 + a31*b23
    out_mat.m[10] = a02*b20 + a12*b21 + a22*b22 + a32*b23
    out_mat.m[11] = a03*b20 + a13*b21 + a23*b22 + a33*b23

    out_mat.m[12] = a00*b30 + a10*b31 + a20*b32 + a30*b33
    out_mat.m[13] = a01*b30 + a11*b31 + a21*b32 + a31*b33
    out_mat.m[14] = a02*b30 + a12*b31 + a22*b32 + a32*b33
    out_mat.m[15] = a03*b30 + a13*b31 + a23*b32 + a33*b33
end

-- Strictly Standard Vulkan Orthographic [0, 1] Z-Space
function vmath.ortho_vk(left, right, bottom, top, near, far, out_mat)
    out_mat.m[0] = 2.0 / (right - left)
    out_mat.m[4] = 0.0
    out_mat.m[8] = 0.0
    out_mat.m[12] = -(right + left) / (right - left)

    out_mat.m[1] = 0.0
    out_mat.m[5] = 2.0 / (bottom - top)
    out_mat.m[9] = 0.0
    out_mat.m[13] = -(bottom + top) / (bottom - top)

    out_mat.m[2] = 0.0
    out_mat.m[6] = 0.0

    -- FIX: Invert the sign to map Closer objects to smaller Z values
    out_mat.m[10] = -1.0 / (far - near)

    out_mat.m[14] = -near / (far - near)

    out_mat.m[3] = 0.0
    out_mat.m[7] = 0.0
    out_mat.m[11] = 0.0
    out_mat.m[15] = 1.0
end

function vmath.multiply_mat4_vec4(m, x, y, z, w, out_vec)
    out_vec.x = m.m[0]*x + m.m[4]*y + m.m[8]*z  + m.m[12]*w
    out_vec.y = m.m[1]*x + m.m[5]*y + m.m[9]*z  + m.m[13]*w
    out_vec.z = m.m[2]*x + m.m[6]*y + m.m[10]*z + m.m[14]*w
    out_vec.w = m.m[3]*x + m.m[7]*y + m.m[11]*z + m.m[15]*w
end

function vmath.inverse_mat4(m, invOut)
    local inv = invOut.m
    local m00 = m.m[0];  local m01 = m.m[1];  local m02 = m.m[2];  local m03 = m.m[3]
    local m10 = m.m[4];  local m11 = m.m[5];  local m12 = m.m[6];  local m13 = m.m[7]
    local m20 = m.m[8];  local m21 = m.m[9];  local m22 = m.m[10]; local m23 = m.m[11]
    local m30 = m.m[12]; local m31 = m.m[13]; local m32 = m.m[14]; local m33 = m.m[15]

    inv[0] = m11*(m22*m33 - m23*m32) - m12*(m21*m33 - m23*m31) + m13*(m21*m32 - m22*m31)
    inv[4] = -m10*(m22*m33 - m23*m32) + m12*(m20*m33 - m23*m30) - m13*(m20*m32 - m22*m30)
    inv[8] = m10*(m21*m33 - m23*m31) - m11*(m20*m33 - m23*m30) + m13*(m20*m31 - m21*m30)
    inv[12] = -m10*(m21*m32 - m22*m31) + m11*(m20*m32 - m22*m30) - m12*(m20*m31 - m21*m30)

    inv[1] = -m01*(m22*m33 - m23*m32) + m02*(m21*m33 - m23*m31) - m03*(m21*m32 - m22*m31)
    inv[5] = m00*(m22*m33 - m23*m32) - m02*(m20*m33 - m23*m30) + m03*(m20*m32 - m22*m30)
    inv[9] = -m00*(m21*m33 - m23*m31) + m01*(m20*m33 - m23*m30) - m03*(m20*m31 - m21*m30)
    inv[13] = m00*(m21*m32 - m22*m31) - m01*(m20*m32 - m22*m30) + m02*(m20*m31 - m21*m30)

    inv[2] = m01*(m12*m33 - m13*m32) - m02*(m11*m33 - m13*m31) + m03*(m11*m32 - m12*m31)
    inv[6] = -m00*(m12*m33 - m13*m32) + m02*(m10*m33 - m13*m30) - m03*(m10*m32 - m12*m30)
    inv[10] = m00*(m11*m33 - m13*m31) - m01*(m10*m33 - m13*m30) + m03*(m10*m31 - m11*m30)
    inv[14] = -m00*(m11*m32 - m12*m31) + m01*(m10*m32 - m12*m30) - m02*(m10*m31 - m11*m30)

    inv[3] = -m01*(m12*m23 - m13*m22) + m02*(m11*m23 - m13*m21) - m03*(m11*m22 - m12*m21)
    inv[7] = m00*(m12*m23 - m13*m22) - m02*(m10*m23 - m13*m20) + m03*(m10*m22 - m12*m20)
    inv[11] = -m00*(m11*m23 - m13*m21) + m01*(m10*m23 - m13*m20) - m03*(m10*m21 - m11*m20)
    inv[15] = m00*(m11*m22 - m12*m21) - m01*(m10*m22 - m12*m20) + m02*(m10*m21 - m11*m20)

    local det = m00*inv[0] + m01*inv[4] + m02*inv[8] + m03*inv[12]
    if det == 0 then return false end
    det = 1.0 / det
    for i = 0, 15 do inv[i] = inv[i] * det end
    return true
end

return vmath
