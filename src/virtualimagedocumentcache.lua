local lru = require("ffi/lru")
local util = require("util")
local logger = require("logger")

local function calcTileCacheSize()
    local min = 32 * 1024 * 1024
    local max = 256 * 1024 * 1024

    local memfree = util.calcFreeMem() or 0
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
    _stats = {
        hits = 0,
        misses = 0,
        sets = 0,
        evictions = 0,
    },
}

function VIDCache:init()
    if self._native_cache then
        return
    end

    local cache_size = computeNativeCacheSize()
    local cache_size_mb = cache_size / (1024 * 1024)

    -- Put 9999 since we want to limit by size only
    self._native_cache = lru.new(9999, cache_size, true)

    -- Reader context for position-aware eviction. Maintained by the viewer
    -- via setReaderContext: { doc_path, current_page, visible_pages,
    -- behind_keep }. _evictToFit uses it to evict behind-the-reader pages
    -- (and stale other-chapter tiles) before the read-ahead window, instead
    -- of pure LRU (which wrongly evicts prefetched-but-not-yet-rendered
    -- ahead pages first). nil before first paint -> pure-LRU fallback.
    self._reader_ctx = nil

    logger.info(string.format("VIDCache: Initialized | Max size: %.1fMB | Free mem: %.1fMB",
                              cache_size_mb,
                              (util.calcFreeMem() or 0) / (1024 * 1024)))
end

function VIDCache:getNativeTile(hash)
    if not self._native_cache then
        self:init()
    end

    local tile = self._native_cache:get(hash)

    if tile then
        self._stats.hits = self._stats.hits + 1
    else
        self._stats.misses = self._stats.misses + 1
    end

    return tile
end

-- Push the reader's current position so _evictToFit can evict by reading
-- position instead of by recency. `ctx` is:
--   doc_path       = current chapter's file/url (scopes pageno comparison;
--                    tiles from other chapters are evicted first as stale)
--   current_page   = last visible page number (the read position anchor)
--   visible_pages  = set { [pageno] = true } of hard-protected (on-screen)
--                    pages; never evicted except under genuine OOM
--   behind_keep    = how many pages immediately behind current_page to also
--                    protect, for cheap scroll-back (e.g. 2)
-- Pass nil to revert to pure-LRU eviction (used before first paint).
function VIDCache:setReaderContext(ctx)
    self._reader_ctx = ctx
end

-- Position-aware eviction. Eviction order (first victim -> last):
--   Pass 1: stale tiles from ANOTHER chapter (doc_path mismatch) -- LRU oldest.
--   Pass 2: behind-the-reader pages -- farthest back (smallest pageno) first.
--   Pass 3: ahead-of-reader pages -- farthest ahead (largest pageno) first.
--   Pass 4 (OOM fallback): protected pages -- LRU oldest, with a warning.
-- Protected = visible_pages set union { current_page-behind_keep .. current-1 }.
-- The LRU's own makeFreeSpace never fires (so it never touches protected
-- tiles); single-threaded Lua guarantees nothing runs between this and the
-- subsequent lru:set, so the policy is exact. With no _reader_ctx, falls back
-- to pure LRU oldest-first (the original behavior).
function VIDCache:_evictToFit(incoming)
    local cache = self._native_cache
    local max = cache:total_size() or 0

    if (cache:used_size() or 0) + incoming <= max then
        return
    end

    -- Snapshot newest->oldest (lru:pairs follows NEXT from newest). Reverse
    -- iteration (= oldest first) is the LRU tiebreaker within each bucket.
    local entries = {}
    for k, v in cache:pairs() do
        entries[#entries + 1] = { k, v }
    end

    local function fits()
        return (cache:used_size() or 0) + incoming <= max
    end

    local ctx = self._reader_ctx

    -- No reader context: pure LRU oldest-first (original behavior).
    if not ctx or not ctx.current_page or not ctx.doc_path then
        for i = #entries, 1, -1 do
            if fits() then return end
            cache:delete(entries[i][1])
            self._stats.evictions = self._stats.evictions + 1
        end
        return
    end

    local cur          = ctx.current_page
    local doc          = ctx.doc_path
    local visible      = ctx.visible_pages or {}
    local behind_keep  = ctx.behind_keep or 0

    -- Classify every tile into one bucket. protected = visible pages plus the
    -- near-behind keep zone; these survive passes 1-3 and are only evicted as
    -- the OOM fallback in pass 4 (they match neither stale nor the
    -- not-protected branch below, so they simply fall through).
    local stale, behind, ahead = {}, {}, {}
    for i = #entries, 1, -1 do  -- oldest-first so stale/ahead-FIFO buckets are pre-ordered
        local e = entries[i]
        local v = e[2]
        local pn = v and v.pageno
        local dp = v and v.doc_path
        local is_stale = (pn == nil) or (dp == nil) or (dp ~= doc)
        local is_protected = (not is_stale)
            and (visible[pn] or (pn < cur and pn >= cur - behind_keep))
        if is_stale then
            stale[#stale + 1] = e
        elseif not is_protected then
            if pn < cur then
                -- behind the keep zone: insert so smallest pageno is first
                local inserted = false
                for j = 1, #behind do
                    if pn < (behind[j][2].pageno or 0) then
                        table.insert(behind, j, e)
                        inserted = true
                        break
                    end
                end
                if not inserted then behind[#behind + 1] = e end
            else
                -- pn > cur: ahead. Insert so LARGEST pageno is first (farthest
                -- ahead = least likely to be reached soon = evict first).
                local inserted = false
                for j = 1, #ahead do
                    if pn > (ahead[j][2].pageno or 0) then
                        table.insert(ahead, j, e)
                        inserted = true
                        break
                    end
                end
                if not inserted then ahead[#ahead + 1] = e end
            end
        end
    end

    local function evict_bucket(bucket)
        for _, e in ipairs(bucket) do
            if fits() then return end
            cache:delete(e[1])
            self._stats.evictions = self._stats.evictions + 1
        end
    end

    evict_bucket(stale)   -- pass 1: other-chapter leftovers
    if fits() then return end
    evict_bucket(behind)  -- pass 2: behind reader, farthest back first
    if fits() then return end
    evict_bucket(ahead)   -- pass 3: ahead, farthest ahead first
    if fits() then return end

    -- Pass 4 (OOM fallback): protected tiles by LRU oldest-first.
    if not fits() then
        logger.warn(string.format(
            "VIDCache: behind/ahead exhausted; falling back to evicting protected tiles (need %d bytes)",
            incoming))
        for i = #entries, 1, -1 do
            if fits() then return end
            cache:delete(entries[i][1])
            self._stats.evictions = self._stats.evictions + 1
        end
    end
end

function VIDCache:setNativeTile(hash, tile, size)
    if not self._native_cache then
        self:init()
    end

    self:_evictToFit(size)

    self._native_cache:set(hash, tile, size)
    self._stats.sets = self._stats.sets + 1
end

function VIDCache:clear()
    if self._native_cache then
        self._native_cache:clear()
    end
    self._reader_ctx = nil
    self._stats = {
        hits = 0,
        misses = 0,
        sets = 0,
        evictions = 0,
    }
end

function VIDCache:getCacheSize()
    if not self._native_cache then
        self:init()
    end
    return self._native_cache:total_size() or computeNativeCacheSize()
end

function VIDCache:getStats()
    if not self._native_cache then
        self:init()
    end

    local current_size = self._native_cache:used_size() or 0
    local max_size = self._native_cache:total_size() or 0
    local current_count = self._native_cache:used_slots() or 0

    return {
        hits = self._stats.hits,
        misses = self._stats.misses,
        sets = self._stats.sets,
        evictions = self._stats.evictions,
        hit_rate = (self._stats.hits + self._stats.misses > 0)
                   and (self._stats.hits / (self._stats.hits + self._stats.misses) * 100)
                   or 0,
        current_size_mb = current_size / (1024 * 1024),
        max_size_mb = max_size / (1024 * 1024),
        usage_pct = (max_size > 0) and (current_size / max_size * 100) or 0,
        tile_count = current_count,
    }
end

function VIDCache:logStats()
    local stats = self:getStats()
    logger.info(string.format("VIDCache stats | Hits: %d | Misses: %d | Rate: %.1f%% | Size: %.1f/%.1fMB (%.0f%%) | Tiles: %d | Sets: %d | Evictions: %d",
                              stats.hits, stats.misses, stats.hit_rate,
                              stats.current_size_mb, stats.max_size_mb, stats.usage_pct,
                              stats.tile_count, stats.sets, stats.evictions))
end

return VIDCache
