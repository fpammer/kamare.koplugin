-- VirtualPageCanvas: owns all projection / viewing state.
--
-- Ownership contract:
--   * The canvas stores viewport size, margins, gaps, zoom,
--     zoom_mode, view_mode, current_page, scroll_offset, center ratios,
--     render_quality, and the canvas-local _layout_dirty flag.
--   * Layout queries delegate to the document's pure projection methods
--     (getVirtualHeight etc.) with the canvas's current viewing state.
--   * Render dims are computed here via _renderDimsFor(native_w, native_h)
--     from render_quality + screen size; passed to drawPageTiled /
--     _preSplitPageTiles as parameters.
--
-- Rotation: NOT tracked by the canvas. Visual rotation is delegated entirely
-- to KOReader's screen-level framebuffer (`Screen:setRotationMode`). When
-- the screen rotates, `Screen:getWidth/Height` swap, the viewer's
-- `handleRotation` re-sizes the canvas, and the canvas re-fits to the new
-- viewport. The plugin never rotates page pixels.
--
-- Coordinate-space naming convention (see virtualimagedocument.lua for the
-- full table): `native_*`, `render_*`, `scaled_*`, `canvas_*`.
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local Math = require("optmath")
local time = require("ui/time")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Device = require("device")
local Screen = Device.screen

local VirtualPageCanvas = Widget:extend{
    document = nil,

    view_mode = 0, -- 0: "page" | 1: "scroll" | 2: "dual"
    current_page = 1,

    zoom_mode = 0, -- 0: "full" | 1: "width" | 2: "height"
    zoom = 1.0,

    -- Render-quality (prescale factor for image decoding). Owned by the
    -- canvas because it depends on screen DPI/size, which are projection
    -- concerns. -1 means "decode at native resolution".
    render_quality = -1,

    center_x_ratio = 0.5,
    center_y_ratio = 0.5,

    scroll_offset = 0,

    h_margin = 0,
    top_margin = 0,
    bottom_margin = 0,
    background = Blitbuffer.COLOR_WHITE,
    page_gap_height = 8,

    page_direction = 0, -- 0: LTR, 1: RTL
    dual_page_gap = 5,

    _layout_dirty = true,

    -- Callback (set by the viewer) invoked when a page is painted as "pending"
    -- (image not arrived yet): function(page_num). The viewer uses it to kick
    -- off an async fetch and repaint on arrival.
    on_pending_page = nil,
}

function VirtualPageCanvas:init()
    if Widget.init then
        Widget.init(self)
    end
    self.dimen = Geom:new(self.dimen)
end

function VirtualPageCanvas:setDocument(doc)
    if self.document ~= doc then
        self.document = doc
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setViewMode(mode)
    mode = tonumber(mode) or 0

    if mode < 0 or mode > 2 then
        logger.warn("VPC:setViewMode invalid mode:", mode)
        return
    end

    if self.view_mode ~= mode then
        self.view_mode = mode
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setPageDirection(direction)
    direction = tonumber(direction) or 0

    if direction ~= 0 and direction ~= 1 then
        logger.warn("VPC:setPageDirection invalid direction:", direction)
        return
    end

    if self.page_direction ~= direction then
        self.page_direction = direction
        if self.view_mode == 2 then
            self:markDirty()
        end
    end
end

function VirtualPageCanvas:setPage(page)
    local new_page = tonumber(page) or self.current_page
    if new_page ~= self.current_page then
        self.current_page = new_page
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setZoom(zoom)
    zoom = tonumber(zoom) or self.zoom
    if zoom <= 0 then zoom = 1.0 end
    if math.abs(zoom - self.zoom) > 1e-6 then
        self.zoom = zoom
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setZoomMode(mode)
    local new_mode = tonumber(mode)
    if new_mode ~= 0 and new_mode ~= 1 and new_mode ~= 2 then
        logger.warn("VPC:setZoomMode invalid mode:", mode)
        return
    end
    if self.zoom_mode ~= new_mode then
        self.zoom_mode = new_mode
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setRenderQuality(quality)
    quality = tonumber(quality) or -1
    if self.render_quality ~= quality then
        self.render_quality = quality
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setCenter(x_ratio, y_ratio)
    x_ratio = Math.clamp(tonumber(x_ratio) or self.center_x_ratio, 0, 1)
    y_ratio = Math.clamp(tonumber(y_ratio) or self.center_y_ratio, 0, 1)

    if math.abs(self.center_x_ratio - x_ratio) > 1e-6
        or math.abs(self.center_y_ratio - y_ratio) > 1e-6 then
        self.center_x_ratio = x_ratio
        self.center_y_ratio = y_ratio

        if self.view_mode ~= 1 then
            self:markDirty()
        end
    end
end

function VirtualPageCanvas:setScrollOffset(offset)
    local requested = tonumber(offset)

    if requested == nil then
        requested = self.scroll_offset or 0
    end

    requested = math.max(0, requested)

    local max_offset = self:getMaxScrollOffset()
    local clamped = requested

    if max_offset >= 0 then
        clamped = Math.clamp(requested, 0, max_offset)
    end

    local prev = self.scroll_offset or 0

    if math.abs(clamped - prev) > 0.5 then
        self.scroll_offset = clamped
        if self.view_mode == 1 then
            self:markDirty()
        end
    end
end

function VirtualPageCanvas:setHMargin(margin)
    margin = math.max(0, tonumber(margin) or 0)

    if margin ~= self.h_margin then
        self.h_margin = margin
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setTopMargin(margin)
    margin = math.max(0, tonumber(margin) or 0)

    if margin ~= self.top_margin then
        self.top_margin = margin
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setBottomMargin(margin)
    margin = math.max(0, tonumber(margin) or 0)

    if margin ~= self.bottom_margin then
        self.bottom_margin = margin
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setDualPageGap(gap)
    gap = math.max(0, tonumber(gap) or 0)

    if math.abs(gap - self.dual_page_gap) > 0.5 then
        self.dual_page_gap = gap
        if self.view_mode == 2 then
            self:markDirty()
        end
    end
end

function VirtualPageCanvas:setBackground(color)
    if self.background ~= color then
        self.background = color
        self:markDirty()
    end
end

function VirtualPageCanvas:setPageGapHeight(gap)
    gap = math.max(0, tonumber(gap) or 0)

    if math.abs(gap - self.page_gap_height) > 0.5 then
        self.page_gap_height = gap
        if self.view_mode == 1 then
            self._layout_dirty = true
            self:markDirty()
        end
    end
end

function VirtualPageCanvas:setSize(w, h)
    if type(w) == "table" then
        h = w.h
        w = w.w
    end
    w = tonumber(w) or 0
    h = tonumber(h) or 0

    if not self.dimen then
        self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
        self._layout_dirty = true
        self:markDirty()
        return
    end

    if self.dimen.w ~= w or self.dimen.h ~= h then
        self.dimen.w = w
        self.dimen.h = h
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:getViewportSize()
    local w = math.floor(math.max(0, self.dimen.w - 2 * self.h_margin))
    local h = math.floor(math.max(0, self.dimen.h - self.top_margin - self.bottom_margin))

    return w, h
end

function VirtualPageCanvas:getVirtualHeight()
    if self.view_mode ~= 1 or not (self.document and self.document.is_open) then
        return 0
    end
    if self._layout_dirty then
        self:recalculateLayout()
    end
    local viewport_w = select(1, self:getViewportSize())
    return self.document:getVirtualHeight(self.zoom, self.zoom_mode, viewport_w, self.page_gap_height)
end

function VirtualPageCanvas:getMaxScrollOffset()
    if self.view_mode ~= 1 then
        return 0
    end

    local total_h = self:getVirtualHeight()
    local _, viewport_h = self:getViewportSize()

    if viewport_h <= 0 then
        return 0
    end

    return math.max(0, total_h - viewport_h)
end

function VirtualPageCanvas:_computeZoomForPage(page)
    if not (self.document and self.document.is_open) then
        return self.zoom
    end

    local viewport_w, viewport_h = self:getViewportSize()
    if viewport_w <= 0 or viewport_h <= 0 then
        return self.zoom
    end

    local dims = self.document:getNativePageDimensions(page)
    if not dims or dims.w <= 0 or dims.h <= 0 then
        return self.zoom
    end

    local page_w = dims.w
    local page_h = dims.h

    if page_w <= 0 or page_h <= 0 then
        return self.zoom
    end

    local zoom_w = viewport_w / page_w
    local zoom_h = viewport_h / page_h

    local result
    if self.zoom_mode == 1 then -- width
        result = zoom_w
    elseif self.zoom_mode == 2 then -- height
        result = zoom_h
    else
        result = math.min(zoom_w, zoom_h)
    end

    -- Quantize zoom to integer pixels using the native page dimensions.
    if self.zoom_mode == 1 then -- width
        local scaled_w = math.floor(page_w * result + 0.5)
        result = scaled_w / page_w
    elseif self.zoom_mode == 2 then -- height
        local scaled_h = math.floor(page_h * result + 0.5)
        result = scaled_h / page_h
    else
        if zoom_w <= zoom_h then
            local scaled_w = math.floor(page_w * result + 0.5)
            result = scaled_w / page_w
        else
            local scaled_h = math.floor(page_h * result + 0.5)
            result = scaled_h / page_h
        end
    end

    return result
end

function VirtualPageCanvas:_maxNativePageWidth()
    if not (self.document and self.document.is_open and self.document._dims_cache) then
        return 0
    end
    local max_w = 0
    for i = 1, self.document:getPageCount() do
        local dims = self.document._dims_cache[i]
        if dims and dims.w and dims.w > 0 then
            if dims.w > max_w then max_w = dims.w end
        end
    end
    return max_w
end

-- Compute render-space dimensions for a page from its native dimensions
-- and the canvas's render_quality setting. Pure function; no cache.
-- Returns (render_w, render_h) in render pixels.
function VirtualPageCanvas:_renderDimsFor(native_w, native_h)
    local render_w, render_h = native_w, native_h
    if self.render_quality ~= -1 then
        local screen_size = Screen:getSize()
        -- Always use portrait width (smaller dimension) for consistent
        -- prescale across orientations.
        local portrait_w = math.min(screen_size.w, screen_size.h)
        local cap_w = math.floor(portrait_w * self.render_quality)
        if native_w > cap_w then
            local scale = cap_w / native_w
            render_w = math.floor(native_w * scale)
            render_h = math.floor(native_h * scale)
        end
    end
    return render_w, render_h
end

function VirtualPageCanvas:_ensureZoom()
    if self.view_mode == 1 and self.zoom_mode == 1 then
        -- Scroll + fit-width: each page zooms to fit viewport_w; the canvas
        -- zoom represents the widest page (used only for clamping/offset math).
        local viewport_w = select(1, self:getViewportSize())
        if viewport_w > 0 and self.document and self.document.is_open then
            local target_width = self:_maxNativePageWidth()
            if target_width > 0 then
                local computed = viewport_w / target_width
                local scaled_w = math.floor(target_width * computed + 0.5)
                computed = scaled_w / target_width
                if computed > 0 and math.abs(computed - self.zoom) > 1e-6 then
                    self.zoom = computed
                    self._layout_dirty = true
                end
                return
            end
        end
    end

    local page = self.current_page or 1
    local computed = self:_computeZoomForPage(page)
    if computed and computed > 0 and math.abs(computed - self.zoom) > 1e-6 then
        self.zoom = computed
        self._layout_dirty = true
    end

    -- In scroll mode, always cap page width by the indented viewport so that
    -- `h_margin` produces a visible indent regardless of zoom_mode.
    -- Without this cap, fit-height / fit-page modes can pick a zoom that
    -- leaves the page wider than the viewport, causing the centering math at
    -- paintScroll to algebraically cancel out the margin.
    if self.view_mode == 1 then
        local viewport_w = select(1, self:getViewportSize())
        local max_w = self:_maxNativePageWidth()
        if viewport_w > 0 and max_w > 0 then
            local cap = viewport_w / max_w
            if self.zoom > cap + 1e-9 then
                self.zoom = cap
                self._layout_dirty = true
            end
        end
    end
end

function VirtualPageCanvas:recalculateLayout()
    self:_ensureZoom()
    self._layout_dirty = false
    if not (self.document and self.document.is_open) then return end
    self.scroll_offset = Math.clamp(self.scroll_offset or 0, 0, self:getMaxScrollOffset())
end

function VirtualPageCanvas:markDirty()
    if self.dimen and self.dimen.w > 0 and self.dimen.h > 0 then
        UIManager:setDirty(self, "partial", self.dimen)
    end
end

function VirtualPageCanvas:paintTo(target, x, y)
    local ok, err = pcall(self._paintToImpl, self, target, x, y)
    if not ok then
        logger.warn("VPC:paintTo failed:", err)
    end
end

function VirtualPageCanvas:_paintToImpl(target, x, y)
    if not self.dimen then return end
    local canvas_w = self.dimen.w
    local canvas_h = self.dimen.h
    if canvas_w <= 0 or canvas_h <= 0 then return end

    self.dimen.x = x
    self.dimen.y = y

    target:paintRect(x, y, canvas_w, canvas_h, self.background)

    if not (self.document and self.document.is_open) then
        return
    end

    if self.view_mode == 2 then
        self:paintDualPage(target, x, y)
    elseif self.view_mode == 1 then
        self:paintScroll(target, x, y)
    else
        self:paintSinglePage(target, x, y)
    end
end


-- Glyph shown centered over a page region whose image hasn't arrived yet.
local PLACEHOLDER_GLYPH = "⏳"

-- Used by the render path when drawPageTiled reports a page as "pending".
function VirtualPageCanvas:_paintPlaceholder(target, rx, ry, rw, rh)
    if rw <= 0 or rh <= 0 then return end
    if not self._placeholder_widget then
        self._placeholder_widget = TextWidget:new{
            text = PLACEHOLDER_GLYPH,
            face = Font:getFace("ffont", 22),
        }
    end
    local w = self._placeholder_widget
    local size = w:getSize()
    local px = rx + math.max(0, math.floor((rw - size.w) / 2))
    local py = ry + math.max(0, math.floor((rh - size.h) / 2))
    pcall(function() w:paintTo(target, px, py) end)
end

function VirtualPageCanvas:paintSinglePage(target, x, y)
    if not self.document then
        return
    end
    self:_ensureZoom()
    local page = Math.clamp(self.current_page or 1, 1, self.document:getPageCount())
    local viewport_w, viewport_h = self:getViewportSize()
    if viewport_w <= 0 or viewport_h <= 0 then
        return
    end

    local native_dims = self.document:getNativePageDimensions(page)
    if not native_dims or native_dims.w <= 0 or native_dims.h <= 0 then
        return
    end

    local zoom = self.zoom
    if zoom <= 0 then zoom = 1.0 end
    local scaled_w = native_dims.w * zoom
    local scaled_h = native_dims.h * zoom
    if scaled_w <= 0 or scaled_h <= 0 then
        return
    end

    local view_w = math.min(viewport_w, scaled_w)
    local view_h = math.min(viewport_h, scaled_h)

    local cx = (self.view_mode == 0 and self.zoom_mode == 0) and 0.5 or Math.clamp(self.center_x_ratio, 0, 1)
    local cy = (self.view_mode == 0 and self.zoom_mode == 0) and 0.5 or Math.clamp(self.center_y_ratio, 0, 1)
    local center_px = cx * scaled_w
    local center_py = cy * scaled_h

    local src_x = Math.clamp(math.floor(center_px - view_w / 2), 0, math.max(0, scaled_w - view_w))
    local src_y = Math.clamp(math.floor(center_py - view_h / 2), 0, math.max(0, scaled_h - view_h))

    local rect = Geom:new{
        x = src_x / zoom,
        y = src_y / zoom,
        w = view_w / zoom,
        h = view_h / zoom,
    }

    local dest_x = x + self.h_margin + math.floor((viewport_w - view_w) / 2)
    local dest_y = y + self.top_margin + math.floor((viewport_h - view_h) / 2)

    local render_w, render_h = self:_renderDimsFor(native_dims.w, native_dims.h)
    local ok_draw, r = pcall(function()
        return self.document:drawPageTiled(target, dest_x, dest_y, rect, page, zoom,
                                           nil, 0, true, render_w, render_h, self.render_quality)
    end)
    if not ok_draw then
        logger.warn("VPC:paintSinglePage tiled render failed")
    elseif r == "pending" then
        self:_paintPlaceholder(target, dest_x, dest_y, view_w, view_h)
        if self.on_pending_page then self.on_pending_page(page) end
    end
end

function VirtualPageCanvas:getDualPagePair(current_page)
    if not self.document or not self.document._dual_page_pairs then
        return current_page, 0
    end

    -- O(1) reverse-index lookup (built alongside _dual_page_pairs).
    local idx = self.document._dual_page_pair_index
                                and self.document._dual_page_pair_index[current_page]
    if idx == nil then
        return current_page, 0
    end

    local pair = self.document._dual_page_pairs[idx]
    local page1, page2 = pair[1], pair[2]

    if page1 == page2 and page1 > 0 then
        return current_page, -1  -- Signal solo landscape display
    end

    -- Apply RTL flipping for display
    -- page_direction: 0 = LTR, 1 = RTL
    local left_page, right_page
    if self.page_direction == 1 then
        -- RTL: swap pages (right page comes first in reading order)
        left_page, right_page = page2, page1
    else
        -- LTR: keep physical order
        left_page, right_page = page1, page2
    end

    return left_page, right_page
end

function VirtualPageCanvas:_computeZoomForDualPage(left_page, right_page, page_width, vp_h)
    if not self.document then return 1.0 end

    local left_dims, right_dims

    if left_page > 0 then
        left_dims = self.document:getNativePageDimensions(left_page)
    end

    if right_page > 0 then
        right_dims = self.document:getNativePageDimensions(right_page)
    end

    if not left_dims and not right_dims then return 1.0 end

    if not left_dims then left_dims = right_dims end
    if not right_dims then right_dims = left_dims end
    local zoom_left_w = page_width / left_dims.w
    local zoom_left_h = vp_h / left_dims.h
    local zoom_left = math.min(zoom_left_w, zoom_left_h)

    local zoom_right_w = page_width / right_dims.w
    local zoom_right_h = vp_h / right_dims.h
    local zoom_right = math.min(zoom_right_w, zoom_right_h)

    local zoom = math.min(zoom_left, zoom_right)

    zoom = math.max(0.01, zoom)
    return zoom
end

function VirtualPageCanvas:_getDualPageRect(page, zoom, side, page_width, vp_h, gap_offset)
    if not self.document then return nil end

    if page == 0 then return nil end

    gap_offset = gap_offset or 0

    local dims = self.document:getNativePageDimensions(page)
    if not dims then return nil end

    local zoomed_w = dims.w * zoom
    local zoomed_h = dims.h * zoom

    local x_offset = self.h_margin
    if side == "right" then
        x_offset = x_offset + page_width + gap_offset
    end

    x_offset = x_offset + (page_width - zoomed_w) / 2
    local y_offset = self.top_margin + (vp_h - zoomed_h) / 2

    return {
        x = x_offset,
        y = y_offset,
        w = zoomed_w,
        h = zoomed_h
    }
end

function VirtualPageCanvas:paintDualPage(target, x, y)
    if not self.document then
        return
    end

    local page_count = self.document:getPageCount()
    local page = Math.clamp(self.current_page or 1, 1, page_count)
    local viewport_w, viewport_h = self:getViewportSize()
    if viewport_w <= 0 or viewport_h <= 0 then
        return
    end

    local gap = self.dual_page_gap
    local page_width = math.floor((viewport_w - gap) / 2)

    local left_page, right_page = self:getDualPagePair(page)

    if right_page == -1 then
        self:paintSinglePage(target, x, y)
        return
    end

    local zoom = self:_computeZoomForDualPage(left_page, right_page, page_width, viewport_h)
    if zoom <= 0 then zoom = 1.0 end

    if left_page > 0 and left_page <= page_count then
        local left_rect_info = self:_getDualPageRect(left_page, zoom, "left", page_width, viewport_h)
        if left_rect_info then
            local native_dims = self.document:getNativePageDimensions(left_page)
            if native_dims then
                local rect = Geom:new{
                    x = 0,
                    y = 0,
                    w = native_dims.w,
                    h = native_dims.h,
                }

                local dest_x = x + math.floor(left_rect_info.x)
                local dest_y = y + math.floor(left_rect_info.y)

                local render_w, render_h = self:_renderDimsFor(native_dims.w, native_dims.h)
                local ok_draw, r = pcall(function()
                    return self.document:drawPageTiled(target, dest_x, dest_y, rect, left_page, zoom,
                                                       nil, 0, true, render_w, render_h, self.render_quality)
                end)
                if not ok_draw then
                    logger.warn("VPC:paintDualPage left page tiled render failed")
                elseif r == "pending" then
                    self:_paintPlaceholder(target, dest_x, dest_y, left_rect_info.w, left_rect_info.h)
                    if self.on_pending_page then self.on_pending_page(left_page) end
                end
            end
        end
    end

    if right_page > 0 and right_page <= page_count then
        local right_rect_info = self:_getDualPageRect(right_page, zoom, "right", page_width, viewport_h, gap)
        if right_rect_info then
            local native_dims = self.document:getNativePageDimensions(right_page)
            if native_dims then
                local rect = Geom:new{
                    x = 0,
                    y = 0,
                    w = native_dims.w,
                    h = native_dims.h,
                }

                local dest_x = x + math.floor(right_rect_info.x)
                local dest_y = y + math.floor(right_rect_info.y)

                local render_w, render_h = self:_renderDimsFor(native_dims.w, native_dims.h)
                local ok_draw, r = pcall(function()
                    return self.document:drawPageTiled(target, dest_x, dest_y, rect, right_page, zoom,
                                                       nil, 0, true, render_w, render_h, self.render_quality)
                end)
                if not ok_draw then
                    logger.warn("VPC:paintDualPage right page tiled render failed")
                elseif r == "pending" then
                    self:_paintPlaceholder(target, dest_x, dest_y, right_rect_info.w, right_rect_info.h)
                    if self.on_pending_page then self.on_pending_page(right_page) end
                end
            end
        end
    end
end

function VirtualPageCanvas:_prepareLayout()
    if self._layout_dirty then
        self:recalculateLayout()
    end
end

function VirtualPageCanvas:paintScroll(target, x, y)
    local t0 = time.now()

    self:_ensureZoom()
    self:_prepareLayout()

    local viewport_w, viewport_h = self:getViewportSize()
    if viewport_w <= 0 or viewport_h <= 0 then
        return
    end

    local scroll_offset = Math.clamp(self.scroll_offset or 0, 0, self:getMaxScrollOffset())
    local zoom = self.zoom

    local visible_pages = {}
    local ok, err = pcall(function()
        visible_pages = self.document:getVisiblePagesAtOffset(scroll_offset, viewport_h, zoom, self.zoom_mode, viewport_w, self.page_gap_height)
    end)
    if not ok then
        logger.warn("VPC:paintScroll getVisiblePagesAtOffset failed:", err)
        return
    end
    if not visible_pages or #visible_pages == 0 then
        logger.warn("VPC:paintScroll no visible pages", "scroll_offset", scroll_offset, "viewport_h", viewport_h, "zoom", zoom)
        return
    end

    local page_nums = {}
    for _, p in ipairs(visible_pages) do
        table.insert(page_nums, p.page_num)
    end
    logger.dbg(string.format("[kamare:scroll] paint offset=%d vp=%dx%d zoom=%.3f pages=[%s]",
        scroll_offset, viewport_w, viewport_h, zoom, table.concat(page_nums, ",")))

    local stacked_y = self.top_margin
    local bottom_limit = self.dimen.h - self.bottom_margin

    local gap_px = math.floor(self.page_gap_height)
    local prev_page
    for _, page_info in ipairs(visible_pages) do
        if prev_page and page_info.page_num ~= prev_page and gap_px > 0 then
            local remain_gap = bottom_limit - stacked_y
            if remain_gap <= 0 then break end
            local draw_gap = math.min(gap_px, remain_gap)
            stacked_y = stacked_y + draw_gap
        end

        local remain = bottom_limit - stacked_y
        if remain <= 0 then break end
        local visible_h = page_info.visible_bottom - page_info.visible_top
        local slice_h_px = math.min(math.floor(visible_h), remain)
        if slice_h_px <= 0 then
            prev_page = page_info.page_num
        else
            local top_px = math.floor(page_info.visible_top - page_info.page_top)

            local layout = page_info.layout
            local page_zoom = page_info.zoom or zoom

            local scaled_w = math.floor(layout.native_width * page_zoom)

            local horizontal_spacing = self.h_margin
            local dest_x = x + horizontal_spacing + math.floor((viewport_w - scaled_w) / 2)
            local dest_y = y + stacked_y

            local native_y = math.floor(top_px / page_zoom)
            local native_h = math.floor(slice_h_px / page_zoom)

            local native_dims_w = layout.native_width
            local native_dims_h = layout.native_height
            local render_w, render_h = self:_renderDimsFor(native_dims_w, native_dims_h)
            -- Slice height in scaled space (must match getVisiblePagesAtOffset's
            -- scaled-space accounting to avoid rounding drift).
            local actual_slice_h_px = math.floor(native_h * page_zoom)

            local rect = Geom:new{
                x = 0,
                y = native_y,
                w = native_dims_w,
                h = native_h,
            }

            local ok_draw, r = pcall(function()
                return self.document:drawPageTiled(target, dest_x, dest_y, rect, page_info.page_num, page_zoom,
                                                    nil, 1, false,
                                                    render_w, render_h, self.render_quality)
            end)
            if not ok_draw then
                logger.warn("VPC:paintScroll tiled slice render failed", "page", page_info.page_num)
            elseif r == "pending" then
                self:_paintPlaceholder(target, dest_x, dest_y, scaled_w, actual_slice_h_px)
                if self.on_pending_page then self.on_pending_page(page_info.page_num) end
            end

            stacked_y = stacked_y + actual_slice_h_px
            prev_page = page_info.page_num
        end
    end

    logger.dbg(string.format("[kamare:scroll] paint done %dms", time.to_ms(time.now() - t0)))
end

function VirtualPageCanvas:onCloseWidget()
    self.document = nil
end

return VirtualPageCanvas
