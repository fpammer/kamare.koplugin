-- VirtualImageDocument: owns intrinsic document data only.
--
-- Ownership contract:
--   * The document stores native page dimensions, native orientation, injected
--     raw image bytes, and the tile bitmap cache. Nothing view-dependent
--     (rotation, zoom, viewport, render_quality) lives here as state.
--   * The four layout-projection methods (getVirtualHeight,
--     getVisiblePagesAtOffset, getScrollPositionForPage, getPageAtOffset)
--     are PURE FUNCTIONS over `_dims_cache` + viewing parameters supplied
--     by the caller. No internal layout cache, no dirty flags.
--   * Render dims (`render_w`, `render_h`) and `render_quality` are supplied
--     by the canvas at call time to drawPageTiled / _preSplitPageTiles.
--
-- Coordinate-space naming convention (used throughout this file):
--   * `native_*`  — original image pixels (e.g. 1200×1800)
--   * `render_*`  — native prescaled by render_quality (e.g. 750×1125)
--   * `scaled_*`  — render × zoom (display pixels)
--   * `canvas_*`  — screen pixels after padding/margins
-- Avoid bare `w`, `h`, `x`, `y`, `rect`, `offset` for any coordinate-bearing
-- identifier — always prefix with the space.
local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local Geom = require("ui/geometry")
local logger = require("logger")
local Blitbuffer = require("ffi/blitbuffer")
local TileCacheItem = require("document/tilecacheitem")
local mupdf = require("ffi/mupdf")
local VIDCache = require("virtualimagedocumentcache")
local time = require("ui/time")
local ffi = require("ffi")

local DEFAULT_PAGE_WIDTH = 800
local DEFAULT_PAGE_HEIGHT = 1200
local TILE_SIZE_PX = 1024

local function buildGammaLUT(gamma)
    local lut = ffi.new("uint8_t[256]")
    for i = 0, 255 do
        local val = 255.0 * (i / 255.0) ^ gamma
        if val <= 0 then
            lut[i] = 0
        elseif val >= 255 then
            lut[i] = 255
        else
            lut[i] = math.floor(val + 0.5)
        end
    end
    return lut
end

-- Fused gamma + color-boost pass. `lut` is a 256-entry gamma LUT (or nil to
-- skip gamma); `saturation` is a multiplier where 1.0 = neutral, >1 boosts
-- color, <1 desaturates (0 = grayscale). Saturation only applies to RGB
-- formats; grayscale formats get the gamma LUT only. When both are neutral
-- the caller skips this entirely.
--
-- The saturation boost is luminance-preserving (Rec.601 luma) and uses a
-- vibrance curve: it scales the boost down as a pixel approaches a pure
-- color (max-min large) to avoid neon clipping, and leaves true grays
-- untouched. For desaturation it inversely fades colorful pixels while
-- leaving grays alone:
--   Y      = 0.299r + 0.587g + 0.114b
--   rng    = max(r,g,b) - min(r,g,b)        (0 => gray, no-op)
--   s_eff  = 1 + (s-1)*(1 - rng/255)          when s > 1  (boost: protect vivid)
--          = s                                when s < 1  (linear desaturate)
--   out    = clamp(s_eff*c + (1-s_eff)*Y)
local function applyColorBoost(bb, lut, saturation)
    local bbtype = bb:getType()
    local p = ffi.cast("uint8_t*", bb.data)
    local n = tonumber(bb.stride) * tonumber(bb.h)

    local has_lut = lut ~= nil
    local do_sat = saturation ~= nil and saturation ~= 1.0
        and (bbtype == Blitbuffer.TYPE_BBRGB24 or bbtype == Blitbuffer.TYPE_BBRGB32)

    -- No saturation work: at most apply the gamma LUT across the buffer.
    if not do_sat then
        if not has_lut then return end
        if bbtype == Blitbuffer.TYPE_BB8 then
            for i = 0, n - 1 do
                p[i] = lut[p[i]]
            end
        elseif bbtype == Blitbuffer.TYPE_BB8A then
            local i = 0
            while i < n do
                p[i] = lut[p[i]]
                i = i + 2
            end
        elseif bbtype == Blitbuffer.TYPE_BBRGB24 then
            local i = 0
            while i < n do
                p[i] = lut[p[i]]
                p[i + 1] = lut[p[i + 1]]
                p[i + 2] = lut[p[i + 2]]
                i = i + 3
            end
        elseif bbtype == Blitbuffer.TYPE_BBRGB32 then
            local i = 0
            while i < n do
                p[i] = lut[p[i]]
                p[i + 1] = lut[p[i + 1]]
                p[i + 2] = lut[p[i + 2]]
                i = i + 4
            end
        end
        return
    end

    local s = saturation
    local amt = s - 1.0
    local amt_per255 = amt / 255.0
    local boost = amt > 0

    if bbtype == Blitbuffer.TYPE_BBRGB24 then
        local i = 0
        while i < n do
            local r = has_lut and lut[p[i]] or p[i]
            local g = has_lut and lut[p[i + 1]] or p[i + 1]
            local b = has_lut and lut[p[i + 2]] or p[i + 2]
            local mx, mn
            if r >= g then mx, mn = r, g else mx, mn = g, r end
            if b > mx then mx = b elseif b < mn then mn = b end
            local rng = mx - mn
            if rng ~= 0 then
                local Y = 0.299 * r + 0.587 * g + 0.114 * b
                local s_eff = boost and (1.0 + amt_per255 * (255 - rng)) or s
                local inv = 1.0 - s_eff
                local nr = s_eff * r + inv * Y
                local ng = s_eff * g + inv * Y
                local nb = s_eff * b + inv * Y
                p[i]     = nr <= 0 and 0 or (nr >= 255 and 255 or math.floor(nr + 0.5))
                p[i + 1] = ng <= 0 and 0 or (ng >= 255 and 255 or math.floor(ng + 0.5))
                p[i + 2] = nb <= 0 and 0 or (nb >= 255 and 255 or math.floor(nb + 0.5))
            elseif has_lut then
                p[i] = r; p[i + 1] = g; p[i + 2] = b
            end
            i = i + 3
        end
    elseif bbtype == Blitbuffer.TYPE_BBRGB32 then
        local i = 0
        while i < n do
            local r = has_lut and lut[p[i]] or p[i]
            local g = has_lut and lut[p[i + 1]] or p[i + 1]
            local b = has_lut and lut[p[i + 2]] or p[i + 2]
            local mx, mn
            if r >= g then mx, mn = r, g else mx, mn = g, r end
            if b > mx then mx = b elseif b < mn then mn = b end
            local rng = mx - mn
            if rng ~= 0 then
                local Y = 0.299 * r + 0.587 * g + 0.114 * b
                local s_eff = boost and (1.0 + amt_per255 * (255 - rng)) or s
                local inv = 1.0 - s_eff
                local nr = s_eff * r + inv * Y
                local ng = s_eff * g + inv * Y
                local nb = s_eff * b + inv * Y
                p[i]     = nr <= 0 and 0 or (nr >= 255 and 255 or math.floor(nr + 0.5))
                p[i + 1] = ng <= 0 and 0 or (ng >= 255 and 255 or math.floor(ng + 0.5))
                p[i + 2] = nb <= 0 and 0 or (nb >= 255 and 255 or math.floor(nb + 0.5))
            elseif has_lut then
                p[i] = r; p[i + 1] = g; p[i + 2] = b
            end
            i = i + 4
        end
    end
end

local VirtualImageDocument = Document:extend{
    provider = "virtualimagedocument",
    provider_name = "Virtual Image Document",

    title = "Virtual Image Document",

    images_list = nil,
    images_dimensions = nil,

    pages_override = nil,

    cache_id = nil,

    sw_dithering = false,

    _pages = 0,

    dc_default = DrawContext.new(),

    render_color = true,

    gamma = 1.0,

    saturation = 1.0,

    _dims_cache = nil,
    _orientation_cache = nil,

    -- Memoization for getVirtualHeight: the result depends only on
    -- (zoom, zoom_mode, viewport_width, page_gap_height) and the contents
    -- of _dims_cache. We track a generation counter (_vh_gen) bumped
    -- whenever _dims_cache changes meaningfully, and cache the last
    -- computed value keyed on the inputs + gen.
    _vh_gen = 0,
    _vh_cache_key = nil,
    _vh_cache_val = nil,

    _dual_page_offset = nil,
    _dual_page_layout = nil, -- Pre-calculated layout: [page_num] = {left, right}
    _dual_page_pairs = nil, -- Pre-calculated pairs array: [index] = {left, right}
    content_type = "auto", -- "auto", "volume", or "chapter"

    tile_px = TILE_SIZE_PX, -- default tile size (px)

    on_image_load_error = nil, -- Callback: function(pageno, error_msg)

    -- Per-page "fully cached" set. Populated when _preSplitPageTiles succeeds
    -- for a page; cleared on tile eviction (via onFree callback) or on
    -- cache/document reset. Read by the viewer's prefetch budget math
    -- (estimateBytesForPage) to know which upcoming pages already occupy the
    -- cache, without per-tile hash probes. Best-effort: a page marked here is
    -- guaranteed to have been fully cached at *some* point; eviction keeps it
    -- accurate under normal LRU pressure.
    _fully_cached_pages = nil,
}

local function isPositiveDimension(w, h)
    return w and h and w > 0 and h > 0
end

-- Single source of truth for "how tall is this page in display space?"
-- Called by all four layout-projection methods; one formula, no drift.
local function pageDisplayHeight(native_w, native_h, zoom_mode, viewport_w, zoom)
    if zoom_mode == 1 and viewport_w and viewport_w > 0 and native_w > 0 then
        return native_h * (viewport_w / native_w)
    end
    return native_h * (zoom or 1.0)
end

local function intersectRects(a, b)
    local ax1, ay1 = a.x or 0, a.y or 0
    local ax2, ay2 = ax1 + (a.w or 0), ay1 + (a.h or 0)
    local bx1, by1 = b.x or 0, b.y or 0
    local bx2, by2 = bx1 + (b.w or 0), by1 + (b.h or 0)

    local x1 = math.max(ax1, bx1)
    local y1 = math.max(ay1, by1)
    local x2 = math.min(ax2, bx2)
    local y2 = math.min(ay2, by2)
    if x2 <= x1 or y2 <= y1 then return nil end

    return Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

-- Build a tile-free callback suitable for `tile.onFree`.
--
-- When `pageno` is non-nil, the callback clears `_fully_cached_pages[pageno]`
-- on eviction so the prefetch budget math stays accurate. A weak reference to
-- `self` is used to avoid keeping the document alive after the viewer drops it
-- (tiles can outlive the document in VIDCache across chapter changes).
--
-- When `pageno` is nil (transient scaled tiles not stored in the cache), the
-- callback only frees the BlitBuffer.
local function createTileFreeCallback(doc, pageno)
    if pageno == nil then
        return function(tile_self)
            if tile_self.bb and tile_self.bb.free then
                tile_self.bb:free()
                tile_self.bb = nil
            end
        end
    end

    local weak = setmetatable({ [1] = doc }, { __mode = "v" })
    return function(tile_self)
        if tile_self.bb and tile_self.bb.free then
            tile_self.bb:free()
            tile_self.bb = nil
        end
        local live_doc = weak[1]
        if live_doc and live_doc._fully_cached_pages then
            live_doc._fully_cached_pages[pageno] = nil
        end
    end
end

function VirtualImageDocument:_hasCompleteDimensions()
    if not self._dims_cache then
        return false
    end
    if (self._pages or 0) == 0 then
        return false
    end
    for i = 1, self._pages do
        local dims = self._dims_cache[i]
        if not (dims and isPositiveDimension(dims.w, dims.h)) then
            return false
        end
    end
    return true
end

function VirtualImageDocument:init()
    Document._init(self)

    self.render_mode = 0

    self.images_list = self.images_list or {}
    self._pages = self.pages_override or #self.images_list
    self._dims_cache = {}
    self._orientation_cache = {}
    self._fully_cached_pages = {}
    self._vh_gen = 0
    self._vh_cache_key = nil
    self._vh_cache_val = nil
    if self.images_dimensions then
        self:preloadDimensions(self.images_dimensions)
    end

    if self._pages == 0 then
        logger.warn("VirtualImageDocument: No images provided")
        self.is_open = false
        return
    end

    self.file = "virtualimage://" .. (self.cache_id or self.title or "session")
    self.mod_time = self.cache_mod_time or 0

    self.is_open = true
    self.info.has_pages = true
    self.info.number_of_pages = self._pages
    self.info.configurable = false

    -- Add metadata for statistics compatibility
    self.info.title = self.title or "Virtual Image Document"
    self.info.authors = (self.metadata and self.metadata.author) or ""
    self.info.series = (self.metadata and self.metadata.seriesName) or ""
    self.is_pic = false

    self.tile_cache_validity_ts = os.time()

    self:updateColorRendering()

    if self._pages > 0 then
        self:_buildDualPageLayout()
    end
end

function VirtualImageDocument:clearCache()
    VIDCache:clear()
    self._fully_cached_pages = {}
end

function VirtualImageDocument:close()
    self.is_open = false
    self._dims_cache = nil
    self._orientation_cache = nil
    self._prefetched_raw = nil
    self._fully_cached_pages = nil
    return true
end

function VirtualImageDocument:_getDimsWithDefault(pageno)
    local dims = self._dims_cache and self._dims_cache[pageno]
    if dims and isPositiveDimension(dims.w, dims.h) then
        return dims
    end
    return Geom:new{ w = DEFAULT_PAGE_WIDTH, h = DEFAULT_PAGE_HEIGHT }
end

function VirtualImageDocument:_storeDims(pageno, w, h)
    self._dims_cache = self._dims_cache or {}
    self._orientation_cache = self._orientation_cache or {}
    if not isPositiveDimension(w, h) then
        w, h = DEFAULT_PAGE_WIDTH, DEFAULT_PAGE_HEIGHT
    end
    local prev = self._dims_cache[pageno]
    local function diff(a, b)
        return math.abs((a or 0) - (b or 0))
    end
    if prev then
        local delta_w = diff(prev.w, w)
        local delta_h = diff(prev.h, h)
        if delta_w < 0.5 and delta_h < 0.5 then
            return
        end
    end
    self._dims_cache[pageno] = Geom:new{ w = w, h = h }
    self._orientation_cache[pageno] = (w > h) and 1 or 0
    -- Invalidate the getVirtualHeight memo: a page's dims changed in a
    -- way that could affect the aggregate height.
    self._vh_gen = self._vh_gen + 1
end

function VirtualImageDocument:_getRawImageData(pageno)
    -- The raw body is only ever available via async injection (injectRawBody).
    -- We deliberately NEVER fall back to the page-table supplier here: that
    -- would fetch synchronously and block the UI. If the body isn't injected
    -- yet, return the "pending" sentinel so callers (tilegen / render) can
    -- signal the canvas to paint a placeholder and request the page async.
    if self._prefetched_raw and self._prefetched_raw[pageno] then
        return self._prefetched_raw[pageno]
    end
    return nil, "pending"
end

-- True if a raw body for `pageno` has been injected (and is thus renderable
-- without a fetch).
function VirtualImageDocument:isRawBodyReady(pageno)
    return self._prefetched_raw and self._prefetched_raw[pageno] ~= nil or false
end

-- Inject a raw image body obtained asynchronously (non-blocking pump). The next
-- _getRawImageData(pageno) / tilegen for this page will use it instead of
-- fetching synchronously through the page-table supplier.
function VirtualImageDocument:injectRawBody(pageno, body)
    if type(body) ~= "string" or #body == 0 then
        return false
    end
    self._prefetched_raw = self._prefetched_raw or {}
    self._prefetched_raw[pageno] = body
    return true
end



function VirtualImageDocument:getDocumentProps()
    return {
        title = "Virtual Image Collection",
        pages = self._pages,
    }
end

function VirtualImageDocument:getPageCount()
    return self._pages
end

function VirtualImageDocument:getNativePageDimensions(pageno)
    if pageno < 1 or pageno > self._pages then
        logger.warn("VID:getNativePageDimensions invalid", "page", pageno, "valid", 1, self._pages)
        return Geom:new{ w = 0, h = 0 }
    end

    local cached = self._dims_cache and self._dims_cache[pageno]
    if cached then
        return cached
    end

    self:validateDims(pageno)
    cached = self._dims_cache and self._dims_cache[pageno]
    if cached then
        return cached
    end

    return Geom:new{ w = DEFAULT_PAGE_WIDTH, h = DEFAULT_PAGE_HEIGHT }
end

function VirtualImageDocument:getPageOrientation(pageno)
    return (self._orientation_cache and self._orientation_cache[pageno]) or 0
end

function VirtualImageDocument:getDualPageOffset()
    if self._dual_page_offset ~= nil then
        return self._dual_page_offset
    end

    local content_type = self.content_type or "auto"

    if content_type == "chapter" then
        self._dual_page_offset = 0
        return 0
    end

    -- Scan ALL pages for landscape spreads (merged pages)
    -- In physical books, spreads ALWAYS start at even pages
    -- If first spread is at odd position, we need offset=1 to shift it to even
    for page = 2, self._pages do
        if self:getPageOrientation(page) == 1 then
            if (page % 2) == 0 then
                self._dual_page_offset = 0

                return 0
            else
                self._dual_page_offset = 1

                return 1
            end
        end
    end

    self._dual_page_offset = 0

    return 0
end

-- Pre-calculate dual page pairs array: pairs[index] = {left, right}
-- Pairs are built in physical order (ascending page numbers). Also builds
-- a reverse index `_dual_page_pair_index[page] = index_into_pairs` so all
-- "find pair containing page N" lookups are O(1) instead of O(pairs).
function VirtualImageDocument:_buildDualPageLayout()
    local content_type = self.content_type or "auto"
    local pairs = {}
    local page_to_pair = {}
    local offset = self:getDualPageOffset()
    local page_count = self._pages

    local function is_landscape(page)
        if page < 1 or page > page_count then return false end

        return self:getPageOrientation(page) == 1
    end

    local function record(pair_idx, page)
        if page and page > 0 then
            page_to_pair[page] = pair_idx
        end
    end

    local is_chapter = (content_type == "chapter")
    local page = 1

    if page == 1 and not is_chapter then
        table.insert(pairs, {0, 1})
        record(#pairs, 1)
        page = page + 1

        if offset == 1 then
            table.insert(pairs, {0, 2})
            record(#pairs, 2)
            page = page + 1
        end
    end

    while page <= page_count do
        if is_landscape(page) then
            table.insert(pairs, {page, page})
            record(#pairs, page)
            page = page + 1
        else
            local next_page = page + 1
            if next_page <= page_count and not is_landscape(next_page) then
                table.insert(pairs, {page, next_page})
                record(#pairs, page)
                record(#pairs, next_page)
                page = page + 2
            else
                table.insert(pairs, {page, 0})
                record(#pairs, page)
                page = page + 1
            end
        end
    end

    self._dual_page_pairs = pairs
    self._dual_page_pair_index = page_to_pair
    return pairs
end

function VirtualImageDocument:getSpreadForPage(page)
    -- Passthrough; kept for API symmetry with getNext/PrevSpreadPage.
    if page < 1 or page > self._pages then
        return page
    end
    return page
end

function VirtualImageDocument:getNextSpreadPage(current_page)
    if current_page < 1 or current_page > self._pages then
        return current_page
    end

    if not self._dual_page_pairs then
        return math.min(current_page + 1, self._pages)
    end

    local i = self._dual_page_pair_index and self._dual_page_pair_index[current_page]
    if i == nil then
        return math.min(current_page + 1, self._pages)
    end

    local next_pair = self._dual_page_pairs[i + 1]
    if next_pair then
        local next_page1, next_page2 = next_pair[1], next_pair[2]
        if next_page1 > 0 then
            return next_page1
        elseif next_page2 > 0 then
            return next_page2
        end
    end

    return current_page
end

function VirtualImageDocument:getPrevSpreadPage(current_page)
    if current_page < 1 or current_page > self._pages then
        return current_page
    end

    if not self._dual_page_pairs then
        return math.max(current_page - 1, 1)
    end

    local i = self._dual_page_pair_index and self._dual_page_pair_index[current_page]
    if i == nil then
        return math.max(current_page - 1, 1)
    end

    local prev_pair = self._dual_page_pairs[i - 1]
    if prev_pair then
        local prev_page1, prev_page2 = prev_pair[1], prev_pair[2]
        if prev_page1 > 0 then
            return prev_page1
        elseif prev_page2 > 0 then
            return prev_page2
        end
    end
    return current_page
end

function VirtualImageDocument:preloadDimensions(list)
    if type(list) ~= "table" then return end
    for _, d in ipairs(list) do
        local pn = d.pageNumber or d.page or d.page_num
        local w, h = d.width, d.height
        if type(pn) == "number" and w and h and w > 0 and h > 0 then
            self:_storeDims(pn, w, h)
        end
    end
end

function VirtualImageDocument:validateDims(pageno)
    if pageno < 1 or pageno > self._pages then return end
    self._dims_cache = self._dims_cache or {}
    local cached = self._dims_cache[pageno]
    if not (cached and isPositiveDimension(cached.w, cached.h)) then
        logger.warn("VirtualImageDocument: missing or invalid dims for page", pageno)
    end
end

function VirtualImageDocument:getUsedBBox(pageno)
    local native_dims = self:getNativePageDimensions(pageno)
    return {
        x0 = 0, y0 = 0,
        x1 = native_dims.w,
        y1 = native_dims.h,
    }
end

function VirtualImageDocument:getPageBBox(pageno)
    local native_dims = self:getNativePageDimensions(pageno)
    return {
        x0 = 0, y0 = 0,
        x1 = native_dims.w,
        y1 = native_dims.h,
    }
end

-- Layout projection methods (pure; see file header).

function VirtualImageDocument:getVirtualHeight(zoom, zoom_mode, viewport_width, page_gap_height)
    zoom = zoom or 1.0
    page_gap_height = math.max(0, tonumber(page_gap_height) or 0)
    if not self._dims_cache then return 0 end

    -- Memoized (see _vh_gen); hot path is O(1) during scroll.
    local gen = self._vh_gen
    local key = zoom .. "|" .. (zoom_mode or 0) .. "|"
                .. (viewport_width or 0) .. "|" .. page_gap_height
                .. "|" .. gen
    if self._vh_cache_key == key then
        return self._vh_cache_val
    end

    local total = 0
    local valid_count = 0
    for i = 1, self._pages do
        local dims = self._dims_cache[i]
        if dims and isPositiveDimension(dims.w, dims.h) then
            total = total + pageDisplayHeight(dims.w, dims.h,
                                              zoom_mode, viewport_width, zoom)
            valid_count = valid_count + 1
        end
    end
    if valid_count > 1 then
        total = total + (valid_count - 1) * page_gap_height
    end

    self._vh_cache_key = key
    self._vh_cache_val = total
    return total
end

function VirtualImageDocument:getVisiblePagesAtOffset(offset_y, viewport_height, zoom, zoom_mode, viewport_width, page_gap_height)
    offset_y = math.max(0, offset_y or 0)
    viewport_height = math.max(0, viewport_height or 0)
    zoom = (zoom and zoom > 0) and zoom or 1.0
    page_gap_height = math.max(0, tonumber(page_gap_height) or 0)

    if viewport_height <= 0 then
        logger.warn("VID:getVisiblePagesAtOffset invalid viewport", "viewport_height", viewport_height)
        return {}
    end
    if not self._dims_cache then return {} end

    local result = {}
    local bottom = offset_y + viewport_height
    local accumulated_offset = 0
    local seen_valid = false

    for i = 1, self._pages do
        local dims = self._dims_cache[i]
        if dims and isPositiveDimension(dims.w, dims.h) then
            local native_w, native_h = dims.w, dims.h

            -- Per-page zoom: in fit-width, each page zooms to fit viewport_w.
            local page_zoom = zoom
            if zoom_mode == 1 and viewport_width and viewport_width > 0 and native_w > 0 then
                page_zoom = viewport_width / native_w
            end

            -- Inter-page gap is inserted BEFORE every valid page except the
            -- first. Must match getVirtualHeight / getScrollPositionForPage.
            if seen_valid and page_gap_height > 0 then
                accumulated_offset = accumulated_offset + page_gap_height
            end

            local page_top = accumulated_offset
            local page_height = native_h * page_zoom
            local page_bottom = page_top + page_height
            accumulated_offset = page_bottom
            seen_valid = true

            -- Early-exit once we're past the viewport.
            if page_top > bottom then break end

            if page_bottom >= offset_y and page_top <= bottom then
                table.insert(result, {
                    page_num = i,
                    page_top = page_top,
                    page_bottom = page_bottom,
                    visible_top = math.max(page_top, offset_y),
                    visible_bottom = math.min(page_bottom, bottom),
                    layout = {
                        page_num = i,
                        native_width = native_w,
                        native_height = native_h,
                    },
                    zoom = page_zoom,
                })
            end
        end
    end

    return result
end

function VirtualImageDocument:getScrollPositionForPage(pageno, zoom, zoom_mode, viewport_width, page_gap_height)
    zoom = (zoom and zoom > 0) and zoom or 1.0
    page_gap_height = math.max(0, tonumber(page_gap_height) or 0)
    if pageno < 1 or not self._dims_cache then return 0 end

    -- Iterate pages 1..pageno (inclusive). For each valid page after the
    -- first, insert a gap BEFORE it. Stop and return the accumulated offset
    -- when we reach pageno (without adding pageno's own height); if pageno
    -- is past the end of the document, the loop exits and returns the total
    -- virtual height (matching getVirtualHeight for pageno > _pages).
    local accumulated_offset = 0
    local seen_valid = false
    for i = 1, math.min(pageno, self._pages) do
        local dims = self._dims_cache[i]
        if dims and isPositiveDimension(dims.w, dims.h) then
            if seen_valid and page_gap_height > 0 then
                accumulated_offset = accumulated_offset + page_gap_height
            end
            if i == pageno then
                return accumulated_offset
            end
            accumulated_offset = accumulated_offset
                + pageDisplayHeight(dims.w, dims.h,
                                    zoom_mode, viewport_width, zoom)
            seen_valid = true
        end
    end
    return accumulated_offset
end

function VirtualImageDocument:getPageAtOffset(offset_y, zoom, zoom_mode, viewport_width, page_gap_height)
    zoom = (zoom and zoom > 0) and zoom or 1.0
    offset_y = math.max(0, offset_y or 0)
    page_gap_height = math.max(0, tonumber(page_gap_height) or 0)
    if not self._dims_cache then return 1 end

    local accumulated_offset = 0
    local seen_valid = false
    for i = 1, self._pages do
        local dims = self._dims_cache[i]
        if dims and isPositiveDimension(dims.w, dims.h) then
            if seen_valid and page_gap_height > 0 then
                accumulated_offset = accumulated_offset + page_gap_height
            end
            local page_height = pageDisplayHeight(dims.w, dims.h,
                                                  zoom_mode, viewport_width, zoom)
            local page_top = accumulated_offset
            local page_bottom = page_top + page_height
            if offset_y >= page_top and offset_y < page_bottom then
                return i
            end
            accumulated_offset = page_bottom
            seen_valid = true
        end
    end

    return self._pages
end

function VirtualImageDocument:_computeTileRects(rect, tile_px)
    tile_px = math.max(16, tonumber(tile_px or self.tile_px or TILE_SIZE_PX))

    local rx, ry = rect.x or 0, rect.y or 0
    local rw, rh = rect.w or 0, rect.h or 0

    local rect_x1 = rx
    local rect_y1 = ry
    local rect_x2 = rx + rw
    local rect_y2 = ry + rh

    local tile_x_start = math.floor(rect_x1 / tile_px) * tile_px
    local tile_y_start = math.floor(rect_y1 / tile_px) * tile_px
    local tile_x_end = math.ceil(rect_x2 / tile_px) * tile_px
    local tile_y_end = math.ceil(rect_y2 / tile_px) * tile_px

    local tiles = {}
    local y = tile_y_start
    while y < tile_y_end do
        local x = tile_x_start
        while x < tile_x_end do
            local tile = Geom:new{
                x = x,
                y = y,
                w = tile_px,
                h = tile_px
            }

            if intersectRects(tile, rect) then
                tiles[#tiles + 1] = tile
            end

            x = x + tile_px
        end
        y = y + tile_px
    end

    return tiles
end

-- Byte-cost estimation for the prefetch budget. Pure over `_dims_cache` and
-- the supplied render dimensions; mirrors the actual tile-storage clamping
-- in _preSplitPageTiles (tw/th clamped to content, +512 byte overhead per
-- tile) so the budget math and the cache accounting stay aligned.
function VirtualImageDocument:_estimateTileBytes(rect, render_w, render_h)
    if not rect or rect.w <= 0 or rect.h <= 0 then return 0 end
    if not render_w or not render_h or render_w <= 0 or render_h <= 0 then return 0 end

    local tp = math.max(16, tonumber(self.tile_px or TILE_SIZE_PX))
    local tiles = self:_computeTileRects(rect, tp)
    if #tiles == 0 then return 0 end

    local bpp = self.render_color and 4 or 1
    local bytes = 0
    for _, t in ipairs(tiles) do
        local tx = math.max(0, math.min(t.x, render_w))
        local ty = math.max(0, math.min(t.y, render_h))
        local tw = math.max(0, math.min(t.w, render_w - tx))
        local th = math.max(0, math.min(t.h, render_h - ty))
        if tw > 0 and th > 0 then
            bytes = bytes + tw * bpp * th + 512
        end
    end
    return bytes
end

-- Total byte cost of all tiles needed to fully cover `pageno` at the given
-- render dimensions. Used by the prefetch budget to size upcoming pages.
function VirtualImageDocument:estimateBytesForPage(pageno, render_w, render_h)
    if not self._dims_cache then return 0 end
    local native = self._dims_cache[pageno]
    if not native or native.w <= 0 or native.h <= 0 then return 0 end
    local rect = Geom:new{ x = 0, y = 0, w = render_w, h = render_h }
    return self:_estimateTileBytes(rect, render_w, render_h)
end

-- Byte cost of the tiles intersecting a sub-rect of `pageno`. Used to size
-- the currently-visible slice (the active reserve) without crediting the
-- entire page's worth of tiles -- critical for very long webtoon pages
-- where the visible slice is a small fraction of the page.
function VirtualImageDocument:estimateBytesForRect(pageno, rect, render_w, render_h)
    if not self._dims_cache then return 0 end
    local native = self._dims_cache[pageno]
    if not native or native.w <= 0 or native.h <= 0 then return 0 end
    return self:_estimateTileBytes(rect, render_w, render_h)
end

-- Whether every tile for `pageno` is currently in the cache. Updated by
-- _preSplitPageTiles on success and cleared on tile eviction (via the onFree
-- callback). Best-effort: the prefetch budget reads this to skip pages that
-- already occupy the cache without doing per-tile hash probes.
function VirtualImageDocument:isPageFullyCached(pageno)
    if not self._fully_cached_pages then return false end
    return self._fully_cached_pages[pageno] == true
end

-- Hash key for a tile. Cached prefix per (pageno, gamma, render_quality);
-- only the per-tile rect coordinates are appended per call.
function VirtualImageDocument:_tileHash(pageno, zoom, gamma, rect, render_quality)
    local prefix = self:_tileHashPrefix(pageno, gamma, render_quality)
    return prefix
        .. "|" .. math.floor(rect.x or 0)
        .. "|" .. math.floor(rect.y or 0)
        .. "|" .. math.floor(rect.w or 0)
        .. "|" .. math.floor(rect.h or 0)
end

-- Single-slot memoized prefix. Hot-path callers (drawPageTiled,
-- _preSplitPageTiles) hit the same (pageno, gamma, render_quality) for
-- every tile in a paint; this avoids re-canonicalizing file, mod_time,
-- render_mode, color, etc. per tile.
function VirtualImageDocument:_tileHashPrefix(pageno, gamma, render_quality)
    local qg = math.floor((gamma or 1) * 1000 + 0.5)
    local qs = math.floor((self.saturation or 1) * 1000 + 0.5)
    local cache_key = (pageno or 0) .. "|" .. qg .. "|" .. qs .. "|" .. (render_quality or -1)
    if self._tile_hash_cache_key == cache_key
       and self._tile_hash_cache_file == (self.file or "")
       and self._tile_hash_cache_mod  == (self.mod_time or 0)
       and self._tile_hash_cache_mode == (self.render_mode or 0)
       and self._tile_hash_cache_color == (self.render_color and 1 or 0) then
        return self._tile_hash_cache_value
    end
    local value = table.concat({
        "nativetile",
        self.file or "",
        tostring(self.mod_time or 0),
        tostring(pageno or 0),
        tostring(qg),
        tostring(qs),
        tostring(self.render_mode or 0),
        self.render_color and "color" or "bw",
        tostring(render_quality or -1),
    }, "|")
    self._tile_hash_cache_key = cache_key
    self._tile_hash_cache_file = self.file or ""
    self._tile_hash_cache_mod = self.mod_time or 0
    self._tile_hash_cache_mode = self.render_mode or 0
    self._tile_hash_cache_color = self.render_color and 1 or 0
    self._tile_hash_cache_value = value
    return value
end


function VirtualImageDocument:getPageDimensions(pageno, zoom)
    local native_rect = self:getNativePageDimensions(pageno)
    -- Delegate to base class with rotation=0; this method exists for
    -- Document-class API compatibility and is not on the kamare hot path.
    return Document.transformRect(self, native_rect, zoom, 0)
end

function VirtualImageDocument:getToc()
    return {}
end

-- Gamma LUT, cached across renders. gamma is a setting, normally constant for
-- the whole chapter, so we rebuild only when it actually changes (buildGammaLUT
-- allocates a 256-entry cdata array). Returns nil when gamma is neutral (1.0).
function VirtualImageDocument:_gammaLUT()
    if self.gamma == 1.0 then return nil end
    local key = math.floor(self.gamma * 1000 + 0.5)
    if self._gamma_lut_key ~= key then
        self._gamma_lut = buildGammaLUT(self.gamma)
        self._gamma_lut_key = key
    end
    return self._gamma_lut
end

-- Fused gamma + saturation pass; no-op when both are neutral.
function VirtualImageDocument:_applyColorAdjustments(bb)
    if self.gamma == 1.0 and self.saturation == 1.0 then return end
    applyColorBoost(bb, self:_gammaLUT(), self.saturation)
end

function VirtualImageDocument:renderPage(pageno, rect, zoom, page_mode, clip_rect, render_quality)
    if pageno < 1 or pageno > self._pages then
        logger.warn("VID:renderPage invalid page", "page", pageno, "total", self._pages)
        return nil
    end

    local native_dims = self:getNativePageDimensions(pageno)
    local native_rect = rect or Geom:new{ x = 0, y = 0, w = native_dims.w, h = native_dims.h }

    local offset_x = math.max(0, math.min(native_rect.x or 0, native_dims.w))
    local offset_y = math.max(0, math.min(native_rect.y or 0, native_dims.h))
    local end_x = math.min(native_dims.w, (native_rect.x or 0) + (native_rect.w or native_dims.w))
    local end_y = math.min(native_dims.h, (native_rect.y or 0) + (native_rect.h or native_dims.h))
    local native_w = math.max(0, end_x - offset_x)
    local native_h = math.max(0, end_y - offset_y)

    if native_w <= 0 or native_h <= 0 then
        logger.warn("VID:renderPage rect outside page bounds", "page", pageno, "rect", native_rect, "page_dims", native_dims)
        return nil
    end

    local hash = self:_tileHash(pageno, zoom, self.gamma, native_rect, render_quality)

    local native_tile = VIDCache:getNativeTile(hash)
    if native_tile then
        return self:_scaleToZoom(native_tile, zoom, clip_rect)
    end

    local raw_data = self:_getRawImageData(pageno)
    if not raw_data then
        if self.on_image_load_error then
            self.on_image_load_error(pageno, "Failed to load image data")
        end
        return nil
    end

    -- renderPage is currently unused by the plugin; decodes at native res.
    local render_w, render_h = native_dims.w, native_dims.h

    local ok, full_bb = pcall(mupdf.renderImage, raw_data, #raw_data, render_w, render_h)
    if not ok or not full_bb then
        logger.warn("VID:renderPage renderImage failed", "page", pageno, "error", full_bb)
        if self.on_image_load_error then
            self.on_image_load_error(pageno, "Failed to render image")
        end
        return nil
    end

    self:_applyColorAdjustments(full_bb)

    local render_scale_x = render_w / native_dims.w
    local render_scale_y = render_h / native_dims.h

    local scaled_offset_x = math.floor(offset_x * render_scale_x)
    local scaled_offset_y = math.floor(offset_y * render_scale_y)
    local scaled_end_x = math.floor((offset_x + native_w) * render_scale_x)
    local scaled_end_y = math.floor((offset_y + native_h) * render_scale_y)
    local scaled_w = scaled_end_x - scaled_offset_x
    local scaled_h = scaled_end_y - scaled_offset_y

    local tile_bb = Blitbuffer.new(scaled_w, scaled_h, self.render_color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)

    tile_bb:blitFrom(full_bb, 0, 0, scaled_offset_x, scaled_offset_y, scaled_w, scaled_h)
    full_bb:free()

    local scaled_rect = Geom:new{ x = scaled_offset_x, y = scaled_offset_y, w = scaled_w, h = scaled_h }
    local tile = TileCacheItem:new{
        persistent = true,
        doc_path = self.file,
        created_ts = os.time(),
        excerpt = scaled_rect,
        pageno = pageno,
        bb = tile_bb,
    }
    tile.size = tonumber(tile_bb.stride) * tile_bb.h + 512
    tile.render_scale_x = render_scale_x
    tile.render_scale_y = render_scale_y
    tile.onFree = createTileFreeCallback(self, pageno)

    VIDCache:setNativeTile(hash, tile, tile.size)

    return self:_scaleToZoom(tile, zoom, clip_rect)
end

function VirtualImageDocument:_scaleToZoom(native_tile, zoom, clip_rect)
    if not (native_tile and native_tile.bb) then
        return native_tile
    end

    local input_bb = native_tile.bb
    local tile_excerpt = native_tile.excerpt
    local render_scale_x = native_tile.render_scale_x or 1.0
    local render_scale_y = native_tile.render_scale_y or 1.0

    if clip_rect and tile_excerpt then
        local rel_x = clip_rect.x - tile_excerpt.x
        local rel_y = clip_rect.y - tile_excerpt.y

        local bb_x = math.floor(rel_x * render_scale_x)
        local bb_y = math.floor(rel_y * render_scale_y)
        local bb_end_x = math.floor((rel_x + clip_rect.w) * render_scale_x)
        local bb_end_y = math.floor((rel_y + clip_rect.h) * render_scale_y)
        local bb_w = bb_end_x - bb_x
        local bb_h = bb_end_y - bb_y

        local orig_bb_w = input_bb:getWidth()
        local orig_bb_h = input_bb:getHeight()
        bb_x = math.max(0, math.min(bb_x, orig_bb_w))
        bb_y = math.max(0, math.min(bb_y, orig_bb_h))
        bb_w = math.min(bb_w, orig_bb_w - bb_x)
        bb_h = math.min(bb_h, orig_bb_h - bb_y)

        if bb_w > 0 and bb_h > 0 and (bb_w * bb_h) < (orig_bb_w * orig_bb_h * 0.95) then
            local cropped_bb = Blitbuffer.new(bb_w, bb_h, input_bb:getType())
            cropped_bb:blitFrom(input_bb, 0, 0, bb_x, bb_y, bb_w, bb_h)
            input_bb = cropped_bb

            tile_excerpt = Geom:new{
                x = clip_rect.x,
                y = clip_rect.y,
                w = clip_rect.w,
                h = clip_rect.h,
            }
        end
    end

    if math.abs(zoom - 1.0) < 0.001 and math.abs(render_scale_x - 1.0) < 0.001 and math.abs(render_scale_y - 1.0) < 0.001 then
        return native_tile
    end

    local native_w = input_bb:getWidth()
    local native_h = input_bb:getHeight()

    local effective_zoom_x = zoom / render_scale_x
    local effective_zoom_y = zoom / render_scale_y

    local target_w = math.floor(native_w * effective_zoom_x + 0.5)
    local target_h = math.floor(native_h * effective_zoom_y + 0.5)

    if target_w <= 0 or target_h <= 0 then
        return native_tile
    end

    local ok, scaled_bb = pcall(mupdf.scaleBlitBuffer, input_bb, target_w, target_h)
    if not ok then
        logger.warn("VID:_scaleToZoom scale failed", "page", native_tile.pageno, "zoom", zoom, "error", scaled_bb)
        collectgarbage("collect")
        ok, scaled_bb = pcall(mupdf.scaleBlitBuffer, input_bb, target_w, target_h)
        if not ok then
            logger.err("VID:_scaleToZoom failed after GC", "page", native_tile.pageno, "error", scaled_bb)
            return native_tile
        end
    end

    local scaled_tile = TileCacheItem:new{
        persistent = false,
        doc_path = native_tile.doc_path,
        created_ts = native_tile.created_ts,
        excerpt = tile_excerpt,
        pageno = native_tile.pageno,
        bb = scaled_bb,
    }
    scaled_tile.size = tonumber(scaled_bb.stride) * scaled_bb.h + 512
    scaled_tile.render_scale_x = zoom
    scaled_tile.render_scale_y = zoom
    scaled_tile.onFree = createTileFreeCallback(nil, nil)

    return scaled_tile
end

function VirtualImageDocument:drawPage(target, x, y, rect, pageno, zoom, page_mode)
    local tile = self:renderPage(pageno, rect, zoom, page_mode)
    if tile and tile.bb then
        target:blitFrom(tile.bb,
            x, y,
            0, 0,
            tile.bb:getWidth(), tile.bb:getHeight())
        return true
    end
    return false
end

function VirtualImageDocument:prefetchPage(page, zoom, page_mode, render_w, render_h, render_quality)
    return self:_preSplitPageTiles(page, zoom, nil, page_mode, render_w, render_h, render_quality)
end

function VirtualImageDocument:_preSplitPageTiles(pageno, zoom, tile_px, page_mode, render_w, render_h, render_quality)
    local t0 = time.now()
    local native = self:getNativePageDimensions(pageno)
    if not native or native.w <= 0 or native.h <= 0 then return 0 end

    if not render_w or not render_h then
        -- Backward-compat fallback: should never happen in normal flow
        -- (canvas always supplies render dims). Avoid silent wrong render.
        logger.warn("VID:_preSplitPageTiles missing render dims, using native")
        render_w, render_h = native.w, native.h
    end

    local render_scale_x = render_w / native.w
    local render_scale_y = render_h / native.h
    local scaled_rect = Geom:new{ x = 0, y = 0, w = render_w, h = render_h }
    local tp = math.max(16, tonumber(tile_px or self.tile_px or TILE_SIZE_PX))
    local tiles = self:_computeTileRects(scaled_rect, tp)

    if #tiles == 0 then return 0 end

    local missing = {}

    for _, t in ipairs(tiles) do
        local key = self:_tileHash(pageno, zoom, self.gamma, t, render_quality)
        local exists = VIDCache:getNativeTile(key)
        if not (exists and exists.bb) then
            table.insert(missing, t)
        end
    end

    if #missing == 0 then
        -- Fast path: all tiles already cached. Caller (prefetch/render) logs
        -- the "+0 tiles" outcome; nothing to do here.
        self._fully_cached_pages = self._fully_cached_pages or {}
        self._fully_cached_pages[pageno] = true
        return 0
    end

    -- At least one tile is missing; clear the fully-cached flag for the
    -- duration of the (possibly async) fill so the prefetch budget math
    -- doesn't falsely credit this page while we work on it.
    if self._fully_cached_pages then
        self._fully_cached_pages[pageno] = nil
    end

    local raw_data, rerr = self:_getRawImageData(pageno)

    if not raw_data then
        if rerr == "pending" then
            -- Body not injected yet; caller should paint a placeholder and
            -- request the page async. Don't treat as an error.
            return "pending"
        end
        logger.dbg(string.format("[kamare:tilegen] page=%d missing=%d/%d raw-fetch-FAIL %dms",
            pageno, #missing, #tiles, time.to_ms(time.now() - t0)))
        if self.on_image_load_error then
            self.on_image_load_error(pageno, "Failed to load image data")
        end
        return 0
    end

    local ok, full_bb = pcall(mupdf.renderImage, raw_data, #raw_data, render_w, render_h)

    if not ok or not full_bb then
        logger.warn("VID:_preSplitPageTiles renderImage failed", "page", pageno, "error", full_bb)
        if self.on_image_load_error then
            self.on_image_load_error(pageno, "Failed to render image")
        end
        return 0
    end

    self:_applyColorAdjustments(full_bb)

    local tiles_generated = 0

    for _, t in ipairs(missing) do
        local tx = math.max(0, math.min(t.x, render_w))
        local ty = math.max(0, math.min(t.y, render_h))
        local tw = math.max(0, math.min(t.w, render_w - tx))
        local th = math.max(0, math.min(t.h, render_h - ty))

        if tw > 0 and th > 0 then
            local tile_bb = Blitbuffer.new(tw, th, self.render_color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
            tile_bb:blitFrom(full_bb, 0, 0, tx, ty, tw, th)

            local tile = TileCacheItem:new{
                persistent = true,
                doc_path = self.file,
                created_ts = os.time(),
                excerpt = Geom:new{ x = tx, y = ty, w = tw, h = th },
                pageno = pageno,
                bb = tile_bb,
            }
            tile.size = tonumber(tile_bb.stride) * tile_bb.h + 512
            tile.render_scale_x = render_scale_x
            tile.render_scale_y = render_scale_y
            tile.onFree = createTileFreeCallback(self, pageno)

            local key = self:_tileHash(pageno, zoom, self.gamma, t, render_quality)
            VIDCache:setNativeTile(key, tile, tile.size)

            tiles_generated = tiles_generated + 1
        end
    end

    full_bb:free()

    -- Drop the raw JPEG/PNG body now that all tiles have been generated.
    -- The tiles themselves hold the decoded image data; if any tile is
    -- later evicted from the LRU, the async-fetch path will re-request
    -- the body. Holding the raw body for every prefetched page across
    -- a long chapter adds up to ~hundreds of MB of dead weight.
    if self._prefetched_raw then
        self._prefetched_raw[pageno] = nil
    end

    logger.dbg(string.format("[kamare:tilegen] page=%d missing=%d/%d generated=%d %dms",
        pageno, #missing, #tiles, tiles_generated, time.to_ms(time.now() - t0)))

    -- All missing tiles were generated and inserted; the page is now fully cached.
    self._fully_cached_pages = self._fully_cached_pages or {}
    self._fully_cached_pages[pageno] = true

    return tiles_generated
end

function VirtualImageDocument:drawPageTiled(target, x, y, rect, pageno, zoom, tile_px, prefetch_rows, page_mode, render_w, render_h, render_quality)
    local t0 = time.now()
    local native = self:getNativePageDimensions(pageno)

    if not native or native.w <= 0 or native.h <= 0 then
        logger.warn("VID:drawPageTiled invalid page dimensions", "page", pageno)
        return false
    end

    if not render_w or not render_h then
        logger.warn("VID:drawPageTiled missing render dims", "page", pageno)
        render_w, render_h = native.w, native.h
    end
    local render_scale_x = render_w / native.w
    local render_scale_y = render_h / native.h
    local start_y = math.max(0, rect.y or 0)
    local end_y = math.min(native.h, (rect.y or 0) + (rect.h or 0))
    local clamped_h = math.max(0, end_y - start_y)

    if clamped_h <= 0 then
        logger.warn("VID:drawPageTiled rect completely outside page bounds", "page", pageno, "rect_y", rect.y, "rect_h", rect.h, "native_h", native.h)
        return true
    end

    local base_rect = Geom:new{
        x = math.floor((rect.x or 0) * render_scale_x),
        y = math.floor(start_y * render_scale_y),
        w = math.floor(math.min(rect.w or native.w, native.w) * render_scale_x),
        h = math.floor(clamped_h * render_scale_y),
    }

    local tp = math.max(16, tonumber(tile_px or self.tile_px or TILE_SIZE_PX))
    local rows = tonumber(prefetch_rows) or 0

    local prefetch_rect = base_rect

    if rows > 0 then
        local pad = rows * tp
        local y0 = math.max(0, base_rect.y - pad)
        local y1 = math.min(render_h, base_rect.y + base_rect.h + pad)
        prefetch_rect = Geom:new{
            x = base_rect.x,
            y = y0,
            w = base_rect.w,
            h = math.max(0, y1 - y0),
        }
    end

    local tiles = self:_computeTileRects(prefetch_rect, tp)
    local any_missing = false

    for _, t in ipairs(tiles) do
        local key = self:_tileHash(pageno, zoom, self.gamma, t, render_quality)
        if not VIDCache:getNativeTile(key) then
            any_missing = true
            break
        end
    end

    if any_missing then
        local gen = self:_preSplitPageTiles(pageno, zoom, tile_px, page_mode,
                                             render_w, render_h, render_quality)
        if gen == "pending" then
            -- Body not available yet (page wasn't prefetched). Tell the caller
            -- (canvas) to paint a placeholder and request the page async; do
            -- NOT proceed to assemble/blit partial tiles.
            return "pending"
        end
    end

    tiles = self:_computeTileRects(base_rect, tp)

    if #tiles == 0 then return true end

    local zoom_scale_x = zoom / render_scale_x
    local zoom_scale_y = zoom / render_scale_y
    local assembled_bb = Blitbuffer.new(base_rect.w, base_rect.h, self.render_color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
    local tiles_rendered = 0
    local ok = pcall(function()
        for i, t in ipairs(tiles) do
            local key = self:_tileHash(pageno, zoom, self.gamma, t, render_quality)
            local ttile = VIDCache:getNativeTile(key)
            if ttile and ttile.bb then
                local tile_bb = ttile.bb
                local tile_rect = ttile.excerpt

                local overlap = intersectRects(tile_rect, base_rect)
                if overlap then
                    local src_x = overlap.x - tile_rect.x
                    local src_y = overlap.y - tile_rect.y
                    local src_w = overlap.w
                    local src_h = overlap.h

                    src_w = math.min(src_w, tile_bb:getWidth() - src_x)
                    src_h = math.min(src_h, tile_bb:getHeight() - src_y)

                    if src_w > 0 and src_h > 0 then
                        local dst_x = overlap.x - base_rect.x
                        local dst_y = overlap.y - base_rect.y

                        assembled_bb:blitFrom(tile_bb, dst_x, dst_y, src_x, src_y, src_w, src_h)
                        tiles_rendered = tiles_rendered + 1
                    end
                end
            end
        end

        if zoom_scale_x ~= 1.0 or zoom_scale_y ~= 1.0 then
            local final_w = math.floor(base_rect.w * zoom_scale_x)
            local final_h = math.floor(base_rect.h * zoom_scale_y)

            local ok_scale, scaled_bb = pcall(mupdf.scaleBlitBuffer, assembled_bb, final_w, final_h)
            if ok_scale and scaled_bb then
                target:blitFrom(scaled_bb, x, y, 0, 0, final_w, final_h)
                scaled_bb:free()
            else
                logger.warn("VID:drawPageTiled scaling assembled image failed, using unscaled")
                target:blitFrom(assembled_bb, x, y, 0, 0, base_rect.w, base_rect.h)
            end
        else
            target:blitFrom(assembled_bb, x, y, 0, 0, base_rect.w, base_rect.h)
        end
    end)
    -- Always free assembled_bb, whether the pcall succeeded or threw. A
    -- mid-loop blitFrom failure used to leak a viewport-sized BlitBuffer;
    -- failures tend to cluster under memory pressure, so the leak compounded.
    if assembled_bb then
        assembled_bb:free()
    end
    if not ok then
        logger.dbg(string.format("[kamare:render] page=%d miss=%s tiles_rendered=%d ASSEMBLE-FAIL %dms",
            pageno, tostring(any_missing), tiles_rendered, time.to_ms(time.now() - t0)))
        return false
    end

    logger.dbg(string.format("[kamare:render] page=%d miss=%s tiles_rendered=%d %dms",
        pageno, tostring(any_missing), tiles_rendered, time.to_ms(time.now() - t0)))

    return true
end

function VirtualImageDocument:register(registry)
end

return VirtualImageDocument
