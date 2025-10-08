local optionsutil = require("ui/data/optionsutil")
local _ = require("gettext")

local KamareOptions = {
    prefix = "kamare",
    {
        icon = "appbar.pageview",
        options = {
            {
                name = "scroll_mode",
                name_text = _("View Mode"),
                toggle = {_("page"), _("continuous")},
                values = {0, 1},
                default_value = 0,
                event = "SetScrollMode",
                args = {0, 1},
                help_text = _([[- 'page' mode shows only one page of the document at a time.- 'scroll' mode allows you to scroll the pages like you would in a web browser.]]),
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
                    return optionsutil.enableIfEquals(configurable, "scroll_mode", 1)
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
                    return optionsutil.enableIfEquals(configurable, "scroll_mode", 1)
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
                help_text = _([[Set how the page should be resized to fit the screen.]]),
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
                    return optionsutil.enableIfEquals(configurable, "scroll_mode", 1)
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
                name_text = _("Prefetch Pages"),
                toggle = {_("Off"), _("1"), _("2"), _("3")},
                values = {0, 1, 2, 3},
                default_value = 1,
                event = "SetPrefetchPages",
                args = {0, 1, 2, 3},
                help_text = _([[Set how many pages to prefetch when reading.]]),
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
            }
        }
    }
}

return KamareOptions
