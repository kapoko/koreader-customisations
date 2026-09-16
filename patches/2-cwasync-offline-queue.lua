local userpatch = require("userpatch")

userpatch.registerPatchPluginFunc("cwasync", function(CWASync)
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local Device = require("device")
    local logger = require("logger")
    local md5 = require("ffi/sha2").md5
    local CWASyncClient = require("CWASyncClient")

    local QUEUE_KEY = "cwasync_pending_progress_queue"

    ----------------------------------------------------------------
    -- Shared module state
    ----------------------------------------------------------------

    local STATE = CWASyncClient._cwasync_offline_queue_state

    if not STATE then
        STATE = {
            instance = nil,
            next_request_session = nil,
            queue_flushing = false,
            queue_waiters = {},
        }

        CWASyncClient._cwasync_offline_queue_state = STATE
    end

    ----------------------------------------------------------------
    -- Persistent queue
    ----------------------------------------------------------------

    local function getQueue()
        return G_reader_settings:readSetting(QUEUE_KEY, {})
    end

    local function persistQueue(queue)
        G_reader_settings:saveSetting(QUEUE_KEY, queue)

        -- Pending progress exists specifically to survive restarts,
        -- crashes and shutdowns, so write it immediately.
        if G_reader_settings.flush then
            G_reader_settings:flush()
        end
    end

    local function makeQueueKey(server, username, document)
        return md5(
            tostring(server)
            .. "\0"
            .. tostring(username)
            .. "\0"
            .. tostring(document)
        )
    end

    local function removeQueueItem(key)
        local queue = getQueue()

        if queue[key] then
            logger.dbg(
                "CWA offline queue: removing",
                queue[key].document
            )

            queue[key] = nil
            persistQueue(queue)
        end
    end

    local function findMatchingItem(
        queue,
        server,
        username,
        skipped,
        preferred_key
    )
        if preferred_key
            and not skipped[preferred_key]
        then
            local preferred = queue[preferred_key]

            if preferred
                and preferred.server == server
                and preferred.username == username
            then
                return preferred_key, preferred
            end
        end

        for key, item in pairs(queue) do
            if not skipped[key]
                and item.server == server
                and item.username == username
            then
                return key, item
            end
        end

        return nil, nil
    end

    ----------------------------------------------------------------
    -- Wi-Fi state
    --
    -- This deliberately preserves the behavior of the last
    -- silent-offline patch:
    --
    -- * already online -> use it
    -- * KOReader previously disconnected a known-good connection
    --   -> reconnect silently
    -- * genuinely offline / Wi-Fi intent unknown -> do NOTHING
    --
    -- This avoids the PocketBook "turn Wi-Fi on" nag loop.
    ----------------------------------------------------------------

    local safe_to_reconnect = false
    local silent_connect_in_progress = false
    local intentional_disconnect = false

    local function cleanupWifi()
        intentional_disconnect = true

        logger.dbg(
            "CWA offline queue: network work finished; afterWifiAction"
        )

        NetworkMgr:afterWifiAction()

        UIManager:scheduleIn(2, function()
            intentional_disconnect = false
        end)
    end

    ----------------------------------------------------------------
    -- Queue flush
    --
    -- Sequential:
    --
    -- GET remote state
    --   ↓
    -- determine which state is newer
    --   ↓
    -- PUSH only when queued state is safe to apply
    --
    -- This prevents an old offline state from overwriting newer
    -- progress made on another device.
    ----------------------------------------------------------------

    local function flushQueue(instance, done, preferred_key)
        done = done or function() end

        if STATE.queue_flushing then
            table.insert(STATE.queue_waiters, done)
            return
        end

        if not instance
            or not instance.settings
            or not instance.settings.server
            or not instance.settings.username
            or not instance.settings.password
        then
            done(false)
            return
        end

        if not NetworkMgr:isOnline() then
            done(false)
            return
        end

        local server = instance.settings.server
        local username = instance.settings.username
        local password = instance.settings.password
        local service_spec = instance.path .. "/api.json"

        local initial_queue = getQueue()
        local skipped = {}

        local first_key = findMatchingItem(
            initial_queue,
            server,
            username,
            skipped,
            preferred_key
        )

        if not first_key then
            done(true)
            return
        end

        STATE.queue_flushing = true
        STATE.queue_waiters = { done }

        logger.dbg(
            "CWA offline queue: starting flush"
        )

        local finished = false

        local function finishFlush(success)
            if finished then
                return
            end

            finished = true
            STATE.queue_flushing = false

            local waiters = STATE.queue_waiters
            STATE.queue_waiters = {}

            logger.dbg(
                "CWA offline queue: flush finished",
                success
            )

            for _, waiter in ipairs(waiters) do
                local ok, err = pcall(waiter, success)

                if not ok then
                    logger.warn(
                        "CWA offline queue: waiter failed:",
                        err
                    )
                end
            end
        end

        local processNext

        ------------------------------------------------------------
        -- Push one item
        ------------------------------------------------------------

        local function pushItem(key, item)
            if not NetworkMgr:isOnline() then
                finishFlush(false)
                return
            end

            logger.dbg(
                "CWA offline queue: pushing",
                item.document,
                item.percentage
            )

            local client = CWASyncClient:new{
                service_url = server .. "/kosync",
                service_spec = service_spec,
            }

            -- Prevent our generic client wrapper from mistaking this
            -- direct queue request for the current-book operation.
            client._cwasync_queue_request = true

            local ok, err = pcall(
                client.update_progress,
                client,
                username,
                password,
                item.document,
                item.progress,
                item.percentage,
                item.device or Device.model,
                item.device_id or instance.device_id,
                function(success, body)
                    if not success then
                        logger.warn(
                            "CWA offline queue: push failed; keeping item",
                            item.document
                        )

                        finishFlush(false)
                        return
                    end

                    logger.dbg(
                        "CWA offline queue: push succeeded",
                        item.document
                    )

                    removeQueueItem(key)
                    processNext()
                end
            )

            if not ok then
                logger.warn(
                    "CWA offline queue: error starting push:",
                    err
                )

                finishFlush(false)
            end
        end

        ------------------------------------------------------------
        -- Process next pending book
        ------------------------------------------------------------

        processNext = function()
            if not NetworkMgr:isOnline() then
                finishFlush(false)
                return
            end

            local queue = getQueue()

            local key, item = findMatchingItem(
                queue,
                server,
                username,
                skipped,
                preferred_key
            )

            -- Preferred item only needs preference once.
            preferred_key = nil

            if not key then
                finishFlush(true)
                return
            end

            logger.dbg(
                "CWA offline queue: checking remote state for",
                item.document
            )

            local client = CWASyncClient:new{
                service_url = server .. "/kosync",
                service_spec = service_spec,
            }

            client._cwasync_queue_request = true

            local ok, err = pcall(
                client.get_progress,
                client,
                username,
                password,
                item.document,
                function(success, body)
                    ------------------------------------------------
                    -- Network/server problem.
                    --
                    -- Keep everything and wait for the next
                    -- opportunity.
                    ------------------------------------------------

                    if not success then
                        logger.warn(
                            "CWA offline queue: remote check failed; keeping item",
                            item.document
                        )

                        finishFlush(false)
                        return
                    end

                    ------------------------------------------------
                    -- CWA itself treats a non-table response as an
                    -- invalid/error response.
                    ------------------------------------------------

                    if type(body) ~= "table" then
                        logger.warn(
                            "CWA offline queue: invalid remote response; keeping item",
                            item.document
                        )

                        finishFlush(false)
                        return
                    end

                    ------------------------------------------------
                    -- No percentage = CWA has no progress for this
                    -- document.
                    --
                    -- Safe to upload our queued state.
                    ------------------------------------------------

                    if body.percentage == nil then
                        logger.dbg(
                            "CWA offline queue: no remote progress; pushing",
                            item.document
                        )

                        pushItem(key, item)
                        return
                    end

                    ------------------------------------------------
                    -- Percentage exists but progress doesn't:
                    -- malformed state. Never overwrite blindly.
                    ------------------------------------------------

                    if body.progress == nil then
                        logger.warn(
                            "CWA offline queue: malformed remote state; keeping item",
                            item.document
                        )

                        finishFlush(false)
                        return
                    end

                    ------------------------------------------------
                    -- Exact same reading position already exists.
                    ------------------------------------------------

                    if tostring(body.progress)
                        == tostring(item.progress)
                    then
                        logger.dbg(
                            "CWA offline queue: remote already matches",
                            item.document
                        )

                        removeQueueItem(key)
                        processNext()
                        return
                    end

                    ------------------------------------------------
                    -- Modern CWA server:
                    --
                    -- Compare server timestamp with the time at
                    -- which we captured the offline close.
                    --
                    -- Stock CWA uses the server timestamp against
                    -- os.time()-based local reading timestamps too.
                    ------------------------------------------------

                    local remote_timestamp =
                        tonumber(body.timestamp)

                    local queued_timestamp =
                        tonumber(item.queued_at)

                    if remote_timestamp
                        and queued_timestamp
                    then
                        if remote_timestamp
                            > queued_timestamp
                        then
                            ----------------------------------------
                            -- Another state reached CWA after our
                            -- offline close. Remote wins.
                            ----------------------------------------

                            logger.dbg(
                                "CWA offline queue: remote state newer; discarding stale queue item",
                                item.document
                            )

                            removeQueueItem(key)
                            processNext()
                            return
                        end

                        if remote_timestamp
                            == queued_timestamp
                            and (
                                body.device ~= item.device
                                or body.device_id
                                    ~= item.device_id
                            )
                        then
                            ----------------------------------------
                            -- Same timestamp from another device.
                            -- Conservative choice: remote wins.
                            ----------------------------------------

                            logger.dbg(
                                "CWA offline queue: timestamp tie from another device; remote wins",
                                item.document
                            )

                            removeQueueItem(key)
                            processNext()
                            return
                        end

                        --------------------------------------------
                        -- Our queued close is newer, or the same
                        -- timestamp belongs to this same device.
                        --------------------------------------------

                        pushItem(key, item)
                        return
                    end

                    ------------------------------------------------
                    -- Legacy server without timestamps.
                    --
                    -- If the remote state belongs to THIS device,
                    -- the queued close is known to be later local
                    -- state which failed to reach CWA.
                    ------------------------------------------------

                    if body.device == item.device
                        and body.device_id == item.device_id
                    then
                        logger.dbg(
                            "CWA offline queue: legacy server, same device; pushing",
                            item.document
                        )

                        pushItem(key, item)
                        return
                    end

                    ------------------------------------------------
                    -- Legacy server + different device:
                    --
                    -- We cannot safely know which position is newer.
                    -- Keep this item for later, but don't let it
                    -- block syncing unrelated queued books.
                    ------------------------------------------------

                    logger.warn(
                        "CWA offline queue: cannot safely order legacy remote state; leaving item queued",
                        item.document
                    )

                    skipped[key] = true
                    processNext()
                end
            )

            if not ok then
                logger.warn(
                    "CWA offline queue: error starting remote check:",
                    err
                )

                finishFlush(false)
            end
        end

        processNext()
    end

    ----------------------------------------------------------------
    -- Watch exactly one normal CWA HTTP request.
    --
    -- This lets us run:
    --
    -- current book sync
    --     ↓
    -- pending queue
    --     ↓
    -- afterWifiAction()
    --
    -- only after the actual asynchronous CWA request completed.
    ----------------------------------------------------------------

    if not CWASyncClient._offline_queue_client_wrapped then
        CWASyncClient._offline_queue_client_wrapped = true

        local original_push = CWASyncClient.update_progress
        local original_pull = CWASyncClient.get_progress

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
            local session = nil

            if not client._cwasync_queue_request
                and STATE.next_request_session
            then
                session = STATE.next_request_session
                STATE.next_request_session = nil
            end

            local wrapped_callback = callback

            if session then
                wrapped_callback = function(ok, body)
                    if callback then
                        callback(ok, body)
                    end

                    session.done(ok, body)
                end
            end

            local ok, result = pcall(
                original_push,
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

            if not ok then
                if session then
                    session.done(false, nil)
                end

                error(result)
            end

            return result
        end

        CWASyncClient.get_progress = function(
            client,
            username,
            password,
            document,
            callback
        )
            local session = nil

            if not client._cwasync_queue_request
                and STATE.next_request_session
            then
                session = STATE.next_request_session
                STATE.next_request_session = nil
            end

            local wrapped_callback = callback

            if session then
                wrapped_callback = function(ok, body)
                    if callback then
                        callback(ok, body)
                    end

                    session.done(ok, body)
                end
            end

            local ok, result = pcall(
                original_pull,
                client,
                username,
                password,
                document,
                wrapped_callback
            )

            if not ok then
                if session then
                    session.done(false, nil)
                end

                error(result)
            end

            return result
        end
    end

    ----------------------------------------------------------------
    -- Run a current-book CWA operation.
    --
    -- cleanup_after:
    --   true  -> queue, then afterWifiAction()
    --   false -> queue, but leave current network state alone
    --
    -- The false case is useful for an externally-established
    -- NetworkConnected event.
    ----------------------------------------------------------------

    local function runManagedOperation(
        instance,
        operation,
        cleanup_after
    )
        local completed = false

        local function finish(ok)
            if completed then
                return
            end

            completed = true

            if not ok then
                if cleanup_after then
                    cleanupWifi()
                end

                return
            end

            flushQueue(instance, function()
                if cleanup_after then
                    cleanupWifi()
                end
            end)
        end

        STATE.next_request_session = {
            done = function(ok, body)
                finish(ok)
            end,
        }

        local ok, err = pcall(operation)

        if not ok then
            logger.warn(
                "CWA offline queue: managed CWA operation failed:",
                err
            )

            STATE.next_request_session = nil
            finish(false)
            return
        end

        ------------------------------------------------------------
        -- No HTTP request consumed the one-shot session.
        --
        -- This happens when CWA debounces the call, has no digest,
        -- etc. We still have a valid network session, so use it to
        -- flush old pending books.
        ------------------------------------------------------------

        if STATE.next_request_session then
            STATE.next_request_session = nil

            flushQueue(instance, function()
                if cleanup_after then
                    cleanupWifi()
                end
            end)
        end
    end

    ----------------------------------------------------------------
    -- Silent PocketBook networking
    ----------------------------------------------------------------

    local function silentlyGetOnline(callback)
        if NetworkMgr:isOnline() then
            safe_to_reconnect = true

            --------------------------------------------------------
            -- Preserve the behavior you liked:
            -- "Action when done with Wi-Fi" still applies even when
            -- the connection was already up.
            --------------------------------------------------------

            NetworkMgr:setBeforeActionFlag()

            callback(true)
            return
        end

        ------------------------------------------------------------
        -- CRITICAL:
        --
        -- Don't call WiFiPower(1) unless we already KNOW this is a
        -- connection KOReader previously disconnected itself.
        --
        -- When PocketBook Wi-Fi is genuinely off, this returns
        -- silently with zero dialog.
        ------------------------------------------------------------

        if not safe_to_reconnect then
            logger.dbg(
                "CWA offline queue: offline; reconnect not known safe, skipping"
            )

            callback(false)
            return
        end

        if silent_connect_in_progress then
            logger.dbg(
                "CWA offline queue: silent connection already in progress"
            )

            callback(false)
            return
        end

        silent_connect_in_progress = true

        NetworkMgr:setBeforeActionFlag()

        logger.dbg(
            "CWA offline queue: silently reconnecting known Wi-Fi session"
        )

        local attempts = 0
        local max_attempts = 12 -- ~6 seconds
        local finished = false

        local function finish(success)
            if finished then
                return
            end

            finished = true
            silent_connect_in_progress = false

            if success then
                safe_to_reconnect = true

                logger.dbg(
                    "CWA offline queue: silent reconnect succeeded"
                )

                callback(true)
                return
            end

            --------------------------------------------------------
            -- A known-safe reconnect stopped being safe.
            --
            -- Most importantly, never keep hammering the PocketBook
            -- Wi-Fi dialog.
            --------------------------------------------------------

            safe_to_reconnect = false

            logger.dbg(
                "CWA offline queue: reconnect failed; disabling automatic retries"
            )

            cleanupWifi()
            callback(false)
        end

        local function checkConnection()
            if finished then
                return
            end

            attempts = attempts + 1

            if NetworkMgr:isOnline() then
                finish(true)
                return
            end

            if attempts >= max_attempts then
                finish(false)
                return
            end

            UIManager:scheduleIn(
                0.5,
                checkConnection
            )
        end

        local status = NetworkMgr:turnOnWifi(function()
            UIManager:scheduleIn(
                0.5,
                checkConnection
            )
        end)

        if status == false then
            finish(false)
        end
    end

    ----------------------------------------------------------------
    -- Install lifecycle handlers only once
    ----------------------------------------------------------------

    if CWASync._offline_queue_handlers_wrapped then
        return
    end

    CWASync._offline_queue_handlers_wrapped = true

    ----------------------------------------------------------------
    -- Reader ready
    ----------------------------------------------------------------

    local original_onReaderReady =
        CWASync.onReaderReady

    CWASync.onReaderReady = function(self)
        STATE.instance = self

        if NetworkMgr:isOnline() then
            safe_to_reconnect = true
        end

        if not self.settings.auto_sync then
            return original_onReaderReady(self)
        end

        ------------------------------------------------------------
        -- Let stock CWA do all normal reader initialization while
        -- suppressing ONLY its automatic networking attempt.
        ------------------------------------------------------------

        local auto_sync =
            self.settings.auto_sync

        self.settings.auto_sync = false

        original_onReaderReady(self)

        self.settings.auto_sync = auto_sync
        self:registerEvents()

        silentlyGetOnline(function(online)
            if not online then
                return
            end

            runManagedOperation(
                self,
                function()
                    self:getProgress(false, false)
                end,
                true
            )
        end)
    end

    ----------------------------------------------------------------
    -- Resume
    ----------------------------------------------------------------

    CWASync._onResume = function(self)
        STATE.instance = self

        logger.dbg(
            "CWA offline queue: onResume"
        )

        ------------------------------------------------------------
        -- PocketBook networking itself can generate Suspend/Resume.
        ------------------------------------------------------------

        if silent_connect_in_progress then
            logger.dbg(
                "CWA offline queue: ignoring Resume during silent connection"
            )

            return
        end

        silentlyGetOnline(function(online)
            if not online then
                return
            end

            runManagedOperation(
                self,
                function()
                    self:getProgress(false, false)
                end,
                true
            )
        end)
    end

    ----------------------------------------------------------------
    -- Suspend
    ----------------------------------------------------------------

    CWASync._onSuspend = function(self)
        STATE.instance = self

        logger.dbg(
            "CWA offline queue: onSuspend"
        )

        if silent_connect_in_progress then
            logger.dbg(
                "CWA offline queue: ignoring Suspend during silent connection"
            )

            return
        end

        silentlyGetOnline(function(online)
            if not online then
                return
            end

            runManagedOperation(
                self,
                function()
                    ------------------------------------------------
                    -- Stock CWA's on_suspend=true path disconnects
                    -- Wi-Fi immediately after STARTING its async
                    -- request.
                    --
                    -- We wait for the actual HTTP completion instead.
                    ------------------------------------------------

                    self:updateProgress(
                        false,
                        false,
                        false
                    )
                end,
                true
            )
        end)
    end

    ----------------------------------------------------------------
    -- Close document
    ----------------------------------------------------------------

    CWASync._onCloseDocument = function(self)
        STATE.instance = self

        logger.dbg(
            "CWA offline queue: onCloseDocument"
        )

        ------------------------------------------------------------
        -- Prevent PocketBook focus/network events from initiating
        -- more document operations during teardown.
        ------------------------------------------------------------

        self.onResume = nil
        self.onSuspend = nil

        if not self.settings.auto_sync
            or not self.settings.username
            or not self.settings.password
            or not self.settings.server
        then
            return
        end

        ------------------------------------------------------------
        -- Capture EVERYTHING before the document object disappears.
        ------------------------------------------------------------

        local document =
            self:getDocumentDigest()

        if not document then
            logger.warn(
                "CWA offline queue: cannot queue close; no document digest"
            )

            return
        end

        local key = makeQueueKey(
            self.settings.server,
            self.settings.username,
            document
        )

        local queue = getQueue()

        ------------------------------------------------------------
        -- Latest close wins for this book/account/server.
        ------------------------------------------------------------

        queue[key] = {
            document = document,

            progress =
                self:getLastProgress(),

            percentage =
                self:getLastPercent(),

            device =
                Device.model,

            device_id =
                self.device_id,

            queued_at =
                os.time(),

            server =
                self.settings.server,

            username =
                self.settings.username,
        }

        persistQueue(queue)

        logger.dbg(
            "CWA offline queue: persisted close progress",
            document,
            queue[key].percentage
        )

        ------------------------------------------------------------
        -- If Wi-Fi genuinely isn't available/allowed, this simply
        -- returns. The queued state remains safely on disk.
        ------------------------------------------------------------

        silentlyGetOnline(function(online)
            if not online then
                return
            end

            --------------------------------------------------------
            -- Current closed book gets priority.
            --
            -- No live document object is needed anymore.
            --------------------------------------------------------

            flushQueue(
                self,
                function()
                    cleanupWifi()
                end,
                key
            )
        end)
    end

    ----------------------------------------------------------------
    -- Network connected
    ----------------------------------------------------------------

    local original_onNetworkDisconnecting =
        CWASync._onNetworkDisconnecting

    CWASync._onNetworkConnected = function(self)
        STATE.instance = self
        safe_to_reconnect = true

        logger.dbg(
            "CWA offline queue: NetworkConnected"
        )

        ------------------------------------------------------------
        -- Our own silent reconnect already has an operation waiting
        -- for it. Don't launch CWA's duplicate pull.
        ------------------------------------------------------------

        if silent_connect_in_progress then
            logger.dbg(
                "CWA offline queue: suppressing duplicate NetworkConnected pull"
            )

            return
        end

        ------------------------------------------------------------
        -- Match stock CWA's 0.5 s delay.
        --
        -- Because this network connection came from elsewhere, don't
        -- automatically turn it off afterward. We still use it to
        -- pull the current book and flush the pending queue.
        ------------------------------------------------------------

        UIManager:scheduleIn(0.5, function()
            if not NetworkMgr:isOnline() then
                return
            end

            runManagedOperation(
                self,
                function()
                    self:getProgress(false, false)
                end,
                false
            )
        end)
    end

    ----------------------------------------------------------------
    -- Network disconnecting
    ----------------------------------------------------------------

    CWASync._onNetworkDisconnecting = function(self)
        STATE.instance = self

        if intentional_disconnect then
            --------------------------------------------------------
            -- This is our post-sync NetDisconnect().
            --
            -- Do not let stock CWA start another push while the
            -- connection is being deliberately torn down.
            --------------------------------------------------------

            logger.dbg(
                "CWA offline queue: intentional post-sync disconnect"
            )

            intentional_disconnect = false
            safe_to_reconnect = true

            return
        end

        ------------------------------------------------------------
        -- Something outside us initiated the disconnect.
        -- Don't assume we may turn Wi-Fi back on automatically.
        ------------------------------------------------------------

        logger.dbg(
            "CWA offline queue: external disconnect; clearing reconnect permission"
        )

        safe_to_reconnect = false

        return original_onNetworkDisconnecting(self)
    end
end)
