local cfg; -- Config struct
local env_control = {};

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
local scripts_dir = cfg.script_dir or ".scripts";
local unix_path_format = cfg.unix_path_format;

log(("Global script directories: [ %s ]"):format(table.concat(global_script_dirs, ", ")), "DEBUG");

---@class EnvTable
---@field id string
---@field requires table<string, any[]>
---@field script_dirs string[]
---@field action_wheel Page?
---@field events table<Event, {f: function, n: string}[]>
---@field env table
---@field model_root? ModelPart
---@field root_visibility boolean
---@field auto_scripts string[]
---@field avatar_vars table<string, any>
---@field pings table<string, function>
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
    elseif environments[id] ~= nil then
        log(("Environment with id %s already exists. Skipping environment #%s."):format(id, i), "ERROR");
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

    -- Moving specified models to this environment.
    if type(env.models) == "table" then
        for _, model_name in ipairs(env.models) do
            local model = models[model_name];
            if model ~= nil then
                models:removeChild(model);
                env_models[#env_models+1] = model;
            end
        end
    end

    local model_root = models:newPart(id);

    local script_environment = {
        models = model_root
    };

    -- Adding environment models to model root of this environment
    for _, model in ipairs(env_models) do
        model_root:addChild(model);
    end

    local script_dirs = {};

    if env.script_dirs ~= nil then
        for _, dir in ipairs(env.script_dirs) do
            script_dirs[#script_dirs+1] = dir;
        end
    elseif env.script_dir ~= nil then
        if type(env.script_dir == "string") then
            script_dirs[1] = env.script_dir;
        end
    end

    ---@type EnvTable
    local env_table = {
        id = id,
        requires = {},
        script_dirs = script_dirs,
        action_wheel = nil,
        events = {},
        env = script_environment,
        model_root = model_root,
        root_visibility = true,
        auto_scripts = env.auto_scripts or {},
        avatar_vars = {},
        pings = {},
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
    script_dirs = {},
    action_wheel = nil,
    events = {},
    env = {},
    root_visibility = false,
    auto_scripts = {},
    avatar_vars = {},
    pings = {},
    initialized = true
}

--#endregion

-- Making all models in avatar root invisible
-- Roots of environments will be made visible on initialized
-- All other models, that are not in environments, shouldn't be visible
for _, model in ipairs(models:getChildren()) do
    model:setVisible(false);
end

---Returns id of the current active environment
---@return string
function environment_id()
    return active_environment or "___ROOT___"
end

---Returns list of all available environments ids
---@return string[]
function environments_list()
    local envs = {}
    for _, value in ipairs(environment_ids) do
        envs[#envs+1] = value;
    end
    return envs;
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

--#region REDEFINING PING CLASS BEHAVIOR
local old_ping_set = figuraMetatables.PingAPI.__newindex;

function figuraMetatables.PingAPI.__newindex(pings, key, value)
    local k_type = type(key)
    if k_type ~= "string" then
        error(("Ping expects string as a key, not %s"):format(k_type));
    end
    local v_type = type(value);
    if value ~= nil and v_type ~= "function" then
        error(("Ping expects function as a handler, not %s"):format(v_type));
    end
    local env = env_control.current_env();
    env.pings[key] = value;
    old_ping_set(pings, key, value);
end
--#endregion

---Returns path components
---@param path string
---@return string[]
local function path_components(path)
    local components = {};
    for value in string.gmatch(path.."/", "(.-)/") do
        if #value ~= 0 then
            components[#components+1] = value;
        end
    end
    return components;
end

--#region ENVIRONMENT CONTROL FUNCTIONS
local function env_require(name)
    local env = env_control.current_env();
    local script_env = env.env;
    local reqs = env.requires;
    local req = reqs[name];
    if req ~= nil then
        return table.unpack(req);
    else
        local dirs = {table.unpack(env.script_dirs), table.unpack(global_script_dirs)};
        for _, dir in ipairs(dirs) do
            local script_path;
            local global_path;
            if #dir == 0 then
                global_path = name;
            else
                global_path = dir .. "/" .. name;
            end
            if unix_path_format then
                local path_comps = path_components(scripts_dir .. "/" .. global_path .. ".lua");
                script_path = table.concat(path_comps, "/");
            else
                script_path = scripts_dir .. "/" .. string.gsub(global_path, "%.", "/") .. ".lua";
            end
            local script_content = load_res(script_path);
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

function env_control.remove_env(name)
    environments[name] = nil;
    for i = 1, #environment_ids, 1 do
        if environment_ids[i] == name then
            environment_ids[i] = nil;
            return;
        end
    end
end

---@param env EnvTable Environment
function env_control.init_env(env)
    -- Environment root is always not nil, except for ___ROOT___, which is never going through initialization.
    local model_root = env.model_root --[[@as ModelPart]];
    -- Setting root visibility to true at first initialization of environment
    model_root:setVisible(true);

    log(("Initializing %s"):format(env.id), "DEBUG");
    -- Initializing autoscripts
    for _, script_name in ipairs(env.auto_scripts) do
        -- Using the env_require function to properly setup script environment and etc.
        local success, error = pcall(env_require, script_name);
        -- If error occurred during initialization of any script - removing the environment. 
        if not success then
            log(environment_init_error:format(active_environment, error or "UNKNOWN"), "ERROR", active_environment);
            env_control.remove_env(env.id);
            switch_environment(); -- Switching to root
            return;
        end
    end
    env.initialized = true;
end

---Restores avatar variables by using the table
---@param tbl table<string, any>
local function restore_avatar_variables(tbl)
    for key, value in pairs(tbl) do
        avatar:store(key, value);
    end
end

---Restores avatar pings by using the table
---@param tbl table<string, function>
local function restore_pings(tbl)
    for key, value in pairs(tbl) do
        old_ping_set(pings, key, value);
    end
end

---@param env EnvTable Environment
function env_control.load_env(env)
    if not env.initialized then
        env_control.init_env(env);
    else
        -- Registering events for this environment
        local handlers = env.events;
        for event, handlers in pairs(handlers) do
            for _, handler in ipairs(handlers) do
                old_event.register(event, handler.f, handler.n);
            end
        end
        
        -- Restoring action wheel page
        action_wheel:setPage(env.action_wheel);

        -- Restoring environment root visibility state
        local model_root = env.model_root;
        if model_root ~= nil then
            print("mrrrp");
            model_root:setVisible(env.root_visibility);
        end

        restore_avatar_variables(env.avatar_vars);
        restore_pings(env.pings);
    end
end

---Clears avatar variables and returns table with them
local function clear_avatar_variables()
    local out = {};
    for key, value in pairs(user:getVariable()) do
        out[key] = value;
        avatar:store(key, nil);
    end
    return out;
end

local function clear_pings(tbl)
    for key, _ in pairs(tbl) do
        old_ping_set(pings, key, nil);
    end
end

---@param env EnvTable Environment
function env_control.unload_env(env)
    -- Unregistering current environment events
    for event, _ in pairs(env.events) do
        old_event.clear(event);
    end
    -- Saving current action wheel page
    env.action_wheel = action_wheel:getCurrentPage();

    local model_root = env.model_root;
    if model_root ~= nil then -- Checking if environment root is nil (for example, for ___ROOT___ it is nil)
        local visible = model_root:getVisible();
        -- Saving visibility state of this environment root
        env.root_visibility = visible;
        model_root:setVisible(false);
    end

    env.avatar_vars = clear_avatar_variables();
    clear_pings(env.pings);

    -- Setting current action wheel page to nil
    action_wheel:setPage(nil);
end

function env_control.current_env()
    return environments[environment_id()]
end

---Switches the current environment
---@param name string? ID of the environment. Default - id of the root environment;
function switch_environment(name)
    local env_name = environment_id();
    if env_name == name then
        return;
    end

    local old_env = env_control.current_env();
    env_control.unload_env(old_env);

    active_environment = name or "___ROOT___";

    local new_env = env_control.current_env();

    env_control.load_env(new_env);

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