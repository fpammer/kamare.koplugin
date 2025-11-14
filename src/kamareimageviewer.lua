local Device = require("device")
local KamareFooter = require("kamarefooter")
local MD5 = require("ffi/sha2").md5
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local logger = require("logger")
local DocCache = require("document/doccache")
local ConfigDialog = require("ui/widget/configdialog")
local CanvasContext = require("document/canvascontext")
local KamareOptions = require("kamareoptions")
local Configurable = require("frontend/configurable")
local InputContainer = require("ui/widget/container/inputcontainer")
local TitleBar = require("ui/widget/titlebar")
local Geom = require("ui/geometry")
local VirtualImageDocument = require("virtualimagedocument")
local VirtualPageCanvas = require("virtualpagecanvas")
local KavitaClient = require("kavitaclient")
local Math = require("optmath")
local ButtonDialog = require("ui/widget/buttondialog")
local VIDCache = require("virtualimagedocumentcache")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local T = require("ffi/util").template

local TILE_SIZE_PX = 1024

local KamareImageViewer = InputContainer:extend{
    images_list_data = nil,
    images_list_nb = nil,

    fullscreen = false,
    width = nil,
    height = nil,
    rotated = false,
    title = "",
    canvas = nil,
    canvas_container = nil,
    _images_list_cur = 1,

    on_close_callback = nil,
    start_page = 1,

    configurable = Configurable:new(),
    options = KamareOptions,
    prefetch_pages = 1,
    page_gap_height = 5,

    virtual_document = nil,
    view_mode = 0, -- 0: page, 1: continuous, 2: dual
    page_direction = 0, -- 0: LTR, 1: RTL
    scroll_offset = 0,
    current_zoom = 1.0,
    zoom_mode = 0, -- "full"
    _pending_scroll_page = nil,

    scroll_distance = 25, -- percentage (25, 50, 75, 100)
    scroll_margin = 0, -- horizontal margin in scroll mode (left/right only)
    page_padding = 0, -- uniform padding on all sides
    background_color = 1, -- 0 = black, 1 = white

    _failed_image_loads = {}, -- Track failed image pages to show error toast

    footer_settings = {
        enabled = true,
        page_progress = true,
        pages_left_book = true,
        time = true,
        battery = Device:hasBattery(),
        percentage = true,
        book_time_to_read = true,
        mode = 1,
        item_prefix = "icons",
        text_font_size = 14,
        text_font_bold = false,
        height = Screen:scaleBySize(15),
        disable_progress_bar = false,
        progress_bar_position = "alongside",
        progress_style_thin = false,
        progress_style_thick_height = 7,
        progress_margin_width = 10,
        items_separator = "bar",
        align = "center",
        lock_tap = false,
    },
}

function KamareImageViewer:init()
    self:loadSettings()

    if self.fullscreen then
        self.covers_fullscreen = true
    end

    self.image_viewing_times = {}
    self.current_image_start_time = os.time()
    self.title_bar_visible = false
    self._failed_image_loads = {}

    self.initial_rotation_mode = Screen:getRotationMode()

    if not CanvasContext.device then
        CanvasContext:init(Device)
    end

    self:_initDocument()
    self:_initCanvas()
    self:_setupStatisticsInterface()

    self.align = "center"
    self.region = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    self:_updateDimensions()

    self:registerKeyEvents()
    self:setupTitleBar()
    self:initConfigGesListener()

    self.frame_elements = VerticalGroup:new{ align = "left" }

    self.main_frame = FrameContainer:new{
        radius = not self.fullscreen and 8 or nil,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.frame_elements,
    }
    self[1] = WidgetContainer:new{
        align = self.align,
        dimen = self.region,
        self.main_frame,
    }

    if self.view_mode == 1 then
        self._pending_scroll_page = self._images_list_cur
    end

    if self.virtual_document and self._images_list_nb > 1 then
        self.footer = KamareFooter:new{
            settings = self.footer_settings,
        }
    end

    self:update()

    UIManager:nextTick(function()
        self:prefetchUpcomingTiles()
        self:_postViewProgress()

        if self.ui and self.ui.statistics and self.doc_settings then
            self.ui.statistics:onReaderReady(self.doc_settings)
        end
    end)
end

function KamareImageViewer:_initDocument()
    local has_valid_images_data = true
    if not self.images_list_data then
        logger.err("KamareImageViewer: No images_list_data provided. Displaying empty screen.")
        has_valid_images_data = false
        self.images_list_data = { function() return nil end }
        self.images_list_nb = 1
    end

    local cache_id = (self.metadata and (self.title .. "/" .. self.metadata.seriesId .. "/" .. self.metadata.chapterId))
        or self.title or "session"

    self.virtual_document = VirtualImageDocument:new{
        images_list = self.images_list_data,
        images_dimensions = self.preloaded_dimensions,
        pages_override = self.images_list_nb,
        title = self.title,
        cache_id = cache_id,
        cache_mod_time = 0,
        render_quality = self.render_quality or -1,
        content_type = self.metadata and self.metadata.content_type or "auto",
        on_image_load_error = function(pageno, error_msg)
            self:onImageLoadError(pageno, error_msg)
        end,
    }

    if not self.virtual_document.is_open then
        logger.err("KamareImageViewer: Failed to initialize VirtualImageDocument. Displaying empty screen.")
    end

    self:_updatePageCount()
    self._images_list_cur = Math.clamp((self.metadata and self.metadata.startPage) or 1, 1, self._images_list_nb)

    if has_valid_images_data and G_reader_settings:isTrue("imageviewer_rotate_auto_for_best_fit") then
        local dims = self.virtual_document:getNativePageDimensions(self._images_list_cur)
        if dims then
            self.rotated = (Screen:getWidth() > Screen:getHeight()) ~= (dims.w > dims.h)
        end
    end
end

function KamareImageViewer:_initCanvas()
    local bg_color = self.background_color == 1 and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    self.canvas = VirtualPageCanvas:new{
        document = self.virtual_document,
        padding = self.page_padding,
        horizontal_margin = self.scroll_margin,
        background = bg_color,
        view_mode = self.view_mode,
        page_direction = self.page_direction,
        page_gap_height = self.page_gap_height,
    }

    self.canvas_container = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        self.canvas,
    }

    self.image_container = self.canvas_container
end

function KamareImageViewer:_setupStatisticsInterface()
    if not (self.ui and self.virtual_document) then
        return
    end

    if not self.ui.statistics then
        return
    end

    local viewer_ref = self
    local doc_wrapper = setmetatable({}, {
        __index = function(t, k)
            if k == "getCurrentPage" then
                return function() return viewer_ref._images_list_cur end
            elseif k == "getPageCount" then
                return function() return viewer_ref._images_list_nb end
            elseif k == "hasHiddenFlows" then
                return function() return false end
            else
                return viewer_ref.virtual_document[k]
            end
        end
    })

    self.document = doc_wrapper
    self.ui.document = doc_wrapper
    if self.ui.statistics then
        self.ui.statistics.document = doc_wrapper
        self.ui.statistics.view = nil
    end

    local partial_md5 = MD5(self.virtual_document.file)

    local stats_data = {
        performance_in_pages = {},
        title = self.metadata and self.metadata.localizedName or self.title or "Unknown",
        authors = self.metadata and self.metadata.author or "",
        series = self.metadata and self.metadata.seriesName or "",
    }

    local doc_settings = {
        readSetting = function(_, key, default)
            if key == "summary" then
                return { status = "reading", modified = os.date("%Y-%m-%d") }
            elseif key == "percent_finished" then
                return (viewer_ref._images_list_cur or 1) / (viewer_ref._images_list_nb or 1)
            elseif key == "doc_pages" then
                return viewer_ref._images_list_nb
            elseif key == "doc_props" then
                return viewer_ref.ui.doc_props
            elseif key == "stats" then
                return stats_data
            elseif key == "partial_md5_checksum" then
                return partial_md5
            end
            return default
        end,
        saveSetting = function(_, key, value)
            logger.dbg("KamareImageViewer: doc_settings saveSetting", key, "=", value)
        end,
        isTrue = function(_, key) return false end,
        nilOrFalse = function(_, key) return true end,
    }

    self.doc_settings = doc_settings
    self.ui.doc_settings = doc_settings

    local doc_props = {
        title = self.metadata and self.metadata.localizedName or self.title or "Unknown",
        display_title = self.metadata and self.metadata.localizedName or self.title or "Unknown",
        authors = self.metadata and self.metadata.author or "",
        series = self.metadata and self.metadata.seriesName or "",
        series_index = self.metadata and self.metadata.volumeNumber or nil,
        language = "N/A",
        pages = self._images_list_nb,
    }

    self.doc_props = doc_props
    self.ui.doc_props = doc_props

    local annotation = {
        getNumberOfHighlightsAndNotes = function()
            return 0, 0
        end
    }

    self.annotation = annotation
    self.ui.annotation = annotation

    if not self.menu then
        self.menu = {
            registerToMainMenu = function() end
        }
    end

    -- Ensure parent's dictionary module has required fields initialized
    -- This prevents crashes during suspend/settings flush
    if self.ui.dictionary then
        if not self.ui.dictionary.preferred_dictionaries then
            self.ui.dictionary.preferred_dictionaries = {}
        end
        if not self.ui.dictionary.doc_disabled_dicts then
            self.ui.dictionary.doc_disabled_dicts = {}
        end
        self.dictionary = self.ui.dictionary
    end

    local view_stub = {
        footer = {
            maybeUpdateFooter = function()
                if viewer_ref.footer then
                    viewer_ref:updateFooter()
                end
            end
        },
        state = {
            page = viewer_ref._images_list_cur,
        }
    }

    self.view = view_stub
    if self.ui.statistics then
        self.ui.statistics.view = view_stub
    end

    if not self.bookinfo and self.ui.bookinfo then
        self.bookinfo = self.ui.bookinfo
    end
end

function KamareImageViewer:_updateDimensions()
    if self.fullscreen then
        self.height = Screen:getHeight()
        self.width = Screen:getWidth()
    else
        self.height = Screen:getHeight() - Screen:scaleBySize(40)
        self.width = Screen:getWidth() - Screen:scaleBySize(40)
    end
end

function KamareImageViewer:loadSettings()
    if not self.kamare_settings then
        logger.warn("KIV:loadSettings: no settings object")
        return
    end

    self.configurable.footer_mode = self.footer_settings.mode
    self.configurable.prefetch_pages = self.prefetch_pages
    self.configurable.view_mode = self.view_mode
    self.configurable.page_direction = self.page_direction
    self.configurable.zoom_mode_type = self.zoom_mode
    self.configurable.page_gap_height = self.page_gap_height
    self.configurable.scroll_distance = self.scroll_distance
    self.configurable.scroll_margin = self.scroll_margin
    self.configurable.page_padding = self.page_padding
    self.configurable.render_quality = self.render_quality or -1
    self.configurable.background_color = self.background_color
    self.configurable.rotation_lock = false

    self.configurable:loadSettings(self.kamare_settings, self.options.prefix .. "_")

    self.footer_settings.mode = self.configurable.footer_mode
    self.prefetch_pages = self.configurable.prefetch_pages or 1
    self.view_mode = self.configurable.view_mode or 0
    self.page_direction = self.configurable.page_direction or 0
    self.zoom_mode = self.configurable.zoom_mode_type or 0
    self.page_gap_height = self.configurable.page_gap_height or 8
    self.scroll_distance = self.configurable.scroll_distance or 25
    self.scroll_margin = self.configurable.scroll_margin or 0
    self.page_padding = self.configurable.page_padding or 0
    self.render_quality = self.configurable.render_quality or -1
    self.background_color = self.configurable.background_color or 1
    self.rotation_locked = self.configurable.rotation_lock or false

    self:syncAndSaveSettings()
end

function KamareImageViewer:syncAndSaveSettings()
    if not self.kamare_settings then
        logger.warn("KIV:syncAndSaveSettings: no settings object")
        return
    end

    self.configurable.footer_mode = self.footer_settings.mode
    self.configurable.prefetch_pages = self.prefetch_pages
    self.configurable.view_mode = self.view_mode
    self.configurable.page_direction = self.page_direction
    self.configurable.zoom_mode_type = self.zoom_mode
    self.configurable.page_gap_height = self.page_gap_height
    self.configurable.scroll_distance = self.scroll_distance
    self.configurable.scroll_margin = self.scroll_margin
    self.configurable.page_padding = self.page_padding
    self.configurable.render_quality = self.render_quality
    self.configurable.background_color = self.background_color
    self.configurable.rotation_lock = self.rotation_locked

    self.configurable:saveSettings(self.kamare_settings, self.options.prefix .. "_")
end

function KamareImageViewer:getCurrentZoom()
    if self.canvas and self.canvas.zoom and self.canvas.zoom > 0 then
        return self.canvas.zoom
    end
    if self.canvas then
        self.canvas:setZoomMode(self.zoom_mode)
        if self.canvas.zoom and self.canvas.zoom > 0 then
            return self.canvas.zoom
        end
    end
    return self.current_zoom or 1.0
end

function KamareImageViewer:setZoomMode(mode)
    local changed = self.zoom_mode ~= mode
    if changed then
        self.zoom_mode = mode
        self._pending_scroll_page = self._images_list_cur
    end

    self.configurable.zoom_mode_type = self.zoom_mode
    self:syncAndSaveSettings()

    if changed then
        if self.canvas then
            self.canvas:setZoomMode(self.zoom_mode)
        end

        self:updateImageOnly()
        self:updateFooter()

        -- Force screen refresh when changing zoom mode
        UIManager:setDirty(self, "ui", self.main_frame.dimen)

        UIManager:nextTick(function()
            self:prefetchUpcomingTiles()
        end)
    end

    return true
end

function KamareImageViewer:registerKeyEvents()
    if not Device:hasKeys() then return end
    self.key_events = {
        Close         = { { Device.input.group.Back } },
        ShowPrevImage = { { Device.input.group.PgBack } },
        ShowNextImage = { { Device.input.group.PgFwd } },
    }
end

function KamareImageViewer:setupTitleBar()
    local title = self.title or _("Images")
    local subtitle

    if self.metadata then
        title = self.metadata.seriesName
            or self.metadata.localizedName
            or self.metadata.originalName
            or title
        if self.metadata.author then
            subtitle = T(_("by %1"), self.metadata.author)
        end
    end

    self.title_bar = TitleBar:new{
        width = Screen:getWidth(),
        fullscreen = true,
        align = "center",
        title = title,
        subtitle = subtitle,
        title_shrink_font_to_fit = true,
        title_top_padding = Screen:scaleBySize(6),
        button_padding = Screen:scaleBySize(5),
        right_icon_size_ratio = 1,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
end


function KamareImageViewer:getTimeEstimate(remaining_images)
    if #self.image_viewing_times == 0 then return _("N/A") end
    local total = 0
    for _, t in ipairs(self.image_viewing_times) do total = total + t end
    local average = total / #self.image_viewing_times
    local remaining = remaining_images * average

    if remaining < 60 then
        return T(_("%1s"), math.ceil(remaining))
    elseif remaining < 3600 then
        return T(_("%1m"), math.ceil(remaining / 60))
    else
        local hours = math.floor(remaining / 3600)
        local minutes = math.ceil((remaining % 3600) / 60)
        return T(_("%1h %2m"), hours, minutes)
    end
end

function KamareImageViewer:recordViewingTimeIfValid()
    if self.current_image_start_time and self._images_list_cur then
        local viewing_time = os.time() - self.current_image_start_time
        if viewing_time > 0 and viewing_time < 300 then
            table.insert(self.image_viewing_times, viewing_time)
            if #self.image_viewing_times > 10 then
                table.remove(self.image_viewing_times, 1)
            end
        end
    end
end

function KamareImageViewer:getFooterState()
    local scroll_progress = 0

    if self.view_mode == 1 and self.canvas and self.virtual_document then
        local zoom = self:getCurrentZoom()
        local viewport_w, viewport_h = self.canvas:getViewportSize()
        local total = self.virtual_document:getVirtualHeight(zoom, self:_getRotationAngle(), self.zoom_mode, viewport_w)
        if total > 0 then
            -- Use bottom of viewport for progress calculation so 100% is reached at the end
            local pos = (self.scroll_offset or 0) + viewport_h
            scroll_progress = Math.clamp(pos / total, 0, 1)
        end
    end

    local display_page = self._images_list_cur
    local total_pages = self._images_list_nb

    if self.view_mode == 2 and self.canvas and self.virtual_document then
        local left, right = self.canvas:getDualPagePair(self._images_list_cur)

        if left > 0 and right > 0 then
            display_page = math.min(left, right)
        elseif left > 0 then
            display_page = left
        elseif right > 0 then
            display_page = right
        end
    end

    local remaining = total_pages - display_page
    if self.view_mode == 2 and self.virtual_document then
        for p = display_page + 1, total_pages do
            local _, p_right = self.canvas:getDualPagePair(p)
            if p_right == -1 then
                remaining = remaining + 1  -- Landscape counts as 2 pages
            end
        end
    end

    local time_estimate = self:getTimeEstimate(remaining)

    local footer_state = {
        current_page = display_page,
        total_pages = total_pages,
        has_document = self.virtual_document ~= nil,
        is_scroll_mode = (self.view_mode == 1) or false,
        scroll_progress = scroll_progress,
        time_estimate = time_estimate,
        is_rtl_mode = (self.view_mode == 2 and self.page_direction == 1) or false,
    }

    return footer_state
end

function KamareImageViewer:updateFooter()
    if self.footer and self.footer:update(self:getFooterState()) then
        UIManager:setDirty(self, "ui", self.footer:getWidget().dimen)
    end
end

function KamareImageViewer:getCurrentFooterMode()
    return (self.footer and self.footer:getMode()) or self.footer_settings.mode
end

function KamareImageViewer:isValidMode(mode)
    return self.footer and self.footer:isValidMode(mode)
end

function KamareImageViewer:cycleToNextValidMode()
    if not self.footer then return self.footer_settings.mode end
    local mode = self.footer:cycleToNextValidMode()
    self:syncAndSaveSettings()
    self:updateFooter()
    return mode
end

function KamareImageViewer:setFooterMode(mode)
    if not (self.footer and self.footer:isValidMode(mode)) then return false end
    self.footer:setMode(mode)
    self:syncAndSaveSettings()
    self:updateFooter()
    return true
end

function KamareImageViewer:initConfigGesListener()
    if not Device:isTouchDevice() then return end

    local DTAP_ZONE_MENU      = G_defaults:readSetting("DTAP_ZONE_MENU")
    local DTAP_ZONE_MENU_EXT  = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    local DTAP_ZONE_CONFIG    = G_defaults:readSetting("DTAP_ZONE_CONFIG")
    local DTAP_ZONE_CONFIG_EXT= G_defaults:readSetting("DTAP_ZONE_CONFIG_EXT")
    local DTAP_ZONE_MINIBAR   = G_defaults:readSetting("DTAP_ZONE_MINIBAR")
    local DTAP_ZONE_FORWARD   = G_defaults:readSetting("DTAP_ZONE_FORWARD")
    local DTAP_ZONE_BACKWARD  = G_defaults:readSetting("DTAP_ZONE_BACKWARD")

    self:registerTouchZones({
        {
            id = "kamare_menu_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h,
            },
            handler = function() return self:onTapMenu() end,
        },
        {
            id = "kamare_menu_ext_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MENU_EXT.x, ratio_y = DTAP_ZONE_MENU_EXT.y,
                ratio_w = DTAP_ZONE_MENU_EXT.w, ratio_h = DTAP_ZONE_MENU_EXT.h,
            },
            overrides = {
                "kamare_menu_tap",
            },
            handler = function() return self:onTapMenu() end,
        },
        {
            id = "kamare_config_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_CONFIG.x, ratio_y = DTAP_ZONE_CONFIG.y,
                ratio_w = DTAP_ZONE_CONFIG.w, ratio_h = DTAP_ZONE_CONFIG.h,
            },
            handler = function() return self:onTapConfig() end,
        },
        {
            id = "kamare_config_ext_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_CONFIG_EXT.x, ratio_y = DTAP_ZONE_CONFIG_EXT.y,
                ratio_w = DTAP_ZONE_CONFIG_EXT.w, ratio_h = DTAP_ZONE_CONFIG_EXT.h,
            },
            overrides = {
                "kamare_config_tap",
            },
            handler = function() return self:onTapConfig() end,
        },
        {
            id = "kamare_forward_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_FORWARD.x, ratio_y = DTAP_ZONE_FORWARD.y,
                ratio_w = DTAP_ZONE_FORWARD.w, ratio_h = DTAP_ZONE_FORWARD.h,
            },
            handler = function() return self:onTapForward() end,
        },
        {
            id = "kamare_backward_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_BACKWARD.x, ratio_y = DTAP_ZONE_BACKWARD.y,
                ratio_w = DTAP_ZONE_BACKWARD.w, ratio_h = DTAP_ZONE_BACKWARD.h,
            },
            handler = function() return self:onTapBackward() end,
        },
        {
            id = "kamare_minibar_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MINIBAR.x, ratio_y = DTAP_ZONE_MINIBAR.y,
                ratio_w = DTAP_ZONE_MINIBAR.w, ratio_h = DTAP_ZONE_MINIBAR.h,
            },
            handler = function() return self:onTapMinibar() end,
        },
    })
end

function KamareImageViewer:onTapMenu()
    self:toggleTitleBar()
    return true
end

function KamareImageViewer:onTapConfig()
    return self:onShowConfigMenu()
end

function KamareImageViewer:onTapMinibar()
    if not self.footer_settings.enabled or not self.virtual_document or self._images_list_nb <= 1 then
        return false
    end

    if self.footer_settings.lock_tap then
        return self:onShowConfigMenu()
    end

    self:cycleToNextValidMode()

    return true
end

function KamareImageViewer:onTapForward()
    self:onShowNextImage()

    return true
end

function KamareImageViewer:onTapBackward()
    self:onShowPrevImage()

    return true
end

function KamareImageViewer:onShowConfigMenu()
    self.configurable.footer_mode  = self.footer_settings.mode
    self.configurable.prefetch_pages = self.prefetch_pages
    self.configurable.view_mode  = self.view_mode
    self.configurable.page_direction = self.page_direction
    self.configurable.zoom_mode_type = self.zoom_mode
    self.configurable.page_gap_height = self.page_gap_height
    self.configurable.scroll_distance = self.scroll_distance
    self.configurable.scroll_margin = self.scroll_margin
    self.configurable.page_padding = self.page_padding
    self.configurable.background_color = self.background_color
    self.configurable.rotation_lock = self.rotation_locked

    self.config_dialog = ConfigDialog:new{
        document = nil,
        ui = self,  -- Always use self as ui, not parent ui
        configurable = self.configurable,
        config_options = self.options,
        is_always_active = true,
        covers_footer = true,
        close_callback = function() self:onConfigCloseCallback() end,
    }

    self.config_dialog:onShowConfigPanel(1)
    UIManager:show(self.config_dialog)
    return true
end

function KamareImageViewer:onConfigCloseCallback()
    self.config_dialog = nil

    local footer_mode = self.configurable.footer_mode
    if footer_mode and footer_mode ~= self.footer_settings.mode then
        self:setFooterMode(footer_mode)
    end

    if self.configurable.view_mode ~= nil then
        local new_mode = tonumber(self.configurable.view_mode)
        if new_mode ~= self.view_mode then
            self.view_mode = new_mode
            self._pending_scroll_page = self._images_list_cur
            if self.view_mode ~= 1 then
                self.scroll_offset = 0
                if self.canvas and self.zoom_mode == 0 then
                    self.canvas:setCenter(0.5, 0.5)
                end
            end
            if self.canvas then
                self.canvas:setViewMode(new_mode)
            end
            self:update()
            UIManager:setDirty(self, "ui", self.main_frame.dimen)
        end
    end

    if self.configurable.page_direction ~= nil then
        local new_direction = tonumber(self.configurable.page_direction)
        if new_direction ~= self.page_direction then
            self.page_direction = new_direction
            if self.canvas then
                self.canvas:setPageDirection(new_direction)
            end
            self:update()
            UIManager:setDirty(self, "ui", self.main_frame.dimen)
        end
    end

    local needs_update = false

    if self.configurable.page_padding ~= nil and self.configurable.page_padding ~= self.page_padding then
        self.page_padding = self.configurable.page_padding
        if self.canvas then
            self.canvas:setPadding(self.page_padding)
        end
        needs_update = true
    end

    if self.configurable.scroll_margin ~= nil and self.configurable.scroll_margin ~= self.scroll_margin then
        self.scroll_margin = self.configurable.scroll_margin
        if self.canvas then
            self.canvas:setHorizontalMargin(self.scroll_margin)
        end
        needs_update = true
    end

    if self.configurable.page_gap_height ~= nil and self.configurable.page_gap_height ~= self.page_gap_height then
        self.page_gap_height = self.configurable.page_gap_height
        if self.canvas then
            self.canvas:setPageGapHeight(self.page_gap_height)
        end
        needs_update = true
    end

    if self.configurable.scroll_distance ~= nil then
        self.scroll_distance = self.configurable.scroll_distance
    end

    if self.configurable.prefetch_pages ~= nil then
        self.prefetch_pages = self.configurable.prefetch_pages
    end

    if needs_update then
        self._pending_scroll_page = self._images_list_cur
        self:update()
        UIManager:setDirty(self, "ui", self.main_frame.dimen)
        UIManager:nextTick(function() self:prefetchUpcomingTiles() end)
    end

    self:syncAndSaveSettings()
end

function KamareImageViewer:onCloseConfigMenu()
    if self.config_dialog then
        self.config_dialog:closeDialog()
    end
end

function KamareImageViewer:onSetFooterMode(mode)
    return self:setFooterMode(mode)
end

function KamareImageViewer:onSetPrefetchPages(value)
    local n = tonumber(value)
    if not n then return false end
    if n ~= -1 then
        n = Math.clamp(n, 0, 3)
    end
    if n == self.prefetch_pages then return true end
    self.prefetch_pages = n
    self.configurable.prefetch_pages = n
    self:syncAndSaveSettings()

    UIManager:nextTick(function() self:prefetchUpcomingTiles() end)
    return true
end

function KamareImageViewer:onSetRenderQuality(quality)
    local q = tonumber(quality)
    if not q then return false end
    if q == self.render_quality then return true end

    self.render_quality = q
    self.configurable.render_quality = q
    self:syncAndSaveSettings()

    if self.virtual_document then
        self.virtual_document.render_quality = q
        self.virtual_document:clearCache()
    end

    return true
end

function KamareImageViewer:_updatePageCount()
    -- Update page count - always use physical page count
    if self.virtual_document then
        self._images_list_nb = self.virtual_document:getPageCount()
    end
end

function KamareImageViewer:onSetViewMode(value)
    local mode = tonumber(value) or 0
    if mode == self.view_mode then return true end

    self.view_mode = mode
    self.configurable.view_mode = mode
    self._pending_scroll_page = self._images_list_cur

    -- Update page count when switching modes
    self:_updatePageCount()

    -- Continuous mode requires width-fit zoom
    if mode == 1 then
        if self.zoom_mode ~= 1 then
            self.zoom_mode = 1
            self.configurable.zoom_mode_type = 1
            if self.canvas then
                self.canvas:setZoomMode(1)
            end
        end
    else
        self.scroll_offset = 0
        if mode == 0 and self.zoom_mode == 1 then
            self.zoom_mode = 0
            self.configurable.zoom_mode_type = 0
            if self.canvas then
                self.canvas:setZoomMode(0)
            end
        end
        if self.canvas and self.zoom_mode == 0 then
            self.canvas:setCenter(0.5, 0.5)
        end
    end

    if self.canvas then
        self.canvas:setViewMode(mode)
    end

    self:syncAndSaveSettings()
    self:update()
    UIManager:setDirty(self, "ui", self.main_frame.dimen)

    return true
end

function KamareImageViewer:onSetPageDirection(value)
    local direction = tonumber(value) or 0
    if direction == self.page_direction then return true end

    self.page_direction = direction
    self.configurable.page_direction = direction

    if self.canvas then
        self.canvas:setPageDirection(direction)
    end

    self:syncAndSaveSettings()
    self:update()
    UIManager:setDirty(self, "ui", self.main_frame.dimen)

    return true
end

function KamareImageViewer:onDefineZoom(mode)
    return self:setZoomMode(mode)
end

function KamareImageViewer:onPageGapUpdate(value)
    local gap = tonumber(value)
    if not gap then return false end
    gap = math.max(0, gap)
    if gap == self.page_gap_height then return true end

    self.page_gap_height = gap
    self.configurable.page_gap_height = gap
    self:syncAndSaveSettings()

    if self.canvas then
        self.canvas:setPageGapHeight(gap)
    end

    if self.view_mode == 1 then
        self._pending_scroll_page = self._images_list_cur
        self:update()
        UIManager:nextTick(function() self:prefetchUpcomingTiles() end)
    end

    return true
end

function KamareImageViewer:onScrollDistanceUpdate(value)
    local distance = tonumber(value)
    if not distance then return false end
    distance = Math.clamp(distance, 0, 100)
    if distance == self.scroll_distance then return true end

    self.scroll_distance = distance
    self.configurable.scroll_distance = distance
    self:syncAndSaveSettings()

    return true
end

function KamareImageViewer:onScrollMarginUpdate(value)
    local margin = tonumber(value)
    if not margin then return false end
    margin = math.max(0, margin)
    if margin == self.scroll_margin then return true end

    self.scroll_margin = margin
    self.configurable.scroll_margin = margin
    self:syncAndSaveSettings()

    if self.canvas then
        self.canvas:setHorizontalMargin(margin)
    end

    if self.view_mode == 1 then
        self._pending_scroll_page = self._images_list_cur
        self:update()
        UIManager:nextTick(function() self:prefetchUpcomingTiles() end)
    end

    return true
end

function KamareImageViewer:onPagePaddingUpdate(value)
    local padding = tonumber(value)
    if not padding then return false end
    padding = math.max(0, padding)
    if padding == self.page_padding then return true end

    self.page_padding = padding
    self.configurable.page_padding = padding
    self:syncAndSaveSettings()

    if self.canvas then
        self.canvas:setPadding(padding)
    end

    self._pending_scroll_page = self._images_list_cur
    self:update()
    UIManager:nextTick(function() self:prefetchUpcomingTiles() end)

    return true
end

function KamareImageViewer:onSetBackgroundColor(value)
    local color = tonumber(value)
    if not color then return false end
    if color ~= 0 and color ~= 1 then return false end
    if color == self.background_color then return true end

    self.background_color = color
    self.configurable.background_color = color
    self:syncAndSaveSettings()

    if self.canvas then
        local bg_color = color == 1 and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        self.canvas:setBackground(bg_color)
    end

    self:update()
    UIManager:setDirty(self, "ui", self.main_frame.dimen)

    return true
end

function KamareImageViewer:_clampScrollOffset(offset)
    if not self.canvas then return offset or 0 end
    local max_offset = self.canvas:getMaxScrollOffset() or 0
    return Math.clamp(offset or 0, 0, max_offset)
end

function KamareImageViewer:_setScrollOffset(offset, opts)
    if self.view_mode ~= 1 then return end

    local clamped = self:_clampScrollOffset(offset)

    if math.abs(clamped - (self.scroll_offset or 0)) > 0.5 then
        self.scroll_offset = clamped
        if self.canvas then
            self.canvas:setScrollOffset(clamped)
        end
        self:_updatePageFromScroll(opts and opts.silent)
    end
end

function KamareImageViewer:_scrollBy(delta)
    self:_setScrollOffset((self.scroll_offset or 0) + delta)
end

function KamareImageViewer:_scrollStep(direction)
    if not (self.view_mode == 1 and self.canvas and self.virtual_document) then
        return false
    end

    local viewport_w, viewport_h = self.canvas:getViewportSize()
    if viewport_h <= 0 then
        return false
    end

    local zoom = self:getCurrentZoom()
    local step_ratio = (self.scroll_distance or 25) / 100
    local step = math.max(viewport_h * step_ratio, 1)
    local total = self.virtual_document:getVirtualHeight(zoom, self:_getRotationAngle(), self.zoom_mode, viewport_w) or 0
    local offset = self.scroll_offset or 0

    if direction > 0 then
        if total > 0 and offset + step >= total - viewport_h then
            if self._images_list_cur < self._images_list_nb then
                self:switchToImageNum(self._images_list_cur + 1)
            else
                local at_bottom = offset >= total - viewport_h - 1
                if at_bottom then
                    self:_checkAndOfferNextChapter()
                else
                    self:_setScrollOffset(math.max(0, total - viewport_h))
                end
            end
        else
            self:_scrollBy(step)
        end
        return true
    elseif direction < 0 then
        if offset - step <= 0 then
            if self._images_list_cur > 1 then
                self:switchToImageNum(self._images_list_cur - 1)
            else
                self:_setScrollOffset(0)
            end
        else
            self:_scrollBy(-step)
        end
        return true
    end

    return false
end

function KamareImageViewer:_scrollToPage(page)
    if self.view_mode ~= 1 or not self.virtual_document then return end

    local zoom = self:getCurrentZoom()
    local viewport_w = self.canvas and select(1, self.canvas:getViewportSize()) or 0
    local offset = self.virtual_document:getScrollPositionForPage(page, zoom, self:_getRotationAngle(), self.zoom_mode, viewport_w)

    self:_setScrollOffset(offset, { silent = true })
    self:_updatePageFromScroll(true)
    self:updateFooter()
end

function KamareImageViewer:_updatePageFromScroll(silent)
    if self.view_mode ~= 1 or not self.virtual_document then return end

    local zoom = self:getCurrentZoom()
    local viewport_w, viewport_h = self.canvas and self.canvas:getViewportSize() or 0, 0
    local check_offset = (self.scroll_offset or 0) + viewport_h
    local new_page = self.virtual_document:getPageAtOffset(check_offset, zoom, self:_getRotationAngle(), self.zoom_mode, viewport_w)

    local should_prefetch = false

    if self._images_list_cur < self._images_list_nb then
        local current_page_start = self.virtual_document:getScrollPositionForPage(self._images_list_cur, zoom, self:_getRotationAngle(), self.zoom_mode, viewport_w)
        local next_page_start = self.virtual_document:getScrollPositionForPage(self._images_list_cur + 1, zoom, self:_getRotationAngle(), self.zoom_mode, viewport_w)
        local current_page_height = next_page_start - current_page_start

        if current_page_height > 0 then
            local current_offset = self.scroll_offset or 0
            local progress_in_page = current_offset - current_page_start
            local page_progress = progress_in_page / current_page_height

            local step_ratio = (self.scroll_distance or 25) / 100
            local scroll_step = viewport_h * step_ratio
            local predicted_offset = current_offset + scroll_step
            local predicted_progress = (predicted_offset - current_page_start) / current_page_height

            local threshold = 0.30
            if (page_progress >= threshold or predicted_progress >= threshold) and self._prefetch_triggered_for_page ~= self._images_list_cur then
                should_prefetch = true
                self._prefetch_triggered_for_page = self._images_list_cur
            end
        end
    end

    if new_page ~= self._images_list_cur then
        if not silent then self:recordViewingTimeIfValid() end
        self._images_list_cur = new_page
        self.current_image_start_time = os.time()
        self:updateFooter()
        self:_postViewProgress()

        if self.ui and self.ui.statistics then
            self.ui.statistics:onPageUpdate(new_page)
        end

        self._prefetch_triggered_for_page = nil
        should_prefetch = true
    elseif not silent then
        self:updateFooter()
        self:_postViewProgress()
    end

    if should_prefetch then
        UIManager:nextTick(function() self:prefetchUpcomingTiles() end)
    end
end

function KamareImageViewer:_updateCanvasState()
    if not (self.canvas and self.virtual_document) then return end

    local page = Math.clamp(self._images_list_cur or 1, 1, self._images_list_nb or 1)
    local rotation = self:_getRotationAngle()

    self.canvas:setRotation(rotation)
    self.canvas:setZoomMode(self.zoom_mode)
    self.canvas:setPage(page)
    self.canvas:setSize{
        w = math.max(1, self.width),
        h = math.max(1, self.img_container_h or self.height or Screen:getHeight()),
    }

    local need_layout_refresh = self.canvas._layout_dirty
    if not need_layout_refresh then
        need_layout_refresh = not (self.canvas.zoom and self.canvas.zoom > 0)
    end

    if need_layout_refresh
        and self.canvas.recalculateLayout
        and self.canvas.dimen
        and self.canvas.dimen.w > 0
        and self.canvas.dimen.h > 0 then
        local ok, err = pcall(function()
            self.canvas:recalculateLayout()
        end)
        if not ok then
            logger.warn("KamareImageViewer:_updateCanvasState recalc failed", err)
        end
    end

    self.current_zoom = self.canvas.zoom or 1.0

    if self.view_mode == 1 then
        local desired = self.scroll_offset or 0
        if self._pending_scroll_page then
            local viewport_w = select(1, self.canvas:getViewportSize())
            desired = self.virtual_document:getScrollPositionForPage(self._pending_scroll_page, self.current_zoom, rotation, self.zoom_mode, viewport_w)
            self._pending_scroll_page = nil
        end
        desired = self:_clampScrollOffset(desired)
        self.scroll_offset = desired
        self.canvas:setScrollOffset(desired)
        self:_updatePageFromScroll(true)
        self:updateFooter()
    else
        self.scroll_offset = 0
        if self.zoom_mode == 0 then
            self.canvas:setCenter(0.5, 0.5)
        end
        self:updateFooter()
    end
end

function KamareImageViewer:update()
    local orig = self.main_frame.dimen

    self:_updateDimensions()
    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    if self.title_bar_visible and self.title_bar then
        table.insert(self.frame_elements, self.title_bar)
    end

    local image_idx = #self.frame_elements + 1

    if self.footer and self.footer:isVisible() then
        self.footer:update(self:getFooterState())
        table.insert(self.frame_elements, self.footer:getWidget())
    end

    self.img_container_h = self.height - self.frame_elements:getSize().h

    if self.canvas_container then
        self.canvas_container.dimen = Geom:new{ w = self.width, h = self.img_container_h }
    end

    self:_updateCanvasState()

    if self.image_container then
        table.insert(self.frame_elements, image_idx, self.image_container)
    end

    self.frame_elements:resetLayout()
    self.main_frame.radius = not self.fullscreen and 8 or nil

    UIManager:setDirty(self, function()
        local region = self.main_frame.dimen:combine(orig)
        return "partial", region
    end)
end

function KamareImageViewer:updateImageOnly()
    if not self.canvas then return self:update() end
    self:_updateCanvasState()
end

function KamareImageViewer:calculateAdaptivePrefetch()
    if self._images_list_cur <= 1 and not self._initial_prefetch_done then
        self._initial_prefetch_done = true
        return 1
    end

    if self.view_mode == 1 then
        return 1
    end

    local ok, cache_stats = pcall(function()
        return VIDCache:stats()
    end)

    if not ok or not cache_stats then
        logger.warn("KamareImageViewer: Failed to get cache stats, using fallback prefetch")
        return 1
    end

    local native_stats = cache_stats.native or {}
    local total_size = native_stats.total_size or 0
    local max_size = native_stats.max_size or 0
    local count = native_stats.count or 0
    local utilization = native_stats.utilization or 0

    if max_size <= 0 then
        logger.warn("KamareImageViewer: Invalid cache max_size, using fallback prefetch")
        return 1
    end

    local avg_tile_size

    if count > 0 and total_size > 0 then
        avg_tile_size = total_size / count
    else
        avg_tile_size = 2 * 1024 * 1024
    end

    local tiles_capacity = math.floor(max_size / avg_tile_size)

    local tiles_per_page = 20
    local current_page = self._images_list_cur

    if current_page and self.virtual_document then
        local native_dims = self.virtual_document:getNativePageDimensions(current_page)

        if native_dims and native_dims.w > 0 and native_dims.h > 0 then
            local tiles_x = math.ceil(native_dims.w / TILE_SIZE_PX)
            local tiles_y = math.ceil(native_dims.h / TILE_SIZE_PX)
            tiles_per_page = tiles_x * tiles_y
        end
    end

    local prefetch_pages

    if utilization < 0.5 then
        local remaining_tiles = tiles_capacity * (1.0 - utilization)
        local max_pages_by_space = math.floor(remaining_tiles / tiles_per_page)

        prefetch_pages = math.min(3, math.max(1, max_pages_by_space))
    elseif utilization < 0.8 then
        local remaining_tiles = tiles_capacity * (1.0 - utilization)
        local max_pages_by_space = math.floor(remaining_tiles / tiles_per_page)

        prefetch_pages = math.min(2, math.max(1, max_pages_by_space))
    else
        prefetch_pages = 1
    end

    return prefetch_pages
end

function KamareImageViewer:prefetchUpcomingTiles()
    if not self.virtual_document then return end

    local target_buffer_size

    if self.prefetch_pages == -1 then
        target_buffer_size = self:calculateAdaptivePrefetch()
    else
        target_buffer_size = tonumber(self.prefetch_pages) or 0
    end

    if target_buffer_size <= 0 then return end

    local zoom = self:getCurrentZoom()
    local rotation = self:_getRotationAngle()

    local current_page = self._images_list_cur

    if self.view_mode == 1 and self.canvas then
        local viewport_w, viewport_h = self.canvas:getViewportSize()
        local visible = self.virtual_document:getVisiblePagesAtOffset(self.scroll_offset or 0, viewport_h, zoom, rotation, self.zoom_mode, viewport_w) or {}
        if #visible > 0 then
            current_page = visible[#visible].page_num
        end
    end

    local pages_to_prefetch = {}
    local pages_already_cached = {}
    local scan_window = math.min(target_buffer_size + 2, self._images_list_nb - current_page)

    for i = 1, scan_window do
        local check_page = current_page + i
        if check_page > self._images_list_nb then break end

        local page_cached = false
        local native_dims = self.virtual_document:getNativePageDimensions(check_page)

        if native_dims and native_dims.w > 0 and native_dims.h > 0 then
            local first_tile_rect = Geom:new{ x = 0, y = 0, w = TILE_SIZE_PX, h = TILE_SIZE_PX }
            local hash = self.virtual_document:_tileHash(check_page, zoom, rotation, self.virtual_document.gamma, first_tile_rect)
            local cached = VIDCache:getNativeTile(hash)
            page_cached = (cached ~= nil)
        end

        if not page_cached then
            if #pages_to_prefetch < target_buffer_size then
                table.insert(pages_to_prefetch, check_page)
            end
        else
            table.insert(pages_already_cached, check_page)
        end
    end

    if #pages_to_prefetch == 0 then
        return
    end

    for _, page in ipairs(pages_to_prefetch) do
        UIManager:nextTick(function()
            pcall(function()
                local page_mode = (self.view_mode ~= 1)
                self.virtual_document:prefetchPage(page, zoom, rotation, page_mode)
            end)
        end)
    end
end

function KamareImageViewer:onSwipe(_, ges)
    local dir = ges.direction
    local dist = ges.distance

    if dir == "north" then
        if self.view_mode == 1 then
            self:_scrollBy(dist)
        end
    elseif dir == "south" then
        if self.view_mode == 1 then
            self:_scrollBy(-dist)
        end
    end

    return true
end

function KamareImageViewer:_canPanInPageMode(direction)
    if self.view_mode == 1 then return false end
    if self.view_mode == 2 then return false end  -- Disable panning in dual-page mode
    if not (self.canvas and self.virtual_document) then return false end

    local viewport_w, viewport_h = self.canvas:getViewportSize()

    if viewport_w <= 0 or viewport_h <= 0 then return false end

    local page = Math.clamp(self._images_list_cur or 1, 1, self._images_list_nb or 1)
    local dims = self.virtual_document:getNativePageDimensions(page)

    if not dims or dims.w <= 0 or dims.h <= 0 then return false end

    local zoom = self:getCurrentZoom()
    local rotation = self:_getRotationAngle()

    local page_w = dims.w
    local page_h = dims.h

    if rotation % 180 ~= 0 then
        page_w, page_h = page_h, page_w
    end

    local scaled_w = page_w * zoom
    local scaled_h = page_h * zoom

    if self.zoom_mode == 1 then
        if scaled_h <= viewport_h then return false end

        local min_y = viewport_h / (2 * scaled_h)
        local max_y = 1.0 - min_y

        local center_y = self.canvas.center_y_ratio or 0.5
        if direction > 0 then
            return center_y < max_y - 1e-3
        else
            return center_y > min_y + 1e-3
        end
    elseif self.zoom_mode == 2 then
        if scaled_w <= viewport_w then return false end

        local min_x = viewport_w / (2 * scaled_w)
        local max_x = 1.0 - min_x

        local center_x = self.canvas.center_x_ratio or 0.5
        if direction > 0 then
            return center_x < max_x - 1e-3
        else
            return center_x > min_x + 1e-3
        end
    end

    return false
end

function KamareImageViewer:_panWithinPage(direction)
    if not self.canvas then return false end

    local viewport_w, viewport_h = self.canvas:getViewportSize()
    if viewport_w <= 0 or viewport_h <= 0 then return false end

    local page = Math.clamp(self._images_list_cur or 1, 1, self._images_list_nb or 1)
    local dims = self.virtual_document:getNativePageDimensions(page)
    if not dims or dims.w <= 0 or dims.h <= 0 then return false end

    local zoom = self:getCurrentZoom()
    local rotation = self:_getRotationAngle()
    local page_w = dims.w
    local page_h = dims.h
    if rotation % 180 ~= 0 then
        page_w, page_h = page_h, page_w
    end

    local step_ratio = (self.scroll_distance or 25) / 100

    if self.zoom_mode == 1 then
        local scaled_h = page_h * zoom
        if scaled_h <= viewport_h then return false end

        local step_pixels = viewport_h * step_ratio
        local center_ratio_step = step_pixels / scaled_h

        local center_y = self.canvas.center_y_ratio or 0.5
        local new_y = center_y + (direction > 0 and center_ratio_step or -center_ratio_step)
        new_y = Math.clamp(new_y, 0.0, 1.0)

        if math.abs(new_y - center_y) < 1e-6 then
            return false
        end

        self.canvas:setCenter(self.canvas.center_x_ratio or 0.5, new_y)
        self:updateImageOnly()
        UIManager:setDirty(self, "partial", self.canvas.dimen)
        return true
    elseif self.zoom_mode == 2 then
        local scaled_w = page_w * zoom
        if scaled_w <= viewport_w then return false end

        local step_pixels = viewport_w * step_ratio
        local center_ratio_step = step_pixels / scaled_w

        local center_x = self.canvas.center_x_ratio or 0.5
        local new_x = center_x + (direction > 0 and center_ratio_step or -center_ratio_step)
        new_x = Math.clamp(new_x, 0.0, 1.0)

        if math.abs(new_x - center_x) < 1e-6 then
            return false
        end

        self.canvas:setCenter(new_x, self.canvas.center_y_ratio or 0.5)
        self:updateImageOnly()
        UIManager:setDirty(self, "partial", self.canvas.dimen)
        return true
    end

    return false
end

function KamareImageViewer:switchToImageNum(page)
    self:recordViewingTimeIfValid()
    page = Math.clamp(page, 1, self._images_list_nb)

    if self.view_mode == 2 and self.virtual_document then
        local canonical_page = self.virtual_document:getSpreadForPage(page)
        if canonical_page ~= page then
            page = canonical_page
        end
    end

    if page == self._images_list_cur then return end

    local moving_forward = page > self._images_list_cur
    self._images_list_cur = page
    self.current_image_start_time = os.time()

    if self.ui and self.ui.statistics then
        self.ui.statistics:onPageUpdate(page)
    end

    if self.view_mode == 1 then
        self:_scrollToPage(page)
    else
        self.scroll_offset = 0

        if self.canvas and (self.zoom_mode == 1 or self.zoom_mode == 2) then
            local viewport_w, viewport_h = self.canvas:getViewportSize()
            local dims = self.virtual_document:getNativePageDimensions(page)

            if dims and viewport_w > 0 and viewport_h > 0 then
                local zoom = self:getCurrentZoom()
                local rotation = self:_getRotationAngle()
                local page_w = dims.w
                local page_h = dims.h
                if rotation % 180 ~= 0 then
                    page_w, page_h = page_h, page_w
                end

                if self.zoom_mode == 1 then
                    local scaled_h = page_h * zoom
                    if scaled_h > viewport_h then
                        local min_y = viewport_h / (2 * scaled_h)
                        local max_y = 1.0 - min_y
                        local new_y = moving_forward and min_y or max_y
                        self.canvas:setCenter(0.5, new_y)
                    else
                        self.canvas:setCenter(0.5, 0.5)
                    end
                elseif self.zoom_mode == 2 then
                    local scaled_w = page_w * zoom
                    if scaled_w > viewport_w then
                        local min_x = viewport_w / (2 * scaled_w)
                        local max_x = 1.0 - min_x
                        local new_x = moving_forward and min_x or max_x
                        self.canvas:setCenter(new_x, 0.5)
                    else
                        self.canvas:setCenter(0.5, 0.5)
                    end
                end
            end
        end
    end

    self:updateImageOnly()
    self:updateFooter()
    self:_postViewProgress()
    UIManager:nextTick(function() self:prefetchUpcomingTiles() end)
end

function KamareImageViewer:onShowNextImage()
    -- In RTL dual-page mode, "next" in reading direction means going backward in page numbers
    local is_rtl = self.view_mode == 2 and self.page_direction == 1

    if is_rtl then
        return self:_showPrevImageInternal()
    else
        return self:_showNextImageInternal()
    end
end

function KamareImageViewer:onShowPrevImage()
    -- In RTL dual-page mode, "prev" in reading direction means going forward in page numbers
    local is_rtl = self.view_mode == 2 and self.page_direction == 1

    if is_rtl then
        return self:_showNextImageInternal()
    else
        return self:_showPrevImageInternal()
    end
end

function KamareImageViewer:_showNextImageInternal()
    if self.view_mode == 1 and self:_scrollStep(1) then
        return
    end

    if self.view_mode ~= 1 and self:_canPanInPageMode(1) then
        if self:_panWithinPage(1) then
            return
        end
    end

    local next_page
    if self.view_mode == 2 and self.virtual_document and self.virtual_document.getNextSpreadPage then
        next_page = self.virtual_document:getNextSpreadPage(self._images_list_cur)

        if next_page == self._images_list_cur then
            self:_checkAndOfferNextChapter()
            return
        end
    else
        next_page = self._images_list_cur + 1

        if next_page > self._images_list_nb then
            self:_checkAndOfferNextChapter()
            return
        end
    end

    self:switchToImageNum(next_page)
end

function KamareImageViewer:_showPrevImageInternal()
    if self.view_mode == 1 and self:_scrollStep(-1) then
        return
    end

    if self.view_mode ~= 1 and self:_canPanInPageMode(-1) then
        if self:_panWithinPage(-1) then
            return
        end
    end

    local prev_page
    if self.view_mode == 2 and self.virtual_document and self.virtual_document.getPrevSpreadPage then
        prev_page = self.virtual_document:getPrevSpreadPage(self._images_list_cur)

        if prev_page == self._images_list_cur then
            return
        end
    else
        prev_page = self._images_list_cur - 1

        if prev_page < 1 then
            return
        end
    end

    self:switchToImageNum(prev_page)
end

function KamareImageViewer:onShowNextSlice()
    if self.view_mode ~= 1 then
        self:onShowNextImage()
        return
    end

    self:_scrollStep(1)
end

function KamareImageViewer:onShowPrevSlice()
    if self.view_mode ~= 1 then
        self:onShowPrevImage()
        return
    end

    self:_scrollStep(-1)
end

function KamareImageViewer:_checkAndOfferNextChapter()
    if not (self.metadata and KavitaClient and KavitaClient.bearer) then
        return
    end

    local seriesId = self.metadata.seriesId or self.metadata.series_id
    local volumeId = self.metadata.volumeId or self.metadata.volume_id
    local currentChapterId = self.metadata.chapterId or self.metadata.chapter_id

    if not (seriesId and volumeId and currentChapterId) then
        logger.warn("KamareImageViewer: Missing required IDs for next chapter query")
        return
    end

    logger.info("KamareImageViewer: Querying next chapter for series", seriesId, "volume", volumeId, "chapter", currentChapterId)

    UIManager:nextTick(function()
        local nextChapterId, code = KavitaClient:getNextChapter(seriesId, volumeId, currentChapterId)

        if nextChapterId == -1 or not nextChapterId or type(code) ~= "number" or code < 200 or code >= 300 then
            self.next_chapter_dialog = ButtonDialog:new{
                title = _("You've reached the end of the series"),
                title_align = "center",
                buttons = {
                    {
                        {
                            text = _("Close"),
                            callback = function()
                                UIManager:close(self.next_chapter_dialog)
                                self.next_chapter_dialog = nil
                                self:onClose()
                            end,
                        },
                    },
                },
            }
            UIManager:show(self.next_chapter_dialog)
            return
        end

        self.next_chapter_dialog = ButtonDialog:new{
            title = _("Continue to next chapter?"),
            title_align = "center",
            buttons = {
                {
                    {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(self.next_chapter_dialog)
                            self.next_chapter_dialog = nil
                            self:onClose()
                        end,
                    },
                    {
                        text = _("Continue"),
                        callback = function()
                            UIManager:close(self.next_chapter_dialog)
                            self.next_chapter_dialog = nil
                            if self.on_next_chapter_callback then
                                self.on_next_chapter_callback(nextChapterId)
                            end
                            self:onClose()
                        end,
                    },
                },
            },
        }
        UIManager:show(self.next_chapter_dialog)
    end)
end

function KamareImageViewer:_postViewProgress()
    if not (self.metadata and KavitaClient and KavitaClient.bearer) then return end

    local at_end = false

    if self.view_mode == 1 and self._images_list_cur == self._images_list_nb and self.canvas then
        local max_offset = self.canvas:getMaxScrollOffset() or 0
        if max_offset > 0 then
            at_end = math.abs((self.scroll_offset or 0) - max_offset) < 1
        end
    end

    -- In dual-page mode, post the furthest page in the current pair for progress tracking
    local current_page = self._images_list_cur
    if self.view_mode == 2 and self.canvas and self.virtual_document then
        local left, right = self.canvas:getDualPagePair(self._images_list_cur)
        -- Use the maximum page (furthest progress)
        current_page = math.max(left, right)
    end

    local page_to_post
    local on_last_page = current_page == self._images_list_nb

    if on_last_page or at_end then
        page_to_post = current_page
    else
        page_to_post = math.max(1, current_page - 1)
    end

    if self.last_posted_page == page_to_post and not (at_end or on_last_page) then return end

    UIManager:nextTick(function()
        pcall(function()
            KavitaClient:postReaderProgressForPage(self.metadata, page_to_post)
        end)
    end)
    self.last_posted_page = page_to_post
end

function KamareImageViewer:onClose()
    if self.next_chapter_dialog then
        UIManager:close(self.next_chapter_dialog)
        self.next_chapter_dialog = nil
    end

    if self.ui and self.ui.statistics then
        logger.info("KamareImageViewer: Calling statistics:onCloseDocument")
        self.ui.statistics:onCloseDocument()
        self.ui.statistics.is_doc = false
    end

    if self.ui then
        logger.info("KamareImageViewer: Clearing UI state")
        self.ui.document = nil
        self.ui.doc_settings = nil
        self.ui.doc_props = nil
        self.ui.annotation = nil

        if self.ui.statistics then
            self.ui.statistics.document = nil
            self.ui.statistics.view = nil
        end
    end

    if self.config_dialog then
        self.config_dialog:closeDialog()
    end

    self:syncAndSaveSettings()
    self:_postViewProgress()
    self:recordViewingTimeIfValid()

    if self.initial_rotation_mode and Screen:getRotationMode() ~= self.initial_rotation_mode then
        logger.info("KamareImageViewer: Restoring rotation mode to", self.initial_rotation_mode)
        Screen:setRotationMode(self.initial_rotation_mode)
    end

    if self.title_bar_visible then
        self.title_bar_visible = false
    end

    if self.on_close_callback then
        self.on_close_callback(self._images_list_cur, self._images_list_nb)
    end

    if self.virtual_document and self.virtual_document.file then
        local ok, err = pcall(DocCache.serialize, DocCache, self.virtual_document.file)
        if not ok then
            logger.warn("DocCache serialize failed:", err)
        end
    end

    UIManager:close(self)
    return true
end

function KamareImageViewer:onCloseWidget()
    if self.virtual_document then
        self.virtual_document:close()
        self.virtual_document = nil
    end

    if self.canvas then
        self.canvas:setDocument(nil)
        self.canvas = nil
    end
    self.canvas_container = nil

    if self.footer then self.footer:free() end
    if self.title_bar then self.title_bar:free() end

    UIManager:setDirty(nil, function()
        return "flashui", self.main_frame.dimen
    end)
end

function KamareImageViewer:_getRotationAngle()
    return self.rotated and 90 or 0
end

function KamareImageViewer:onImageLoadError(pageno, error_msg)
    -- Only show error toast once per page to avoid spamming
    if self._failed_image_loads[pageno] then
        return
    end

    self._failed_image_loads[pageno] = true

    logger.warn("KamareImageViewer: Image load error", "page", pageno, "error", error_msg)

    UIManager:show(InfoMessage:new{
        text = T(_("Cannot load image on page %1"), pageno),
        timeout = 3,
    })
end

function KamareImageViewer:toggleTitleBar()
    self.title_bar_visible = not self.title_bar_visible
    self:update()
end

function KamareImageViewer:onSetRotationLock(locked)
    self.rotation_locked = locked
    self.configurable.rotation_lock = locked
    self:syncAndSaveSettings()

    if locked then
        logger.info("KamareImageViewer: Rotation locked at mode", Screen:getRotationMode())
    else
        logger.info("KamareImageViewer: Rotation unlocked")
    end
    return true
end

function KamareImageViewer:onSetRotationMode(mode)
    -- If rotation is locked, ignore rotation change events
    if self.rotation_locked then
        logger.info("KamareImageViewer: Rotation locked, ignoring rotation mode change")
        return true  -- consume the event
    end

    local old_mode = Screen:getRotationMode()
    if mode ~= nil and mode ~= old_mode then
        logger.info("KamareImageViewer: Rotation mode changed from", old_mode, "to", mode)
        Screen:setRotationMode(mode)
        self:handleRotation(mode, old_mode)
    end
end

function KamareImageViewer:handleRotation(mode, old_mode)
    local matching_orientation = bit.band(mode, 1) == bit.band(old_mode, 1)

    if matching_orientation then
        UIManager:setDirty(self, "full")
    else
        UIManager:setDirty(nil, "full")
        local new_screen_size = Screen:getSize()

        self.region = Geom:new{ x = 0, y = 0, w = new_screen_size.w, h = new_screen_size.h }

        if self[1] then
            self[1].dimen = self.region
        end

        self:_updateDimensions()

        if self.title_bar then
            self.title_bar:free()
            self:setupTitleBar()
        end

        if self.footer then
            self.footer:free()
            if self.virtual_document and self._images_list_nb > 1 then
                self.footer = KamareFooter:new{
                    settings = self.footer_settings,
                }
            end
        end

        if self.canvas_container then
            self.canvas_container.dimen = Geom:new{ w = self.width, h = self.height }
        end

        self._pending_scroll_page = self._images_list_cur

        if self.canvas then
            self.canvas._layout_dirty = true
        end

        -- Re-initialize gesture listeners after dimensions are updated
        self:initConfigGesListener()

        self:update()
    end
end

return KamareImageViewer
