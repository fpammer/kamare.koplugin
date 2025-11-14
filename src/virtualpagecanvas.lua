local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local Math = require("optmath")

local VirtualPageCanvas = Widget:extend{
    document = nil,

    view_mode = 0, -- 0: "page" | 1: "scroll" | 2: "dual"
    current_page = 1,

    zoom_mode = 0, -- 0: "full" | 1: "width" | 2: "height"
    zoom = 1.0,
    rotation = 0,

    center_x_ratio = 0.5,
    center_y_ratio = 0.5,

    scroll_offset = 0,

    padding = 0,
    horizontal_margin = 0,
    background = Blitbuffer.COLOR_WHITE,
    page_gap_height = 8,

    page_direction = 0, -- 0: LTR, 1: RTL
    dual_page_gap = 5,

    _virtual_height = 0,
    _layout_dirty = true,
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

function VirtualPageCanvas:setRotation(rotation)
    rotation = rotation or 0
    rotation = rotation % 360
    if self.rotation ~= rotation then
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

function VirtualPageCanvas:setPadding(padding)
    padding = math.max(0, tonumber(padding) or 0)

    if padding ~= self.padding then
        self.padding = padding
        self._layout_dirty = true
        self:markDirty()
    end
end

function VirtualPageCanvas:setHorizontalMargin(margin)
    margin = math.max(0, tonumber(margin) or 0)

    if margin ~= self.horizontal_margin then
        self.horizontal_margin = margin
        if self.view_mode == 1 then
            self._layout_dirty = true
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

    if math.abs(gap - (self.page_gap_height or 0)) > 0.5 then
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
    local horizontal_spacing = self.padding

    if self.view_mode == 1 then
        horizontal_spacing = self.padding + (self.horizontal_margin or 0)
    end

    local w = math.max(0, self.dimen.w - 2 * horizontal_spacing)
    local h = math.max(0, self.dimen.h - 2 * self.padding)

    return w, h
end

function VirtualPageCanvas:getVirtualHeight()
    if self.view_mode ~= 1 or not self.document then
        return 0
    end

    if self._layout_dirty then
        self:recalculateLayout()
    end

    return self._virtual_height or 0
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
    if self.rotation % 180 ~= 0 then
        page_w, page_h = page_h, page_w
    end
    if page_w <= 0 or page_h <= 0 then
        return self.zoom
    end

    local zoom_w = viewport_w / page_w
    local zoom_h = viewport_h / page_h

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

    -- Quantize zoom to integer pixels
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

function VirtualPageCanvas:_ensureZoom()
    if self.view_mode == 1 and self.zoom_mode == 1 then
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
                local scaled_w = math.floor(target_width * computed + 0.5)
                computed = scaled_w / target_width
                if computed > 0 and math.abs(computed - (self.zoom or 0)) > 1e-6 then
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
end

function VirtualPageCanvas:recalculateLayout()
    self:_ensureZoom()
    self._layout_dirty = false
    self._virtual_height = 0

    if not self.document or not self.document.is_open then
        return
    end

    if self.document.virtual_layout == nil or self.document.total_virtual_height == nil then
        if self.document._calculateVirtualLayout then
            self.document:_calculateVirtualLayout()
        end
    end

    local viewport_w, viewport_h = self:getViewportSize()
    if self.document.getVirtualHeight then
        local total = self.document:getVirtualHeight(self.zoom, self.rotation, self.zoom_mode, viewport_w)
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
    rect.scaled_rect = Geom:new{
        x = src_x,
        y = src_y,
        w = view_w,
        h = view_h,
    }

    local dest_x = x + self.padding + math.floor((viewport_w - view_w) / 2)
    local dest_y = y + self.padding + math.floor((viewport_h - view_h) / 2)

    local ok_draw = pcall(function()
        return self.document:drawPageTiled(target, dest_x, dest_y, rect, page, zoom, rotation, nil, 0, true)
    end)
    if not ok_draw then
        logger.warn("VPC:paintSinglePage tiled render failed")
    end
end

function VirtualPageCanvas:getDualPagePair(current_page)
    if not self.document then
        return current_page, 0
    end

    -- Pairs should already be built in document init
    if not self.document._dual_page_pairs then
        return current_page, 0
    end

    local pairs = self.document._dual_page_pairs
    for i, pair in ipairs(pairs) do
        local page1, page2 = pair[1], pair[2]

        if current_page == page1 or current_page == page2 then
            logger.warn(string.format("VPC:getDualPagePair page %d found in pairs[%d] {%d, %d}", current_page, i, page1, page2))

            -- Check for landscape solo spreads (same non-zero page number)
            if page1 == page2 and page1 > 0 then
                logger.warn("VPC:getDualPagePair SOLO landscape display for page", current_page)
                return current_page, -1  -- Signal solo landscape display
            end

            -- Apply RTL flipping for display
            -- page_direction: 0 = LTR, 1 = RTL
            local left_page, right_page
            if self.page_direction == 1 then
                -- RTL: swap pages (right page comes first in reading order)
                left_page, right_page = page2, page1
                logger.warn(string.format("VPC:getDualPagePair RTL mode, swapped to {%d, %d}", left_page, right_page))
            else
                -- LTR: keep physical order
                left_page, right_page = page1, page2
            end

            return left_page, right_page
        end
    end

    logger.warn("VPC:getDualPagePair No pair found for page", current_page)
    return current_page, 0
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

    local x_offset = self.padding
    if side == "right" then
        x_offset = x_offset + page_width + gap_offset
    end

    x_offset = x_offset + (page_width - zoomed_w) / 2
    local y_offset = self.padding + (vp_h - zoomed_h) / 2

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
    local page_width = (viewport_w - gap) / 2

    local left_page, right_page = self:getDualPagePair(page)

    if right_page == -1 then
        self:paintSinglePage(target, x, y)
        return
    end

    local zoom = self:_computeZoomForDualPage(left_page, right_page, page_width, viewport_h)
    if zoom <= 0 then zoom = 1.0 end

    local rotation = self.rotation or 0

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
                rect.scaled_rect = Geom:new{
                    x = 0,
                    y = 0,
                    w = left_rect_info.w,
                    h = left_rect_info.h,
                }

                local dest_x = x + math.floor(left_rect_info.x)
                local dest_y = y + math.floor(left_rect_info.y)

                local ok_draw = pcall(function()
                    return self.document:drawPageTiled(target, dest_x, dest_y, rect, left_page, zoom, rotation, nil, 0, true)
                end)
                if not ok_draw then
                    logger.warn("VPC:paintDualPage left page tiled render failed")
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
                rect.scaled_rect = Geom:new{
                    x = 0,
                    y = 0,
                    w = right_rect_info.w,
                    h = right_rect_info.h,
                }

                local dest_x = x + math.floor(right_rect_info.x)
                local dest_y = y + math.floor(right_rect_info.y)

                local ok_draw = pcall(function()
                    return self.document:drawPageTiled(target, dest_x, dest_y, rect, right_page, zoom, rotation, nil, 0, true)
                end)
                if not ok_draw then
                    logger.warn("VPC:paintDualPage right page tiled render failed")
                end
            end
        end
    end
end

function VirtualPageCanvas:_prepareLayout()
    if self._layout_dirty then
        self:recalculateLayout()
    end
    if not (self.document and self.document.virtual_layout) then
        if self.document and self.document._calculateVirtualLayout then
            self.document:_calculateVirtualLayout()
        end
    end
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
        visible_pages = self.document:getVisiblePagesAtOffset(scroll_offset, viewport_h, zoom, self.rotation, self.zoom_mode, viewport_w)
    end)
    if not ok then
        logger.warn("VPC:paintScroll getVisiblePagesAtOffset failed:", err)
        return
    end
    if not visible_pages or #visible_pages == 0 then
        logger.warn("VPC:paintScroll no visible pages", "scroll_offset", scroll_offset, "viewport_h", viewport_h, "zoom", zoom)
        return
    end


    local stacked_y = self.padding

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


    local gap_px = math.floor((self.page_gap_height or 0) * zoom)
    local prev_page
    for _, page_info in ipairs(visible_pages) do
        if prev_page and page_info.page_num ~= prev_page and gap_px > 0 then
            local remain_gap = viewport_h - stacked_y
            if remain_gap <= 0 then break end
            local draw_gap = math.min(gap_px, remain_gap)
            stacked_y = stacked_y + draw_gap
        end

        local remain = viewport_h - stacked_y
        if remain <= 0 then break end
        local visible_h = page_info.visible_bottom - page_info.visible_top
        local slice_h_px = math.min(math.floor(visible_h), remain)
        if slice_h_px <= 0 then goto continue end
        local top_px = math.floor(page_info.visible_top - page_info.page_top)

        local layout = page_info.layout
        local page_zoom = page_info.zoom or zoom

        local scaled_w = math.floor((layout.rotated_width or layout.native_width) * page_zoom)

        local horizontal_spacing = self.padding + (self.horizontal_margin or 0)
        local dest_x = x + horizontal_spacing + math.floor((viewport_w - scaled_w) / 2)
        local dest_y = y + stacked_y

        local native_y = math.floor(top_px / page_zoom)
        local native_h = math.floor(slice_h_px / page_zoom)

        local rect = Geom:new{
            x = 0,
            y = native_y,
            w = layout.native_width,
            h = native_h,
        }

        local ok_draw = pcall(function()
            return self.document:drawPageTiled(target, dest_x, dest_y, rect, page_info.page_num, page_zoom, self.rotation, nil, 1, false)
        end)
        if not ok_draw then
            logger.warn("VPC:paintScroll tiled slice render failed", "page", page_info.page_num)
        end

        local actual_rendered_h = math.floor(native_h * page_zoom)

        stacked_y = stacked_y + actual_rendered_h
        prev_page = page_info.page_num

        ::continue::
    end

end

function VirtualPageCanvas:onCloseWidget()
    self.document = nil
end

return VirtualPageCanvas
