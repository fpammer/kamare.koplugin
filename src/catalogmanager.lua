local OPDSClient = require("opdsclient")
local url = require("socket.url")
local logger = require("logger")
local _ = require("gettext")

local CatalogManager = {}

CatalogManager.acquisition_rel = "^http://opds%-spec%.org/acquisition"
CatalogManager.borrow_rel = "http://opds-spec.org/acquisition/borrow"
CatalogManager.stream_rel = "http://vaemendis.net/opds-pse/stream"
CatalogManager.facet_rel = "http://opds-spec.org/facet"
CatalogManager.image_rel = {
    ["http://opds-spec.org/image"] = true,
    ["http://opds-spec.org/cover"] = true, -- ManyBooks.net, not in spec
    ["x-stanza-cover-image"] = true,
}
CatalogManager.thumbnail_rel = {
    ["http://opds-spec.org/image/thumbnail"] = true,
    ["http://opds-spec.org/thumbnail"] = true, -- ManyBooks.net, not in spec
    ["x-stanza-cover-image-thumbnail"] = true,
}

-- Special feed identifiers for Kavita OPDS server
CatalogManager.special_feeds = {
    on_deck = "onDeck",
    recently_updated = "recentlyUpdated",
    recently_added = "recentlyAdded",
    reading_lists = "readingList",
    want_to_read = "wantToRead",
    all_libraries = "allLibraries",
    all_collections = "allCollections",
}

function CatalogManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.client = OPDSClient:new()
    return o
end

-- Generates catalog item table and processes OPDS facets/search links
function CatalogManager:genItemTableFromCatalog(catalog, item_url)
    local item_table = {}
    local facet_groups = nil
    local search_url = nil

    if not catalog then
        return item_table, facet_groups, search_url
    end

    local feed = catalog.feed or catalog
    facet_groups = {} -- Initialize table to store facet groups

    local function build_href(href)
        return url.absolute(item_url, href)
    end

    local has_opensearch = false
    local hrefs = {}
    if feed.link then
        for __, link in ipairs(feed.link) do
            if link.type ~= nil and link.rel and link.href then
                local link_href = build_href(link.href)

                -- Always add the link to hrefs if it has a rel and href
                -- Navigation links (prev, next, start, first, last) take priority
                -- and won't be overwritten by later processing of the same rel
                if not hrefs[link.rel] then
                    hrefs[link.rel] = link_href
                end

                -- OpenSearch
                if link.type:find(self.client.search_type) then
                    if link.href then
                        search_url = build_href(self.client:getSearchTemplate(build_href(link.href)))
                        has_opensearch = true
                    end
                end
                -- Calibre search (also matches the actual template for OpenSearch!)
                if link.type:find(self.client.search_template_type) and link.rel and link.rel:find("search") then
                    if link.href and not has_opensearch then
                        search_url = build_href(link.href:gsub("{searchTerms}", "%%s"))
                    end
                end
                -- Process OPDS facets
                if link.rel == self.facet_rel then
                    local group_name = link["opds:facetGroup"] or _("Filters")
                    if not facet_groups[group_name] then
                        facet_groups[group_name] = {}
                    end
                    table.insert(facet_groups[group_name], link)
                end
            end
        end
    end
    item_table.hrefs = hrefs

    for __, entry in ipairs(feed.entry or {}) do
        local item = {}
        item.acquisitions = {}
        if entry.link then
            for ___, link in ipairs(entry.link) do
                local link_href = build_href(link.href)
                if link.type and link.type:find(self.client.catalog_type)
                    and (not link.rel
                    or link.rel == "subsection"
                    or link.rel == "http://opds-spec.org/subsection"
                    or link.rel == "http://opds-spec.org/sort/popular"
                    or link.rel == "http://opds-spec.org/sort/new") then
                    item.url = link_href
                end
                -- Process streaming and display links only
                if link.rel or link.title then
                    if link.rel == self.stream_rel then
                        -- https://vaemendis.net/opds-pse/
                        -- «count» MUST provide the number of pages of the document
                        -- namespace may be not "pse"
                        local count, last_read
                        for k, v in pairs(link) do
                            if k:sub(-6) == ":count" then
                                count = tonumber(v)
                            elseif k:sub(-9) == ":lastRead" then
                                last_read = tonumber(v)
                            end
                        end
                        if count then
                            table.insert(item.acquisitions, {
                                type  = link.type,
                                href  = link_href,
                                title = link.title,
                                count = count,
                                last_read = last_read and last_read > 0 and last_read or nil
                            })
                        end
                    elseif self.thumbnail_rel[link.rel] then
                        item.thumbnail = link_href
                    elseif self.image_rel[link.rel] then
                        item.image = link_href
                    end
                end
            end
        end
        local title = _("Unknown")
        if type(entry.title) == "string" then
            title = entry.title
        elseif type(entry.title) == "table" then
            if type(entry.title.type) == "string" and entry.title.div ~= "" then
                title = entry.title.div
            end
        end
        item.text = title
        local author = _("")
        if type(entry.author) == "table" and entry.author.name then
            author = entry.author.name
            if type(author) == "table" then
                if #author > 0 then
                    author = table.concat(author, ", ")
                else
                    -- we may get an empty table on https://gallica.bnf.fr/opds
                    author = nil
                end
            end
        end
        item.text = title  -- Just use the title, author will be shown as subtitle
        item.title = title
        item.author = author
        item.content = entry.content or entry.summary

        -- Add type determination and reading status
        local has_streaming = false
        local reading_status = nil  -- nil = read, "unread", "started"

        for _, acquisition in ipairs(item.acquisitions) do
            if acquisition.count then
                has_streaming = true
                -- Determine reading status
                if not acquisition.last_read or acquisition.last_read == 0 then
                    reading_status = "unread"
                elseif acquisition.last_read > 0 and acquisition.last_read < acquisition.count then
                    reading_status = "started"
                else
                    reading_status = nil  -- read (completed)
                end
                break
            end
        end

        item.type = has_streaming and "stream" or "normal"

        -- Set symbol based on reading status
        if reading_status == "unread" then
            item.mandatory = "●"
        elseif reading_status == "started" then
            item.mandatory = "◒"
        end
        -- No symbol for read status

        table.insert(item_table, item)
    end

    if next(facet_groups) == nil then facet_groups = nil end -- Clear if empty

    return item_table, facet_groups, search_url
end

-- Generates menu items from the fetched list of catalog entries
function CatalogManager:genItemTableFromURL(item_url, username, password)
    local all_items = {}
    local current_url = item_url
    local facet_groups, search_url, opensearch_data
    local page_count = 0

    while current_url do
        page_count = page_count + 1

        local ok, catalog = pcall(self.client.parseFeed, self.client, current_url, username, password)
        if not ok then
            if page_count == 1 then -- Only return error if first page fails
                return nil, catalog
            end
            break
        end
        if not catalog then
            if page_count == 1 then -- Only return error if first page fails
                return nil, "Failed to parse catalog"
            end
            break
        end

        local page_items, page_facets, page_search = self:genItemTableFromCatalog(catalog, current_url)

        -- Store metadata from first page only
        if not facet_groups then
            facet_groups = page_facets
            search_url = page_search
            if catalog.opensearch then
                opensearch_data = catalog.opensearch
            end
        end

        -- Add items from this page
        for _, item in ipairs(page_items) do
            table.insert(all_items, item)
        end

        -- Check for next page link
        local next_url = page_items.hrefs and page_items.hrefs.next or nil
        if next_url and next_url ~= current_url then
            current_url = next_url
        else
            current_url = nil
        end

        -- Safety limit to prevent infinite loops
        if page_count > 50 then
            logger.warn("CatalogManager:genItemTableFromURL - Reached safety limit of 50 pages")
            break
        end
    end

    return all_items, facet_groups, search_url, nil, opensearch_data
end

return CatalogManager
