local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local Geom = require("ui/geometry")
local logger = require("logger")
local Blitbuffer = require("ffi/blitbuffer")
local TileCacheItem = require("document/tilecacheitem")
local mupdf = require("ffi/mupdf")
local VIDCache = require("virtualimagedocumentcache")
local Device = require("device")
local Screen = Device.screen

local DEFAULT_PAGE_WIDTH = 800
local DEFAULT_PAGE_HEIGHT = 1200
local TILE_SIZE_PX = 1024

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

    _virtual_layout_cache = nil,
    _virtual_layout_dirty = true,

    _dims_cache = nil,
    _orientation_cache = nil,

    _dual_page_offset = nil,
    _dual_page_pairs = nil, -- Pre-calculated pairs array: [index] = {left, right}
    content_type = "auto", -- "auto", "volume", or "chapter"

    tile_px = TILE_SIZE_PX, -- default tile size (px)

    on_image_load_error = nil, -- Callback: function(pageno, error_msg)
}

local function isPositiveDimension(w, h)
    return w and h and w > 0 and h > 0
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
    if self.images_dimensions then
        self:preloadDimensions(self.images_dimensions)
    end

    self._virtual_layout_cache = {}
    self._virtual_layout_dirty = true

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

    -- Mark as non-picture document so statistics will track it
    self.is_pic = false

    self.tile_cache_validity_ts = os.time()

    self:updateColorRendering()

    if self._pages > 0 then
        self:_preSplitPageTiles(1, 1.0, 0, nil, true)
        -- Build dual-page layout once on init
        self:_buildDualPageLayout()
    end
end

function VirtualImageDocument:clearCache()
    VIDCache:clear()
end

function VirtualImageDocument:close()
    self.is_open = false
    self._dims_cache = nil
    self._orientation_cache = nil
    self._virtual_layout_cache = nil
    self.virtual_layout = nil
    self.total_virtual_height = nil
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
end

function VirtualImageDocument:_ensureVirtualLayout(rotation)
    rotation = rotation or 0
    self._virtual_layout_cache = self._virtual_layout_cache or {}
    if self._virtual_layout_dirty then
        self._virtual_layout_cache = {}
        self._virtual_layout_dirty = false
    end

    local cache_key = string.format("%d:%d", rotation, self._pages)
    local entry = self._virtual_layout_cache[cache_key]
    if entry then
        self.virtual_layout = entry.pages
        self.total_virtual_height = entry.rotated_total_height
        return entry
    end
    entry = {
        rotation = rotation,
        pages = {},
        native_total_height = 0,
        rotated_total_height = 0,
        native_max_width = 0,
        rotated_max_width = 0,
    }

    local native_offset = 0
    local rotated_offset = 0

    for i = 1, self._pages do
        local dims = self:_getDimsWithDefault(i)
        local native_w = dims.w
        local native_h = dims.h

        local rotated_dims = self:transformRect(Geom:new{ w = native_w, h = native_h }, 1, rotation)
        local rotated_w = rotated_dims and rotated_dims.w or native_w
        local rotated_h = rotated_dims and rotated_dims.h or native_h
        if rotated_w <= 0 or rotated_h <= 0 then
            rotated_w, rotated_h = native_w, native_h
        end

        entry.pages[i] = {
            page_num = i,
            native_width = native_w,
            native_height = native_h,
            rotated_width = rotated_w,
            rotated_height = rotated_h,
            native_y_offset = native_offset,
            rotated_y_offset = rotated_offset,
        }

        entry.native_max_width = math.max(entry.native_max_width, native_w)
        entry.rotated_max_width = math.max(entry.rotated_max_width, rotated_w)

        native_offset = native_offset + native_h
        rotated_offset = rotated_offset + rotated_h
    end

    if self._pages > 0 then
        entry.native_total_height = math.max(0, native_offset)
        entry.rotated_total_height = math.max(0, rotated_offset)
    end

    self._virtual_layout_cache[cache_key] = entry
    self.virtual_layout = entry.pages
    self.total_virtual_height = entry.rotated_total_height

    return entry
end

function VirtualImageDocument:_calculateRenderDimensions(native_dims, cap_height)
    local render_w = native_dims.w
    local render_h = native_dims.h

    if cap_height == nil then
        cap_height = true
    end

    if self.render_quality ~= -1 then
        local screen_size = Screen:getSize()
        local cap_w = math.floor(screen_size.w * self.render_quality)

        if cap_height then
            local cap_h = math.floor(screen_size.h * self.render_quality)
            if native_dims.w > cap_w or native_dims.h > cap_h then
                local scale = math.min(cap_w / native_dims.w, cap_h / native_dims.h)
                render_w = math.floor(native_dims.w * scale)
                render_h = math.floor(native_dims.h * scale)
            end
        else
            if native_dims.w > cap_w then
                local scale = cap_w / native_dims.w
                render_w = math.floor(native_dims.w * scale)
                render_h = math.floor(native_dims.h * scale)
            end
        end
    end

    return render_w, render_h
end

function VirtualImageDocument:_getRawImageData(pageno)
    local entry = self.images_list and self.images_list[pageno]

    if type(entry) == "function" then
        local ok, result = pcall(entry)
        if ok then
            entry = result
        else
            logger.warn("VID:_getRawImageData supplier error", "page", pageno, "error", result)
            return nil
        end
    end

    return entry
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
-- Pairs are built in physical order (ascending page numbers)
function VirtualImageDocument:_buildDualPageLayout()
    local content_type = self.content_type or "auto"
    local pairs = {}
    local offset = self:getDualPageOffset()
    local page_count = self._pages

    local function is_landscape(page)
        if page < 1 or page > page_count then return false end

        return self:getPageOrientation(page) == 1
    end

    local is_chapter = (content_type == "chapter")
    local page = 1

    if page == 1 and not is_chapter then
        table.insert(pairs, {0, 1})
        page = page + 1

        if offset == 1 then
            table.insert(pairs, {0, 2})
            page = page + 1
        end
    end

    while page <= page_count do
        if is_landscape(page) then
            table.insert(pairs, {page, page})
            page = page + 1
        else
            local next_page = page + 1
            if next_page <= page_count and not is_landscape(next_page) then
                table.insert(pairs, {page, next_page})
                page = page + 2
            else
                table.insert(pairs, {page, 0})
                page = page + 1
            end
        end
    end

    self._dual_page_pairs = pairs
    return pairs
end

function VirtualImageDocument:getSpreadForPage(page)
    if page < 1 or page > self._pages then
        return page
    end

    if not self._dual_page_pairs then
        return page
    end
    local pairs = self._dual_page_pairs

    -- Find the pair that contains this page
    for i, pair in ipairs(pairs) do
        local left, right = pair[1], pair[2]

        if page == left or page == right then
            return page
        elseif left > 0 and right > 0 and (page == left or page == right) then
            -- This case handles when we find the exact page in a valid pair
            return page
        end
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
    local pairs = self._dual_page_pairs

    for i, pair in ipairs(pairs) do
        local page1, page2 = pair[1], pair[2]

        if current_page == page1 or current_page == page2 then
            local next_pair = pairs[i + 1]

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
    end

    return math.min(current_page + 1, self._pages)
end

function VirtualImageDocument:getPrevSpreadPage(current_page)
    if current_page < 1 or current_page > self._pages then
        return current_page
    end

    if not self._dual_page_pairs then
        return math.max(current_page - 1, 1)
    end

    local pairs = self._dual_page_pairs

    -- Find the current spread
    for i, pair in ipairs(pairs) do
        local page1, page2 = pair[1], pair[2]

        if current_page == page1 or current_page == page2 then
            -- Found current spread, return first page of previous spread
            local prev_pair = pairs[i - 1]
            if prev_pair then
                local prev_page1, prev_page2 = prev_pair[1], prev_pair[2]
                -- Return the first non-zero page
                if prev_page1 > 0 then
                    return prev_page1
                elseif prev_page2 > 0 then
                    return prev_page2
                end
            end
            -- No previous spread, stay on current page
            return current_page
        end
    end

    -- Not found in pairs, just decrement
    return math.max(current_page - 1, 1)
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

function VirtualImageDocument:_calculateVirtualLayout()
    local entry = self:_ensureVirtualLayout(0)
    if entry then
        self.virtual_layout = entry.pages
        self.total_virtual_height = entry.rotated_total_height
    end
end

function VirtualImageDocument:getVirtualHeight(zoom, rotation, zoom_mode, viewport_width)
    zoom = zoom or 1.0
    local entry = self:_ensureVirtualLayout(rotation or 0)
    if not entry then
        logger.warn("VID:getVirtualHeight no layout", "rotation", rotation, "zoom", zoom)
        return 0
    end

    local use_fit_width = (zoom_mode == 1 and viewport_width and viewport_width > 0)
    if use_fit_width then
        local total_height = 0
        for _, page in ipairs(entry.pages or {}) do
            if page.native_width and page.native_width > 0 then
                local page_zoom = viewport_width / page.native_width
                total_height = total_height + page.rotated_height * page_zoom
            end
        end
        return total_height
    else
        local height = math.max(0, entry.rotated_total_height) * zoom
        return height
    end
end

function VirtualImageDocument:getVisiblePagesAtOffset(offset_y, viewport_height, zoom, rotation, zoom_mode, viewport_width)
    offset_y = math.max(0, offset_y or 0)
    viewport_height = math.max(0, viewport_height or 0)
    zoom = zoom or 1.0
    if zoom <= 0 then
        zoom = 1.0
    end
    if viewport_height <= 0 then
        logger.warn("VID:getVisiblePagesAtOffset invalid viewport", "viewport_height", viewport_height)
        return {}
    end

    local entry = self:_ensureVirtualLayout(rotation or 0)
    if not entry or not entry.pages then
        logger.warn("VID:getVisiblePagesAtOffset no entry", "rotation", rotation)
        return {}
    end

    local result = {}
    local bottom = offset_y + viewport_height

    local use_fit_width = (zoom_mode == 1 and viewport_width and viewport_width > 0)
    local accumulated_offset = 0

    for _, page in ipairs(entry.pages) do
        local page_zoom = zoom
        local page_top, page_height

        if use_fit_width then
            if page.native_width and page.native_width > 0 then
                page_zoom = viewport_width / page.native_width
            end

            page_top = accumulated_offset
            page_height = page.rotated_height * page_zoom
            accumulated_offset = accumulated_offset + page_height
        else
            page_top = page.rotated_y_offset * zoom
            page_height = page.rotated_height * zoom
        end

        local page_bottom = page_top + page_height

        if page_bottom >= offset_y and page_top <= bottom then
            local visible_top = math.max(page_top, offset_y)
            local visible_bottom = math.min(page_bottom, bottom)
            table.insert(result, {
                page_num = page.page_num,
                page_top = page_top,
                page_bottom = page_bottom,
                visible_top = visible_top,
                visible_bottom = visible_bottom,
                layout = page,
                rotation = entry.rotation,
                zoom = page_zoom,  -- Use per-page zoom
                max_rotated_width = entry.rotated_max_width,
            })
        end
    end

    return result
end

function VirtualImageDocument:getScrollPositionForPage(pageno, zoom, rotation, zoom_mode, viewport_width)
    zoom = zoom or 1.0
    if zoom <= 0 then zoom = 1.0 end
    local entry = self:_ensureVirtualLayout(rotation or 0)
    if not entry or not entry.pages then
        logger.warn("VID:getScrollPositionForPage no entry", "page", pageno, "rotation", rotation)
        return 0
    end
    local page = entry.pages[pageno]
    if not page then
        logger.warn("VID:getScrollPositionForPage missing page", "page", pageno)
        return 0
    end

    local use_fit_width = (zoom_mode == 1 and viewport_width and viewport_width > 0)
    if use_fit_width then
        local accumulated_offset = 0
        for i = 1, pageno - 1 do
            local p = entry.pages[i]
            if p and p.native_width and p.native_width > 0 then
                local page_zoom = viewport_width / p.native_width
                accumulated_offset = accumulated_offset + p.rotated_height * page_zoom
            end
        end
        return accumulated_offset
    else
        local position = page.rotated_y_offset * zoom
        return position
    end
end

function VirtualImageDocument:getPageAtOffset(offset_y, zoom, rotation, zoom_mode, viewport_width)
    zoom = zoom or 1.0
    if zoom <= 0 then zoom = 1.0 end
    offset_y = math.max(0, offset_y or 0)

    local entry = self:_ensureVirtualLayout(rotation or 0)
    if not entry or not entry.pages then
        logger.warn("VID:getPageAtOffset no entry", "offset", offset_y, "rotation", rotation)
        return 1
    end

    local use_fit_width = (zoom_mode == 1 and viewport_width and viewport_width > 0)
    if use_fit_width then
        local accumulated_offset = 0
        for _, page in ipairs(entry.pages) do
            local page_zoom = zoom
            if page.native_width and page.native_width > 0 then
                page_zoom = viewport_width / page.native_width
            end
            local page_height = page.rotated_height * page_zoom
            local page_top = accumulated_offset
            local page_bottom = page_top + page_height
            if offset_y >= page_top and offset_y < page_bottom then
                return page.page_num
            end
            accumulated_offset = accumulated_offset + page_height
        end
    else
        for _, page in ipairs(entry.pages) do
            local page_top = page.rotated_y_offset * zoom
            local page_bottom = page_top + page.rotated_height * zoom
            if offset_y >= page_top and offset_y < page_bottom then
                return page.page_num
            end
        end
    end

    return entry.pages[#entry.pages].page_num
end

function VirtualImageDocument:transformRect(native_rect, zoom, rotation)
    return Document.transformRect(self, native_rect, zoom, rotation)
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

function VirtualImageDocument:_tileHash(pageno, zoom, rotation, gamma, rect)
    local qg = math.floor((gamma or 1) * 1000 + 0.5)
    local x = math.floor(rect.x or 0)
    local y = math.floor(rect.y or 0)
    local w = math.floor(rect.w or 0)
    local h = math.floor(rect.h or 0)
    local color = self.render_color and "color" or "bw"
    local quality_key = tostring(self.render_quality or -1)

    return table.concat({
        "nativetile",
        self.file or "",
        tostring(self.mod_time or 0),
        tostring(pageno or 0),
        tostring(x), tostring(y), tostring(w), tostring(h),
        tostring(rotation or 0),
        tostring(qg),
        tostring(self.render_mode or 0),
        color,
        quality_key,
    }, "|")
end


function VirtualImageDocument:getPageDimensions(pageno, zoom, rotation)
    local native_rect = self:getNativePageDimensions(pageno)
    local transformed = self:transformRect(native_rect, zoom, rotation)
    return transformed
end

function VirtualImageDocument:getToc()
    return {}
end

function VirtualImageDocument:renderPage(pageno, rect, zoom, rotation, page_mode, clip_rect)
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

    local clamped_rect = Geom:new{ x = offset_x, y = offset_y, w = native_w, h = native_h }
    local hash = self:_tileHash(pageno, zoom, rotation, self.gamma, native_rect)

    local native_tile = VIDCache:getNativeTile(hash)
    if native_tile then
        return self:_scaleToZoom(native_tile, zoom, rotation, clip_rect)
    end

    local raw_data = self:_getRawImageData(pageno)
    if not raw_data then
        if self.on_image_load_error then
            self.on_image_load_error(pageno, "Failed to load image data")
        end
        return nil
    end

    local cap_height = (page_mode == nil) or page_mode
    local render_w, render_h = self:_calculateRenderDimensions(native_dims, cap_height)

    local ok, full_bb = pcall(mupdf.renderImage, raw_data, #raw_data, render_w, render_h)
    if not ok or not full_bb then
        logger.warn("VID:renderPage renderImage failed", "page", pageno, "error", full_bb)
        if self.on_image_load_error then
            self.on_image_load_error(pageno, "Failed to render image")
        end
        return nil
    end

    local render_scale_x = render_w / native_dims.w
    local render_scale_y = render_h / native_dims.h

    local scaled_offset_x = math.floor(offset_x * render_scale_x + 0.5)
    local scaled_offset_y = math.floor(offset_y * render_scale_y + 0.5)
    local scaled_w = math.floor(native_w * render_scale_x + 0.5)
    local scaled_h = math.floor(native_h * render_scale_y + 0.5)

    local tile_bb = Blitbuffer.new(scaled_w, scaled_h, self.render_color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
    tile_bb:blitFrom(full_bb, 0, 0, scaled_offset_x, scaled_offset_y, scaled_w, scaled_h)

    full_bb:free()

    local tile = TileCacheItem:new{
        persistent = true,
        doc_path = self.file,
        created_ts = os.time(),
        excerpt = clamped_rect,
        pageno = pageno,
        bb = tile_bb,
    }
    tile.size = tonumber(tile_bb.stride) * tile_bb.h + 512
    -- Store render scale for correct zoom scaling later
    tile.render_scale_x = render_scale_x
    tile.render_scale_y = render_scale_y

    VIDCache:setNativeTile(hash, tile, tile.size)

    return self:_scaleToZoom(tile, zoom, rotation, clip_rect)
end

function VirtualImageDocument:_scaleToZoom(native_tile, zoom, rotation, clip_rect)
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

        local bb_x = math.floor(rel_x * render_scale_x + 0.5)
        local bb_y = math.floor(rel_y * render_scale_y + 0.5)
        local bb_w = math.floor(clip_rect.w * render_scale_x + 0.5)
        local bb_h = math.floor(clip_rect.h * render_scale_y + 0.5)

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

    local target_w = math.ceil(native_w * effective_zoom_x)
    local target_h = math.ceil(native_h * effective_zoom_y)

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
    scaled_tile.render_scale_x = native_tile.render_scale_x
    scaled_tile.render_scale_y = native_tile.render_scale_y

    return scaled_tile
end

function VirtualImageDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, page_mode)
    local tile = self:renderPage(pageno, rect, zoom, rotation, page_mode)
    if tile and tile.bb then
        target:blitFrom(tile.bb,
            x, y,
            0, 0,
            tile.bb:getWidth(), tile.bb:getHeight())
        return true
    end
    return false
end

function VirtualImageDocument:prefetchPage(page, zoom, rotation, page_mode)
    return self:_preSplitPageTiles(page, zoom, rotation, nil, page_mode)
end

function VirtualImageDocument:_preSplitPageTiles(pageno, zoom, rotation, tile_px, page_mode)
    local native = self:getNativePageDimensions(pageno)
    if not native or native.w <= 0 or native.h <= 0 then return end

    local full_rect = Geom:new{ x = 0, y = 0, w = native.w, h = native.h }
    local tp = math.max(16, tonumber(tile_px or self.tile_px or TILE_SIZE_PX))
    local tiles = self:_computeTileRects(full_rect, tp)

    if #tiles == 0 then return end

    local missing = {}

    for _, t in ipairs(tiles) do
        local key = self:_tileHash(pageno, zoom, rotation, self.gamma, t)
        local exists = VIDCache:getNativeTile(key)
        if not (exists and exists.bb) then
            table.insert(missing, t)
        end
    end

    if #missing == 0 then
        return
    end

    local raw_data = self:_getRawImageData(pageno)
    if not raw_data then
        if self.on_image_load_error then
            self.on_image_load_error(pageno, "Failed to load image data")
        end
        return
    end

    local cap_height = (page_mode == nil) or page_mode
    local render_w, render_h = self:_calculateRenderDimensions(native, cap_height)

    local ok, full_bb = pcall(mupdf.renderImage, raw_data, #raw_data, render_w, render_h)
    if not ok or not full_bb then
        logger.warn("VID:_preSplitPageTiles renderImage failed", "page", pageno, "error", full_bb)
        if self.on_image_load_error then
            self.on_image_load_error(pageno, "Failed to render image")
        end
        return
    end

    local render_scale_x = render_w / native.w
    local render_scale_y = render_h / native.h

    for _, t in ipairs(missing) do
        local tx = math.max(0, math.min(t.x, native.w))
        local ty = math.max(0, math.min(t.y, native.h))
        local tw = math.max(0, math.min(t.w, native.w - tx))
        local th = math.max(0, math.min(t.h, native.h - ty))

        if tw > 0 and th > 0 then
            local scaled_tx = math.floor(tx * render_scale_x + 0.5)
            local scaled_ty = math.floor(ty * render_scale_y + 0.5)
            local scaled_tw = math.floor(tw * render_scale_x + 0.5)
            local scaled_th = math.floor(th * render_scale_y + 0.5)

            local tile_bb = Blitbuffer.new(scaled_tw, scaled_th, self.render_color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
            tile_bb:blitFrom(full_bb, 0, 0, scaled_tx, scaled_ty, scaled_tw, scaled_th)

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

            local key = self:_tileHash(pageno, zoom, rotation, self.gamma, t)
            VIDCache:setNativeTile(key, tile, tile.size)
        end
    end

    full_bb:free()
end

function VirtualImageDocument:drawPageTiled(target, x, y, rect, pageno, zoom, rotation, tile_px, prefetch_rows, page_mode)
    local tp = math.max(16, tonumber(tile_px or self.tile_px or TILE_SIZE_PX))
    local tiles = self:_computeTileRects(rect, tp)
    local any_missing = false

    for _, t in ipairs(tiles) do
        local key = self:_tileHash(pageno, zoom, rotation, self.gamma, t)
        if not VIDCache:getNativeTile(key) then
            any_missing = true
            break
        end
    end

    if any_missing then
        self:_preSplitPageTiles(pageno, zoom, rotation, tile_px, page_mode)
    end

    local native = self:getNativePageDimensions(pageno)

    if not native or native.w <= 0 or native.h <= 0 then
        logger.warn("VID:drawPageTiled invalid page dimensions", "page", pageno)
        return false
    end

    local start_y = math.max(0, rect.y or 0)
    local end_y = math.min(native.h, (rect.y or 0) + (rect.h or 0))
    local clamped_h = math.max(0, end_y - start_y)

    if clamped_h <= 0 then
        logger.warn("VID:drawPageTiled rect completely outside page bounds", "page", pageno, "rect_y", rect.y, "rect_h", rect.h, "native_h", native.h)
        return true
    end

    local base_rect = Geom:new{
        x = rect.x or 0,
        y = start_y,
        w = math.min(rect.w or native.w, native.w),
        h = clamped_h,
    }

    local rows = tonumber(prefetch_rows) or 0

    local prefetch_rect = base_rect

    if rows > 0 then
        local pad = rows * tp
        local y0 = math.max(0, base_rect.y - pad)
        local y1 = math.min(native.h, base_rect.y + base_rect.h + pad)
        prefetch_rect = Geom:new{
            x = base_rect.x,
            y = y0,
            w = base_rect.w,
            h = math.max(0, y1 - y0),
        }
    end

    local need_batch = false

    do
        local probe_tiles = self:_computeTileRects(prefetch_rect, tp)
        for _, t in ipairs(probe_tiles) do
            local key = self:_tileHash(pageno, zoom, rotation, self.gamma, t)
            local hit = VIDCache:getNativeTile(key)
            if not (hit and hit.bb) then
                need_batch = true
                break
            end
        end
    end

    local batch_started = need_batch and self:_beginTileBatch(pageno) or false

    tiles = self:_computeTileRects(prefetch_rect, tp)

    if #tiles == 0 then return true end

    local ok, err = pcall(function()
        for i, t in ipairs(tiles) do
            local tile_overlap = intersectRects(t, base_rect)

            if not tile_overlap then
                goto continue
            end

            local ttile = self:renderPage(pageno, t, zoom, rotation, page_mode, tile_overlap)

            if ttile and ttile.bb then
                local actual_tile_rect = ttile.excerpt or tile_overlap

                local overlap = intersectRects(actual_tile_rect, base_rect)
                if overlap then
                    local tile_bb_w = ttile.bb:getWidth()
                    local tile_bb_h = ttile.bb:getHeight()

                    local native_src_x = overlap.x - actual_tile_rect.x
                    local native_src_y = overlap.y - actual_tile_rect.y

                    local src_x = math.floor(native_src_x * zoom)
                    local src_y = math.floor(native_src_y * zoom)

                    local dst_x_start = x + math.floor((overlap.x - base_rect.x) * zoom)
                    local dst_y_start = y + math.floor((overlap.y - base_rect.y) * zoom)
                    local dst_x_end = x + math.floor((overlap.x + overlap.w - base_rect.x) * zoom)
                    local dst_y_end = y + math.floor((overlap.y + overlap.h - base_rect.y) * zoom)

                    local dst_x = dst_x_start
                    local dst_y = dst_y_start
                    local w = dst_x_end - dst_x_start
                    local h = dst_y_end - dst_y_start

                    local src_w_avail = tile_bb_w - src_x
                    local src_h_avail = tile_bb_h - src_y
                    local blit_w = math.min(w, src_w_avail)
                    local blit_h = math.min(h, src_h_avail)

                    if blit_w > 0 and blit_h > 0 then
                        target:blitFrom(ttile.bb, dst_x, dst_y, src_x, src_y, blit_w, blit_h)
                    end
                end
            end

            ::continue::
        end
    end)
    if batch_started then
        self:_endTileBatch()
    end
    if not ok then
        return false
    end

    return true
end

function VirtualImageDocument:register(registry)
end

return VirtualImageDocument
