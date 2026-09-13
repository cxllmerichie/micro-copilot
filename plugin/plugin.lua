---@class BufPane
---@field Buf Buffer

---@class Buffer
---@field Settings table
---@field VirtualText string
---@field ClearVirtualText function
---@field AddVirtualText function
---@field SetVirtualText function
---@field GetActiveCursor function
---@field Line function
---@field LinesNum function
---@field Insert function

---@class Cursor
---@field X number
---@field Y number
---@field Loc table

---@class Job
---@field Cancel function

local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")
local shell = import("micro/shell")
local json = import("encoding/json")

---@type Job|nil
local active_copilot_stream = nil
---@type Job|nil
local active_steering_stream = nil
---@type number
local fim_request_id = 0
---@type string
local current_virtual_text = ""

---@type string|nil
local cached_steering_prompt = nil
---@type string|nil
local last_prompt_filepath = nil

--- Retrieves a setting from the buffer or global configuration.
---@param bp BufPane The active buffer pane.
---@param key string The setting key to retrieve.
---@return any The value of the setting.
local function get_setting(bp, key)
    local val = bp.Buf.Settings[key]
    if val ~= nil and val ~= "" then return val end
    return config.GetGlobalOption(key)
end

--- Ensures a path string is properly resolved by expanding tildes.
---@param filepath string|nil The raw filepath.
---@return string|nil The expanded filepath.
local function ensurepath(filepath)
    if filepath == nil or type(filepath) ~= "string" or filepath == "" then return filepath end
    local expanded = filepath:gsub("^~", os.getenv("HOME") or "~")
    return expanded
end

--- Clears any active virtual text and cancels ongoing FIM or steering requests.
---@param bp BufPane The active buffer pane.
local function clear_and_cancel(bp)
    if active_copilot_stream ~= nil then
        active_copilot_stream:Cancel()
        active_copilot_stream = nil
    end
    if active_steering_stream ~= nil then
        active_steering_stream:Cancel()
        active_steering_stream = nil
    end
    if bp.Buf ~= nil and bp.Buf.VirtualText ~= "" then
        bp.Buf:ClearVirtualText()
    end
    current_virtual_text = ""
end

--- Gets the text prefix before the cursor up to the configured prefix length.
---@param bp BufPane The active buffer pane.
---@return string The prefix text.
local function get_prefix(bp)
    if bp.Buf == nil then return "" end
    local prefix_len = tonumber(get_setting(bp, "copilot.prefix_len"))
    
    local cursor = bp.Buf:GetActiveCursor()
    local x, y = cursor.X, cursor.Y
    local prefix = ""
    for i = y, 0, -1 do
        local line = bp.Buf:Line(i)
        if i == y then
            prefix = string.sub(line, 1, x)
        else
            prefix = line .. "\n" .. prefix
        end
        if string.len(prefix) >= prefix_len then
            prefix = string.sub(prefix, -prefix_len)
            break
        end
    end
    return prefix
end

--- Gets the text suffix after the cursor up to the configured suffix length.
---@param bp BufPane The active buffer pane.
---@return string The suffix text.
local function get_suffix(bp)
    if bp.Buf == nil then return "" end
    local suffix_len = tonumber(get_setting(bp, "copilot.suffix_len"))
    
    local cursor = bp.Buf:GetActiveCursor()
    local x, y = cursor.X, cursor.Y
    local suffix = ""
    local num_lines = bp.Buf:LinesNum()
    for i = y, num_lines - 1 do
        local line = bp.Buf:Line(i)
        if i == y then
            suffix = string.sub(line, x + 1)
        else
            suffix = suffix .. "\n" .. line
        end
        if string.len(suffix) >= suffix_len then
            suffix = string.sub(suffix, 1, suffix_len)
            break
        end
    end
    return suffix
end


--- Reads and caches the steering prompt from the specified filepath.
---@param filepath string|nil The path to the steering prompt file.
---@return string|nil The contents of the prompt file, or nil if not found/empty.
local function get_steering_prompt(filepath)
    filepath = ensurepath(filepath)
    if filepath == nil or filepath == "" then return nil end
    if cached_steering_prompt ~= nil and filepath == last_prompt_filepath then return cached_steering_prompt end
    
    local file, err = io.open(filepath, "r")
    if file == nil then return nil end
    local prompt = file:read("*all")
    file:close()
    cached_steering_prompt = prompt
    last_prompt_filepath = filepath
    return prompt
end

--- Escapes a value into a JSON string using the built-in json encoder.
---@param val any The value to escape.
---@return string The JSON encoded representation.
local function json_escape(val)
    if val == nil then return "null" end
    return json.encode(val)
end

--- Logs an event to the appropriate log file configured by setting_key.
---@param bp BufPane The active buffer pane.
---@param setting_key string The configuration key containing the log filepath.
---@param event string The event name.
---@param data table The payload data.
local function log_event(bp, setting_key, event_type, fn_name, data)
    local filepath = ensurepath(get_setting(bp, setting_key))

    if filepath == nil or filepath == "" then return end
    
    local f = io.open(filepath, "a")
    if not f then return end

    local lines = {}
    table.insert(lines, "{")
    table.insert(lines, '  "timestamp": ' .. json_escape(os.date()) .. ',')
    table.insert(lines, '  "type": ' .. json_escape(event_type) .. ',')
    table.insert(lines, '  "function": ' .. json_escape(fn_name) .. ',')

    local count = 0
    local size = 0
    for _ in pairs(data) do size = size + 1 end

    for k, v in pairs(data) do
        count = count + 1
        local comma = (count < size) and "," or ""
        table.insert(lines, '  "' .. tostring(k) .. '": ' .. json_escape(v) .. comma)
    end
    table.insert(lines, "}")

    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
end

--- Triggers the Fill-In-the-Middle (FIM) model to generate code completions.
---@param bp BufPane The active buffer pane.
---@param prefix string The text before the cursor.
---@param suffix string The text after the cursor.
---@param request_id number The unique identifier for this FIM request.
local function send_copilot_request(bp, prefix, suffix, request_id)
    log_event(bp, "copilot.log_filepath", "API Request", "send_copilot_request", { request_id = request_id, prefix = prefix, suffix = suffix })
    local url = get_setting(bp, "copilot.url")
    local model = get_setting(bp, "copilot.model")
    local suggest_len = tonumber(get_setting(bp, "copilot.suggest_len"))
    local temp = tonumber(get_setting(bp, "copilot.temperature"))
    
    local payload = json.encode({
        model = model,
        input_prefix = prefix,
        input_suffix = suffix,
        n_predict = suggest_len,
        temperature = temp,
        stream = true
    })
        
    local headers = {"Content-Type", "application/json"}
    current_virtual_text = ""
    
    active_copilot_stream = shell.HttpStream("POST", url, payload, headers, function(out, args)
        if request_id ~= fim_request_id then return end
        
        local dataStr = string.gsub(out, "^data: ", "")
        dataStr = string.gsub(dataStr, "\ndata: ", "\n")
        
        for line in string.gmatch(dataStr, "[^\n]+") do
            if string.match(line, "^error: ") then return end
            if line == "[DONE]" then
                active_copilot_stream = nil
                log_event(bp, "copilot.log_filepath", "API Response", "send_copilot_request", { request_id = request_id, completion = current_virtual_text })
                return
            end
            
            local content = string.match(dataStr, '"content"%s*:%s*"([^"]*)"')
            if content then
                content = string.gsub(content, "\\n", "\n")
                content = string.gsub(content, "\\t", "\t")
                content = string.gsub(content, '\\"', '"')
                content = string.gsub(content, "\\\\", "\\")
                current_virtual_text = current_virtual_text .. content
                bp.Buf:ClearVirtualText()
                bp.Buf:SetVirtualText(current_virtual_text)
            end
        end
    end)
end

--- Sends a steering request to a secondary model before triggering the main FIM model.
---@param bp BufPane The active buffer pane.
---@param prefix string The text before the cursor.
---@param suffix string The text after the cursor.
---@param system_prompt string The system prompt for the steering model.
---@param request_id number The unique identifier for this FIM request.
local function send_steering_request(bp, prefix, suffix, system_prompt, request_id)
    log_event(bp, "copilot.log_filepath", "API Request", "send_steering_request", { request_id = request_id, prefix = prefix, suffix = suffix })
    local url = get_setting(bp, "copilot.steering.url")
    local model = get_setting(bp, "copilot.steering.model")
    local temp = tonumber(get_setting(bp, "copilot.steering.temperature"))
    
    local user_content = "PREFIX:\n" .. prefix .. "\nSUFFIX:\n" .. suffix
    
    local payload = json.encode({
        model = model,
        messages = {
            {role = "system", content = system_prompt},
            {role = "user", content = user_content}
        },
        temperature = temp,
        stream = true
    })
        
    local headers = {"Content-Type", "application/json"}
    local accumulated_comment = ""
    
    active_steering_stream = shell.HttpStream("POST", url, payload, headers, function(out, args)
        if request_id ~= fim_request_id then return end
        
        local dataStr = string.gsub(out, "^data: ", "")
        dataStr = string.gsub(dataStr, "\ndata: ", "\n")
        
        for line in string.gmatch(dataStr, "[^\n]+") do
            if string.match(line, "^error: ") then 
                send_copilot_request(bp, prefix, suffix, request_id)
                return
            end
            if line == "[DONE]" then
                active_steering_stream = nil
                log_event(bp, "copilot.log_filepath", "API Response", "send_steering_request", { request_id = request_id, comment = accumulated_comment })
                
                if accumulated_comment ~= "" then
                    local comment_prefix = prefix .. accumulated_comment .. "\n"
                    log_event(bp, "copilot.steering.log_filepath", "Flow", "send_steering_request", {
                        prefix = prefix,
                        suffix = suffix,
                        comment = accumulated_comment,
                        outcome = comment_prefix
                    })
                    send_copilot_request(bp, comment_prefix, suffix, request_id)
                else
                    send_copilot_request(bp, prefix, suffix, request_id)
                end
                return
            end
            
            local content = string.match(dataStr, '"content"%s*:%s*"([^"]*)"')
            if content then
                content = string.gsub(content, "\\n", "\n")
                content = string.gsub(content, "\\t", "\t")
                content = string.gsub(content, '\\"', '"')
                content = string.gsub(content, "\\\\", "\\")
                accumulated_comment = accumulated_comment .. content
            end
        end
    end)
end

--- Schedules a FIM request to be executed after the configured delay.
---@param bp BufPane The active buffer pane.
local function trigger_copilot(bp)
    log_event(bp, "copilot.log_filepath", "Flow", "trigger_copilot", {})
    if bp.Buf == nil then return end
    clear_and_cancel(bp)
    
    local delay = tonumber(get_setting(bp, "copilot.trigger_delay_ms"))
    
    fim_request_id = fim_request_id + 1
    local current_id = fim_request_id

    micro.After(delay * 1000000, function()
        if current_id ~= fim_request_id then return end
        if bp.Buf == nil then return end
        local prefix = get_prefix(bp)
        local suffix = get_suffix(bp)
        
        local prompt_path = ensurepath(get_setting(bp, "copilot.steering.prompt_filepath"))
        local system_prompt = get_steering_prompt(prompt_path)
        
        if system_prompt ~= nil and system_prompt ~= "" then
            log_event(bp, "copilot.log_filepath", "Flow", "trigger_copilot", {
                action = "Steering triggered",
                prompt_path = prompt_path,
                system_prompt = system_prompt
            })
            send_steering_request(bp, prefix, suffix, system_prompt, current_id)
        else
            log_event(bp, "copilot.log_filepath", "Flow", "trigger_copilot", {
                action = "Skipping steering. System_prompt is nil or empty",
                prompt_path = prompt_path,
                system_prompt = system_prompt
            })
            send_copilot_request(bp, prefix, suffix, current_id)
        end
    end)
end

--- Hook: Called when a rune (character) is typed.
---@param bp BufPane The active buffer pane.
---@param r string The rune typed.
function onRune(bp, r)
    log_event(bp, "copilot.log_filepath", "Hook", "onRune", { rune = r })
    trigger_copilot(bp)
end

--- Hook: Called before a newline is inserted.
---@param bp BufPane The active buffer pane.
---@return boolean Whether the original action should proceed.
function preInsertNewline(bp)
    log_event(bp, "copilot.log_filepath", "Hook", "preInsertNewline", {})
    trigger_copilot(bp)
    return true
end

--- Hook: Called before a backspace is executed.
---@param bp BufPane The active buffer pane.
---@return boolean Whether the original action should proceed.
function preBackspace(bp)
    log_event(bp, "copilot.log_filepath", "Hook", "preBackspace", {})
    trigger_copilot(bp)
    return true
end

--- Hook: Called before a delete is executed.
---@param bp BufPane The active buffer pane.
---@return boolean Whether the original action should proceed.
function preDelete(bp)
    log_event(bp, "copilot.log_filepath", "Hook", "preDelete", {})
    trigger_copilot(bp)
    return true
end

--- Hook: Called before cursor moves up.
---@param bp BufPane The active buffer pane.
---@return boolean Whether the original action should proceed.
function preCursorUp(bp)
    log_event(bp, "copilot.log_filepath", "Hook", "preCursorUp", {})
    clear_and_cancel(bp)
    return true
end

--- Hook: Called before cursor moves down.
---@param bp BufPane The active buffer pane.
---@return boolean Whether the original action should proceed.
function preCursorDown(bp)
    log_event(bp, "copilot.log_filepath", "Hook", "preCursorDown", {})
    clear_and_cancel(bp)
    return true
end

--- Hook: Called before cursor moves left.
---@param bp BufPane The active buffer pane.
---@return boolean Whether the original action should proceed.
function preCursorLeft(bp)
    log_event(bp, "copilot.log_filepath", "Hook", "preCursorLeft", {})
    clear_and_cancel(bp)
    return true
end

--- Hook: Called before cursor moves right.
---@param bp BufPane The active buffer pane.
---@return boolean Whether the original action should proceed.
function preCursorRight(bp)
    log_event(bp, "copilot.log_filepath", "Hook", "preCursorRight", {})
    clear_and_cancel(bp)
    return true
end

--- Accepts the first line of the current virtual text completion.
---@param bp BufPane The active buffer pane.
function accept_line_virtual_text(bp)
    log_event(bp, "copilot.log_filepath", "Action", "accept_line_virtual_text", { current_virtual_text = current_virtual_text })
    if bp.Buf ~= nil and bp.Buf.VirtualText ~= "" then
        local text = bp.Buf.VirtualText
        local idx = string.find(text, "\n")
        local to_insert = text
        if idx ~= nil then
            to_insert = string.sub(text, 1, idx)
        end
        local loc = bp.Buf:GetActiveCursor().Loc
        bp.Buf:Insert(buffer.Loc(loc.X, loc.Y), to_insert)
        
        if idx == nil then
            bp.Buf:ClearVirtualText()
            current_virtual_text = ""
        else
            current_virtual_text = string.sub(text, idx + 1)
            bp.Buf:SetVirtualText(current_virtual_text)
        end
    end
end

--- Accepts the entire current virtual text completion.
---@param bp BufPane The active buffer pane.
function accept_full_virtual_text(bp)
    log_event(bp, "copilot.log_filepath", "Action", "accept_full_virtual_text", { current_virtual_text = current_virtual_text })
    if bp.Buf ~= nil and bp.Buf.VirtualText ~= "" then
        local text = bp.Buf.VirtualText
        bp.Buf:ClearVirtualText()
        current_virtual_text = ""
        local loc = bp.Buf:GetActiveCursor().Loc
        bp.Buf:Insert(buffer.Loc(loc.X, loc.Y), text)
    end
end

---@type string
local bound_line_shortcut = ""
---@type string
local bound_full_shortcut = ""

--- Binds the dynamic shortcuts for accepting completions.
---@param bp BufPane The active buffer pane.
function bind_shortcuts(bp)
    log_event(bp, "copilot.log_filepath", "Flow", "bind_shortcuts", {})
    if bp == nil or bp.Buf == nil then return end
    
    local line_shortcut = tostring(get_setting(bp, "copilot.accept_line_shortcut"))
    if line_shortcut ~= bound_line_shortcut then
        config.TryBindKey(line_shortcut, "command:copilot_accept_line", true)
        bound_line_shortcut = line_shortcut
    end

    local full_shortcut = tostring(get_setting(bp, "copilot.accept_full_shortcut"))
    if full_shortcut ~= bound_full_shortcut then
        config.TryBindKey(full_shortcut, "command:copilot_accept_full", true)
        bound_full_shortcut = full_shortcut
    end
end

--- Hook: Called after any action is executed.
---@param bp BufPane The active buffer pane.
---@param action string The action that was executed.
function onAction(bp, action)
    log_event(bp, "copilot.log_filepath", "Hook", "onAction", { action = action })
    bind_shortcuts(bp)
end

--- Hook: Called when a new buffer pane is opened.
---@param bp BufPane The active buffer pane.
function onBufPaneOpen(bp)
    log_event(bp, "copilot.log_filepath", "Hook", "onBufPaneOpen", {})
    bind_shortcuts(bp)
end

--- Hook: Initializes the plugin and registers configuration options before buffers load.
function preinit()
    config.MakeCommand("copilot_accept_line", accept_line_virtual_text, config.NoComplete)
    config.MakeCommand("copilot_accept_full", accept_full_virtual_text, config.NoComplete)
    
    config.RegisterCommonOption("copilot", "url", "http://127.0.0.1:65432/infill")
    config.RegisterCommonOption("copilot", "model", "deepseek-coder-1.3b-base.Q8_0.gguf")
    config.RegisterCommonOption("copilot", "trigger_delay_ms", 250)
    config.RegisterCommonOption("copilot", "accept_line_shortcut", "Alt-l")
    config.RegisterCommonOption("copilot", "accept_full_shortcut", "Alt-Shift-l")
    config.RegisterCommonOption("copilot", "text_color", "gray")
    config.RegisterCommonOption("copilot", "log_filepath", ensurepath("~/.config/micro/plug/copilot/events.log"))
    config.RegisterCommonOption("copilot", "prefix_len", 1024)
    config.RegisterCommonOption("copilot", "suffix_len", 256)
    config.RegisterCommonOption("copilot", "suggest_len", 64)
    config.RegisterCommonOption("copilot", "temperature", 0.1)
    
    config.RegisterCommonOption("copilot", "steering.url", "http://127.0.0.1:65433/v1/chat/completions")
    config.RegisterCommonOption("copilot", "steering.model", "llama-3.2-1b-instruct-q8_0.gguf")
    config.RegisterCommonOption("copilot", "steering_temperature", 0.1)
    config.RegisterCommonOption("copilot", "steering.prompt_filepath", ensurepath(""))
    config.RegisterCommonOption("copilot", "steering.log_filepath", ensurepath("~/.config/micro/plug/copilot-steering/events.log"))
end
