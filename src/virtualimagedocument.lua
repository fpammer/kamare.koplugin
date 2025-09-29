local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local Geom = require("ui/geometry")
local logger = require("logger")
local Blitbuffer = require("ffi/blitbuffer")
local TileCacheItem = require("document/tilecacheitem")
local DocCache = require("document/doccache")

-- Debug helpers
local function rectToStr(r)
    if not r then return "nil" end
    local x = r.x or (r.x0 or 0)
    local y = r.y or (r.y0 or 0)
    local w = r.w or ((r.x1 or 0) - (r.x0 or 0))
    local h = r.h or ((r.y1 or 0) - (r.y0 or 0))
    return string.format("x=%d y=%d w=%d h=%d", x, y, w, h)
end

local function boolStr(b) return b and "true" or "false" end

local mupdf = nil -- Declared as nil initially

local VirtualImageDocument = Document:extend{
    provider = "virtualimagedocument",
    provider_name = "Virtual Image Document",

    title = "Virtual Image Document",

    -- Table of image data: array of strings (raw data) or functions () -> string
    images_list = nil,
    pages_override = nil,  -- For lazy tables with known length

    cache_id = nil,        -- Stable ID for caching (e.g., session ID)

    sw_dithering = false,

    -- Number of images/pages
    _pages = 0,

    -- DC for null renders (e.g., getSize)
    dc_null = DrawContext.new(),

    render_color = true,  -- Render in color if possible
}

local function detectImageMagic(raw_data)
    if not raw_data or #raw_data < 4 then return nil end
    local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12 = raw_data:byte(1, 12)
    -- PNG: 89 50 4E 47
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then
        return "image/png"
    -- JPEG: FF D8 FF
    elseif b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then
        return "image/jpeg"
    -- GIF: 47 49 46 38
    elseif b1 == 0x47 and b2 == 0x49 and b3 == 0x46 and b4 == 0x38 then
        return "image/gif"
    -- WEBP: "RIFF" .... "WEBP"
    elseif b1 == 0x52 and b2 == 0x49 and b3 == 0x46 and b4 == 0x46
        and b9 == 0x57 and b10 == 0x45 and b11 == 0x42 and b12 == 0x50 then
        return "image/webp"
    end
    return nil  -- Invalid/unsupported
end

-- Helpers to extract image dimensions directly from headers without decoding via MuPDF
local bit = bit

local function u16be(s, o)
    local b1, b2 = s:byte(o, o+1)
    if not b1 then return nil end
    return b1*256 + b2
end

local function u32be(s, o)
    local b1, b2, b3, b4 = s:byte(o, o+3)
    if not b1 then return nil end
    return ((b1*256 + b2)*256 + b3)*256 + b4
end

local function u16le(s, o)
    local b1, b2 = s:byte(o, o+1)
    if not b1 then return nil end
    return b1 + b2*256
end

local function u32le(s, o)
    local b1, b2, b3, b4 = s:byte(o, o+3)
    if not b1 then return nil end
    return b1 + b2*256 + b3*65536 + b4*16777216
end

local function u24le(s, o)
    local b1, b2, b3 = s:byte(o, o+2)
    if not b1 then return nil end
    return b1 + b2*256 + b3*65536
end

local function getImageSizeFromHeader(raw)
    if type(raw) ~= "string" or #raw < 12 then return nil end

    local b1, b2, b3, b4, b5, b6 = raw:byte(1, 6)

    -- PNG: 89 50 4E 47 0D 0A 1A 0A, IHDR must be first chunk
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then
        if #raw < 24 then return nil end
        local w = u32be(raw, 17)
        local h = u32be(raw, 21)
        if w and h and w > 0 and h > 0 then return w, h end
        return nil
    end

    -- JPEG: FF D8 FF ... scan to SOF markers
    if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then
        local i = 3
        local n = #raw
        while i < n do
            while i < n and raw:byte(i) ~= 0xFF do i = i + 1 end
            while i < n and raw:byte(i) == 0xFF do i = i + 1 end
            if i >= n then break end
            local marker = raw:byte(i); i = i + 1

            if (marker >= 0xD0 and marker <= 0xD9) or marker == 0x01 then
                -- standalone markers
            else
                if i + 1 > n then break end
                local seglen = u16be(raw, i); i = i + 2
                if not seglen or seglen < 2 or i + seglen - 2 > n then break end

                if (marker >= 0xC0 and marker <= 0xCF) and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                    if seglen < 7 then break end
                    local _precision = raw:byte(i)
                    local h = u16be(raw, i+1)
                    local w = u16be(raw, i+3)
                    if w and h and w > 0 and h > 0 then return w, h end
                    break
                end
                i = i + seglen - 2
            end
        end
        return nil
    end

    -- GIF: "GIF87a" or "GIF89a"
    if raw:sub(1, 6) == "GIF87a" or raw:sub(1, 6) == "GIF89a" then
        if #raw < 10 then return nil end
        local w = u16le(raw, 7)
        local h = u16le(raw, 9)
        if w and h and w > 0 and h > 0 then return w, h end
        return nil
    end

    -- WebP: RIFF....WEBP with chunks VP8X/VP8 /VP8L
    if raw:sub(1, 4) == "RIFF" and raw:sub(9, 12) == "WEBP" then
        local n = #raw
        local i = 13 -- first chunk header offset
        while i + 7 <= n do
            local fourcc = raw:sub(i, i+3)
            local size = u32le(raw, i+4) or 0
            local data_start = i + 8
            local data_end = data_start + size - 1
            if data_end > n then break end

            if fourcc == "VP8X" and size >= 10 then
                local w = u24le(raw, data_start + 4)
                local h = u24le(raw, data_start + 7)
                if w and h then return (w + 1), (h + 1) end
            elseif fourcc == "VP8 " and size >= 10 then
                local s1, s2, s3 = raw:byte(data_start+3, data_start+5)
                if s1 == 0x9D and s2 == 0x01 and s3 == 0x2A then
                    local w = u16le(raw, data_start+6)
                    local h = u16le(raw, data_start+8)
                    if w and h then return w, h end
                end
            elseif fourcc == "VP8L" and size >= 5 then
                if raw:byte(data_start) == 0x2F then
                    local b0, b1, b2, b3 = raw:byte(data_start+1, data_start+4)
                    if b0 then
                        local bits = b0 + b1*256 + b2*65536 + b3*16777216
                        local w = bit.band(bits, 0x3FFF) + 1
                        local h = bit.band(bit.rshift(bits, 14), 0x3FFF) + 1
                        if w > 0 and h > 0 then return w, h end
                    end
                end
            end

            i = data_end + (size % 2 == 1 and 2 or 1) -- pad to even
        end
        return nil
    end

    return nil
end

local function isPositiveDimension(w, h)
    return w and h and w > 0 and h > 0
end

function VirtualImageDocument:init()
    Document._init(self)  -- Call base init

    if not mupdf then mupdf = require("ffi/mupdf") end -- Loaded here

    -- Default render mode required by base Document hashing
    self.render_mode = 0

    self.images_list = self.images_list or {}
    self._pages = self.pages_override or #self.images_list
    -- Lazy cache for native dimensions
    self._dims_cache = {}

    if self._pages == 0 then
        logger.warn("VirtualImageDocument: No images provided")
        self.is_open = false
        return
    end

    -- Provide stable identifiers for hashing/caching (must remain stable across sessions)
    self.file = "virtualimage://" .. (self.cache_id or self.title or "session")
    self.mod_time = self.cache_mod_time or 0

    self.is_open = true
    self.info.has_pages = true
    self.info.number_of_pages = self._pages
    self.info.configurable = false

    self:updateColorRendering()

end

function VirtualImageDocument:close()
    -- Not registered in DocumentRegistry; avoid calling Document.close().
    -- Just mark as closed and let GC handle any transient resources.
    self.is_open = false
    self._dims_cache = nil
    return true
end

function VirtualImageDocument:_getRawImageData(pageno)
    local entry = self.images_list and self.images_list[pageno]
    if type(entry) == "function" then
        local ok, result = pcall(entry)
        if ok then
            entry = result
        else
            return nil, "supplier_error", result
        end
    end
    if type(entry) ~= "string" or #entry == 0 then
        return nil, "invalid_data", nil
    end
    return entry, nil, nil
end

function VirtualImageDocument:_openImageDoc(raw_data, magic, opts)
    opts = opts or {}
    if not magic then return nil end
    if not mupdf then mupdf = require("ffi/mupdf") end
    local ok, doc_or_err = pcall(mupdf.openDocumentFromText, raw_data, magic, nil)
    if ok and doc_or_err and doc_or_err.doc then
        return doc_or_err
    end
    if not opts.silent then
        logger.warn("Failed to open mini-doc for page", opts.pageno or "?", ":", doc_or_err)
    end
    return nil
end

function VirtualImageDocument:_determineNativeDims(raw_data, opts)
    opts = opts or {}
    local magic = opts.magic or detectImageMagic(raw_data)
    local w_hdr, h_hdr = getImageSizeFromHeader(raw_data)
    local doc = opts.doc
    local doc_created = false
    if not doc and magic and (opts.open_doc or not isPositiveDimension(w_hdr, h_hdr)) then
        doc = self:_openImageDoc(raw_data, magic, {
            silent = opts.silent_doc_fail,
            pageno = opts.pageno,
        })
        doc_created = doc ~= nil
    end

    local w, h
    local dims_source
    if doc then
        doc:setColorRendering(self.render_color)
        local page = doc:openPage(1)
        w, h = page:getSize(self.dc_null)
        page:close()
        if isPositiveDimension(w, h) then
            dims_source = "mupdf"
        end
        if not opts.keep_doc and doc_created then
            doc:close()
            doc = nil
        end
    end

    if not isPositiveDimension(w, h) and isPositiveDimension(w_hdr, h_hdr) then
        w, h = w_hdr, h_hdr
        dims_source = dims_source or "header"
    end

    if not isPositiveDimension(w, h) then
        w, h = 800, 1200
        dims_source = dims_source or "fallback"
    end

    return w, h, magic, doc, w_hdr, h_hdr, dims_source
end

function VirtualImageDocument:getDocumentProps()
    -- Minimal metadata for virtual doc
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
        logger.warn("getNativePageDimensions: invalid pageno", pageno, "valid:", 1, self._pages)
        return Geom:new{ w = 0, h = 0 }
    end

    local cached = self._dims_cache and self._dims_cache[pageno]
    if cached then
        return cached
    end

    self:ensureDims(pageno)
    cached = self._dims_cache and self._dims_cache[pageno]
    if cached then
        return cached
    end

    return Geom:new{ w = 800, h = 1200 }
end

-- Preload per-page native dimensions from a list of FileDimensionDto.
function VirtualImageDocument:preloadDimensions(list)
    if type(list) ~= "table" then return end
    self._dims_cache = self._dims_cache or {}
    local count = 0
    for _, d in ipairs(list) do
        local pn = d.pageNumber or d.page or d.page_num
        local w, h = d.width, d.height
        if type(pn) == "number" and w and h and w > 0 and h > 0 then
            self._dims_cache[pn] = Geom:new{ w = w, h = h }
            count = count + 1
        end
    end
    if count > 0 then
        local sample = list[1]
        if sample then
            local pn = sample.pageNumber or sample.page or sample.page_num
        end
    end
end

function VirtualImageDocument:ensureDims(pageno)
    if pageno < 1 or pageno > self._pages then return end
    self._dims_cache = self._dims_cache or {}
    local cached = self._dims_cache[pageno]
    if cached and isPositiveDimension(cached.w, cached.h) then
        return
    end

    local raw_data, err_kind = self:_getRawImageData(pageno)
    local w, h = 800, 1200
    if raw_data then
        w, h = self:_determineNativeDims(raw_data, {
            silent_doc_fail = true,
            pageno = pageno,
        })
    elseif err_kind == "supplier_error" then
    end

    self._dims_cache[pageno] = Geom:new{ w = w, h = h }
end

function VirtualImageDocument:getUsedBBox(pageno)
    -- Full image rect as bbox (no content detection needed)
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
    self.virtual_layout = {}
    local current_y = 0
    local gap_between_images = 20  -- pixels between images

    for i = 1, self._pages do
        local native_dims = self:getNativePageDimensions(i)
        if native_dims.w == 0 or native_dims.h == 0 then
            logger.warn("Page", i, "has zero dimensions, using fallback")
            native_dims = Geom:new{ w = 800, h = 1200 }  -- Fallback dimensions
        end

        self.virtual_layout[i] = {
            y_offset = current_y,
            width = native_dims.w,
            height = native_dims.h,
            page_num = i
        }
        current_y = current_y + native_dims.h + gap_between_images
    end

    self.total_virtual_height = math.max(0, current_y - gap_between_images)
end

function VirtualImageDocument:getVirtualHeight(zoom)
    if not self.total_virtual_height then
        self:_calculateVirtualLayout()
    end
    return (self.total_virtual_height or 0) * (zoom or 1.0)
end

function VirtualImageDocument:getVisiblePagesAtOffset(offset_y, viewport_height, zoom)
    local visible_pages = {}
    local scaled_zoom = zoom or 1.0

    for i, layout in ipairs(self.virtual_layout) do
        local page_top = layout.y_offset * scaled_zoom
        local page_bottom = page_top + (layout.height * scaled_zoom)

        -- Check if page overlaps with viewport
        if page_bottom >= offset_y and page_top <= offset_y + viewport_height then
            table.insert(visible_pages, {
                page_num = i,
                page_top = page_top,
                page_bottom = page_bottom,
                visible_top = math.max(page_top, offset_y),
                visible_bottom = math.min(page_bottom, offset_y + viewport_height),
                layout = layout
            })
        end
    end

    return visible_pages
end

-- Transform native rect by zoom/rotation (inherit from Document)
function VirtualImageDocument:transformRect(native_rect, zoom, rotation)
    return Document.transformRect(self, native_rect, zoom, rotation)
end

function VirtualImageDocument:getPageDimensions(pageno, zoom, rotation)
    local native_rect = self:getNativePageDimensions(pageno)
    return self:transformRect(native_rect, zoom, rotation)
end

function VirtualImageDocument:getToc()
    -- No TOC for images
    return {}
end

function VirtualImageDocument:getPageLinks(pageno)
    local raw_data = self:_getRawImageData(pageno)
    if not raw_data then
        return {}
    end

    local magic = detectImageMagic(raw_data)
    if not magic then return {} end

    local doc = self:_openImageDoc(raw_data, magic, { silent = true, pageno = pageno })
    if not doc then
        return {}
    end

    doc:setColorRendering(self.render_color)
    local page = doc:openPage(1)
    local links = page:getPageLinks()
    page:close()
    doc:close()
    return links
end

function VirtualImageDocument:renderPage(pageno, rect, zoom, rotation, gamma)
    -- Validate page
    if pageno < 1 or pageno > self._pages then
        logger.warn("Invalid pageno:", pageno)
        return nil
    end

    -- Hash for cache (full or partial)
    local hash
    if rect then
        hash = self:getPagePartHash(pageno, zoom, rotation, gamma, rect)
    else
        hash = self:getFullPageHash(pageno, zoom, rotation, gamma)
    end

    -- Check cache first
    local tile = DocCache:check(hash, TileCacheItem)
    if tile then
        if self.tile_cache_validity_ts and tile.created_ts < self.tile_cache_validity_ts then
        else
            -- Derive native dims from cached full-page tile so viewers can refit correctly on first display.
            if not rect and zoom and zoom > 0 and tile.bb then
                local dw = tile.bb:getWidth()
                local dh = tile.bb:getHeight()
                if dw and dh and dw > 0 and dh > 0 then
                    local w = dw / zoom
                    local h = dh / zoom
                    local rot = rotation or 0
                    if rot == 90 or rot == 270 then
                        w, h = h, w
                    end
                    self._dims_cache = self._dims_cache or {}
                    local cached = self._dims_cache[pageno]
                    local function diff(a, b) return math.abs((a or 0) - (b or 0)) end
                    if not cached or diff(cached.w, w) > 0.5 or diff(cached.h, h) > 0.5 then
                        self._dims_cache[pageno] = Geom:new{ w = w, h = h }
                    end
                end
            end
            return tile
        end
    end

    -- Resolve raw data from supplier (single touch per render)
    local raw_data, err_kind, err_detail = self:_getRawImageData(pageno)
    if not raw_data then
        if err_kind == "supplier_error" then
            logger.warn("Supplier failed for page", pageno, ":", err_detail)
        else
            logger.warn("Invalid image data for page", pageno, "- creating placeholder")
        end
        local placeholder_w, placeholder_h = 800, 1200
        local placeholder = TileCacheItem:new{
            persistent = not rect,
            doc_path = self.file,
            created_ts = os.time(),
            excerpt = Geom:new{ w = placeholder_w, h = placeholder_h },
            pageno = pageno,
            bb = Blitbuffer.new(placeholder_w, placeholder_h, self.render_color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8),
        }
        placeholder.bb:fill(Blitbuffer.COLOR_LIGHT_GRAY)
        placeholder.size = tonumber(placeholder.bb.stride) * placeholder.bb.h + 512
        return placeholder
    end

    -- Determine native dimensions (re-uses MuPDF doc when available)
    local w, h, magic, doc, w_hdr, h_hdr, dims_source = self:_determineNativeDims(raw_data, {
        open_doc = true,
        keep_doc = true,
        pageno = pageno,
    })

    if doc and isPositiveDimension(w_hdr, h_hdr) and (w ~= w_hdr or h ~= h_hdr) then
    end
    if not isPositiveDimension(w, h) then
        w, h = 800, 1200
    end
    local native_dims = Geom:new{ w = w, h = h }
    self._dims_cache = self._dims_cache or {}
    self._dims_cache[pageno] = native_dims

    -- Compute render size & offsets (mirror core Document semantics) without fetching
    local page_size = self:transformRect(native_dims, zoom, rotation)
    if page_size.w == 0 or page_size.h == 0 then
        logger.warn("Zero page size for", pageno, "- cannot render")
        if doc then doc:close() end
        return nil
    end

    local size = page_size
    local offset_x, offset_y = 0, 0
    if rect then
        if rect.scaled_rect then
            size = rect.scaled_rect
        else
            local r = Geom:new(rect)
            r:transformByScale(zoom)
            size = r
        end
        -- Convert rect offsets to device-space and shift negatively so the viewport fills the tile.
        local sx, sy
        if rect.scaled_rect then
            sx = rect.scaled_rect.x or 0
            sy = rect.scaled_rect.y or 0
        else
            sx = math.floor((rect.x or 0) * zoom + 0.5)
            sy = math.floor((rect.y or 0) * zoom + 0.5)
        end
        offset_x = -sx
        offset_y = -sy
    end

    -- Create BB and TileCacheItem
    tile = TileCacheItem:new{
        persistent = not rect,  -- Don't persist excerpts
        doc_path = self.file,
        created_ts = os.time(),
        excerpt = size,
        pageno = pageno,
        bb = Blitbuffer.new(size.w, size.h, self.render_color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8),
    }
    tile.size = tonumber(tile.bb.stride) * tile.bb.h + 512
    local approx_bpp = tonumber(tile.bb.stride) / tile.bb:getWidth()

    -- Try MuPDF mini-doc rendering
    local rendered_bb = nil
    local doc_for_render = doc
    if not doc_for_render and magic then
        doc_for_render = self:_openImageDoc(raw_data, magic, { pageno = pageno })
        if doc_for_render then
            doc_for_render:setColorRendering(self.render_color)
        end
    end
    if doc_for_render then
        local page = doc_for_render:openPage(1)

        -- Setup DC
        local dc = DrawContext.new()
        dc:setRotate(rotation)
        if rotation == 90 then
            dc:setOffset(page_size.w, 0)
        elseif rotation == 180 then
            dc:setOffset(page_size.w, page_size.h)
        elseif rotation == 270 then
            dc:setOffset(0, page_size.h)
        end
        dc:setZoom(zoom)
        if gamma ~= self.GAMMA_NO_GAMMA then
            dc:setGamma(gamma)
        end

        -- Draw directly into the destination tile
        page:draw(dc, tile.bb, offset_x, offset_y, self.render_mode or 0)
        page:close()
        rendered_bb = tile.bb
        doc_for_render:close()
    else
        logger.warn("Failed to render page", pageno, "- using placeholder")
        tile.bb:fill(Blitbuffer.COLOR_LIGHT_GRAY)
    end

    -- Cache only if we actually rendered real content (not a placeholder)
    if rendered_bb then
        DocCache:insert(hash, tile)
    end

    return tile
end

function VirtualImageDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, gamma)
    local tile = self:renderPage(pageno, rect, zoom, rotation, gamma)
    if tile and tile.bb then
        -- The tile.bb already contains the rendered content for the specified rect and zoom.
        -- We blit it directly to the target at the given screen coordinates (x, y).
        -- The source rectangle for blitFrom should be the full extent of tile.bb.
        target:blitFrom(tile.bb,
            x, y,
            0, 0, -- Source x, y (start from top-left of tile.bb)
            tile.bb:getWidth(), tile.bb:getHeight())
        return true
    end
    return false
end

-- Register with DocumentRegistry (add to end of file or in init)
function VirtualImageDocument:register(registry)
    -- Virtual docs aren't file-based; no extension/mimetype
    -- Call manually in viewer: VirtualImageDocument:new{ images_list = ... }
end

function VirtualImageDocument:prefetchPage(pageno, zoom, rotation, gamma)
    -- Full-page render; persistent flag is set by renderPage when rect == nil.
    return self:renderPage(pageno, nil, zoom, rotation, gamma)
end

return VirtualImageDocument
