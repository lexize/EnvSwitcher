local cfg; -- Config struct

local log_colors = {
    INFO = "#55FF55",
    DEBUG = "#00AA00",
    WARNING = "#FFAA00",
    ERROR = "#FF5555",
    FATAL = "#FF0000"
}

---Log function
---@param message any
---@param level? "INFO"|"DEBUG"|"WARNING"|"ERROR"|"FATAL"
local function log(message, level, env)
    local level = (level or "INFO"):upper();
    if level ~= "DEBUG" or (cfg and cfg.__debug) then
        local prefix;
        if env ~= nil and env ~= "___ROOT___" then
            prefix = level.." | "..env;
        else
            prefix = level;
        end
        local text = {text = ("[ %s ] %s\n"):format(prefix, message), color = log_colors[level] or log_colors.INFO};
        printJson(toJson(text));
    end
end

---@param path string
---@return string? Content
local function load_res(path)
    local res_stream = resources:get(path) --[[@as InputStream]];
    if res_stream == nil then
        return
    end
    local res_buf = data:createBuffer();
    res_buf:readFromStream(res_stream);
    res_buf:setPosition(0);
    local content = res_buf:readString();
    res_stream:close();
    res_buf:close();
    return content;
end

--#region LOADING CONFIG
local cfg_string = load_res("envswitcher.json");
if cfg_string == nil then
    log("Unable to find envswitcher.json. Terminating the EnvSwitcher.", "FATAL");
    return;
end
cfg = parseJson(cfg_string) --[[@as table]];
--#endregion

log("Debug mode is active", "DEBUG");

--#region PARSING CONFIG
local global_script_dirs = cfg.global_script_dirs or {};

log(("Global script directories: [ %s ]"):format(table.concat(global_script_dirs, ", ")), "DEBUG");

---@class EnvTable
---@field id string
---@field requires table<string, any[]>
---@field script_dir string
---@field action_wheel Page?
---@field events table<Event, {f: function, n: string}[]>
---@field env table
---@field model_root? ModelPart
---@field root_visibility boolean
---@field auto_scripts string[]
---@field initialized boolean

local active_environment;
local default_environment;
---@type table<string, EnvTable>
local environments = {};
local environment_ids = {};

for i, env in ipairs(cfg.environments) do
    local id = env.id;
    if id == nil then
        log(("Id is not specified for environment #%s. Skipping."):format(i), "ERROR");
        goto continue
    elseif id == "___ROOT___" then
        log(("___ROOT___ is internal environment ID, that is reserved. Skipping environment #%s"):format(i), "ERROR");
        goto continue
    end
    
    if env.default then
        if default_environment ~= nil then
            log(("Default environment has already been set to %s. Overwriting it to %s."):format(default_environment, id), "WARNING");
        else
            log(("Setting %s as default environment."):format(id), "DEBUG");
        end
        default_environment = id;
    end

    local env_models = {};

    for _, model_name in ipairs(env.models or {}) do
        local model = models[model_name];
        if model ~= nil then
            models:removeChild(model);
            env_models[#env_models+1] = model;
        end
    end

    local model_root = models:newPart(id);

    model_root:setVisible(false);

    local senv = {
        models = model_root
    };


    for _, model in ipairs(env_models) do
        model_root:addChild(model);
    end

    ---@type EnvTable
    local env_table = {
        id = id,
        requires = {},
        script_dir = env.script_dir or id,
        action_wheel = nil,
        events = {},
        env = senv,
        model_root = model_root,
        root_visibility = true,
        auto_scripts= env.auto_scripts or {},
        initialized = false
    };

    environments[id] = env_table;
    environment_ids[#environment_ids+1] = id;
    ::continue::
end

if #environment_ids == 0 then
    log("No environments found. Terminating the EnvSwitcher.", "FATAL");
    return;
end

if default_environment == nil then
    default_environment = "___ROOT___";
end

-- Defining internal environment
environments.___ROOT___ = {
    id = "___ROOT___",
    requires = {},
    script_dir = "",
    action_wheel = nil,
    events = {},
    env = {},
    root_visibility = false,
    auto_scripts = {},
    initialized = true
}

--#endregion

function environment_id()
    return active_environment or "___ROOT___"
end

--#region REDEFINING EVENT CLASS BEHAVIOR
local old_event = figuraMetatables.Event.__index;

local new_event = {};

local function remove_handlers(tbl, name)
    for i = 1, tbl, 1 do
        local h = tbl[i];
        if h.n == name then
            table.remove(tbl, i);
            i = i - 1;
        end
    end
end

function new_event:register(func, name)
    local f_type = type(func);
    if f_type ~= "function" then
        log(("Event expects function as a handler, not %s"):format(f_type), "FATAL", active_environment);
        error("Unable to create an Event handler");
    end
    local n_type = type(name);
    if name ~= nil and n_type ~= "string" then
        log(("Event expects string as handler name, not %s"):format(n_type), "FATAL", active_environment);
        error("Unable to create an Event handler");
    end

    local events = environments[environment_id()].events;
    events[self] = events[self] or {};
    local handlers = events[self];
    handlers[#handlers+1] = {f = func, n = name};
    old_event.register(self, func, name);
    log("Registered new event", "DEBUG", active_environment);
    return self;
end

function new_event:remove(name)
    local events = environments[environment_id()].events;
    events[self] = events[self] or {};
    local handlers = events[self];
    local len = #handlers;
    remove_handlers(handlers, name);
    old_event.remove(self, name);
    return len - #handlers;
end

function new_event:clear()
    local events = environments[environment_id()].events;
    events[self] = {};
    old_event.clear(self);
end

function new_event:getRegisteredCount(name)
    return old_event.getRegisteredCount(self, name);
end

figuraMetatables.Event.__index = new_event;

figuraMetatables.EventsAPI.__newindex = function (events, key, func)
    local f_type = type(func);
    if f_type ~= "function" then
        log(("Event expects function as a handler, not %s"):format(f_type), "FATAL", active_environment);
        error("Unable to create an Event handler");
    end
    local actual_event_name = string.upper(key);
    events[actual_event_name]:register(func);
end
--#endregion

--#region ENVIRONMENT CONTROL FUNCTIONS
local function env_require(name)
    local env = environments[active_environment];
    local script_env = env.env;
    local reqs = env.requires;
    local req = reqs[name];
    if req ~= nil then
        return table.unpack(req);
    else
        local dirs = {env.script_dir, table.unpack(global_script_dirs)};
        for _, dir in ipairs(dirs) do
            local global_path;
            if #dir == 0 then
                global_path = name;
            else
                global_path = dir .. "/" .. name;
            end
            local normalized_path = ".scripts/" .. string.gsub(global_path, "%.", "/") .. ".lua";
            local script_content = load_res(normalized_path);
            if script_content ~= nil then
                local f, err = load(script_content, global_path, setmetatable(script_env, {__index=_G}));
                if (f == nil) then
                    error(err);
                end
                local return_value = table.pack(f());
                reqs[name] = return_value;
                return table.unpack(return_value);
            end
        end
        error(("Unable to find script by path %s in any directories available to environment"):format(name));
    end
end

local environment_init_error = [[Error ocurred during initialization of environment "%s".
%s
This environment has been removed from your runtime.]];

---Switches the current environment
---@param name string? ID of the environment. Default - id of the root environment;
function switch_environment(name)
    local env_name = environment_id();
    if env_name == name then
        return;
    end
    local cur_env = environments[environment_id()];
    for event, _ in pairs(cur_env.events) do
        old_event.clear(event);
    end
    cur_env.action_wheel = action_wheel:getCurrentPage();
    local m = cur_env.model_root;
    if m ~= nil then
        local visible = m:getVisible();
        cur_env.root_visibility = visible;
        m:setVisible(false);
    end

    action_wheel:setPage(nil);

    active_environment = name or "___ROOT___";

    local new_env = environments[active_environment];

    if not new_env.initialized then
        log(("Initializing %s"):format(name), "DEBUG");
        for _, script_name in ipairs(new_env.auto_scripts) do
            local success, error = pcall(env_require, script_name);
            if not success then
                log(environment_init_error:format(active_environment, error or "UNKNOWN"), "ERROR", active_environment);
                switch_environment();
                return;
            end
        end
        new_env.initialized = true;
    else
        local handlers = new_env.events;
        for event, handlers in pairs(handlers) do
            for _, handler in ipairs(handlers) do
                old_event.register(event, handler.f, handler.n);
            end
        end

        action_wheel:setPage(new_env.action_wheel);
    end

    local m = new_env.model_root;
    if m ~= nil then
        m:setVisible(new_env.root_visibility);
    end

    log("Switched environment", "DEBUG", active_environment);
end
--#endregion

--#region ROOT ENVIRONMENT INITIALIZATION
local page = action_wheel:newPage("Root Environment");

for _, value in ipairs(environment_ids) do
    local action = page:newAction();
    action:setTitle(value);
    action:onLeftClick(function (self)
        switch_environment(value);
    end)
end

action_wheel:setPage(page);
--#endregion

require = env_require;

switch_environment(default_environment);