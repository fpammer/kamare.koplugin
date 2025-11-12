local BD = require("ui/bidi")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local Blitbuffer = require("ffi/blitbuffer")
local datetime = require("datetime")
local Geom = require("ui/geometry")

-- Footer mode constants
local MODE = {
    page_progress = 1,
    pages_left_book = 2,
    time = 3,
    battery = 4,
    percentage = 5,
    book_time_to_read = 6,
    off = 7,
}

-- Symbol prefixes for different display styles
local SYMBOL_PREFIX = {
    letters = {
        time = nil,
        pages_left_book = "->",
        battery = "B:",
        percentage = "R:",
        book_time_to_read = "TB:",
    },
    icons = {
        time = "⌚",
        pages_left_book = "⇒",
        battery = "",
        percentage = "⤠",
        book_time_to_read = "⏳",
    },
    compact_items = {
        time = nil,
        pages_left_book = "›",
        battery = "",
        percentage = nil,
        book_time_to_read = nil,
    }
}

-- Mode index mapping mode numbers to mode names
local MODE_INDEX = {
    [1] = "page_progress",
    [2] = "pages_left_book",
    [3] = "time",
    [4] = "battery",
    [5] = "percentage",
    [6] = "book_time_to_read",
    [7] = "off",
}

local KamareFooter = {}
KamareFooter.__index = KamareFooter

function KamareFooter.new(_, opts)
    local self = setmetatable({}, KamareFooter)
    self.settings = assert(opts.settings, "KamareFooter requires settings")
    self.MODE = MODE
    self.symbol_prefix = SYMBOL_PREFIX
    self.mode_index = MODE_INDEX
    self.genFooterText = function() return "" end
    return self
end

function KamareFooter:ensureBuilt()
    if self.widget then return end

    self:__initGenerators()

    self.footer_text_face = Font:getFace("ffont", self.settings.text_font_size)
    self.footer_text = TextWidget:new{
        text = "",
        face = self.footer_text_face,
        bold = self.settings.text_font_bold,
    }

    self.progress_bar = ProgressWidget:new{
        width = Screen:getWidth() - 2 * self.settings.progress_margin_width,
        height = self.settings.progress_style_thick_height,
        percentage = 0,
        tick_width = 0,
        ticks = nil,
        last = nil,
        initial_pos_marker = false,
        fill_from_right = false,
    }
    self.progress_bar:updateStyle(true, self.settings.progress_style_thick_height)

    self.footer_left_margin_span = HorizontalSpan:new{ width = self.settings.progress_margin_width }
    self.footer_right_margin_span = HorizontalSpan:new{ width = self.settings.progress_margin_width }

    self.footer_text_container = CenterContainer:new{
        dimen = Geom:new{ w = 0, h = self.settings.height },
        self.footer_text,
    }

    self.footer_horizontal_group = HorizontalGroup:new{
        self.footer_left_margin_span,
        self.progress_bar,
        self.footer_text_container,
        self.footer_right_margin_span,
    }

    self.footer_vertical_frame = VerticalGroup:new{ self.footer_horizontal_group }
    self.widget = FrameContainer:new{
        self.footer_vertical_frame,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        padding_bottom = 0,
    }
    self.widget.dimen = Geom:new{ w = Screen:getWidth(), h = self.settings.height }

    self:updateTextGenerator()
end

function KamareFooter:getWidget()
    self:ensureBuilt()
    return self.widget
end

function KamareFooter:isVisible()
    return self.settings.enabled and self.settings.mode ~= self.MODE.off
end

function KamareFooter:getMode()
    return self.settings.mode
end

function KamareFooter:isValidMode(mode)
    local m = tonumber(mode)
    if not m then return false end
    if m == self.MODE.off then return true end
    local name = self.mode_index[m]
    return name and self.settings[name]
end

function KamareFooter:setMode(mode)
    if not self:isValidMode(mode) then return false end
    self.settings.mode = tonumber(mode) or self.settings.mode
    self:updateTextGenerator()
    return true
end

function KamareFooter:cycleToNextValidMode()
    local max_modes = #self.mode_index
    local attempts = 0
    self.settings.mode = (self.settings.mode % max_modes) + 1

    while attempts < max_modes do
        if self:isValidMode(self.settings.mode) then break end
        self.settings.mode = (self.settings.mode % max_modes) + 1
        attempts = attempts + 1
    end

    if attempts >= max_modes then
        self.settings.mode = self.MODE.off
    end

    self:updateTextGenerator()
    return self.settings.mode
end

function KamareFooter:__initGenerators()
    self.footerTextGeneratorMap = {
        empty = function() return "" end,

        page_progress = function()
            if not self.state or not self.state.has_document or (self.state.total_pages or 0) <= 1 then return "" end
            return ("%d / %d"):format(self.state.current_page, self.state.total_pages)
        end,

        pages_left_book = function()
            if not self.state or not self.state.has_document or (self.state.total_pages or 0) <= 1 then return "" end
            local prefix = self.symbol_prefix[self.settings.item_prefix].pages_left_book
            local remaining = self.state.total_pages - self.state.current_page
            return prefix and (prefix .. " " .. remaining) or tostring(remaining)
        end,

        time = function()
            if not self.settings.time then return "" end
            local prefix = self.symbol_prefix[self.settings.item_prefix].time
            local clock = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
            return prefix and (prefix .. " " .. clock) or clock
        end,

        battery = function()
            if not Device:hasBattery() or not self.settings.battery then return "" end
            local prefix = self.symbol_prefix[self.settings.item_prefix].battery
            local powerd = Device:getPowerDevice()
            local level = powerd:getCapacity()
            local charging = powerd:isCharging()
            local suffix = (charging and "+" or "") .. level .. "%"
            if self.settings.item_prefix == "icons" then
                return (prefix or "") .. suffix
            elseif self.settings.item_prefix == "compact_items" then
                return BD.wrap(prefix or "")
            end
            return BD.wrap(prefix or "") .. " " .. suffix
        end,

        percentage = function()
            if not self.state or not self.state.has_document or (self.state.total_pages or 0) <= 1 then return "" end
            local prefix = self.symbol_prefix[self.settings.item_prefix].percentage
            local progress = (self.state.current_page - 1) / (self.state.total_pages - 1) * 100
            local fmt = "%.1f%%"
            if prefix then fmt = prefix .. " " .. fmt end
            return fmt:format(progress)
        end,

        book_time_to_read = function()
            if not self.state or not self.state.has_document or (self.state.total_pages or 0) <= 1 then return "" end
            local prefix = self.symbol_prefix[self.settings.item_prefix].book_time_to_read
            return (prefix and prefix .. " " or "") .. self.state.time_estimate
        end,
    }
end

function KamareFooter:updateTextGenerator()
    if not self.settings.enabled then
        self.genFooterText = self.footerTextGeneratorMap.empty
        return
    end
    local mode_name = self.mode_index[self.settings.mode]
    if not mode_name or not self.settings[mode_name] then
        self.genFooterText = self.footerTextGeneratorMap.empty
        return
    end
    self.genFooterText = self.footerTextGeneratorMap[mode_name] or self.footerTextGeneratorMap.empty
end

function KamareFooter:updateContent()
    if not self:isVisible() then return end
    self:ensureBuilt()

    local new_face = Font:getFace("ffont", self.settings.text_font_size)
    if new_face ~= self.footer_text_face or self.footer_text.bold ~= self.settings.text_font_bold then
        local text = self.footer_text.text
        self.footer_text:free()
        self.footer_text_face = new_face
        self.footer_text = TextWidget:new{
            text = text,
            face = new_face,
            bold = self.settings.text_font_bold,
        }
        self.footer_text_container[1] = self.footer_text
    end

    if not self.genFooterText then
        self:__initGenerators()
        self:updateTextGenerator()
    end

    local text = self.genFooterText()
    self.footer_text:setText(text)

    local margins_width = 2 * self.settings.progress_margin_width
    local min_progress_width = math.floor(Screen:getWidth() * 0.20)
    local text_available = Screen:getWidth() - margins_width - min_progress_width

    self.footer_text:setMaxWidth(text_available)
    local text_size = self.footer_text:getSize()
    local text_spacer = Screen:scaleBySize(10)
    local text_container_width = text_size.w + text_spacer

    if text == "" or text_size.w <= 0 then
        self.footer_text_container.dimen.w = 0
        self.progress_bar.width = Screen:getWidth() - margins_width
    else
        self.footer_text_container.dimen.w = text_container_width
        self.progress_bar.width = math.max(min_progress_width, Screen:getWidth() - margins_width - text_container_width)
    end

    self.footer_left_margin_span.width = self.settings.progress_margin_width
    self.footer_right_margin_span.width = self.settings.progress_margin_width

    self.footer_horizontal_group:resetLayout()
end

function KamareFooter:updateProgressBar()
    if not self:isVisible() then return end
    self:ensureBuilt()

    if self.settings.disable_progress_bar then
        self.progress_bar:setPercentage(0)
        return
    end

    if not self.state or not self.state.has_document or (self.state.total_pages or 0) <= 1 then
        self.progress_bar:setPercentage(0)
        return
    end

    -- Update RTL direction for dual-page RTL mode
    if self.state.is_rtl_mode then
        self.progress_bar.fill_from_right = true
    else
        self.progress_bar.fill_from_right = false
    end

    local progress
    if self.state.is_scroll_mode then
        progress = self.state.scroll_progress
    else
        progress = (self.state.current_page - 1) / (self.state.total_pages - 1)
    end
    self.progress_bar:setPercentage(progress or 0)
end

function KamareFooter:update(state)
    if not self:isVisible() then return false end

    -- Check if state actually changed
    local changed = false
    if not self.state or
       self.state.current_page ~= state.current_page or
       self.state.total_pages ~= state.total_pages or
       self.state.scroll_progress ~= state.scroll_progress or
       self.state.time_estimate ~= state.time_estimate or
       self.state.is_scroll_mode ~= state.is_scroll_mode or
       self.state.is_rtl_mode ~= state.is_rtl_mode or
       self.state.has_document ~= state.has_document then
        changed = true
    end

    if changed then
        self.state = state
        self:updateContent()
        self:updateProgressBar()
    end

    return changed
end

function KamareFooter:free()
    if self.footer_text then self.footer_text:free() end
    if self.widget then self.widget:free() end
end

return KamareFooter
