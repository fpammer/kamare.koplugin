--[[
    LRU (Least Recently Used) Cache

    A memory-bounded cache that evicts the least recently used items when full.
    Items are kept in order of usage, with most recently used at the front.
]]

local logger = require("logger")

local LRUCache = {}
LRUCache.__index = LRUCache

--[[
    Create a new LRU cache

    @param opts table with:
        - max_size: maximum total size in bytes
        - name: optional name for logging
        - on_evict: optional function(item) called when item is evicted
]]
function LRUCache:new(opts)
    opts = opts or {}
    local o = {
        name = opts.name or "LRUCache",
        max_size = opts.max_size or (64 * 1024 * 1024),  -- 64MB default
        on_evict = opts.on_evict,
        items = {},  -- Array of {key=string, value=any, size=number}
        total_size = 0,
    }
    setmetatable(o, self)
    return o
end

--[[
    Get an item from the cache

    @param key string
    @return value or nil
]]
function LRUCache:get(key)
    for i, entry in ipairs(self.items) do
        if entry.key == key then
            -- Move to front (most recently used)
            table.remove(self.items, i)
            table.insert(self.items, 1, entry)
            return entry.value
        end
    end
    return nil
end

--[[
    Check if a key exists in cache without updating LRU order

    @param key string
    @return boolean
]]
function LRUCache:has(key)
    for _, entry in ipairs(self.items) do
        if entry.key == key then
            return true
        end
    end
    return false
end

--[[
    Evict items from the end (least recently used) until we have space

    @param needed_size number of bytes needed for new item
]]
function LRUCache:_evict(needed_size)
    while self.total_size + needed_size > self.max_size and #self.items > 0 do
        local entry = table.remove(self.items)  -- Remove last (oldest)

        -- Call eviction callback if provided
        if self.on_evict then
            local ok, err = pcall(self.on_evict, entry.value)
            if not ok then
                logger.warn(self.name .. ":evict callback error", "error", err)
            end
        end

        self.total_size = self.total_size - entry.size
    end
end

--[[
    Put an item in the cache

    @param key string
    @param value any
    @param size number of bytes (optional, defaults to 0)
]]
function LRUCache:set(key, value, size)
    size = size or 0

    -- Check if already cached (update to front)
    for i, entry in ipairs(self.items) do
        if entry.key == key then
            -- Update existing entry
            local size_delta = size - entry.size
            entry.value = value
            entry.size = size
            self.total_size = self.total_size + size_delta

            -- Move to front
            table.remove(self.items, i)
            table.insert(self.items, 1, entry)
            return
        end
    end

    -- Evict if needed
    self:_evict(size)

    -- Add new entry to front
    table.insert(self.items, 1, {
        key = key,
        value = value,
        size = size,
    })
    self.total_size = self.total_size + size
end

--[[
    Remove a specific item from cache

    @param key string
    @return boolean true if found and removed
]]
function LRUCache:remove(key)
    for i, entry in ipairs(self.items) do
        if entry.key == key then
            table.remove(self.items, i)

            -- Call eviction callback
            if self.on_evict then
                local ok, err = pcall(self.on_evict, entry.value)
                if not ok then
                    logger.warn(self.name .. ":remove callback error", "error", err)
                end
            end

            self.total_size = self.total_size - entry.size
            return true
        end
    end
    return false
end

--[[
    Clear the entire cache
]]
function LRUCache:clear()
    -- Call eviction callback for all items
    if self.on_evict then
        for _, entry in ipairs(self.items) do
            local ok, err = pcall(self.on_evict, entry.value)
            if not ok then
                logger.warn(self.name .. ":clear callback error", "error", err)
            end
        end
    end

    self.items = {}
    self.total_size = 0
    logger.info(self.name .. ":clear all items removed")
end

--[[
    Get cache statistics

    @return table with size, count, max_size
]]
function LRUCache:stats()
    return {
        total_size = self.total_size,
        count = #self.items,
        max_size = self.max_size,
        utilization = self.max_size > 0 and (self.total_size / self.max_size) or 0,
    }
end

return LRUCache
