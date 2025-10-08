--[[
Singleton LRU cache for VirtualImageDocument tiles.
Similar to DocCache but specialized for virtual image document rendering.
--]]

local LRUCache = require("lrucache")
local logger = require("logger")
local util = require("util")

local function calcTileCacheSize()
    -- Set reasonable bounds for tile caching
    local min = 32 * 1024 * 1024  -- 32MB minimum
    local max = 256 * 1024 * 1024  -- 256MB maximum

    -- Get free memory
    local memfree, _ = util.calcFreeMem() or 0, 0

    -- Use 15% of free memory for tile caching
    local calc = memfree * 0.15

    -- Clamp between min and max
    return math.min(max, math.max(min, calc))
end

local function computeNativeCacheSize()
    local total = calcTileCacheSize()
    -- Allocate 2/3 of total to native resolution tiles
    local native_size = math.floor(total * 2 / 3)

    local mb_size = native_size / 1024 / 1024
    if mb_size >= 8 then
        logger.dbg(string.format("Allocating %dMB for VirtualImageDocument native tile cache", mb_size))
        return native_size
    else
        logger.dbg("VirtualImageDocument native cache below minimum, using 8MB")
        return 8 * 1024 * 1024
    end
end

local function computeScaledCacheSize()
    local total = calcTileCacheSize()
    -- Allocate 1/3 of total to scaled tiles
    local scaled_size = math.floor(total / 3)

    local mb_size = scaled_size / 1024 / 1024
    if mb_size >= 4 then
        logger.dbg(string.format("Allocating %dMB for VirtualImageDocument scaled tile cache", mb_size))
        return scaled_size
    else
        logger.dbg("VirtualImageDocument scaled cache below minimum, using 4MB")
        return 4 * 1024 * 1024
    end
end

-- Singleton cache instance
local VIDCache = {
    _native_cache = nil,
    _scaled_cache = nil,
    _scaled_cache_zoom = nil,
    _scaled_cache_rotation = nil,
}

function VIDCache:init()
    if self._native_cache then
        -- Already initialized
        return
    end

    self._native_cache = LRUCache:new{
        name = "VID-Native",
        max_size = computeNativeCacheSize(),
        on_evict = function(tile)
            if tile and tile.bb and tile.bb.free then
                tile.bb:free()
                tile.bb = nil
            end
        end,
    }

    self._scaled_cache = LRUCache:new{
        name = "VID-Scaled",
        max_size = computeScaledCacheSize(),
        on_evict = function(tile)
            if tile and tile.bb and tile.bb.free then
                tile.bb:free()
                tile.bb = nil
            end
        end,
    }

    logger.dbg("VirtualImageDocument cache singleton initialized")
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

function VIDCache:getScaledTile(hash)
    if not self._scaled_cache then
        self:init()
    end
    return self._scaled_cache:get(hash)
end

function VIDCache:setScaledTile(hash, tile, size)
    if not self._scaled_cache then
        self:init()
    end
    self._scaled_cache:set(hash, tile, size)
end

function VIDCache:clearScaledCache()
    if self._scaled_cache then
        self._scaled_cache:clear()
    end
    self._scaled_cache_zoom = nil
    self._scaled_cache_rotation = nil
end

function VIDCache:checkScaledCacheParams(zoom, rotation)
    if not self._scaled_cache then
        return false
    end

    if self._scaled_cache_zoom ~= nil then
        if math.abs(self._scaled_cache_zoom - zoom) > 0.001 or self._scaled_cache_rotation ~= rotation then
            self:clearScaledCache()
        end
    end

    self._scaled_cache_zoom = zoom
    self._scaled_cache_rotation = rotation
    return true
end

function VIDCache:clear()
    if self._native_cache then
        self._native_cache:clear()
    end
    if self._scaled_cache then
        self._scaled_cache:clear()
    end
    self._scaled_cache_zoom = nil
    self._scaled_cache_rotation = nil
end

return VIDCache
