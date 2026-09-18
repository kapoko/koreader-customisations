local userpatch = require("userpatch")

userpatch.registerPatchPluginFunc("cwasync", function(CWASync)
    local _ = require("gettext")
    local CWASyncClient = require("CWASyncClient")
    local TouchMenu = require("ui/widget/touchmenu")

    local SETTING_KEY = "cwasync_last_successful_sync"
    local TYPE_SETTING_KEY = "cwasync_last_successful_sync_type"
    local PUSH_ARROW = "\u{2191}"
    local PULL_ARROW = "\u{2193}"

    local function recordSuccessfulSync(sync_type)
        G_reader_settings:saveSetting(
            SETTING_KEY,
            os.time()
        )
        G_reader_settings:saveSetting(
            TYPE_SETTING_KEY,
            sync_type
        )
    end

    -- This wrapper is installed after the Wi-Fi footer wrapper, so prepending
    -- here keeps the latest CWA result immediately to the icon's left.
    local function decorateFooter(tm)
        local text = tm.time_info and tm.time_info.text
        if not text or text == "" then return end
        if text:find(PUSH_ARROW .. " (", 1, true)
            or text:find(PULL_ARROW .. " (", 1, true)
        then
            return
        end

        local timestamp = tonumber(G_reader_settings:readSetting(SETTING_KEY))
        local sync_type = G_reader_settings:readSetting(TYPE_SETTING_KEY)
        if not timestamp or (sync_type ~= "push" and sync_type ~= "pull") then
            return
        end

        local direction = sync_type == "push" and PUSH_ARROW or PULL_ARROW
        tm.time_info:setText(direction .. " (" .. os.date("%H:%M", timestamp) .. ") " .. text)
    end

    local function wrapFooterUpdateItems()
        local inner = TouchMenu.updateItems
        if inner == TouchMenu._cwasync_last_sync_footer_wrapper then return end

        local function wrapper(self, ...)
            inner(self, ...)
            decorateFooter(self)
        end

        TouchMenu._cwasync_last_sync_footer_wrapper = wrapper
        TouchMenu.updateItems = wrapper
    end

    wrapFooterUpdateItems()

    ------------------------------------------------------------
    -- Wrap client only ONCE.
    ------------------------------------------------------------

    if not CWASyncClient._last_sync_wrapped then
        CWASyncClient._last_sync_wrapped = true

        local original_push =
            CWASyncClient.update_progress

        local original_pull =
            CWASyncClient.get_progress

        CWASyncClient.update_progress = function(
            client,
            username,
            password,
            document,
            progress,
            percentage,
            device,
            device_id,
            callback
        )
            local wrapped_callback = function(ok, body)
                if ok then
                    recordSuccessfulSync("push")
                end

                if callback then
                    callback(ok, body)
                end
            end

            return original_push(
                client,
                username,
                password,
                document,
                progress,
                percentage,
                device,
                device_id,
                wrapped_callback
            )
        end

        CWASyncClient.get_progress = function(
            client,
            username,
            password,
            document,
            callback
        )
            local wrapped_callback = function(ok, body)
                -- Count only a valid CWA progress state.
                if ok
                    and type(body) == "table"
                    and body.percentage ~= nil
                    and body.progress ~= nil
                then
                    recordSuccessfulSync("pull")
                end

                if callback then
                    callback(ok, body)
                end
            end

            return original_pull(
                client,
                username,
                password,
                document,
                wrapped_callback
            )
        end
    end

    ------------------------------------------------------------
    -- Wrap menu only ONCE.
    ------------------------------------------------------------

    if CWASync._last_sync_menu_wrapped then
        return
    end

    CWASync._last_sync_menu_wrapped = true

    local original_addToMainMenu =
        CWASync.addToMainMenu

    CWASync.addToMainMenu = function(self, menu_items)
        original_addToMainMenu(self, menu_items)

        local menu =
            menu_items.cwa_progress_sync

        if not menu or not menu.sub_item_table then
            return
        end

        for _, item in ipairs(menu.sub_item_table) do
            if item.cwasync_last_successful_sync_item then
                return
            end
        end

        table.insert(menu.sub_item_table, {
            cwasync_last_successful_sync_item = true,

            text_func = function()
                local timestamp =
                    G_reader_settings:readSetting(
                        SETTING_KEY
                    )

                if not timestamp then
                    return _(
                        "Last successful sync: Never"
                    )
                end

                local sync_type =
                    G_reader_settings:readSetting(
                        TYPE_SETTING_KEY
                    )

                if sync_type then
                    return _(
                        "Last successful sync ("
                    ) .. sync_type .. "): " .. os.date(
                        "%d-%m-%Y %H:%M",
                        timestamp
                    )
                end

                return _(
                    "Last successful sync: "
                ) .. os.date(
                    "%d-%m-%Y %H:%M",
                    timestamp
                )
            end,

            keep_menu_open = true,
        })
    end
end)
