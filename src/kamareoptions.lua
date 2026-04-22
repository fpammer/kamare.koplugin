local optionsutil = require("ui/data/optionsutil")
local Device = require("device")
local _ = require("gettext")

local KamareOptions = {
    prefix = "kamare",
    {
        icon = "appbar.pageview",
        options = {
            {
                name = "view_mode",
                name_text = _("View Mode"),
                toggle = {_("page"), _("continuous"), _("dual page")},
                values = {0, 1, 2},
                default_value = 0,
                event = "SetViewMode",
                args = {0, 1, 2},
                help_text = _([[- 'page' shows one page at a time- 'continuous' allows scrolling through pages- 'dual page' shows two pages side-by-side]]),
            },
            {
                name = "page_direction",
                name_text = _("Page Direction"),
                toggle = {_("LTR"), _("RTL")},
                values = {0, 1},
                default_value = 0,
                event = "SetPageDirection",
                args = {0, 1},
                help_text = _([[Set page reading direction for dual page mode. LTR (Left-to-Right) for comics/webtoons, RTL (Right-to-Left) for manga.]]),
            },
            {
                name = "page_gap_height",
                name_text = _("Page Gap"),
                buttonprogress = true,
                values = {0, 2, 4, 8, 16, 32, 64},
                default_pos = 4,
                default_value = 8,
                event = "PageGapUpdate",
                args = {0, 2, 4, 8, 16, 32, 64},
                enabled_func = function (configurable)
                    return optionsutil.enableIfEquals(configurable, "view_mode", 1)
                end,
                name_text_hold_callback = optionsutil.showValues,
                name_text_unit = true,
                help_text = _([[In continuous view mode, sets the thickness of the separator between document pages.]]),
                more_options = true,
                more_options_param = {
                    value_step = 1, value_hold_step = 10,
                    value_min = 0, value_max = 256,
                    precision = "%.1f",
                },
            },
            {
                name = "scroll_distance",
                name_text = _("Scroll Distance"),
                toggle = {"25%", "50%", "75%", "100%"},
                values = {25, 50, 75, 100},
                default_pos = 1,
                default_value = 25,
                event = "ScrollDistanceUpdate",
                args = {25, 50, 75, 100},
                enabled_func = function (configurable)
                    return optionsutil.enableIfEquals(configurable, "view_mode", 1)
                end,
                name_text_hold_callback = optionsutil.showValues,
                name_text_unit = true,
                help_text = _([[In continuous view mode, sets the distance to scroll when using the up/down buttons.]]),
                more_options = true,
                more_options_param = {
                    value_step = 1, value_hold_step = 10,
                    value_min = 0, value_max = 100,
                    precision = "%.1f",
                },
            },
            {
                name = "background_color",
                name_text = _("Background Color"),
                toggle = {_("Black"), _("White")},
                values = {0, 1},
                args = {0, 1},
                default_value = 1,
                event = "SetBackgroundColor",
                help_text = _([[Choose the background color for the image viewer.]]),
            }
        }
    },
    {
        icon = "appbar.pagefit",
        options = {
            {
                name = "zoom_mode_type",
                name_text = _("Fit"),
                toggle = {_("full"), _("width"), _("height")},
                values = {0,1,2},
                default_value = 0,
                event = "DefineZoom",
                args = {0,1,2},
                help_text = _([[Set how the page should be resized to fit the screen. In continuous mode, only 'width' is available for consistent page alignment.]]),
                enabled_func = function(configurable)
                    local mode = configurable.view_mode or 0
                    return mode == 0 or mode == 1
                end,
            },
            {
                name = "scroll_margin",
                name_text = _("Horizontal Margin"),
                buttonprogress = true,
                values = {0, 10, 20, 30, 40, 60, 80, 100},
                default_pos = 1,
                default_value = 0,
                event = "ScrollMarginUpdate",
                args = {0, 10, 20, 30, 40, 60, 80, 100},
                enabled_func = function (configurable)
                    return optionsutil.enableIfEquals(configurable, "view_mode", 1)
                end,
                name_text_hold_callback = optionsutil.showValues,
                name_text_unit = true,
                help_text = _([[In continuous view mode, sets the horizontal margin on the left and right sides of the page.]]),
                more_options = true,
                more_options_param = {
                    value_step = 5, value_hold_step = 20,
                    value_min = 0, value_max = 300,
                    precision = "%.0f",
                },
            },
            {
                name = "page_padding",
                name_text = _("Page Padding"),
                buttonprogress = true,
                values = {0, 2, 4, 8, 16, 32},
                default_pos = 1,
                default_value = 0,
                event = "PagePaddingUpdate",
                args = {0, 2, 4, 8, 16, 32},
                name_text_hold_callback = optionsutil.showValues,
                name_text_unit = true,
                help_text = _([[Sets uniform padding on all sides to prevent pages from touching the screen borders.]]),
                more_options = true,
                more_options_param = {
                    value_step = 1, value_hold_step = 5,
                    value_min = 0, value_max = 50,
                    precision = "%.0f",
                },
            }
        }
    },
    {
        icon = "appbar.settings",
        options = {
            {
                name = "prefetch_pages",
                name_text = _("Prefetch"),
                toggle = {_("Off"), _("On")},
                values = {0, 1},
                default_value = 1,
                event = "SetPrefetchPages",
                args = {0, 1},
                help_text = _([[Enable or disable automatic page prefetching. When enabled, upcoming pages are loaded in the background for smooth navigation.]]),
            },
            {
                name = "render_quality",
                name_text = _("Render Quality"),
                toggle = {_("Low"), _("High"), _("Native")},
                values = {0.8, 1.2, -1},
                default_value = -1,
                event = "SetRenderQuality",
                args = {0.8, 1.2, -1},
                help_text = _([[Controls internal rendering resolution. Low/High cap rendering based on screen size to save memory on large images. Native always uses full image resolution. Images smaller than threshold are never upscaled.]]),
            },
            {
                name = "rotation_lock",
                name_text = _("Screen Rotation"),
                toggle = {_("Auto"), _("Locked")},
                values = {false, true},
                default_value = false,
                event = "SetRotationLock",
                args = {false, true},
                help_text = _([[Auto rotation adjusts screen orientation automatically. Locked keeps the current system rotation fixed.]]),
            },
            {
                name = "footer_mode",
                name_text = _("Footer"),
                toggle = {_("Off"), _("Progress"), _("Percentage"), _("Time Left"), _("Clock")},
                values = {7, 1, 5, 6, 3},
                args = {7, 1, 5, 6, 3},
                default_value = 1,
                event = "SetFooterMode",
                help_text = _([[Choose what information to display in the footer.]]),
            },
            {
                name = "chapter_end_behavior",
                name_text = _("Chapter End"),
                toggle = {_("Stop"), _("Ask"), _("Auto")},
                values = {0, 1, 2},
                default_value = 1,
                event = "SetChapterEndBehavior",
                args = {0, 1, 2},
                help_text = _([[Choose what happens when you reach the end of a chapter: 'Stop' stays on the last page, 'Ask' shows a dialog to continue or close, 'Auto' automatically continues to the next chapter.]]),
            },
            {
                name = "frontlight",
                name_text = _("Frontlight"),
                toggle = { _("Adjust") },
                values = { 0 },
                event = "ShowFrontlight",
                help_text = _([[Open the frontlight controls to adjust brightness and warmth.]]),
                enabled_func = function() return Device:hasFrontlight() end,
            }
        }
    }
}

return KamareOptions
