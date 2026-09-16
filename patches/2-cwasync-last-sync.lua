local userpatch = require("userpatch")

userpatch.registerPatchPluginFunc("cwasync", function(CWASync)
    local _ = require("gettext")
    local CWASyncClient = require("CWASyncClient")

    local SETTING_KEY = "cwasync_last_successful_sync"

    local function recordSuccessfulSync()
        G_reader_settings:saveSetting(
            SETTING_KEY,
            os.time()
        )
    end

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
                    recordSuccessfulSync()
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
                    recordSuccessfulSync()
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
