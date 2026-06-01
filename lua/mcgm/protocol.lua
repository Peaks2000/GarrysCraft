MC_GM = MC_GM or {}
MC_GM.Protocol = {}

local P = MC_GM.Protocol
local band = bit.band
local bor = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

local function byte(s, i)
    return string.byte(s, i, i)
end

function P.readByte(data, offset)
    local value = byte(data, offset)
    return value, offset + 1
end

function P.readVarInt(data, offset)
    local numRead = 0
    local result = 0
    local read

    repeat
        read = byte(data, offset + numRead)
        if not read then return nil, offset end

        local value = band(read, 0x7F)
        result = bor(result, lshift(value, 7 * numRead))
        numRead = numRead + 1

        if numRead > 5 then
            return nil, offset, "VarInt too large"
        end
    until band(read, 0x80) == 0

    return result, offset + numRead
end

function P.writeVarInt(value)
    local out = {}
    value = tonumber(value) or 0

    repeat
        local temp = band(value, 0x7F)
        value = rshift(value, 7)
        if value ~= 0 then
            temp = bor(temp, 0x80)
        end
        out[#out + 1] = string.char(temp)
    until value == 0

    return table.concat(out)
end

function P.readString(data, offset)
    local len
    len, offset = P.readVarInt(data, offset)
    if not len then return nil, offset end

    local finish = offset + len - 1
    if #data < finish then return nil, offset end
    return string.sub(data, offset, finish), finish + 1
end

function P.writeString(value)
    value = tostring(value or "")
    return P.writeVarInt(#value) .. value
end

function P.readUnsignedShort(data, offset)
    local a, b = byte(data, offset), byte(data, offset + 1)
    if not a or not b then return nil, offset end
    return a * 256 + b, offset + 2
end

function P.writeUnsignedShort(value)
    value = value or 0
    return string.char(band(rshift(value, 8), 0xFF), band(value, 0xFF))
end

function P.writeShort(value)
    value = tonumber(value) or 0
    if value < 0 then value = 0x10000 + value end
    return string.char(band(rshift(value, 8), 0xFF), band(value, 0xFF))
end

function P.writeSlot(itemId, count, damage)
    itemId = tonumber(itemId) or -1
    if itemId < 0 then
        return P.writeShort(-1)
    end

    return P.writeShort(itemId) ..
        string.char(tonumber(count) or 1) ..
        P.writeShort(tonumber(damage) or 0) ..
        "\0"
end

function P.readDouble(data, offset)
    if string.unpack then
        local value = string.unpack(">d", data, offset)
        return value, offset + 8
    end

    if #data < offset + 7 then return nil, offset end

    local b1, b2, b3, b4 = byte(data, offset), byte(data, offset + 1), byte(data, offset + 2), byte(data, offset + 3)
    local b5, b6, b7, b8 = byte(data, offset + 4), byte(data, offset + 5), byte(data, offset + 6), byte(data, offset + 7)
    local high = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    local low = b5 * 16777216 + b6 * 65536 + b7 * 256 + b8
    local sign = high >= 0x80000000 and -1 or 1
    if sign == -1 then high = high - 0x80000000 end

    local exponent = math.floor(high / 0x100000)
    local mantissa = (high % 0x100000) * 4294967296 + low
    if exponent == 0 and mantissa == 0 then return 0, offset + 8 end

    local value = sign * (1 + mantissa / 4503599627370496) * 2 ^ (exponent - 1023)
    return value, offset + 8
end

function P.writeDouble(value)
    value = tonumber(value) or 0
    if string.pack then
        return string.pack(">d", value)
    end

    if value == 0 then return "\0\0\0\0\0\0\0\0" end

    local sign = 0
    if value < 0 then
        sign = 0x80000000
        value = -value
    end

    local exponent = math.floor(math.log(value) / math.log(2))
    local normalized = value / 2 ^ exponent
    local mantissa = math.floor((normalized - 1) * 4503599627370496 + 0.5)

    if mantissa >= 4503599627370496 then
        mantissa = 0
        exponent = exponent + 1
    end

    local biased = exponent + 1023
    local mantissaHigh = math.floor(mantissa / 4294967296)
    local mantissaLow = mantissa - mantissaHigh * 4294967296
    local high = sign + biased * 0x100000 + mantissaHigh

    return P.writeInt(high) .. P.writeInt(mantissaLow)
end

function P.readFloat(data, offset)
    if string.unpack then
        local value = string.unpack(">f", data, offset)
        return value, offset + 4
    end

    if #data < offset + 3 then return nil, offset end

    local b1, b2, b3, b4 = byte(data, offset), byte(data, offset + 1), byte(data, offset + 2), byte(data, offset + 3)
    local raw = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    local sign = raw >= 0x80000000 and -1 or 1
    if sign == -1 then raw = raw - 0x80000000 end

    local exponent = math.floor(raw / 0x800000)
    local mantissa = raw % 0x800000
    if exponent == 0 and mantissa == 0 then return 0, offset + 4 end

    local value = sign * (1 + mantissa / 8388608) * 2 ^ (exponent - 127)
    return value, offset + 4
end

function P.writeFloat(value)
    value = tonumber(value) or 0
    if string.pack then
        return string.pack(">f", value)
    end

    if value == 0 then return "\0\0\0\0" end

    local sign = 0
    if value < 0 then
        sign = 0x80000000
        value = -value
    end

    local exponent = math.floor(math.log(value) / math.log(2))
    local normalized = value / 2 ^ exponent
    local mantissa = math.floor((normalized - 1) * 8388608 + 0.5)

    if mantissa >= 8388608 then
        mantissa = 0
        exponent = exponent + 1
    end

    return P.writeInt(sign + (exponent + 127) * 0x800000 + mantissa)
end

function P.writeInt(value)
    value = tonumber(value) or 0
    if value < 0 then value = 0x100000000 + value end
    return string.char(
        band(rshift(value, 24), 0xFF),
        band(rshift(value, 16), 0xFF),
        band(rshift(value, 8), 0xFF),
        band(value, 0xFF)
    )
end

function P.readInt(data, offset)
    local a, b, c, d = byte(data, offset), byte(data, offset + 1), byte(data, offset + 2), byte(data, offset + 3)
    if not a or not b or not c or not d then return nil, offset end

    local value = a * 16777216 + b * 65536 + c * 256 + d
    if value >= 0x80000000 then value = value - 0x100000000 end
    return value, offset + 4
end

function P.writeLittleShort(value)
    value = tonumber(value) or 0
    if value < 0 then value = 0x10000 + value end
    return string.char(band(value, 0xFF), band(rshift(value, 8), 0xFF))
end

function P.readLong(data, offset)
    if #data < offset + 7 then return nil, offset end
    return string.sub(data, offset, offset + 7), offset + 8
end

function P.readPosition(data, offset)
    local hi, nextOffset = P.readInt(data, offset)
    local lo
    lo, nextOffset = P.readInt(data, nextOffset)
    if not hi or not lo then return nil, offset end

    local unsignedHi = hi < 0 and hi + 0x100000000 or hi
    local unsignedLo = lo < 0 and lo + 0x100000000 or lo
    local x = bit.rshift(unsignedHi, 6)
    local y = bit.bor(bit.lshift(bit.band(unsignedHi, 0x3F), 6), bit.rshift(unsignedLo, 26))
    local z = bit.band(unsignedLo, 0x3FFFFFF)

    if x >= 0x2000000 then x = x - 0x4000000 end
    if y >= 0x800 then y = y - 0x1000 end
    if z >= 0x2000000 then z = z - 0x4000000 end

    return { x = x, y = y, z = z }, nextOffset
end

function P.writeLong(value)
    if type(value) == "string" and #value == 8 then
        return value
    end
    return "\0\0\0\0\0\0\0\0"
end

function P.writeBool(value)
    return value and "\1" or "\0"
end

function P.writeUUID()
    return "00000000-0000-0000-0000-000000000000"
end

function P.writeUUIDBytes(seed)
    seed = tonumber(seed) or 0
    return "\0\0\0\0\0\0\0\0" .. P.writeInt(0) .. P.writeInt(seed)
end

function P.writeUUIDString(value)
    local hex = string.lower(tostring(value or ""))
    hex = string.gsub(hex, "[^0-9a-f]", "")
    if #hex ~= 32 then return nil end

    local out = {}
    for i = 1, 32, 2 do
        out[#out + 1] = string.char(tonumber(string.sub(hex, i, i + 1), 16))
    end
    return table.concat(out)
end

function P.formatUUID(value)
    local hex = string.lower(tostring(value or ""))
    hex = string.gsub(hex, "[^0-9a-f]", "")
    if #hex ~= 32 then return nil end

    return string.sub(hex, 1, 8) .. "-" ..
        string.sub(hex, 9, 12) .. "-" ..
        string.sub(hex, 13, 16) .. "-" ..
        string.sub(hex, 17, 20) .. "-" ..
        string.sub(hex, 21, 32)
end

function P.writePosition(x, y, z)
    x = band(math.floor(x or 0), 0x3FFFFFF)
    y = band(math.floor(y or 0), 0xFFF)
    z = band(math.floor(z or 0), 0x3FFFFFF)

    local hi = bor(lshift(x, 6), rshift(y, 6))
    local lo = bor(lshift(band(y, 0x3F), 26), z)

    return P.writeInt(hi) .. P.writeInt(lo)
end

function P.packet(packetId, payload)
    payload = P.writeVarInt(packetId) .. (payload or "")
    return P.writeVarInt(#payload) .. payload
end

function P.tryReadPacket(buffer)
    local length, afterLength = P.readVarInt(buffer, 1)
    if not length then return nil, buffer end

    local packetEnd = afterLength + length - 1
    if #buffer < packetEnd then return nil, buffer end

    local body = string.sub(buffer, afterLength, packetEnd)
    local rest = string.sub(buffer, packetEnd + 1)
    local id, offset = P.readVarInt(body, 1)

    return {
        id = id,
        data = body,
        payload = string.sub(body, offset),
        offset = offset
    }, rest
end

function P.jsonString(value)
    value = tostring(value or "")
    value = string.gsub(value, "\\", "\\\\")
    value = string.gsub(value, "\"", "\\\"")
    value = string.gsub(value, "\n", "\\n")
    return value
end
