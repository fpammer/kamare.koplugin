local Device = require("device")
local KamareFooter = require("kamarefooter")
local MD5 = require("ffi/sha2").md5
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local FrontlightWidget = require("ui/widget/frontlightwidget")
local Screen = Device.screen
local logger = require("logger")
local time = require("ui/time")
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
local AsyncFetch = require("kamareasyncfetch")
local InfoMessage = require("ui/widget/infomessage")
local FFIUtil = require("ffi/util")
local _ = require("gettext")
local Utils = require("kamareutils")
local T = FFIUtil.template

-- Prefetch budget fraction of VIDCache. Active viewport tiles + cached-ahead
-- pages + newly prefetched pages are kept under cache_size * BUDGET_FRACTION
-- (with a small safety margin) so on-screen tiles aren't evicted by the LRU
-- while the user is still looking at them. See calculateAdaptivePrefetch.
local BUDGET_FRACTION = 0.75
local BUDGET_SAFETY_MARGIN_BYTES = 2 * 1024 * 1024  -- 2 MB slack for backscroll / rounding

-- Adaptive-network tuning. The estimator keeps a ring of recent fetch
-- outcomes; prefetch depth shrinks and speculative prefetch pauses as the
-- link degrades, and transient failures are retried instead of permanently
-- blacklisting a page. See _recordNetSample / _netErrRate / _netBw.
local NET_SAMPLE_WINDOW     = 8      -- recent fetch outcomes retained
local NET_PAUSE_ERR_RATE    = 0.50   -- >= this recent failure rate -> pause prefetch
local NET_PAUSE_MIN_SAMPLES = 3      -- don't pause before we have this many samples
local NET_BW_FACTOR_FLOOR   = 0.15   -- never starve the immediate-next-page prefetch
-- Adaptive-prefetch tier maps. _netTier() classifies the link 3 (fast/clean)
-- .. 0 (poor); these map each tier to a depth multiplier and a lookahead cap.
local NET_BW_FACTOR_BY_TIER = { [3] = 1.0, [2] = 0.6, [1] = 0.3, [0] = NET_BW_FACTOR_FLOOR }
local NET_LOOKAHEAD_BY_TIER = { [3] = 64,  [2] = 6,   [1] = 3,   [0] = 2 }
-- Transient-failure retry: up to N attempts with this exponential backoff (s).
local NET_RETRY_MAX       = 3
local NET_RETRY_BACKOFF_S = { 1, 2, 4 }

-- Position-aware eviction: pages retained behind the reader for cheap
-- scroll-back. Eviction prefers far-behind pages (then far-ahead) over the
-- near read-ahead window; this keep-zone protects the immediate back-pages.
local EVICT_BEHIND_KEEP   = 2

-- Classify a fetch failure. 4xx responses mean the page genuinely won't be
-- served (auth/missing/etc) -> permanent, don't retry. Everything else
-- (timeouts, truncation, connect/handshake/send errors, 5xx, empty body) is
-- transient on a flaky link and worth retrying with backoff.
local function isPermanentFetchFailure(code)
    if code and code >= 400 and code < 500 then
        return true
    end
    return false
end

local KamareImageViewer = InputContainer:extend{
    images_list_data = nil,
    images_list_nb = nil,

    fullscreen = true,
    width = nil,
    height = nil,
    title = "",
    canvas = nil,
    canvas_container = nil,
    _images_list_cur = 1,

    on_close_callback = nil,
    start_page = 1,

    configurable = Configurable:new(),
    options = KamareOptions,
    prefetch_pages = 1,
    page_gap_height = 8,

    virtual_document = nil,
    view_mode = 0, -- 0: page, 1: continuous, 2: dual
    page_direction = 0, -- 0: LTR, 1: RTL
    scroll_offset = 0,
    current_zoom = 1.0,
    zoom_mode = 0, -- "full"
    _pending_scroll_page = nil,
    _pending_scroll_anchor = nil, -- { page = N, frac = 0..1 } for rotation continuity

    scroll_distance = 25, -- percentage (25, 50, 75, 100)
    h_margin = 0, -- left/right viewport margin
    top_margin = 0, -- top viewport margin
    bottom_margin = 0, -- bottom viewport margin
    dual_page_gap = 5, -- gap between side-by-side pages in dual page mode
    background_color = 1, -- 0 = black, 1 = white

    chapter_end_behavior = 1, -- 0 = stop at end, 1 = ask to continue, 2 = continue without asking
    contrast = 1.0,

    saturation = 1.0,

    -- Async page-pipeline state. `_prefetch_gen` is bumped to cancel in-flight
    -- fetches on chapter change / close; `_fetch_handles` maps page -> fetch
    -- handle (so close can abort every live fetch); `_prefetch_chain_active`
    -- prevents overlapping prefetch chains; `_page_fetch_inflight` /
    -- `_page_fetch_failed` dedup and remember per-page fetch outcomes.
    _prefetch_gen = 0,
    _prefetch_chain_active = false,
    _fetch_handles = nil,
    _page_fetch_inflight = nil,
    _page_fetch_failed = nil,
    _page_fetch_retries = nil, -- transient-failure retry count per page
    _pending_repaint_pages = nil,

    -- Adaptive-network estimator: a ring of recent fetch outcomes drives the
    -- prefetch depth, the >=50%-error pause, and visible-page preemption. See
    -- _recordNetSample / _netErrRate / _netBw.
    _net_samples = nil,
    _net_prefetch_paused = false,

    -- Async progress-POST pipeline state. The debounced POST runs through
    -- AsyncFetch so it doesn't block the UI; `_inflight` + `_pending` form a
    -- cooperative guard that prevents overlapping POSTs from landing out of
    -- order on the server. `_handle` lets the close path cancel an in-flight
    -- POST so the sync close POST is the last word.
    _progress_post_inflight = false,
    _progress_post_pending = false,
    _progress_post_handle = nil,

    _failed_image_loads = {}, -- Track failed image pages to show error toast
    _pending_page_direction = nil, -- true=forward(top), false=backward(bottom), nil=no reposition

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

-- Singleton guard
KamareImageViewer.active_instance = nil

function KamareImageViewer:init()
    if KamareImageViewer.active_instance then
        logger.warn("KamareImageViewer: instance already active, refusing duplicate")
        self._aborted = true
        return
    end

    self:loadSettings()

    self._page_turns_since_open = 0

    if self.override_view_mode ~= nil then
        local override_mode = self.override_view_mode
        self.view_mode = override_mode
        self.configurable.view_mode = override_mode

        if override_mode == 1 then
            -- Continuous mode: use fit-width zoom
            self.zoom_mode = 1
            self.configurable.zoom_mode_type = 1
        elseif override_mode == 0 and self.zoom_mode == 1 then
            -- Page mode: if zoom was fit-width, change to fit-page
            self.zoom_mode = 0
            self.configurable.zoom_mode_type = 0
        end

        self:syncAndSaveSettings()
    end

    if self.fullscreen then
        self.covers_fullscreen = true
    end

    self.image_viewing_times = {}
    self.current_image_start_time = os.time()
    self.title_bar_visible = false
    self._failed_image_loads = {}
    self._reached_end = false

    self.initial_rotation_mode = Screen:getRotationMode()

    if not CanvasContext.device then
        CanvasContext:init(Device)
    end

    self:_initDocument()
    self:_initCanvas()
    self:_setupStatisticsInterface()

    self.align = "left"
    self.region = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    self:_updateDimensions()

    self:registerKeyEvents()
    self:setupTitleBar()
    self:initConfigGesListener()

    self.frame_elements = VerticalGroup:new{ align = "left" }

    self.main_frame = FrameContainer:new{
        radius = not self.fullscreen and 8 or nil,
        bordersize = 0,
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
    else
        self._pending_page_direction = true
    end

    if self.virtual_document and self._images_list_nb > 1 then
        self.footer = KamareFooter:new{
            settings = self.footer_settings,
        }
    end

    KamareImageViewer.active_instance = self

    self:update()

    UIManager:nextTick(function()
        self:_postViewProgress()

        if self.ui and self.ui.statistics and self.doc_settings then
            self.ui.statistics:onReaderReady(self.doc_settings)
        end

        -- Fill initial prefetch buffer after UI is ready
        self:_initialPrefetchBuffer()
    end)
end

function KamareImageViewer:_initDocument()
    if not self.images_list_data then
        logger.err("KamareImageViewer: No images_list_data provided. Displaying empty screen.")
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
        content_type = self.metadata and self.metadata.content_type or "auto",
        on_image_load_error = function(pageno, error_msg)
            self:onImageLoadError(pageno, error_msg)
        end,
    }

    if not self.virtual_document.is_open then
        logger.err("KamareImageViewer: Failed to initialize VirtualImageDocument. Displaying empty screen.")
    end

    self.virtual_document.gamma = self.contrast or 1.0
    self.virtual_document.saturation = self.saturation or 1.0

    self:_updatePageCount()
    self._images_list_cur = Math.clamp((self.metadata and self.metadata.startPage) or 1, 1, self._images_list_nb)

    -- Fresh per-chapter fetch/network state: reset so a page marked
    -- failed/inflight in one chapter can't leak into the next.
    self._page_fetch_inflight    = {}
    self._page_fetch_failed     = {}
    self._page_fetch_retries    = {}
    self._fetch_handles         = {}
    self._pending_repaint_pages = {}
    self._net_samples           = {}
    self._net_prefetch_paused   = false
end

function KamareImageViewer:_initCanvas()
    local bg_color = self.background_color == 1 and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    self.canvas = VirtualPageCanvas:new{
        document = self.virtual_document,
        h_margin = self.h_margin,
        top_margin = self.top_margin,
        bottom_margin = self.bottom_margin,
        dual_page_gap = self.dual_page_gap,
        background = bg_color,
        view_mode = self.view_mode,
        page_direction = self.page_direction,
        page_gap_height = self.page_gap_height,
        render_quality = self.render_quality or -1,
    }

    self.canvas_container = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        self.canvas,
    }

    -- Wire the render-path "pending" callback: when the canvas paints a page
    -- whose image isn't cached yet, request it async; on arrival a setDirty
    -- repaint renders the real page where the placeholder glyph was.
    self.canvas.on_pending_page = function(page) self:_onPendingRenderPage(page) end

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
        title = Utils.resolveTitle(self.metadata, self.title),
        authors = self.metadata and self.metadata.author or "",
        series = self.metadata and Utils.firstNonEmpty(self.metadata.seriesName) or "",
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
        title = Utils.resolveTitle(self.metadata, self.title),
        display_title = Utils.resolveTitle(self.metadata, self.title),
        authors = self.metadata and self.metadata.author or "",
        series = self.metadata and Utils.firstNonEmpty(self.metadata.seriesName) or "",
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
    -- expose getCurrentPage to allow screenshoter to work
    self.ui.getCurrentPage = function() return viewer_ref._images_list_cur end
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
    self.configurable.dual_page_gap = self.dual_page_gap
    self.configurable.scroll_distance = self.scroll_distance
    self.configurable.h_margin = self.h_margin
    self.configurable.top_margin = self.top_margin
    self.configurable.bottom_margin = self.bottom_margin
    self.configurable.render_quality = self.render_quality or -1
    self.configurable.contrast = self.contrast or 1.0
    self.configurable.color_boost = self.saturation or 1.0
    self.configurable.background_color = self.background_color
    self.configurable.rotation_lock = false
    self.configurable.chapter_end_behavior = self.chapter_end_behavior

    self.configurable:loadSettings(self.kamare_settings, self.options.prefix .. "_")

    self.footer_settings.mode = self.configurable.footer_mode
    self.prefetch_pages = self.configurable.prefetch_pages or 1
    self.view_mode = self.configurable.view_mode or 0
    self.page_direction = self.configurable.page_direction or 0
    self.zoom_mode = self.configurable.zoom_mode_type or 0
    self.page_gap_height = self.configurable.page_gap_height or 8
    self.scroll_distance = self.configurable.scroll_distance or 25
    self.h_margin = self.configurable.h_margin or 0
    self.top_margin = self.configurable.top_margin or 0
    self.bottom_margin = self.configurable.bottom_margin or 0
    self.dual_page_gap = self.configurable.dual_page_gap or 5
    self.render_quality = self.configurable.render_quality or -1
    self.contrast = self.configurable.contrast or 1.0
    self.saturation = self.configurable.color_boost or 1.0
    self.background_color = self.configurable.background_color or 1
    self.rotation_locked = self.configurable.rotation_lock or false
    self.chapter_end_behavior = self.configurable.chapter_end_behavior or 1

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
    self.configurable.dual_page_gap = self.dual_page_gap
    self.configurable.scroll_distance = self.scroll_distance
    self.configurable.h_margin = self.h_margin
    self.configurable.top_margin = self.top_margin
    self.configurable.bottom_margin = self.bottom_margin
    self.configurable.render_quality = self.render_quality
    self.configurable.contrast = self.contrast
    self.configurable.color_boost = self.saturation
    self.configurable.background_color = self.background_color
    self.configurable.rotation_lock = self.rotation_locked
    self.configurable.chapter_end_behavior = self.chapter_end_behavior

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
        self._pending_page_direction = true
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
    local title
    local subtitle

    if self.metadata then
        title = Utils.firstNonEmpty(
            self.metadata.seriesName,
            self.metadata.localizedName,
            self.metadata.originalName,
            self.title,
            _("Images")
        )
        if self.metadata.author then
            subtitle = T(_("by %1"), self.metadata.author)
        end
    else
        title = self.title or _("Images")
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
        local total = self.virtual_document:getVirtualHeight(zoom, self.zoom_mode, viewport_w, self.page_gap_height)
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

    local time_estimate
    -- The dual-page "remaining" loop below is O(remaining) per call, which
    -- is wasteful when the active footer mode doesn't display time-to-read.
    -- Only compute it (and the estimate) when actually needed.
    if self.footer and self.footer:getMode() == KamareFooter.MODE.book_time_to_read then
        local remaining = total_pages - display_page
        if self.view_mode == 2 and self.virtual_document then
            for p = display_page + 1, total_pages do
                local _, p_right = self.canvas:getDualPagePair(p)
                if p_right == -1 then
                    remaining = remaining + 1  -- Landscape counts as 2 pages
                end
            end
        end
        time_estimate = self:getTimeEstimate(remaining)
    else
        time_estimate = _("N/A")
    end

    local footer_state = {
        current_page = display_page,
        total_pages = total_pages,
        has_document = self.virtual_document ~= nil,
        is_scroll_mode = (self.view_mode == 1) or false,
        scroll_progress = scroll_progress,
        time_estimate = time_estimate,
        is_rtl_mode = (self.page_direction == 1) or false,
        -- Live reference to the document's fully-cached page set; the footer
        -- reads this to paint the prefetched-pages overlay on the progress bar.
        cached_pages = self.virtual_document and self.virtual_document._fully_cached_pages or nil,
    }

    return footer_state
end

function KamareImageViewer:updateFooter()
    if not self.footer then return end
    -- Coalesce multiple calls within the same UI tick. Rapid scrolling can
    -- fire updateFooter many times in quick succession; only the latest
    -- state needs to reach the footer. The pending flag deduplicates, and
    -- the callback reference is kept so onCloseWidget can unschedule it.
    if self._footer_update_pending then return end
    if not self._footer_update_func then
        self._footer_update_func = function()
            self._footer_update_pending = false
            if not self.footer then return end
            if self.footer:update(self:getFooterState()) then
                UIManager:setDirty(self, "ui", self.footer:getWidget().dimen)
            end
        end
    end
    self._footer_update_pending = true
    UIManager:nextTick(self._footer_update_func)
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
    local old_visibility = self.footer:isVisible()
    self.footer:setMode(mode)
    local new_visibility = self.footer:isVisible()
    self:syncAndSaveSettings()

    if old_visibility ~= new_visibility then
        self:update()
    else
        self:updateFooter()
    end
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
    self.configurable.dual_page_gap = self.dual_page_gap
    self.configurable.scroll_distance = self.scroll_distance
    self.configurable.h_margin = self.h_margin
    self.configurable.top_margin = self.top_margin
    self.configurable.bottom_margin = self.bottom_margin
    self.configurable.background_color = self.background_color
    self.configurable.rotation_lock = self.rotation_locked
    self.configurable.chapter_end_behavior = self.chapter_end_behavior

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
            self._pending_page_direction = true
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

    if self.configurable.h_margin ~= nil and self.configurable.h_margin ~= self.h_margin then
        self.h_margin = self.configurable.h_margin
        if self.canvas then
            self.canvas:setHMargin(self.h_margin)
        end
        needs_update = true
    end

    if self.configurable.top_margin ~= nil and self.configurable.top_margin ~= self.top_margin then
        self.top_margin = self.configurable.top_margin
        if self.canvas then
            self.canvas:setTopMargin(self.top_margin)
        end
        needs_update = true
    end

    if self.configurable.bottom_margin ~= nil and self.configurable.bottom_margin ~= self.bottom_margin then
        self.bottom_margin = self.configurable.bottom_margin
        if self.canvas then
            self.canvas:setBottomMargin(self.bottom_margin)
        end
        needs_update = true
    end

    if self.configurable.dual_page_gap ~= nil and self.configurable.dual_page_gap ~= self.dual_page_gap then
        self.dual_page_gap = self.configurable.dual_page_gap
        if self.canvas then
            self.canvas:setDualPageGap(self.dual_page_gap)
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

    n = Math.clamp(n, 0, 1)

    if n == self.prefetch_pages then return true end

    self.prefetch_pages = n
    self.configurable.prefetch_pages = n
    self:syncAndSaveSettings()

    if n == 1 then
        UIManager:tickAfterNext(function() self:prefetchUpcomingTiles() end)
    end
    return true
end

function KamareImageViewer:onSetRenderQuality(quality)
    local q = tonumber(quality)
    if not q then return false end
    if q == self.render_quality then return true end

    self.render_quality = q
    self.configurable.render_quality = q
    self:syncAndSaveSettings()

    -- render_quality lives on the canvas (projection concern).
    -- Tiles are keyed by render_quality, so a change invalidates them.
    if self.canvas then
        self.canvas:setRenderQuality(q)
    end
    if self.virtual_document then
        self.virtual_document:clearCache()
    end

    return true
end

function KamareImageViewer:onSetContrast(value)
    local v = tonumber(value)
    if not v then return false end
    if v == self.contrast then return true end

    self.contrast = v
    self.configurable.contrast = v
    self:syncAndSaveSettings()

    if self.virtual_document then
        self.virtual_document.gamma = v
        self.virtual_document:clearCache()
    end

    return true
end

function KamareImageViewer:onSetColorBoost(value)
    local v = tonumber(value)
    if not v then return false end
    if v == self.saturation then return true end

    self.saturation = v
    self.configurable.color_boost = v
    self:syncAndSaveSettings()

    if self.virtual_document then
        self.virtual_document.saturation = v
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
    self._pending_page_direction = true

    if self.virtual_document then
        self.virtual_document:clearCache()
    end

    self:_updatePageCount()

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

function KamareImageViewer:onHMarginUpdate(value)
    local margin = tonumber(value)
    if not margin then return false end
    margin = math.max(0, margin)
    if margin == self.h_margin then return true end

    self.h_margin = margin
    self.configurable.h_margin = margin
    self:syncAndSaveSettings()

    if self.canvas then
        self.canvas:setHMargin(margin)
    end

    self._pending_scroll_page = self._images_list_cur
    self:update()

    return true
end

function KamareImageViewer:onTopMarginUpdate(value)
    local margin = tonumber(value)
    if not margin then return false end
    margin = math.max(0, margin)
    if margin == self.top_margin then return true end

    self.top_margin = margin
    self.configurable.top_margin = margin
    self:syncAndSaveSettings()

    if self.canvas then
        self.canvas:setTopMargin(margin)
    end

    self._pending_scroll_page = self._images_list_cur
    self:update()

    return true
end

function KamareImageViewer:onBottomMarginUpdate(value)
    local margin = tonumber(value)
    if not margin then return false end
    margin = math.max(0, margin)
    if margin == self.bottom_margin then return true end

    self.bottom_margin = margin
    self.configurable.bottom_margin = margin
    self:syncAndSaveSettings()

    if self.canvas then
        self.canvas:setBottomMargin(margin)
    end

    self._pending_scroll_page = self._images_list_cur
    self:update()

    return true
end

function KamareImageViewer:onDualPageGapUpdate(value)
    local gap = tonumber(value)
    if not gap then return false end
    gap = math.max(0, gap)
    if gap == self.dual_page_gap then return true end

    self.dual_page_gap = gap
    self.configurable.dual_page_gap = gap
    self:syncAndSaveSettings()

    if self.canvas then
        self.canvas:setDualPageGap(gap)
    end

    if self.view_mode == 2 then
        self:update()
    end

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

function KamareImageViewer:onShowFrontlight()
    UIManager:show(FrontlightWidget:new {})
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

            UIManager:setDirty(self, "partial", self.canvas.dimen)
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
    local total = self.virtual_document:getVirtualHeight(zoom, self.zoom_mode, viewport_w, self.page_gap_height) or 0
    local offset = self.scroll_offset or 0

    logger.dbg(string.format("[kamare:scroll] step dir=%d page=%d offset=%d/%d zoom=%.3f",
        direction, self._images_list_cur or -1, math.floor(offset), math.floor(math.max(0, total - viewport_h)), zoom))

    if direction > 0 then
        local max_offset = math.max(0, total - viewport_h)
        local at_end = math.abs(offset - max_offset) < 1

        if at_end then
            if self._reached_end then
                self:_checkAndOfferNextChapter()
            else
                self._reached_end = true
            end
        else
            self:_scrollBy(step)
        end
        return true
    elseif direction < 0 then
        self._reached_end = false

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
    local offset = self.virtual_document:getScrollPositionForPage(page, zoom, self.zoom_mode, viewport_w, self.page_gap_height)

    self:_setScrollOffset(offset, { silent = true })
    self:_updatePageFromScroll(true)
    self:updateFooter()
end

function KamareImageViewer:_updatePageFromScroll(silent)
    if self.view_mode ~= 1 or not self.virtual_document then return end

    local zoom = self:getCurrentZoom()
    local viewport_w, viewport_h = self.canvas and self.canvas:getViewportSize() or 0, 0
    local check_offset = (self.scroll_offset or 0) + viewport_h
    local new_page = self.virtual_document:getPageAtOffset(check_offset, zoom, self.zoom_mode, viewport_w, self.page_gap_height)

    local max_offset = self.canvas and self.canvas:getMaxScrollOffset() or 0
    local at_max = math.abs((self.scroll_offset or 0) - max_offset) < 1

    if at_max and max_offset > 0 then
        new_page = self._images_list_nb
    end

    local should_prefetch = false

    if self._images_list_cur < self._images_list_nb then
        local current_page_start = self.virtual_document:getScrollPositionForPage(self._images_list_cur, zoom, self.zoom_mode, viewport_w, self.page_gap_height)
        local next_page_start = self.virtual_document:getScrollPositionForPage(self._images_list_cur + 1, zoom, self.zoom_mode, viewport_w, self.page_gap_height)
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
        logger.dbg(string.format("[kamare:scroll] page %d -> %d (trigger prefetch)", self._images_list_cur or -1, new_page))
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
        logger.dbg(string.format("[kamare:scroll] mid-page prefetch triggered at page %d (progress-based)", self._images_list_cur))
        UIManager:tickAfterNext(function() self:prefetchUpcomingTiles() end)
    end

    self:_updateReaderContext()
end

function KamareImageViewer:_updateCanvasState()
    if not (self.canvas and self.virtual_document) then return end

    local page = Math.clamp(self._images_list_cur or 1, 1, self._images_list_nb or 1)

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
        if self._pending_scroll_anchor then
            -- Resolve the page-anchored fractional position in the new layout.
            local anchor = self._pending_scroll_anchor
            local viewport_w = select(1, self.canvas:getViewportSize())
            local total_pages = self._images_list_nb or 0
            local page_start = self.virtual_document:getScrollPositionForPage(
                anchor.page, self.current_zoom, self.zoom_mode, viewport_w, self.page_gap_height)
            local next_start
            if anchor.page >= total_pages then
                next_start = self.virtual_document:getVirtualHeight(
                    self.current_zoom, self.zoom_mode, viewport_w, self.page_gap_height)
            else
                next_start = self.virtual_document:getScrollPositionForPage(
                    anchor.page + 1, self.current_zoom, self.zoom_mode, viewport_w, self.page_gap_height)
            end
            desired = math.floor(page_start + anchor.frac * (next_start - page_start) + 0.5)
            self._pending_scroll_anchor = nil
            self._pending_scroll_page = nil
        elseif self._pending_scroll_page then
            local viewport_w = select(1, self.canvas:getViewportSize())
            desired = self.virtual_document:getScrollPositionForPage(self._pending_scroll_page, self.current_zoom, self.zoom_mode, viewport_w, self.page_gap_height)
            self._pending_scroll_page = nil
        end
        desired = self:_clampScrollOffset(desired)
        self.scroll_offset = desired
        self.canvas:setScrollOffset(desired)
        self:_updatePageFromScroll(true)
        self:updateFooter()
    else
        self.scroll_offset = 0
        if self._pending_page_direction ~= nil then
            self:_applyPagePosition(page, self._pending_page_direction)
            self._pending_page_direction = nil
        elseif self.zoom_mode == 0 then
            self.canvas:setCenter(0.5, 0.5)
        end
        self:updateFooter()
    end

    self:_updateReaderContext()
end

-- The set of pages currently intersecting the viewport (single page in page
-- mode, the spread in dual mode, every straddling page in scroll mode).
-- Shared by the cache-protection update and the prefetch visible-preemption
-- gate so they never disagree about what "visible" means.
function KamareImageViewer:_currentVisiblePages()
    if not self.virtual_document then return {} end

    local pages = {}
    if self.view_mode == 1 then
        if self.canvas then
            local zoom = self:getCurrentZoom()
            local viewport_w, viewport_h = self.canvas:getViewportSize()
            if viewport_h > 0 then
                local visible = self.virtual_document:getVisiblePagesAtOffset(
                    self.scroll_offset or 0, viewport_h, zoom, self.zoom_mode,
                    viewport_w, self.page_gap_height) or {}
                for _, vi in ipairs(visible) do
                    if vi.page_num then
                        pages[#pages + 1] = vi.page_num
                    end
                end
            end
        end
    elseif self.view_mode == 2 then
        if self.canvas then
            local lp, rp = self.canvas:getDualPagePair(self._images_list_cur or 1)
            if lp and lp > 0 then
                pages[#pages + 1] = lp
            end
            if rp and rp > 0 then
                pages[#pages + 1] = rp
            end
        end
    else
        local p = self._images_list_cur
        if p and p > 0 then
            pages[#pages + 1] = p
        end
    end
    return pages
end

-- Push the reader's current position to VIDCache so its eviction is
-- position-aware (behind-the-reader pages and stale other-chapter tiles are
-- evicted before the read-ahead window). `current_page` is the last visible
-- page, matching calculateAdaptivePrefetch's notion of the read anchor.
-- Call this on layout changes (scroll/zoom/page-turn) and at the top of each
-- prefetch step so the policy tracks the live reader position.
function KamareImageViewer:_updateReaderContext()
    if not (self.virtual_document and VIDCache) then return end
    local visible = self:_currentVisiblePages()
    local cur = 0
    local vis_set = {}
    for _, p in ipairs(visible) do
        if p and p > 0 then
            vis_set[p] = true
            if p > cur then cur = p end
        end
    end
    if cur == 0 then
        cur = self._images_list_cur or 1
    end
    VIDCache:setReaderContext({
        doc_path      = self.virtual_document.file,
        current_page  = cur,
        visible_pages = vis_set,
        behind_keep   = EVICT_BEHIND_KEEP,
    })
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

    UIManager:setDirty(self, "partial", self.canvas.dimen)
end

-- Estimated encoded size (bytes) of a page's full tile set at its current
-- render resolution, or 0 if dims aren't available yet.
function KamareImageViewer:_estimatePageBytes(page)
    local native_dims = self.virtual_document:getNativePageDimensions(page)
    if native_dims and native_dims.w > 0 and native_dims.h > 0 then
        local rw, rh = self.canvas:_renderDimsFor(native_dims.w, native_dims.h)
        return self.virtual_document:estimateBytesForPage(page, rw, rh)
    end
    return 0
end

function KamareImageViewer:calculateAdaptivePrefetch()
    if not (self.virtual_document and self.canvas) then return {} end

    local zoom = self:getCurrentZoom()
    local current_page = self._images_list_cur
    local visible = {}

    if self.view_mode == 1 then
        local viewport_w, viewport_h = self.canvas:getViewportSize()
        visible = self.virtual_document:getVisiblePagesAtOffset(
            self.scroll_offset or 0, viewport_h, zoom, self.zoom_mode, viewport_w,
            self.page_gap_height) or {}
        if #visible > 0 then
            current_page = visible[#visible].page_num
        end
    end

    local next_page = current_page + 1
    if next_page > self._images_list_nb then
        logger.dbg(string.format("[kamare:prefetch] decision cur=%d no-next-page (last page)", current_page))
        return {}
    end

    -- Network-quality gate: when recent fetches are failing >= half the time,
    -- stop speculating entirely -- the visible page still loads via the render
    -- path, and we avoid wasting bytes (and contending the flaky pipe) on pages
    -- the user may never reach. Clears as soon as fresh successes age out the
    -- failures; the next scroll/page-turn re-kicks the chain.
    if self:_netSampleCount() >= NET_PAUSE_MIN_SAMPLES
       and self:_netErrRate() >= NET_PAUSE_ERR_RATE then
        if not self._net_prefetch_paused then
            self._net_prefetch_paused = true
            logger.dbg(string.format(
                "[kamare:net] err_rate=%.0f%% >= %d%% -> prefetch paused (bw=%.0fKB/s)",
                self:_netErrRate() * 100, NET_PAUSE_ERR_RATE * 100, self:_netBw() / 1024))
        end
        return {}
    end
    if self._net_prefetch_paused then
        self._net_prefetch_paused = false
        logger.dbg("[kamare:net] link recovered -> prefetch resumed")
    end

    -- Adaptive depth: scale the byte budget by measured throughput/error rate,
    -- and tighten how far ahead we look. Fast+clean links keep the full budget;
    -- slow/flaky links shrink toward a floor (still warming the immediate next
    -- page) and stop scanning distant pages.
    local bw_factor = self:_netBwFactor()
    local lookahead_cap = self:_netLookaheadCap()

    -- Byte-accurate budget derived from the known virtual page layout.
    -- Active reserve = bytes for the currently-visible tile slices (not whole
    -- pages), so that very long webtoon images don't reserve their entire
    -- 30-tile page just because a single tile row is on screen. Without this,
    -- prefetch + active demand exceeds the cache cap, the LRU evicts the
    -- oldest (active!) tiles, and scroll-back forces a synchronous full-page
    -- regen via _preSplitPageTiles.
    local cache_bytes = VIDCache:getCacheSize()
    local budget_bytes = math.floor(cache_bytes * BUDGET_FRACTION)
                          - BUDGET_SAFETY_MARGIN_BYTES
    if budget_bytes < 0 then budget_bytes = 0 end

    -- Active reserve: sum bytes for the on-screen slice of each visible page.
    local active_bytes = 0
    if self.view_mode == 1 then
        for _, v in ipairs(visible) do
            local native_dims = self.virtual_document:getNativePageDimensions(v.page_num)
            if native_dims and native_dims.w > 0 and native_dims.h > 0
                and v.zoom and v.zoom > 0
                and v.visible_bottom > v.visible_top then
                local render_w, render_h = self.canvas:_renderDimsFor(native_dims.w, native_dims.h)
                -- Convert visible slice from display coords to render coords.
                -- v.zoom is the per-page display zoom (native -> display).
                local render_scale = render_w / native_dims.w
                local display_to_render = render_scale / v.zoom
                local display_top    = v.visible_top    - v.page_top
                local display_bottom = v.visible_bottom - v.page_top
                local render_y0 = math.max(0, math.floor(display_top * display_to_render))
                local render_y1 = math.min(render_h, math.ceil(display_bottom * display_to_render))
                if render_y1 > render_y0 then
                    local rect = Geom:new{
                        x = 0, y = render_y0,
                        w = render_w, h = render_y1 - render_y0,
                    }
                    active_bytes = active_bytes +
                        self.virtual_document:estimateBytesForRect(v.page_num, rect, render_w, render_h)
                end
            end
        end
    else
        -- Page / dual page: the current page's full tile set is on screen.
        active_bytes = self:_estimatePageBytes(current_page)
    end

    local budget_after_active = budget_bytes - active_bytes
    if budget_after_active < 0 then budget_after_active = 0 end

    -- Page-mode ramp-up: throttles prefetch depth for the first few page
    -- turns to avoid spending RAM aggressively when the user might navigate
    -- away. Scroll mode uses the full budget (chunked async fetch is
    -- non-blocking, so there's no UI-freeze cost to aggressive prefetch).
    local target_bytes
    if self.view_mode == 1 then
        target_bytes = budget_after_active
    else
        local page_turns = self._page_turns_since_open or 0
        local ramp_fraction
        if     page_turns <= 2  then ramp_fraction = 0.10
        elseif page_turns <= 5  then ramp_fraction = 0.25
        elseif page_turns <= 10 then ramp_fraction = 0.50
        elseif page_turns <= 15 then ramp_fraction = 0.75
        else                          ramp_fraction = 1.00 end
        target_bytes = math.floor(budget_after_active * ramp_fraction)
    end

    -- Shrink the prefetch byte budget on slow/flaky links (bw_factor). The
    -- floor (NET_BW_FACTOR_FLOOR) still allows warming the immediate next page.
    target_bytes = math.floor(target_bytes * bw_factor)

    -- Contiguous fully-cached run starting from next_page. The buffer must
    -- stay contiguous; the first gap stops the run.
    local pages_cached_ahead = 0
    local bytes_cached_ahead = 0
    for i = 0, lookahead_cap - 1 do
        local check_page = next_page + i
        if check_page > self._images_list_nb then break end
        if not self.virtual_document:isPageFullyCached(check_page) then break end
        pages_cached_ahead = pages_cached_ahead + 1
        bytes_cached_ahead = bytes_cached_ahead + self:_estimatePageBytes(check_page)
    end

    local bytes_to_prefetch = target_bytes - bytes_cached_ahead
    if bytes_to_prefetch <= 0 then
        logger.dbg(string.format(
            "[kamare:prefetch] decision cur=%d buffer-satisfied budget=%dB active=%dB target=%dB cached_ahead(pages=%d bytes=%dB) [bw=%.0fKB/s err=%.0f%% factor=%.2f]",
            current_page, budget_bytes, active_bytes, target_bytes,
            pages_cached_ahead, bytes_cached_ahead,
            self:_netBw() / 1024, self:_netErrRate() * 100, bw_factor))
        return {}
    end

    -- Walk upcoming pages by cumulative bytes until the budget is exhausted.
    -- No force-include: if even one page exceeds the remaining budget, the
    -- buffer stays empty and the active reserve is prioritized (correct for
    -- very long webtoon pages where prefetch must yield to on-screen state).
    -- Inflight pages reserve bytes (they'll occupy the cache soon) but aren't
    -- re-requested. Failed pages are silently skipped.
    local SOFT_MAX_PAGES_PER_STEP = 4  -- bounds list size; chain fetches one page per step
    local pages_list = {}
    local accumulated_bytes = 0
    local start_page = next_page + pages_cached_ahead

    for i = 0, lookahead_cap - 1 do
        local page_num = start_page + i
        if page_num > self._images_list_nb then break end
        if #pages_list >= SOFT_MAX_PAGES_PER_STEP then break end

        local is_inflight = self._page_fetch_inflight[page_num]
        local is_failed   = self._page_fetch_failed[page_num]

        -- Permanently-broken pages are skipped silently and we keep scanning
        -- (re-trying a failed page would just spin).
        if not is_failed then
            local page_bytes = self:_estimatePageBytes(page_num)

            if accumulated_bytes + page_bytes > bytes_to_prefetch then
                break  -- would exceed budget
            end
            accumulated_bytes = accumulated_bytes + page_bytes

            if not is_inflight then
                table.insert(pages_list, page_num)
            end
            -- Inflight pages reserve bytes but aren't added (already being fetched).
        end
    end

    logger.dbg(string.format(
        "[kamare:prefetch] decision cur=%d budget=%dB active=%dB target=%dB cached_ahead(pages=%d bytes=%dB) want=%dB selected=[%s] [bw=%.0fKB/s err=%.0f%% factor=%.2f cap=%d]",
        current_page, budget_bytes, active_bytes, target_bytes,
        pages_cached_ahead, bytes_cached_ahead, bytes_to_prefetch,
        table.concat(pages_list, ","),
        self:_netBw() / 1024, self:_netErrRate() * 100, bw_factor, lookahead_cap))

    return pages_list
end

function KamareImageViewer:prefetchUpcomingTiles()
    if not self.virtual_document or self.prefetch_pages ~= 1 then
        return
    end

    -- Refresh the reader-position context before the chain starts inserting
    -- tiles, so position-aware eviction uses the live reader position.
    self:_updateReaderContext()

    local pages_to_prefetch = self:calculateAdaptivePrefetch()

    if #pages_to_prefetch == 0 then
        return
    end

    UIManager:tickAfterNext(function()
        self:kickPrefetchChain()
    end)
end

function KamareImageViewer:_initialPrefetchBuffer()
    if not self.virtual_document or self.prefetch_pages ~= 1 then
        return
    end

    local pages_to_prefetch = self:calculateAdaptivePrefetch()
    if #pages_to_prefetch == 0 then
        return
    end

    -- For initial load, only prefetch 1 page (or 2 in dual page mode) to avoid long waits
    local initial_limit = (self.view_mode == 2) and 2 or 1
    if #pages_to_prefetch > initial_limit then
        local limited_list = {}
        for i = 1, initial_limit do
            limited_list[i] = pages_to_prefetch[i]
        end
        pages_to_prefetch = limited_list
    end

    logger.dbg(string.format("[kamare:prefetch] initial pages=[%s]", table.concat(pages_to_prefetch, ",")))
    local gen = self._prefetch_gen
    local i = 1
    local function do_one()
        if i > #pages_to_prefetch then return end
        if gen ~= self._prefetch_gen or not self.virtual_document then return end
        local page = pages_to_prefetch[i]
        i = i + 1
        self:_ensurePageReady(page, gen, do_one)
    end
    do_one()
end

-- Adaptive-network estimator. A ring of the last NET_SAMPLE_WINDOW fetch
-- outcomes ({ok=bool, bw=bytes_per_sec}) drives prefetch depth, the error-rate
-- pause, and visible-page preemption. EWMA is deliberately avoided in favour
-- of an explicit window so the ">=50% recent failures" pause decision is
-- predictable and recovers as soon as fresh successes age the failures out.
function KamareImageViewer:_recordNetSample(ok, bw_Bps)
    self._net_samples = self._net_samples or {}
    local s = { ok = ok and true or false, bw = tonumber(bw_Bps) or 0 }
    table.insert(self._net_samples, s)
    -- trim to window (keep most recent)
    while #self._net_samples > NET_SAMPLE_WINDOW do
        table.remove(self._net_samples, 1)
    end
end

function KamareImageViewer:_netSampleCount()
    return self._net_samples and #self._net_samples or 0
end

-- Fraction of recent samples that failed. 0 when we have no samples.
function KamareImageViewer:_netErrRate()
    local samples = self._net_samples
    if not samples or #samples == 0 then return 0 end
    local fails = 0
    for _, s in ipairs(samples) do
        if not s.ok then fails = fails + 1 end
    end
    return fails / #samples
end

-- Mean throughput (bytes/sec) over recent *successful* samples. 0 if none.
function KamareImageViewer:_netBw()
    local samples = self._net_samples
    if not samples then return 0 end
    local sum, n = 0, 0
    for _, s in ipairs(samples) do
        if s.ok and s.bw > 0 then
            sum = sum + s.bw
            n = n + 1
        end
    end
    return n > 0 and (sum / n) or 0
end

-- Classify the current link into one of 4 tiers (3 = fast+clean .. 0 = poor)
-- from the shared throughput/error thresholds. No samples (fresh chapter) is
-- treated as top tier so the initial prefetch buffer is aggressive; we scale
-- down once real measurements show the link is slow or erroring.
function KamareImageViewer:_netTier()
    if self:_netSampleCount() == 0 then return 3 end
    local bw, err = self:_netBw(), self:_netErrRate()
    local KB = 1024
    if    bw >= 1024 * KB and err < 0.10 then return 3
    elseif bw >=  256 * KB and err < 0.25 then return 2
    elseif bw >=   64 * KB or  err < 0.50 then return 1
    else                                     return 0
    end
end

-- Prefetch depth multiplier (fast+clean links get the full budget; slow or
-- erroring links scale down toward the floor so the immediate-next page can
-- still be warmed without flooding a dropping pipe).
function KamareImageViewer:_netBwFactor()
    return NET_BW_FACTOR_BY_TIER[self:_netTier()]
end

-- Lookahead horizon (max pages ahead to scan/prefetch), tightened on poor
-- links so we don't commit bytes to pages the user may never reach.
function KamareImageViewer:_netLookaheadCap()
    return NET_LOOKAHEAD_BY_TIER[self:_netTier()]
end

-- Adaptive total fetch timeout. On a healthy measured link we can afford to
-- fail fast (a stall is real, hand off to retry); on an unknown/slow link keep
-- it generous so a legit large page isn't aborted. Bounded to [15, 60]s.
function KamareImageViewer:_fetchTimeoutSec()
    local bw = self:_netBw()
    if bw <= 0 then
        return 60 -- unknown link: keep the historic default
    end
    local t = (4 * 1024 * 1024) / bw + 5
    return math.min(60, math.max(15, math.floor(t)))
end

-- Core of the async page pipeline (shared by prefetch and the render path):
-- make sure page `page` has a rendered tile set, fetching its image via the
-- non-blocking client if needed. Dedups concurrent requests for the same page
-- (_page_fetch_inflight) and remembers failures (_page_fetch_failed) so a
-- broken page doesn't re-trigger on every paint. Transient failures (timeout,
-- truncation, 5xx, connect/handshake errors) are retried with exponential
-- backoff instead of permanently blacklisting the page. The retry budget
-- depends on visibility: an OFF-SCREEN (prefetch) page gives up after
-- NET_RETRY_MAX attempts; a VISIBLE page (render-path placeholder, or one that
-- scrolled into view mid-fetch) keeps retrying until it succeeds, since giving
-- up would leave the pending placeholder stuck on screen. Only 4xx responses
-- (server definitively won't serve the page) and the off-screen retry budget
-- being exhausted mark the page failed. `gen` is the generation token; stale
-- results (chapter change / close) are discarded. `on_done()` is always called
-- once (after the final outcome, including all retries).
function KamareImageViewer:_ensurePageReady(page, gen, on_done, repaint)
    on_done = on_done or function() end

    if not self.virtual_document or gen ~= self._prefetch_gen then
        on_done(); return
    end
    if self._page_fetch_failed[page] then
        logger.dbg(string.format("[kamare:render] page=%d ensure skip (failed)", page))
        on_done(); return
    end
    if self._page_fetch_inflight[page] then
        logger.dbg(string.format("[kamare:render] page=%d ensure skip (inflight)", page))
        -- Another caller is fetching this page. If we were asked to repaint
        -- (render path / visible placeholder), remember that so the in-flight
        -- fetch's completion triggers a setDirty even though *it* was started
        -- by the prefetch chain with repaint=false. Otherwise the placeholder
        -- stays on screen until the next user input.
        if repaint then
            self._pending_repaint_pages[page] = true
        end
        on_done(); return
    end

    local zoom = self:getCurrentZoom()
    local pm   = (self.view_mode == 2) and "dual" or nil

    -- Body already injected -> just ensure tiles and done.
    if self.virtual_document:isRawBodyReady(page) then
        logger.dbg(string.format("[kamare:render] page=%d ensure skip (ready)", page))
        local native_dims = self.virtual_document:getNativePageDimensions(page)
        local rw, rh = self.canvas:_renderDimsFor(native_dims.w, native_dims.h)
        self.virtual_document:prefetchPage(page, zoom, pm, rw, rh, self.canvas.render_quality)
        on_done()
        return
    end

    local chapter_id = self.metadata and (self.metadata.chapterId or self.metadata.chapter_id)
    if not chapter_id then on_done(); return end
    local page0 = math.max(0, page - 1)
    local req, err = KavitaClient:buildImageRequestTable(chapter_id, page0)
    if not req then
        self._page_fetch_failed[page] = true
        logger.dbg(string.format("[kamare:render] page=%d build-request FAIL: %s", page, tostring(err)))
        on_done(); return
    end

    self._page_fetch_inflight[page] = true
    self._page_fetch_retries[page] = 0
    local t0 = time.now()

    -- Terminal cleanup shared by every final outcome (success or give-up).
    local function finish_terminal()
        self._fetch_handles[page] = nil
        self._page_fetch_inflight[page] = nil
        self._page_fetch_retries[page] = nil
    end

    local do_fetch  -- forward decl (retry re-enters it)
    do_fetch = function()
        if gen ~= self._prefetch_gen or not self.virtual_document then
            finish_terminal()
            on_done(); return
        end
        local handle = AsyncFetch.fetch(req,
            { quantum_ms = 60, total_timeout = self:_fetchTimeoutSec() },
            function(body, code, stats)
                if gen ~= self._prefetch_gen or not self.virtual_document then
                    finish_terminal()
                    on_done(); return
                end
                if body and code == 200 then
                    self:_recordNetSample(true, stats and stats.throughput_Bps)
                    finish_terminal()
                    self.virtual_document:injectRawBody(page, body)
                    local native_dims = self.virtual_document:getNativePageDimensions(page)
                    local rw, rh = self.canvas:_renderDimsFor(native_dims.w, native_dims.h)
                    local tiles = self.virtual_document:prefetchPage(page, zoom, pm,
                                                                      rw, rh, self.canvas.render_quality)
                    logger.dbg(string.format("[kamare:render] page=%d ready +%d tiles %dms",
                        page, tonumber(tiles) or 0, time.to_ms(time.now() - t0)))
                    -- Repaint ONLY for the render path (visible page with placeholder).
                    -- Two ways to get here needing a repaint: this fetch was started by
                    -- the render path (repaint=true), OR a later render-path call hit
                    -- the in-flight short-circuit and flagged the pending set. Either
                    -- way, fire one setDirty and clear the pending flag. Prefetch-only
                    -- completions (off-screen pages) skip this to avoid e-ink flicker.
                    local want_repaint = repaint or self._pending_repaint_pages[page]
                    self._pending_repaint_pages[page] = nil
                    if want_repaint and self.canvas and self.canvas.dimen then
                        UIManager:setDirty(self, "partial", self.canvas.dimen)
                    end
                    on_done()
                    return
                end
                -- Failure: transient (retry) vs permanent (give up). A flaky link
                -- often produces a single timeout/truncation; retrying recovers the
                -- page instead of blacklisting it until chapter reload.
                self:_recordNetSample(false, stats and stats.throughput_Bps)
                local attempts = self._page_fetch_retries[page] or 0
                -- Visibility governs the retry cap. A page that is currently
                -- on screen (render-path placeholder) must keep retrying until
                -- it arrives; giving up leaves the "pending" placeholder stuck
                -- and the document unreadable. Off-screen / prefetch pages
                -- still respect NET_RETRY_MAX -- there's no point hammering a
                -- server for a page the user may never see. Visibility is
                -- re-checked here (not just the repaint flag captured at fetch
                -- start) so a prefetch fetch whose page scrolled into view
                -- during the backoff window is also upgraded to infinite retry.
                local is_visible = repaint
                    or (self._pending_repaint_pages[page])
                if not is_visible then
                    for _, vp in ipairs(self:_currentVisiblePages()) do
                        if vp == page then is_visible = true; break end
                    end
                end
                -- Give up only on a permanent 4xx (server won't serve it) or
                -- when an OFF-SCREEN page has exhausted its retry budget.
                local give_up = isPermanentFetchFailure(code)
                    or (not is_visible and attempts >= NET_RETRY_MAX)
                if not give_up then
                    self._page_fetch_retries[page] = attempts + 1
                    local backoff = NET_RETRY_BACKOFF_S[attempts + 1] or NET_RETRY_BACKOFF_S[#NET_RETRY_BACKOFF_S]
                    local attempt_lbl = is_visible
                        and tostring(attempts + 1)
                        or string.format("%d/%d", attempts + 1, NET_RETRY_MAX)
                    logger.dbg(string.format("[kamare:render] page=%d transient fail code=%s err=%s retry %s%s in %ds",
                        page, tostring(code), (stats and stats.err) or "-", attempt_lbl,
                        is_visible and " (visible)" or "", backoff))
                    -- Keep _page_fetch_inflight set during the backoff window so the
                    -- dedup short-circuit above suppresses duplicate fetches for the
                    -- same page; the rescheduled do_fetch re-checks the gen token.
                    UIManager:scheduleIn(backoff, function()
                        if gen == self._prefetch_gen and self.virtual_document then
                            do_fetch()
                        else
                            finish_terminal()
                            on_done()
                        end
                    end)
                    return
                end
                local why = isPermanentFetchFailure(code) and "" or " (retries exhausted)"
                logger.dbg(string.format("[kamare:render] page=%d fetch FAIL code=%s err=%s%s",
                    page, tostring(code), (stats and stats.err) or "-", why))
                self._page_fetch_failed[page] = true
                finish_terminal()
                on_done()
            end)
        self._fetch_handles[page] = handle
    end

    do_fetch()
end

-- Render-path trigger: a page was painted as "pending" (cache miss). Request
-- it async; on arrival the repaint above renders the real page.
function KamareImageViewer:_onPendingRenderPage(page)
    if not page or not self.virtual_document then return end
    self:_ensurePageReady(page, self._prefetch_gen, nil, true) -- repaint: replace placeholder
end

-- Async prefetch chain: fetch one page, yield (tickAfterNext), re-evaluate
-- position, and keep filling until calculateAdaptivePrefetch is satisfied.
-- Because the fetch is non-blocking, this runs during active scroll without
-- freezing it. Self-cancels when the gen token changes.
function KamareImageViewer:_prefetchStepAsync()
    if not self.virtual_document or self.prefetch_pages ~= 1 then
        self._prefetch_chain_active = false
        return
    end
    -- Refresh reader context each step: the chain re-enters here directly
    -- (not via prefetchUpcomingTiles), so without this the eviction policy
    -- would run on stale position and could evict the just-prefetched page.
    self:_updateReaderContext()
    local gen = self._prefetch_gen
    local pages = self:calculateAdaptivePrefetch()
    if #pages == 0 then
        self._prefetch_chain_active = false
        return
    end
    -- Anti-spin backstop: a healthy chain advances to a new page each step
    -- (the previous page is now cached or skipped). If the same page is picked
    -- twice in a row, progress isn't happening (stuck fetch / tilegen mismatch)
    -- -- pause the chain instead of looping until crash. The next page-turn or
    -- scroll event re-triggers it.
    local page = pages[1]
    -- Visible-page preemption: on a constrained link (or any recent errors),
    -- don't start a speculative fetch while a visible page is still loading --
    -- that page already fetches via the render path and should own the pipe.
    -- Reschedule shortly instead of consuming the chain step.
    if (self:_netBwFactor() < 1.0 or self:_netErrRate() > 0)
       and self._page_fetch_inflight then
        local visible_busy = false
        for _, vp in ipairs(self:_currentVisiblePages()) do
            if self._page_fetch_inflight[vp] then
                visible_busy = true
                break
            end
        end
        if visible_busy then
            logger.dbg(string.format(
                "[kamare:prefetch] deferring speculative page=%d; visible page in flight (bw=%.0fKB/s err=%.0f%%)",
                page, self:_netBw() / 1024, self:_netErrRate() * 100))
            UIManager:scheduleIn(0.25, function()
                if self._prefetch_gen == gen and self.virtual_document then
                    self:_prefetchStepAsync()
                else
                    self._prefetch_chain_active = false
                end
            end)
            return
        end
    end
    if page == self._prefetch_last_pick then
        logger.dbg(string.format("[kamare:prefetch] chain stuck on page %d; pausing chain", page))
        self._prefetch_chain_active = false
        self._prefetch_last_pick = nil
        return
    end
    self._prefetch_last_pick = page
    self:_ensurePageReady(page, gen, function()
        if self._prefetch_gen ~= gen or not self.virtual_document then
            self._prefetch_chain_active = false
            return
        end
        -- Yield to UIManager between pages so input/paint keep flowing.
        UIManager:tickAfterNext(function() self:_prefetchStepAsync() end)
    end)
end

function KamareImageViewer:kickPrefetchChain()
    if not self.virtual_document then
        return
    end
    if self._prefetch_chain_active then
        return
    end
    self._prefetch_chain_active = true
    self._prefetch_last_pick = nil  -- fresh pass: allow re-attempt of a page a prior pass paused on
    self:_prefetchStepAsync()
end

function KamareImageViewer:onSwipe(_, ges)
    local dir = ges.direction
    local dist = ges.distance

    if dir == "north" then
        if self.view_mode == 1 then
            if self._images_list_cur == self._images_list_nb and self.canvas then
                local max_offset = self.canvas:getMaxScrollOffset() or 0
                local current_offset = self.scroll_offset or 0
                local new_offset = current_offset + dist
                local at_end = math.abs(current_offset - max_offset) < 1

                if at_end and new_offset > current_offset then
                    if self._reached_end then
                        self:_checkAndOfferNextChapter()
                        return true
                    else
                        self._reached_end = true
                    end
                end
            end
            self:_scrollBy(dist)
        end
    elseif dir == "south" then
        if self.view_mode == 1 then
            self._reached_end = false
            self:_scrollBy(-dist)
        end
    end

    return true
end

function KamareImageViewer:_canPanInPageMode(direction)
    if self.view_mode == 1 then return false end

    if self.view_mode == 2 then return false end

    if not (self.canvas and self.virtual_document) then return false end

    local viewport_w, viewport_h = self.canvas:getViewportSize()

    if viewport_w <= 0 or viewport_h <= 0 then return false end

    local page = Math.clamp(self._images_list_cur or 1, 1, self._images_list_nb or 1)
    local dims = self.virtual_document:getNativePageDimensions(page)

    if not dims or dims.w <= 0 or dims.h <= 0 then return false end

    local zoom = self:getCurrentZoom()

    local page_w = dims.w
    local page_h = dims.h

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
    local page_w = dims.w
    local page_h = dims.h

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

function KamareImageViewer:_applyPagePosition(page, moving_forward)
    if self.view_mode == 1 then return end
    if not (self.canvas and self.virtual_document) then return end

    if self.zoom_mode == 0 then
        self.canvas:setCenter(0.5, 0.5)
        return
    end

    local viewport_w, viewport_h = self.canvas:getViewportSize()
    local dims = self.virtual_document:getNativePageDimensions(page)
    if not (dims and viewport_w > 0 and viewport_h > 0) then return end

    local zoom = self:getCurrentZoom()
    local page_w, page_h = dims.w, dims.h

    if self.zoom_mode == 1 then
        local scaled_h = page_h * zoom
        if scaled_h > viewport_h then
            local min_y = viewport_h / (2 * scaled_h)
            local max_y = 1.0 - min_y
            self.canvas:setCenter(0.5, moving_forward and min_y or max_y)
        else
            self.canvas:setCenter(0.5, 0.5)
        end
    elseif self.zoom_mode == 2 then
        local scaled_w = page_w * zoom
        if scaled_w > viewport_w then
            local min_x = viewport_w / (2 * scaled_w)
            local max_x = 1.0 - min_x
            self.canvas:setCenter(moving_forward and min_x or max_x, 0.5)
        else
            self.canvas:setCenter(0.5, 0.5)
        end
    end
end

function KamareImageViewer:_isPageCached(page)
    if not (self.virtual_document and VIDCache) then
        return true
    end
    page = Math.clamp(page or 1, 1, self._images_list_nb or 1)
    -- Primary signal: the document's fully-cached set, kept accurate by
    -- _preSplitPageTiles (marks on success) and the tile onFree callback
    -- (clears on LRU eviction). Covers scroll-mode multi-tile pages.
    if self.virtual_document:isPageFullyCached(page) then
        return true
    end
    -- Fallback probe for page-mode pages rendered via renderPage (single
    -- full-page tile, not tracked in _fully_cached_pages). Used by the
    -- fetch indicator, where a false positive just suppresses one flash.
    local zoom = self:getCurrentZoom()
    local first_tile = Geom:new{ x = 0, y = 0, w = 1024, h = 1024 }
    local hash = self.virtual_document:_tileHash(page, zoom,
                                                  self.virtual_document.gamma, first_tile,
                                                  self.canvas.render_quality)
    return VIDCache:getNativeTile(hash) ~= nil
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

    self._reached_end = false

    local moving_forward = page > self._images_list_cur

    logger.dbg(string.format("[kamare:viewer] turn %d -> %d (%s) mode=%d",
        self._images_list_cur or -1, page, moving_forward and "fwd" or "back", self.view_mode))

    self._images_list_cur = page
    self.current_image_start_time = os.time()

    if moving_forward then
        self._page_turns_since_open = (self._page_turns_since_open or 0) + 1
    end

    if self.ui and self.ui.statistics then
        self.ui.statistics:onPageUpdate(page)
    end

    if self.view_mode == 1 then
        self:_scrollToPage(page)
    else
        self.scroll_offset = 0
        self._pending_page_direction = moving_forward
    end

    self:updateImageOnly()

    -- Explicit page-turn in page/dual mode: flashpartial helps clear e-ink
    -- ghosting from the previous page's artwork. Scroll-mode navigation
    -- already set dirty via _scrollToPage -> _setScrollOffset with "partial";
    -- keep "partial" there to avoid extra flashing on continuous scrolling.
    local refresh_hint = (self.view_mode == 1) and "partial" or "flashpartial"
    UIManager:setDirty(self, refresh_hint, self.canvas.dimen)

    self:updateFooter()

    UIManager:nextTick(function()
        UIManager:waitForVSync()
        self:_postViewProgress()
        self:prefetchUpcomingTiles()
    end)
end

function KamareImageViewer:onShowNextImage()
    local is_rtl = self.page_direction == 1

    if is_rtl then
        return self:_showPrevImageInternal()
    else
        return self:_showNextImageInternal()
    end
end

function KamareImageViewer:onShowPrevImage()
    -- In RTL mode, "prev" in reading direction means going forward in page numbers
    local is_rtl = self.page_direction == 1

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
    if not self.metadata then return end

    if self.chapter_end_behavior == 0 then
        return
    end

    local seriesId = self.metadata.seriesId or self.metadata.series_id
    local volumeId = self.metadata.volumeId or self.metadata.volume_id
    local currentChapterId = self.metadata.chapterId or self.metadata.chapter_id

    if not (seriesId and volumeId and currentChapterId) then
        logger.warn("KamareImageViewer: Missing required IDs for next chapter query")
        return
    end

    local is_auto = self.chapter_end_behavior == 2

    UIManager:nextTick(function()
        local nextChapterId, code = KavitaClient:getNextChapter(seriesId, volumeId, currentChapterId)

        local no_next = nextChapterId == -1 or not nextChapterId or type(code) ~= "number" or code < 200 or code >= 300

        if no_next then
            if is_auto then
                UIManager:show(InfoMessage:new{
                    text = _("You've reached the end of the series"),
                    timeout = 3,
                })
            else
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
            end
            return
        end

        if is_auto then
            if self.on_next_chapter_callback then
                self.on_next_chapter_callback(nextChapterId)
            end

            self:onClose()

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

function KamareImageViewer:_postViewProgress(force)
    if not self.metadata then return end

    local at_end = false

    if self.view_mode == 1 and self._images_list_cur == self._images_list_nb and self.canvas then
        local max_offset = self.canvas:getMaxScrollOffset() or 0

        if max_offset == 0 then
            at_end = true
        elseif max_offset > 0 then
            at_end = math.abs((self.scroll_offset or 0) - max_offset) < 1
        end
    end

    -- In dual-page mode, post the furthest page in the current pair for progress tracking
    local current_page = self._images_list_cur

    if self.view_mode == 2 and self.canvas and self.virtual_document then
        local left, right = self.canvas:getDualPagePair(self._images_list_cur)

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

    -- Cancel any pending debounced POST.
    if self._progress_post_func then
        UIManager:unschedule(self._progress_post_func)
        self._progress_post_func = nil
    end

    if force then
        -- Immediate (sync) POST — used on close to ensure progress is saved.
        -- Cancel any in-flight async POST first so it can't land after the
        -- close POST and clobber the final position with an older page.
        if self._progress_post_handle then
            pcall(function() self._progress_post_handle.cancel() end)
            self._progress_post_handle = nil
        end
        self._progress_post_inflight = false
        self._progress_post_pending = false
        pcall(function()
            KavitaClient:postReaderProgressForPage(self.metadata, page_to_post)
        end)
    else
        -- Debounced: accumulate page changes during fast scroll, fire once
        -- 2s after the user stops. Dispatched via AsyncFetch so the HTTP
        -- round-trip doesn't freeze the UI thread (~300ms typical).
        -- Cooperative inflight guard: if the user keeps moving and a new
        -- debounce fires while the prior POST is still in flight, the new
        -- one defers to the prior POST's completion callback (which then
        -- re-evaluates against the latest page) -- preventing two parallel
        -- POSTs from landing out of order at the server.
        local meta = self.metadata
        local page = page_to_post
        self._progress_post_func = function()
            self._progress_post_func = nil
            if self._progress_post_inflight then
                -- Prior POST still running. Mark pending; the completion
                -- callback will pick up the latest page when it lands.
                self._progress_post_pending = true
                return
            end
            self._progress_post_inflight = true
            self._progress_post_handle = KavitaClient:postReaderProgressForPageAsync(
                meta, page,
                function(_, _code)
                    self._progress_post_inflight = false
                    self._progress_post_handle = nil
                    if self._progress_post_pending then
                        self._progress_post_pending = false
                        -- Force re-evaluation against the latest page state.
                        -- last_posted_page was advanced when we scheduled, so
                        -- clear it to bypass the early-return dedup check.
                        self.last_posted_page = nil
                        self:_postViewProgress()
                    end
                end)
        end
        UIManager:scheduleIn(2.0, self._progress_post_func)
    end
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
    self:_postViewProgress(true) -- force immediate (sync) POST on close
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
    -- Release the singleton slot, but only if it still points at us.
    if KamareImageViewer.active_instance == self then
        KamareImageViewer.active_instance = nil
    end

    -- Cancel any pending coalesced footer refresh so the nextTick callback
    -- can't fire on a freed footer.
    if self._footer_update_func then
        UIManager:unschedule(self._footer_update_func)
        self._footer_update_pending = false
    end

    -- Cancel any pending debounced progress POST.
    if self._progress_post_func then
        UIManager:unschedule(self._progress_post_func)
        self._progress_post_func = nil
    end

    -- Cancel any in-flight async fetches: bump the generation token (pending
    -- callbacks become no-ops) and abort every live fetch handle (there can be
    -- several: prefetch chain + render-path pending pages).
    self._prefetch_gen = (self._prefetch_gen or 0) + 1
    self._prefetch_chain_active = false
    if self._fetch_handles then
        for _page, handle in pairs(self._fetch_handles) do
            if handle and handle.cancel then
                pcall(function() handle.cancel() end)
            end
        end
        self._fetch_handles = {}
    end
    self._pending_repaint_pages = {}

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

function KamareImageViewer:onSetChapterEndBehavior(value)
    local v = tonumber(value)
    if not v then return false end
    v = Math.clamp(v, 0, 2)
    self.chapter_end_behavior = v
    self.configurable.chapter_end_behavior = v
    self:syncAndSaveSettings()
    return true
end

function KamareImageViewer:onSetRotationMode(mode)
    if self.rotation_locked then
        logger.info("KamareImageViewer: Rotation locked, ignoring rotation mode change")
        return true
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
            -- Capture a page-anchored position (page index + within-page fraction)
            -- so continuous mode lands at the same spot after the orientation flip.
            local captured_anchor = nil
            if self.view_mode == 1 and self.canvas and self.virtual_document then
                local max_scroll = self.canvas:getMaxScrollOffset() or 0
                local so = self.scroll_offset or 0
                if max_scroll > 0 and so > 0 then
                    local viewport_w = select(1, self.canvas:getViewportSize())
                    local zoom = self.canvas.zoom or self.current_zoom or 1.0
                    local total_pages = self._images_list_nb or 0
                    local page_at_top = self.virtual_document:getPageAtOffset(
                        so, zoom, self.zoom_mode, viewport_w, self.page_gap_height)
                    local page_start = self.virtual_document:getScrollPositionForPage(
                        page_at_top, zoom, self.zoom_mode, viewport_w, self.page_gap_height)
                    local next_start
                    if page_at_top >= total_pages then
                        next_start = self.virtual_document:getVirtualHeight(
                            zoom, self.zoom_mode, viewport_w, self.page_gap_height)
                    else
                        next_start = self.virtual_document:getScrollPositionForPage(
                            page_at_top + 1, zoom, self.zoom_mode, viewport_w, self.page_gap_height)
                    end
                    local page_h = next_start - page_start
                    local frac = 0
                    if page_h > 0 then
                        frac = (so - page_start) / page_h
                        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
                    end
                    captured_anchor = { page = page_at_top, frac = frac }
                end
            end

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

        if captured_anchor then
            self._pending_scroll_anchor = captured_anchor
            self._pending_scroll_page = nil
        else
            self._pending_scroll_anchor = nil
            self._pending_scroll_page = self._images_list_cur
        end

        if self.canvas then
            self.canvas._layout_dirty = true
        end

        -- Re-initialize gesture listeners after dimensions are updated
        self:initConfigGesListener()

        self:update()
    end
end

return KamareImageViewer
