local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local Math = require("optmath")

local VirtualPageCanvas = Widget:extend{
    document = nil,

    mode = "page", -- "page" | "scroll"
    current_page = 1,

    zoom_mode = 0, -- 0: "full" | 1: "width" | 2: "height"
    zoom = 1.0,
    rotation = 0,

    center_x_ratio = 0.5,
    center_y_ratio = 0.5,

    scroll_offset = 0,

    padding = 0,
    background = Blitbuffer.COLOR_WHITE,


    _virtual_height = 0,
    _layout_dirty = true,
}

function VirtualPageCanvas:init()
    if Widget.init then
        Widget.init(self)
    end
    self.dimen = Geom:new(self.dimen)
    logger.info("VPC:init", "initial_dimen", self.dimen and self.dimen.w, self.dimen and self.dimen.h)
end

function VirtualPageCanvas:setDocument(doc)
    if self.document ~= doc then
        logger.info("VPC:setDocument", "old", self.document ~= nil, "new", doc ~= nil)
        self.document = doc
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setMode(mode)
    if mode ~= "page" and mode ~= "scroll" then
        logger.warn("VPC:setMode invalid mode:", mode)
        return
    end
    if self.mode ~= mode then
        logger.info("VPC:setMode", "from", self.mode, "to", mode)
        self.mode = mode
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setPage(page)
    local new_page = tonumber(page) or self.current_page
    if new_page ~= self.current_page then
        logger.info("VPC:setPage", "from", self.current_page, "to", new_page)
        self.current_page = new_page
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setZoom(zoom)
    zoom = tonumber(zoom) or self.zoom
    if zoom <= 0 then zoom = 1.0 end
    if math.abs(zoom - self.zoom) > 1e-6 then
        logger.info("VPC:setZoom", "from", self.zoom, "to", zoom)
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
        logger.info("VPC:setZoomMode", "from", self.zoom_mode, "to", new_mode)
        self.zoom_mode = new_mode
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setRotation(rotation)
    rotation = rotation or 0
    rotation = rotation % 360
    if self.rotation ~= rotation then
        logger.info("VPC:setRotation", "from", self.rotation, "to", rotation)
        self.rotation = rotation
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setCenter(x_ratio, y_ratio)
    x_ratio = Math.clamp(tonumber(x_ratio) or self.center_x_ratio, 0, 1)
    y_ratio = Math.clamp(tonumber(y_ratio) or self.center_y_ratio, 0, 1)
    if math.abs(self.center_x_ratio - x_ratio) > 1e-6
        or math.abs(self.center_y_ratio - y_ratio) > 1e-6 then
        logger.info("VPC:setCenter", "from", self.center_x_ratio, self.center_y_ratio, "to", x_ratio, y_ratio)
        self.center_x_ratio = x_ratio
        self.center_y_ratio = y_ratio
        if self.mode == "page" then
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
        logger.info("VPC:setScrollOffset", "mode", self.mode, "requested", requested, "clamped", clamped, "max", max_offset, "prev", prev)
        self.scroll_offset = clamped
        if self.mode == "scroll" then
            self:markDirty()
        end
    else
    end
end

function VirtualPageCanvas:setPadding(padding)
    padding = math.max(0, tonumber(padding) or 0)
    if padding ~= self.padding then
        logger.info("VPC:setPadding", "from", self.padding, "to", padding)
        self.padding = padding
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setBackground(color)
    if self.background ~= color then
        logger.info("VPC:setBackground", "from", self.background, "to", color)
        self.background = color
        self:markDirty()
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
        logger.info("VPC:setSize init", "w", w, "h", h)
        self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
        self._layout_dirty = true
        self:markDirty()
        return
    end

    if self.dimen.w ~= w or self.dimen.h ~= h then
        logger.info("VPC:setSize", "from", self.dimen.w, self.dimen.h, "to", w, h)
        self.dimen.w = w
        self.dimen.h = h
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:getViewportSize()
    local w = math.max(0, self.dimen.w - 2 * self.padding)
    local h = math.max(0, self.dimen.h - 2 * self.padding)
    logger.dbg("VPC:getViewportSize", "canvas_w", self.dimen.w, "canvas_h", self.dimen.h, "padding", self.padding, "viewport_w", w, "viewport_h", h)
    return w, h
end

function VirtualPageCanvas:getVirtualHeight()
    if self.mode ~= "scroll" or not self.document then
        return 0
    end
    if self._layout_dirty then
        self:recalculateLayout()
    end
    return self._virtual_height or 0
end

function VirtualPageCanvas:getMaxScrollOffset()
    if self.mode ~= "scroll" then
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
    local rotation = self.rotation or 0
    if viewport_w <= 0 or viewport_h <= 0 then
        logger.warn("ZOOM_DEBUG", "reason", "invalid_viewport", "page", page, "rotation", rotation, "viewport_w", viewport_w, "viewport_h", viewport_h, "padding", self.padding or 0, "canvas_w", self.dimen and self.dimen.w, "canvas_h", self.dimen and self.dimen.h)
        return self.zoom
    end

    local dims = self.document:getNativePageDimensions(page)
    if not dims or dims.w <= 0 or dims.h <= 0 then
        logger.warn("ZOOM_DEBUG", "reason", "invalid_native_dims", "page", page, "rotation", rotation, "native_w", dims and dims.w or 0, "native_h", dims and dims.h or 0)
        return self.zoom
    end

    local page_w = dims.w
    local page_h = dims.h
    if self.rotation % 180 ~= 0 then
        page_w, page_h = page_h, page_w
    end
    if page_w <= 0 or page_h <= 0 then
        return self.zoom
    end
    local rotated_dims
    local ok_rot, rd = pcall(function()
        return self.document:getPageDimensions(page, 1.0, rotation)
    end)
    if ok_rot then rotated_dims = rd end

    logger.warn("ZOOM_DEBUG_INPUT",
        "page", page,
        "rotation", rotation,
        "zoom_mode", self.zoom_mode,
        "viewport_w", viewport_w, "viewport_h", viewport_h,
        "native_w", dims.w, "native_h", dims.h,
        "effective_w", page_w, "effective_h", page_h,
        "rotated_doc_w", rotated_dims and rotated_dims.w or nil,
        "rotated_doc_h", rotated_dims and rotated_dims.h or nil,
        "padding", self.padding or 0)

    local zoom_w = viewport_w / page_w
    local zoom_h = viewport_h / page_h
    logger.dbg("VPC:_computeZoomForPage",
        "page", page,
        "page_w", page_w, "page_h", page_h,
        "viewport_w", viewport_w, "viewport_h", viewport_h,
        "zoom_w", zoom_w, "zoom_h", zoom_h,
        "mode", self.zoom_mode)

    local result
    if self.zoom_mode == 1 then -- width
        result = viewport_w / page_w
    elseif self.zoom_mode == 2 then -- height
        result = viewport_h / page_h
    else
        if zoom_w <= zoom_h then
            result = viewport_w / page_w
        else
            result = viewport_h / page_h
        end
    end
    logger.warn("ZOOM_DEBUG_RESULT",
        "page", page,
        "rotation", rotation,
        "zoom_mode", self.zoom_mode,
        "zoom_w", zoom_w, "zoom_h", zoom_h,
        "result", result)
    return result
end

function VirtualPageCanvas:_ensureZoom()
    local original_zoom = self.zoom
    if self.mode == "scroll" and self.zoom_mode == 1 then
        local viewport_w = select(1, self:getViewportSize())
        if viewport_w > 0 and self.document and self.document.is_open and self.document._ensureVirtualLayout then
            local entry
            local ok, result = pcall(function()
                return self.document:_ensureVirtualLayout(self.rotation or 0)
            end)
            if ok then
                entry = result
            else
                logger.warn("VPC:_ensureZoom ensure layout failed:", result)
            end
            local target_width = entry and entry.rotated_max_width
            if target_width and target_width > 0 then
                local computed = viewport_w / target_width
                if computed > 0 and math.abs(computed - (self.zoom or 0)) > 1e-6 then
                    logger.info("VPC:_ensureZoom width-based", "computed", computed, "prev", self.zoom, "target_width", target_width, "viewport_w", viewport_w)
                    self.zoom = computed
                    self._layout_dirty = true
                end
                logger.info("VPC:_ensureZoom state", "mode", self.mode, "zoom_mode", self.zoom_mode, "page", self.current_page, "zoom", self.zoom, "layout_dirty", self._layout_dirty)
                return
            end
        end
    end

    local page = self.current_page or 1
    local computed = self:_computeZoomForPage(page)
    if computed and computed > 0 and math.abs(computed - self.zoom) > 1e-6 then
        logger.info("VPC:_ensureZoom page-based", "page", page, "computed", computed, "prev", self.zoom)
        self.zoom = computed
        self._layout_dirty = true
    end
    logger.info("VPC:_ensureZoom state", "mode", self.mode, "zoom_mode", self.zoom_mode, "page", page, "zoom", self.zoom, "layout_dirty", self._layout_dirty, "original_zoom", original_zoom)
end

function VirtualPageCanvas:recalculateLayout()
    logger.info("VPC:recalculateLayout start", "layout_dirty", self._layout_dirty, "has_document", self.document ~= nil, "mode", self.mode, "scroll_offset", self.scroll_offset or 0)
    self:_ensureZoom()
    self._layout_dirty = false
    self._virtual_height = 0

    if not self.document or not self.document.is_open then
        logger.info("VPC:recalculateLayout abort", "document_open", self.document and self.document.is_open)
        return
    end

    if self.document.virtual_layout == nil or self.document.total_virtual_height == nil then
        if self.document._calculateVirtualLayout then
            logger.info("VPC:recalculateLayout invoking document _calculateVirtualLayout")
            self.document:_calculateVirtualLayout()
        end
    end

    local _, viewport_h = self:getViewportSize()
    if self.document.getVirtualHeight then
        local total = self.document:getVirtualHeight(self.zoom, self.rotation)
        if total and total > 0 then
            self._virtual_height = total
        else
            self._virtual_height = viewport_h
        end
    elseif self.document.total_virtual_height then
        self._virtual_height = (self.document.total_virtual_height or 0) * self.zoom
    else
        self._virtual_height = viewport_h
    end

    self.scroll_offset = Math.clamp(self.scroll_offset or 0, 0, self:getMaxScrollOffset())
    logger.info("VPC:recalculateLayout done", "virtual_height", self._virtual_height, "max_scroll_offset", self:getMaxScrollOffset(), "scroll_offset", self.scroll_offset, "document_layout_dirty", self.document and self.document._virtual_layout_dirty)
end

function VirtualPageCanvas:markDirty()
    if self.dimen and self.dimen.w > 0 and self.dimen.h > 0 then
        UIManager:setDirty(self, "partial", self.dimen)
    end
end

function VirtualPageCanvas:paintTo(target, x, y)
    if not self.dimen then return end
    local canvas_w = self.dimen.w
    local canvas_h = self.dimen.h
    if canvas_w <= 0 or canvas_h <= 0 then return end

    local tw = target.getWidth and target:getWidth() or nil
    local th = target.getHeight and target:getHeight() or nil
    logger.dbg("VPC:paintTo target", "tw", tw, "th", th, "canvas_w", canvas_w, "canvas_h", canvas_h, "x", x, "y", y)

    target:paintRect(x, y, canvas_w, canvas_h, self.background)

    if not (self.document and self.document.is_open) then
        return
    end

    if self.mode == "scroll" then
        self:paintScroll(target, x, y)
    else
        self:paintSinglePage(target, x, y)
    end
end

function VirtualPageCanvas:_renderFullPage(page)
    logger.dbg("VPC:_renderFullPage request", "page", page, "zoom", self.zoom, "rotation", self.rotation)
    local ok, tile = pcall(function()
        return self.document:renderPage(page, nil, self.zoom, self.rotation)
    end)
    if ok then
        if tile and tile.bb then
            logger.dbg("VPC:_renderFullPage result", "page", page, "bb_w", tile.bb:getWidth(), "bb_h", tile.bb:getHeight(), "stride", tile.bb.stride)
        end
        return tile
    end
    logger.warn("VPC:_renderFullPage failed:", tile)
    return nil
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

    local zoom = self.zoom or 1.0
    if zoom <= 0 then zoom = 1.0 end
    local rotation = self.rotation or 0
    local page_size = self.document:transformRect(native_dims, zoom, rotation)
    local scaled_w = page_size.w or 0
    local scaled_h = page_size.h or 0
    if scaled_w <= 0 or scaled_h <= 0 then
        return
    end

    logger.info("VPC:paintSinglePage", "page", page, "zoom", zoom, "rotation", rotation, "viewport", viewport_w, viewport_h, "scaled", scaled_w, scaled_h, "center", self.center_x_ratio, self.center_y_ratio)

    -- Try full page render - document handles native caching and scaling
    local tile = self:_renderFullPage(page)
    if tile and tile.bb then
        local img_w = tile.bb:getWidth()
        local img_h = tile.bb:getHeight()

        if img_w > 0 and img_h > 0 then
            -- Image fits entirely in viewport - simple center blit
            if img_w <= viewport_w and img_h <= viewport_h then
                local dest_x = x + self.padding + math.floor((viewport_w - img_w) / 2)
                local dest_y = y + self.padding + math.floor((viewport_h - img_h) / 2)
                target:blitFrom(tile.bb, dest_x, dest_y, 0, 0, img_w, img_h)
                return
            end

            -- Image bigger than viewport - blit visible portion
            local view_w = math.min(viewport_w, img_w)
            local view_h = math.min(viewport_h, img_h)

            local cx = (self.mode == "page" and self.zoom_mode == 0) and 0.5 or Math.clamp(self.center_x_ratio, 0, 1)
            local cy = (self.mode == "page" and self.zoom_mode == 0) and 0.5 or Math.clamp(self.center_y_ratio, 0, 1)

            local src_x = Math.clamp(math.floor(cx * img_w - view_w / 2 + 0.5), 0, math.max(0, img_w - view_w))
            local src_y = Math.clamp(math.floor(cy * img_h - view_h / 2 + 0.5), 0, math.max(0, img_h - view_h))

            local dest_x = x + self.padding + math.floor((viewport_w - view_w) / 2)
            local dest_y = y + self.padding + math.floor((viewport_h - view_h) / 2)

            target:blitFrom(tile.bb, dest_x, dest_y, src_x, src_y, view_w, view_h)
            return
        end
    end

    local view_w = math.min(viewport_w, scaled_w)
    local view_h = math.min(viewport_h, scaled_h)

    local cx = (self.mode == "page" and self.zoom_mode == 0) and 0.5 or Math.clamp(self.center_x_ratio, 0, 1)
    local cy = (self.mode == "page" and self.zoom_mode == 0) and 0.5 or Math.clamp(self.center_y_ratio, 0, 1)
    local center_px = cx * scaled_w
    local center_py = cy * scaled_h

    local src_x = Math.clamp(math.floor(center_px - view_w / 2 + 0.5), 0, math.max(0, scaled_w - view_w))
    local src_y = Math.clamp(math.floor(center_py - view_h / 2 + 0.5), 0, math.max(0, scaled_h - view_h))

    local rect = Geom:new{
        x = src_x / zoom,
        y = src_y / zoom,
        w = view_w / zoom,
        h = view_h / zoom,
    }
    rect.scaled_rect = Geom:new{
        x = src_x,
        y = src_y,
        w = view_w,
        h = view_h,
    }

    local dest_x = x + self.padding + math.floor((viewport_w - view_w) / 2)
    local dest_y = y + self.padding + math.floor((viewport_h - view_h) / 2)

    logger.dbg("VPC:paintSinglePage partial", "page", page, "dest_x", dest_x, "dest_y", dest_y, "view_w", view_w, "view_h", view_h, "src_x", rect.scaled_rect.x, "src_y", rect.scaled_rect.y, "src_w", rect.scaled_rect.w, "src_h", rect.scaled_rect.h)

    local ok_draw = pcall(function()
        return self.document:drawPageTiled(target, dest_x, dest_y, rect, page, zoom, rotation, nil, 1, true)
    end)
    if not ok_draw then
        logger.warn("VPC:paintSinglePage tiled render failed")
    end
end

function VirtualPageCanvas:_prepareLayout()
    if self._layout_dirty then
        logger.info("VPC:_prepareLayout recalculating")
        self:recalculateLayout()
    end
    if not (self.document and self.document.virtual_layout) then
        if self.document and self.document._calculateVirtualLayout then
            logger.info("VPC:_prepareLayout calculating document layout")
            self.document:_calculateVirtualLayout()
        end
    end
end

function VirtualPageCanvas:_renderPageSlice(page_info, zoom, slice_top_px, slice_height_px)

    local page_num = page_info.page_num
    local layout = page_info.layout

    if not (page_num and layout) then
        logger.warn("VPC:_renderPageSlice missing page_num or layout")
        return nil
    end


    local image_zoom = zoom

    local page_top = page_info.page_top or 0

    -- Fallback to visible_* if caller didn't pass explicit slice px
    local top_px = tonumber(slice_top_px)
    local height_px = tonumber(slice_height_px)
    if not (top_px and height_px) then
        local vt = page_info.visible_top or page_top
        local vb = page_info.visible_bottom or vt
        top_px = math.floor((vt - page_top) + 0.5)
        height_px = math.max(0, math.floor((vb - vt) + 0.5))
    end


    if not height_px or height_px <= 0 then
        logger.warn("VPC:_renderPageSlice zero slice height (px)", "page", page_num, "top_px", top_px, "height_px", height_px)
        return nil
    end

    -- Convert quantized zoom px back to native coords
    local native_y = top_px / image_zoom
    local native_h = height_px / image_zoom


    local native_page_h = layout.native_height or 0
    if native_page_h <= 0 then
        logger.warn("VPC:_renderPageSlice invalid native height", "page", page_num)
        return nil
    end
    if native_y >= native_page_h then
        logger.warn("VPC:_renderPageSlice slice starts beyond page", "page", page_num, "native_y", native_y, "native_page_h", native_page_h)
        return nil
    end
    if native_y + native_h > native_page_h then
        native_h = native_page_h - native_y
    end
    if native_h <= 0 then
        logger.warn("VPC:_renderPageSlice clamped to zero height", "page", page_num)
        return nil
    end


    local rect = Geom:new{
        x = 0,
        y = native_y,
        w = layout.native_width,
        h = native_h,
    }

    local scaled_w = math.floor(layout.native_width * image_zoom + 0.5)
    local scaled_h = math.floor(native_h * image_zoom + 0.5)


    rect.scaled_rect = Geom:new{
        x = 0,
        y = 0,
        w = scaled_w,
        h = scaled_h,
    }

    logger.info("VPC:_renderPageSlice", "page", page_num, "zoom", image_zoom, "rotation", self.rotation, "native_y", native_y, "native_h", native_h, "scaled_w", scaled_w, "scaled_h", scaled_h)
    logger.info("VPC:_renderPageSlice rect", "x", rect.x, "y", rect.y, "w", rect.w, "h", rect.h)

    local ok, slice = pcall(function()
        return self.document:renderPage(page_num, rect, image_zoom, self.rotation)
    end)

    if ok and slice then
        return slice
    end

    logger.warn("VPC:_renderPageSlice render failed", "page", page_num, "error", slice)
    return nil
end

function VirtualPageCanvas:paintScroll(target, x, y, retry)
    retry = retry or 0

    self:_ensureZoom()
    self:_prepareLayout()

    local viewport_w, viewport_h = self:getViewportSize()
    if viewport_w <= 0 or viewport_h <= 0 then
        return
    end

    local scroll_offset = Math.clamp(self.scroll_offset or 0, 0, self:getMaxScrollOffset())
    local zoom = self.zoom or 1.0

    local visible_pages = {}
    local ok, err = pcall(function()
        visible_pages = self.document:getVisiblePagesAtOffset(scroll_offset, viewport_h, zoom, self.rotation)
    end)
    if not ok then
        logger.warn("VPC:paintScroll getVisiblePagesAtOffset failed:", err)
        return
    end
    if not visible_pages or #visible_pages == 0 then
        logger.warn("VPC:paintScroll no visible pages", "scroll_offset", scroll_offset, "viewport_h", viewport_h, "zoom", zoom)
        return
    end


    local stacked_y = 0

    if self.document and (self.document._virtual_layout_dirty or not self.document.virtual_layout) then
        self._layout_dirty = true
        if retry < 1 then
            self:recalculateLayout()
            return self:paintScroll(target, x, y, retry + 1)
        else
            self:markDirty()
            return
        end
    end


    local gap_px = math.floor(((self.document and self.document:getPageGapHeight()) or 0) * zoom + 0.5)
    local prev_page
    for _, page_info in ipairs(visible_pages) do
        -- Insert inter-page gap (scaled) before subsequent pages
        if prev_page and page_info.page_num ~= prev_page and gap_px > 0 then
            local remain_gap = viewport_h - stacked_y
            if remain_gap <= 0 then break end
            local draw_gap = math.min(gap_px, remain_gap)
            stacked_y = stacked_y + draw_gap
        end

        -- Quantize visible slice to integer pixel rows in zoom space and clamp to remaining viewport height
        local remain = viewport_h - stacked_y
        if remain <= 0 then break end
        local visible_h = page_info.visible_bottom - page_info.visible_top
        local slice_h_px = math.min(math.floor(visible_h + 0.5), remain)
        if slice_h_px <= 0 then goto continue end
        local top_px = math.floor((page_info.visible_top - page_info.page_top) + 0.5)

        local layout = page_info.layout
        local scaled_w = math.floor((layout.rotated_width or layout.native_width) * zoom + 0.5)
        local dest_x = x + self.padding + math.floor((viewport_w - scaled_w) / 2)
        local dest_y = y + self.padding + stacked_y

        local rect = Geom:new{
            x = 0,
            y = top_px / zoom,
            w = layout.native_width,
            h = slice_h_px / zoom,
        }

        local ok_draw = pcall(function()
            return self.document:drawPageTiled(target, dest_x, dest_y, rect, page_info.page_num, zoom, self.rotation, nil, 1, false)
        end)
        if not ok_draw then
            logger.warn("VPC:paintScroll tiled slice render failed", "page", page_info.page_num)
        end

        stacked_y = stacked_y + slice_h_px
        prev_page = page_info.page_num

        ::continue::
    end

end

function VirtualPageCanvas:onCloseWidget()
    logger.info("VPC:onCloseWidget")
    self.document = nil
end

return VirtualPageCanvas
