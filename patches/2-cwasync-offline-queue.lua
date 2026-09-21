local userpatch = require("userpatch")

userpatch.registerPatchPluginFunc("cwasync", function(CWASync)
    local ConfirmBox = require("ui/widget/confirmbox")
    local Device = require("device")
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local band = require("bit").band
    local logger = require("logger")
    local md5 = require("ffi/sha2").md5
    local SyncLogic = require("sync_logic")

    local CWASyncClient = require("CWASyncClient")
    local QUEUE_KEY = "cwasync_pending_progress_queue"
    local CWA_SYNC_SILENT = 2 -- CWA's private SYNC_STRATEGY.SILENT value.
    local state = CWASyncClient._cwasync_offline_queue_state

    if not state then
        state = {
            flushing = false,
            waiters = {},
            after_pull = nil,
            pulling = false,
            pull = nil,
        }
        CWASyncClient._cwasync_offline_queue_state = state
    end

    local function queueKey(server, username, document)
        return md5(table.concat({ server, username, document }, "\0"))
    end

    local function readQueue()
        return G_reader_settings:readSetting(QUEUE_KEY, {})
    end

    local function saveQueue(queue)
        G_reader_settings:saveSetting(QUEUE_KEY, queue)
        if G_reader_settings.flush then
            G_reader_settings:flush()
        end
    end

    local function sameSnapshot(saved, item)
        return saved and saved.queued_at == item.queued_at
            and tostring(saved.progress) == tostring(item.progress)
            and tostring(saved.percentage) == tostring(item.percentage)
    end

    local function queueCurrentProgress(instance, reason)
        local settings = instance.settings
        if not settings.auto_sync or not settings.server or not settings.username
            or not settings.password then
            return
        end

        local document = instance:getDocumentDigest()
        if not document then
            logger.warn("CWA queue: cannot queue " .. reason .. "; no document digest")
            return
        end

        local key = queueKey(settings.server, settings.username, document)
        local queue = readQueue()
        queue[key] = {
            document = document,
            progress = instance:getLastProgress(),
            percentage = instance:getLastPercent(),
            device = Device.model,
            device_id = instance.device_id,
            queued_at = os.time(),
            server = settings.server,
            username = settings.username,
        }
        saveQueue(queue)
        logger.dbg("CWA queue: saved " .. reason .. " progress", document)
        return key
    end

    local function removeQueueItem(key, item)
        local queue = readQueue()
        if sameSnapshot(queue[key], item) then
            queue[key] = nil
            saveQueue(queue)
        end
    end

    local function markConflict(key, item, body)
        local queue = readQueue()
        if not sameSnapshot(queue[key], item) then
            return
        end

        queue[key].conflict = true
        queue[key].remote_progress = body.progress
        queue[key].remote_percentage = body.percentage
        queue[key].remote_device = body.device
        saveQueue(queue)
        logger.warn("CWA queue: retaining conflicting progress", item.document)
    end

    local function matchingItem(queue, settings, skipped, preferred_key)
        if preferred_key and not skipped[preferred_key] then
            local item = queue[preferred_key]
            if item and item.server == settings.server and item.username == settings.username then
                return preferred_key, item
            end
        end

        for key, item in pairs(queue) do
            if not skipped[key] and item.server == settings.server
                and item.username == settings.username then
                return key, item
            end
        end
    end

    local function showCurrentConflict(instance, key, item, body, done)
        local local_percent = tonumber(item.percentage)
        local remote_percent = tonumber(body.percentage)
        local device = body.device or "another device"
        local remote = SyncLogic.resolveRemotePosition(body)

        if not local_percent or not remote_percent then
            logger.warn("CWA queue: invalid conflict percentage", item.document)
            done()
            return
        end

        local function keepLocal()
            local settings = instance.settings
            local client = CWASyncClient:new{
                service_url = settings.server .. "/kosync",
                service_spec = instance.path .. "/api.json",
            }
            local ok, err = pcall(client.update_progress, client,
                settings.username, settings.password, item.document,
                item.progress, item.percentage, item.device, item.device_id,
                function(success)
                    if success then
                        removeQueueItem(key, item)
                    else
                        logger.warn("CWA queue: chosen local push failed", item.document)
                    end
                    done()
                end)
            if not ok then
                logger.warn("CWA queue: could not start chosen local push", err)
                done()
            end
        end

        UIManager:show(ConfirmBox:new{
            text = string.format(
                "Progress conflict with %s:\nThis device: %.2f%%\nServer: %.2f%%",
                device,
                local_percent * 100,
                remote_percent * 100
            ),
            ok_text = string.format("Use server (%.2f%%)", remote_percent * 100),
            cancel_text = string.format("Keep local (%.2f%%)", local_percent * 100),
            ok_callback = function()
                removeQueueItem(key, item)
                instance:syncToProgress(remote)
                done()
            end,
            cancel_callback = keepLocal,
        })
    end

    -- Timestamps order queued and server positions. A user decides only when
    -- the newer state would replace a farther-ahead reading position.
    local function flushQueue(instance, done, preferred_key, resolve_current)
        done = done or function() end

        if state.flushing then
            table.insert(state.waiters, done)
            return
        end

        local settings = instance and instance.settings
        if not settings or not settings.server or not settings.username
            or not settings.password or not NetworkMgr:isOnline() then
            done(false)
            return
        end

        state.flushing = true
        state.waiters = { done }
        local skipped = {}
        local first_key = preferred_key
        local current_document = resolve_current and instance:getDocumentDigest()

        local function finish(success)
            if not state.flushing then
                return
            end
            state.flushing = false
            local waiters = state.waiters
            state.waiters = {}
            for _, waiter in ipairs(waiters) do
                local ok, err = pcall(waiter, success)
                if not ok then
                    logger.warn("CWA queue: waiter failed", err)
                end
            end
        end

        local processNext

        local function pushItem(key, item)
            local client = CWASyncClient:new{
                service_url = settings.server .. "/kosync",
                service_spec = instance.path .. "/api.json",
            }
            local ok, err = pcall(client.update_progress, client,
                settings.username, settings.password, item.document,
                item.progress, item.percentage, item.device, item.device_id,
                function(success)
                    if not success then
                        logger.warn("CWA queue: push failed; keeping item", item.document)
                        finish(false)
                        return
                    end
                    removeQueueItem(key, item)
                    processNext()
                end)
            if not ok then
                logger.warn("CWA queue: could not start push", err)
                finish(false)
            end
        end

        processNext = function()
            if not NetworkMgr:isOnline() then
                finish(false)
                return
            end

            local key, item = matchingItem(readQueue(), settings, skipped, first_key)
            first_key = nil
            if not key then
                finish(true)
                return
            end

            local client = CWASyncClient:new{
                service_url = settings.server .. "/kosync",
                service_spec = instance.path .. "/api.json",
            }
            client._cwasync_queue_request = true
            local ok, err = pcall(client.get_progress, client,
                settings.username, settings.password, item.document,
                function(success, body)
                    if not success or type(body) ~= "table" then
                        logger.warn("CWA queue: remote check failed; keeping item", item.document)
                        finish(false)
                        return
                    end

                    if body.percentage == nil then
                        pushItem(key, item)
                        return
                    end

                    if body.progress ~= nil and tostring(body.progress) == tostring(item.progress) then
                        removeQueueItem(key, item)
                        processNext()
                        return
                    end

                    local remote = SyncLogic.resolveRemotePosition(body)
                    local local_percent = tonumber(item.percentage)
                    local remote_percent = tonumber(body.percentage)
                    if body.progress == nil or remote.kind == "none"
                        or not local_percent or not remote_percent then
                        markConflict(key, item, body)
                        skipped[key] = true
                        processNext()
                        return
                    end

                    local local_is_newer = tonumber(item.queued_at)
                        and tonumber(body.timestamp)
                        and tonumber(item.queued_at) > tonumber(body.timestamp)
                    local replaces_ahead_position = (local_is_newer
                        and local_percent < remote_percent)
                        or (not local_is_newer and remote_percent < local_percent)

                    if replaces_ahead_position then
                        markConflict(key, item, body)
                        skipped[key] = true
                        if resolve_current and item.document == current_document then
                            showCurrentConflict(instance, key, item, body, processNext)
                        else
                            processNext()
                        end
                    elseif local_is_newer then
                        pushItem(key, item)
                    elseif resolve_current and item.document == current_document then
                        markConflict(key, item, body)
                        showCurrentConflict(instance, key, item, body, processNext)
                    else
                        removeQueueItem(key, item)
                        processNext()
                    end
                end)
            if not ok then
                logger.warn("CWA queue: could not start remote check", err)
                finish(false)
            end
        end

        processNext()
    end

    if not CWASyncClient._offline_queue_pull_wrapped then
        CWASyncClient._offline_queue_pull_wrapped = true
        local original_get_progress = CWASyncClient.get_progress
        CWASyncClient.get_progress = function(client, username, password, document, callback)
            local after_pull
            if not client._cwasync_queue_request then
                after_pull = state.after_pull
                state.after_pull = nil
            end
            return original_get_progress(client, username, password, document,
                function(ok, body)
                    local pull = state.pull
                    if pull and not client._cwasync_queue_request then
                        pull.body = body
                    end
                    if callback then
                        callback(ok, body)
                    end
                    if after_pull then
                        after_pull()
                    end
                end)
        end
    end

    if not CWASync._offline_queue_sync_wrapped then
        CWASync._offline_queue_sync_wrapped = true
        local original_syncToProgress = CWASync.syncToProgress
        CWASync.syncToProgress = function(self, remote)
            local pull = state.pull
            if not pull or pull.instance ~= self or type(pull.body) ~= "table" then
                return original_syncToProgress(self, remote)
            end

            state.pull = nil
            local local_percent = tonumber(pull.local_percentage)
            local remote_percent = tonumber(pull.body.percentage)
            if not local_percent or not remote_percent then
                return original_syncToProgress(self, remote)
            end

            local device = pull.body.device or "another device"
            UIManager:show(ConfirmBox:new{
                text = string.format(
                    "Server position from %s:\nThis device: %.2f%%\nServer: %.2f%%",
                    device,
                    local_percent * 100,
                    remote_percent * 100
                ),
                ok_text = string.format("Use server (%.2f%%)", remote_percent * 100),
                cancel_text = string.format("Keep local (%.2f%%)", local_percent * 100),
                ok_callback = function()
                    original_syncToProgress(self, remote)
                end,
            })
        end
    end

    local safe_to_reconnect = false
    local connecting = false
    local intentional_disconnect = false

    local function wifiRadioIsOn()
        for _, ifname in ipairs({ "eth0", "wlan0" }) do
            local f = io.open("/sys/class/net/" .. ifname .. "/flags", "r")
            if f then
                local flags = tonumber(f:read("*l"))
                f:close()
                if flags and band(flags, 1) ~= 0 then
                    return true
                end
            end
        end
        return false
    end

    local function cleanupWifi()
        intentional_disconnect = true
        NetworkMgr:afterWifiAction()
        UIManager:scheduleIn(2, function()
            intentional_disconnect = false
        end)
    end

    local function silentlyGetOnline(callback)
        if NetworkMgr:isOnline() then
            safe_to_reconnect = true
            NetworkMgr:setBeforeActionFlag()
            callback(true)
            return
        end
        if connecting or (not safe_to_reconnect and not wifiRadioIsOn()) then
            callback(false)
            return
        end

        connecting = true
        NetworkMgr:setBeforeActionFlag()
        local attempts = 0
        local finished = false
        local check_scheduled = false
        local function finish(success)
            if finished then
                return
            end
            finished = true
            connecting = false
            safe_to_reconnect = success
            if not success then
                cleanupWifi()
            end
            callback(success)
        end
        local function check()
            if finished then
                return
            end
            attempts = attempts + 1
            if NetworkMgr:isOnline() then
                finish(true)
            elseif attempts >= 12 then
                finish(false)
            else
                check_scheduled = true
                UIManager:scheduleIn(0.5, function()
                    check_scheduled = false
                    check()
                end)
            end
        end
        local function scheduleCheck()
            if not finished and not check_scheduled then
                check_scheduled = true
                UIManager:scheduleIn(0.5, function()
                    check_scheduled = false
                    check()
                end)
            end
        end
        local status = NetworkMgr:turnOnWifi(scheduleCheck)
        -- PocketBook can dismiss its prompt without invoking the callback.
        scheduleCheck()
        if status == false then
            finish(false)
        end
    end

    local function pullWithChoice(instance, cleanup_after)
        if state.pulling then
            return
        end
        state.pulling = true
        local cleanup = cleanup_after and cleanupWifi or function() end
        local original_sync_forward = instance.settings.sync_forward
        local original_sync_backward = instance.settings.sync_backward
        local pull = {
            instance = instance,
            local_percentage = instance:getLastPercent(),
        }
        local finished = false
        local function finishPull()
            if finished then
                return
            end
            finished = true
            state.pulling = false
            if state.pull == pull then
                state.pull = nil
            end
            instance.settings.sync_forward = original_sync_forward
            instance.settings.sync_backward = original_sync_backward
            cleanup()
        end

        -- Let syncToProgress present one consistent choice for either direction.
        instance.settings.sync_forward = CWA_SYNC_SILENT
        instance.settings.sync_backward = CWA_SYNC_SILENT
        state.pull = pull
        state.after_pull = finishPull
        instance:getProgress(false, false)
        UIManager:scheduleIn(10, function()
            if state.after_pull == finishPull then
                state.after_pull = nil
                finishPull()
            end
        end)
    end

    local function syncWhenOnline(instance, pull_after, resolve_current, cleanup_after)
        silentlyGetOnline(function(online)
            if not online then
                return
            end
            flushQueue(instance, function(success)
                if not success then
                    if cleanup_after then
                        cleanupWifi()
                    end
                elseif pull_after then
                    pullWithChoice(instance, cleanup_after)
                elseif cleanup_after then
                    cleanupWifi()
                end
            end, nil, resolve_current)
        end)
    end

    local function queueAndFlush(instance, reason, cleanup_after)
        local key = queueCurrentProgress(instance, reason)
        if not key or connecting then
            return
        end
        silentlyGetOnline(function(online)
            if online then
                flushQueue(instance, function()
                    if cleanup_after then
                        cleanupWifi()
                    end
                end, key, false)
            end
        end)
    end

    if CWASync._offline_queue_handlers_wrapped then
        return
    end
    CWASync._offline_queue_handlers_wrapped = true

    local original_onReaderReady = CWASync.onReaderReady
    CWASync.onReaderReady = function(self)
        if NetworkMgr:isOnline() then
            safe_to_reconnect = true
        end
        if not self.settings.auto_sync then
            return original_onReaderReady(self)
        end

        self.settings.auto_sync = false
        original_onReaderReady(self)
        self.settings.auto_sync = true
        self:registerEvents()
        syncWhenOnline(self, true, true, true)
    end

    CWASync._onResume = function(self)
        if not connecting then
            syncWhenOnline(self, true, true, true)
        end
    end

    CWASync.onIdleSync = function(self)
        queueAndFlush(self, "idle", true)
    end

    CWASync._onSuspend = function(self)
        queueAndFlush(self, "suspend", true)
    end

    CWASync._onCloseDocument = function(self)
        self.onResume = nil
        self.onSuspend = nil
        queueAndFlush(self, "close", true)
    end

    CWASync._onNetworkConnected = function(self)
        safe_to_reconnect = true
        if connecting then
            return
        end
        UIManager:scheduleIn(0.5, function()
            if NetworkMgr:isOnline() then
                flushQueue(self, function(success)
                    if success then
                        pullWithChoice(self, false)
                    end
                end, nil, true)
            end
        end)
    end

    CWASync._onNetworkDisconnecting = function(self)
        if intentional_disconnect then
            return
        end
        safe_to_reconnect = false
        -- Stock CWA pushes directly while the connection is disappearing.
        -- Persist it instead so a different remote position is never replaced.
        queueCurrentProgress(self, "network disconnect")
    end
end)
