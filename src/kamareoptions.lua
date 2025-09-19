local _ = require("gettext")

local KamareOptions = {
    prefix = "kamare",
    --[[
        {
            icon = "appbar.pageview",
            options = {
                {
                    name = "reading_mode",
                    name_text = _("Reading Mode"),
                    toggle = {_("Page Mode"), _("Continuous Mode")},
                    values = {0, 1},
                    args = {0, 1},
                    default_value = 0,
                    event = "SetReadingMode",
                    help_text = _("Page mode for manga (default) or continuous mode for manhwa/long strip content."),
                },
            }
        },
    ]]
    {
        icon = "appbar.settings",
        options = {
            {
                name = "footer_mode",
                name_text = _("Footer Display"),
                toggle = {_("Off"), _("Progress"), _("Pages left"), _("Time")},
                values = {0, 1, 2, 3},
                args = {0, 1, 2, 3},
                event = "SetFooterMode",
                help_text = _("Choose what information to display in the footer."),
            }
        }
    }
}

return KamareOptions
