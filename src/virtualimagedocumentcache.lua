local lru = require("ffi/lru")
local util = require("util")

local function calcTileCacheSize()
    local min = 32 * 1024 * 1024
    local max = 256 * 1024 * 1024

    local memfree, _ = util.calcFreeMem() or 0, 0
    local calc = memfree * 0.25

    return math.min(max, math.max(min, calc))
end

local function computeNativeCacheSize()
    local total = calcTileCacheSize()
    local native_size = total

    local mb_size = native_size / 1024 / 1024
    if mb_size >= 8 then
        return native_size
    else
        return 8 * 1024 * 1024
    end
end

local VIDCache = {
    _native_cache = nil,
}

function VIDCache:init()
    if self._native_cache then
        return
    end

    local cache_size = computeNativeCacheSize()
    -- Put 9999 since we want to limit by size only
    self._native_cache = lru.new(9999, cache_size, true)
end

function VIDCache:getNativeTile(hash)
    if not self._native_cache then
        self:init()
    end
    return self._native_cache:get(hash)
end

function VIDCache:setNativeTile(hash, tile, size)
    if not self._native_cache then
        self:init()
    end
    self._native_cache:set(hash, tile, size)
end

function VIDCache:clear()
    if self._native_cache then
        self._native_cache:clear()
    end
end

return VIDCache
