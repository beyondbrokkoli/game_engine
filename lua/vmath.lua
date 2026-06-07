local ffi = require("ffi")
local math = require("math")

local vmath = {}

ffi.cdef[[
    typedef struct __attribute__((aligned(16))) { float x, y, z, w; } vec4_t;
    typedef struct __attribute__((aligned(16))) { float m[16]; } mat4_t;
]]

local temp_f = ffi.new("vec4_t")
local temp_u = ffi.new("vec4_t")
local temp_r = ffi.new("vec4_t")
local temp_mat = ffi.new("mat4_t")

function vmath.lookAt(eye_x, eye_y, eye_z, center_x, center_y, center_z, out_mat)
    temp_f.x = center_x - eye_x
    temp_f.y = center_y - eye_y
    temp_f.z = center_z - eye_z

    local f_inv = 1.0 / math.sqrt(temp_f.x^2 + temp_f.y^2 + temp_f.z^2)
    temp_f.x = temp_f.x * f_inv
    temp_f.y = temp_f.y * f_inv
    temp_f.z = temp_f.z * f_inv

    local up_x = 0.0
    local up_y = 1.0
    local up_z = 0.0

    if math.abs(temp_f.x) < 0.001 and math.abs(temp_f.z) < 0.001 then
        if temp_f.y > 0 then up_z = -1.0 else up_z = 1.0 end
        up_y = 0.0
        up_x = 0.0
    end

    temp_r.x = up_y * temp_f.z - up_z * temp_f.y
    temp_r.y = up_z * temp_f.x - up_x * temp_f.z
    temp_r.z = up_x * temp_f.y - up_y * temp_f.x

    local r_inv = 1.0 / math.sqrt(temp_r.x^2 + temp_r.y^2 + temp_r.z^2)
    temp_r.x = temp_r.x * r_inv
    temp_r.y = temp_r.y * r_inv
    temp_r.z = temp_r.z * r_inv

    temp_u.x = temp_f.y * temp_r.z - temp_f.z * temp_r.y
    temp_u.y = temp_f.z * temp_r.x - temp_f.x * temp_r.z
    temp_u.z = temp_f.x * temp_r.y - temp_f.y * temp_r.x

    out_mat.m[0] = temp_r.x;  out_mat.m[1] = temp_u.x;  out_mat.m[2] = -temp_f.x;  out_mat.m[3] = 0.0;
    out_mat.m[4] = temp_r.y;  out_mat.m[5] = temp_u.y;  out_mat.m[6] = -temp_f.y;  out_mat.m[7] = 0.0;
    out_mat.m[8] = temp_r.z;  out_mat.m[9] = temp_u.z;  out_mat.m[10] = -temp_f.z; out_mat.m[11] = 0.0;

    out_mat.m[12] = -(temp_r.x*eye_x + temp_r.y*eye_y + temp_r.z*eye_z)
    out_mat.m[13] = -(temp_u.x*eye_x + temp_u.y*eye_y + temp_u.z*eye_z)
    out_mat.m[14] = (temp_f.x*eye_x + temp_f.y*eye_y + temp_f.z*eye_z)
    out_mat.m[15] = 1.0
end

function vmath.multiply_mat4(a, b, out_mat)
    for col = 0, 3 do
        for row = 0, 3 do
            temp_mat.m[col*4 + row] = a.m[0*4 + row] * b.m[col*4 + 0] +
                                      a.m[1*4 + row] * b.m[col*4 + 1] +
                                      a.m[2*4 + row] * b.m[col*4 + 2] +
                                      a.m[3*4 + row] * b.m[col*4 + 3]
        end
    end
    for k = 0, 15 do
        out_mat.m[k] = temp_mat.m[k]
    end
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
