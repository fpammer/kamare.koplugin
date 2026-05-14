local Utils = {}

function Utils.firstNonEmpty(...)
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        if v ~= nil and v ~= "" then
            return v
        end
    end
    return nil
end

function Utils.joinPersonNames(persons, limit)
    if type(persons) == "string" then return persons end
    if type(persons) ~= "table" then return nil end
    limit = limit or 3
    local names = {}
    for _, p in ipairs(persons) do
        if #names >= limit then break end
        if type(p) == "string" then
            table.insert(names, p)
        elseif type(p) == "table" and p.name then
            table.insert(names, p.name)
        end
    end
    if #names == 0 then return nil end
    local result = table.concat(names, ", ")
    if #persons > limit then
        result = result .. ", ..."
    end
    return result
end

function Utils.buildVolumeTitle(dto)
    local vol_prefix = dto.number and ("Volume " .. tostring(dto.number)) or nil
    if Utils.firstNonEmpty(dto.name) then
        local lower = dto.name:lower()
        local is_just_number = tonumber(dto.name) ~= nil and dto.name:match("^%d+$")
        if not (lower:find("vol") or lower:find("volume") or is_just_number) and vol_prefix then
            return vol_prefix .. ": " .. dto.name
        elseif is_just_number and vol_prefix then
            return vol_prefix
        end
        return dto.name
    end
    return vol_prefix or ("Volume #" .. tostring(dto.id or "?"))
end

function Utils.buildChapterTitle(dto)
    local ch_prefix = dto.number and ("Ch. " .. tostring(dto.number)) or nil
    if dto.isSpecial then
        return Utils.firstNonEmpty(dto.titleName, dto.title, dto.range, "Special #" .. tostring(dto.id or "?"))
    end
    if Utils.firstNonEmpty(dto.titleName) then
        local lower = dto.titleName:lower()
        local is_just_number = tonumber(dto.titleName) ~= nil and dto.titleName:match("^%d+$")
        if not (lower:find("ch") or lower:find("chap") or lower:find("chapter")
                or lower:find("vol") or lower:find("volume") or is_just_number) and ch_prefix then
            return ch_prefix .. ": " .. dto.titleName
        end
        return dto.titleName
    end
    return Utils.firstNonEmpty(dto.title, dto.range, ch_prefix, "Chapter #" .. tostring(dto.id or "?"))
end

function Utils.resolveTitle(metadata, fallback_title, default)
    default = default or "Unknown"
    if metadata then
        return Utils.firstNonEmpty(metadata.localizedName, fallback_title, default)
    end
    return fallback_title or default
end

return Utils
