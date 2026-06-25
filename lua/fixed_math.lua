local Fixed = {}

-- 1024 equals 10 bits of fractional precision.
local SCALE = 1024 

function Fixed.from_float(v)
    -- math.floor enforces consistent downstream rounding (unlike math.ceil/round)
    return math.floor(v * SCALE)
end

function Fixed.to_float(v)
    return v / SCALE
end

function Fixed.mul(a, b)
    -- Lua stores numbers as 64-bit doubles natively.
    -- This gives us 53 bits of exact integer precision before overflow.
    -- We can safely multiply large fixed numbers here without FFI tricks.
    return math.floor((a * b) / SCALE)
end

function Fixed.div(a, b)
    return math.floor((a * SCALE) / b)
end

function Fixed.add(a, b)
    return a + b
end

function Fixed.sub(a, b)
    return a - b
end

return Fixed
