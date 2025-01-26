local cfg; -- Config struct
local env_control = {};
local modules = {
    action_wheel = true,
    events = true,
    modelparts = true,
    pings = true,
    keybinds = true,
    avatar_vars = true,
    vanilla_parts = true,
    nameplates = true,
    shared = false
};

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

if type(cfg.modules) == "table" then
    local mods = cfg.modules;
    for key, _ in pairs(modules) do
        local v = mods[key];
        if type(v) == "boolean" then
            modules[key] = v;
        end
    end
end

log(("Global script directories: [ %s ]"):format(table.concat(global_script_dirs, ", ")), "DEBUG");

---@alias EnvKeybind {kb: Keybind, state: boolean}

---@alias EnvPart {values: table<string, table>, indexer: function}

---@alias EnvNameplates { chat: string?, list: string?, entity: table<string, table> }

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
---@field keybinds EnvKeybind[]
---@field vanilla_parts table<VanillaPart, EnvPart>
---@field nameplates EnvNameplates
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

    local model_root;

    if modules.modelparts then
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

        model_root = models:newPart(id);

        -- Adding environment models to model root of this environment
        for _, model in ipairs(env_models) do
            model_root:addChild(model);
        end
    end

    local script_environment = {
        models = model_root
    };

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
        keybinds = {},
        vanilla_parts = {},
        nameplates = {entity = {}},
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
    keybinds = {},
    vanilla_parts = {},
    nameplates = {entity = {}},
    initialized = true
}

--#endregion

if modules.modelparts then
    -- Making all models in avatar root invisible
    -- Roots of environments will be made visible on initialized
    -- All other models, that are not in environments, shouldn't be visible
    for _, model in ipairs(models:getChildren()) do
        model:setVisible(false);
    end
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

if modules.events then    
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
end
--#endregion

--#region REDEFINING PING CLASS BEHAVIOR
local old_ping_set = figuraMetatables.PingAPI.__newindex;
if modules.pings then
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
end
--#endregion

--#region REDEFINING KEYBIND CLASS BEHAVIOR
local old_keybinds = figuraMetatables.KeybindAPI.__index;

if modules.keybinds then
    local new_keybinds = {};

    function new_keybinds:newKeybind(name, key, gui)
        local cur_env = env_control.current_env();
        local new_name;
        if cur_env.id ~= "___ROOT___" then
            new_name = "["..cur_env.id.."] "..name;
        else
            new_name = name;
        end
        local kb = old_keybinds.newKeybind(self, new_name, key, gui);
        cur_env.keybinds[#cur_env.keybinds+1] = {kb = kb, state = true};
        return kb;
    end

    function new_keybinds:of(...)
        return new_keybinds.newKeybind(self, ...);
    end

    function new_keybinds:fromVanilla(id)
        local kb = old_keybinds.fromVanilla(self, id);
        local cur_env = env_control.current_env();
        cur_env.keybinds[#cur_env.keybinds+1] = { kb = kb, state = true };
        return kb;
    end

    function new_keybinds:getKeybinds()
        local cur_env = env_control.current_env();
        local out = {};
        for _, keybind in ipairs(cur_env.keybinds) do
            local keybind = keybind.kb;
            out[keybind:getName()] = keybind;
        end
        return out;
    end

    figuraMetatables.KeybindAPI.__index = setmetatable(new_keybinds, {__index = old_keybinds});
end
--#endregion

--#region REDEFINING VANILLA MODELPART CLASS BEHAVIOR
if modules.vanilla_parts then
    local function vp_wrapper(func, field, indexer)
        return function (self, ...)
            local n_func;
            if type(func) == "string" then
                n_func = indexer(self, func);
            else
                n_func = func;
            end
            local ret = n_func(self, ...);
            local cur_env = env_control.current_env();
            local args = {...};
            local saves = cur_env.vanilla_parts[self] or {values = {}, indexer = indexer};
            saves.values[field] = args;
            cur_env.vanilla_parts[self] = saves;
            return ret;
        end
    end
    
    local old_vanilla_part = figuraMetatables.VanillaPart.__index;
    
    local new_vanilla_part = {};
    new_vanilla_part.offsetRot = vp_wrapper(old_vanilla_part.offsetRot, "offsetRot", old_vanilla_part);
    new_vanilla_part.offsetScale = vp_wrapper(old_vanilla_part.offsetScale, "offsetScale", old_vanilla_part);
    new_vanilla_part.pos = vp_wrapper(old_vanilla_part.pos, "pos", old_vanilla_part);
    new_vanilla_part.rot = vp_wrapper(old_vanilla_part.rot, "rot", old_vanilla_part);
    new_vanilla_part.scale = vp_wrapper(old_vanilla_part.scale, "scale", old_vanilla_part);
    new_vanilla_part.visible = vp_wrapper(old_vanilla_part.visible, "visible", old_vanilla_part);
    new_vanilla_part.setOffsetRot = vp_wrapper(old_vanilla_part.offsetRot, "offsetRot", old_vanilla_part);
    new_vanilla_part.setOffsetScale = vp_wrapper(old_vanilla_part.offsetScale, "offsetScale", old_vanilla_part);
    new_vanilla_part.setPos = vp_wrapper(old_vanilla_part.pos, "pos", old_vanilla_part);
    new_vanilla_part.setRot = vp_wrapper(old_vanilla_part.rot, "rot", old_vanilla_part);
    new_vanilla_part.setScale = vp_wrapper(old_vanilla_part.scale, "scale", old_vanilla_part);
    new_vanilla_part.setVisible = vp_wrapper(old_vanilla_part.visible, "visible", old_vanilla_part);
    
    figuraMetatables.VanillaPart.__index = setmetatable(new_vanilla_part, {__index=old_vanilla_part});
    
    local old_vanilla_model_part = figuraMetatables.VanillaModelPart.__index;
    
    local new_vanilla_model_part = {};
    new_vanilla_model_part.offsetRot = vp_wrapper(old_vanilla_model_part.offsetRot, "offsetRot", old_vanilla_model_part);
    new_vanilla_model_part.offsetScale = vp_wrapper(old_vanilla_model_part.offsetScale, "offsetScale", old_vanilla_model_part);
    new_vanilla_model_part.pos = vp_wrapper(old_vanilla_model_part.pos, "pos", old_vanilla_model_part);
    new_vanilla_model_part.rot = vp_wrapper(old_vanilla_model_part.rot, "rot", old_vanilla_model_part);
    new_vanilla_model_part.scale = vp_wrapper(old_vanilla_model_part.scale, "scale", old_vanilla_model_part);
    new_vanilla_model_part.visible = vp_wrapper(old_vanilla_model_part.visible, "visible", old_vanilla_model_part);
    new_vanilla_model_part.setOffsetRot = vp_wrapper(old_vanilla_model_part.offsetRot, "offsetRot", old_vanilla_model_part);
    new_vanilla_model_part.setOffsetScale = vp_wrapper(old_vanilla_model_part.offsetScale, "offsetScale", old_vanilla_model_part);
    new_vanilla_model_part.setPos = vp_wrapper(old_vanilla_model_part.pos, "pos", old_vanilla_model_part);
    new_vanilla_model_part.setRot = vp_wrapper(old_vanilla_model_part.rot, "rot", old_vanilla_model_part);
    new_vanilla_model_part.setScale = vp_wrapper(old_vanilla_model_part.scale, "scale", old_vanilla_model_part);
    new_vanilla_model_part.setVisible = vp_wrapper(old_vanilla_model_part.visible, "visible", old_vanilla_model_part);
    
    figuraMetatables.VanillaModelPart.__index = setmetatable(new_vanilla_model_part, {__index=old_vanilla_model_part});
    
    local old_vanilla_model_group = figuraMetatables.VanillaModelGroup.__index;
    
    local new_vanilla_model_group = {};
    new_vanilla_model_group.offsetRot = vp_wrapper("offsetRot", "offsetRot", old_vanilla_model_group);
    new_vanilla_model_group.offsetScale = vp_wrapper("offsetScale", "offsetScale", old_vanilla_model_group);
    new_vanilla_model_group.pos = vp_wrapper("pos", "pos", old_vanilla_model_group);
    new_vanilla_model_group.rot = vp_wrapper("rot", "rot", old_vanilla_model_group);
    new_vanilla_model_group.scale = vp_wrapper("scale", "scale", old_vanilla_model_group);
    new_vanilla_model_group.visible = vp_wrapper("visible", "visible", old_vanilla_model_group);
    new_vanilla_model_group.setOffsetRot = vp_wrapper("offsetRot", "offsetRot", old_vanilla_model_group);
    new_vanilla_model_group.setOffsetScale = vp_wrapper("offsetScale", "offsetScale", old_vanilla_model_group);
    new_vanilla_model_group.setPos = vp_wrapper("pos", "pos", old_vanilla_model_group);
    new_vanilla_model_group.setRot = vp_wrapper("rot", "rot", old_vanilla_model_group);
    new_vanilla_model_group.setScale = vp_wrapper("scale", "scale", old_vanilla_model_group);
    new_vanilla_model_group.setVisible = vp_wrapper("visible", "visible", old_vanilla_model_group);
    
    figuraMetatables.VanillaModelGroup.__index = setmetatable(new_vanilla_model_group, {__index=old_vanilla_model_group});     
end
--#endregion

--#region REDEFINING NAMEPLATE CLASS BEHAVIOR
local old_entity_nameplate;
if modules.nameplates then
    local function np_wrapper(func, field)
        return function (self, ...)
            local ret = func(self, ...);
            local cur_env = env_control.current_env();
            local args = {...};
            cur_env.nameplates.entity[field] = args;
            return ret;
        end
    end
    
    old_entity_nameplate = figuraMetatables.EntityNameplateCustomization.__index;
    
    local new_entity_nameplate = {};
    new_entity_nameplate.setPos = np_wrapper(old_entity_nameplate.setPos, "setPos");
    new_entity_nameplate.setScale = np_wrapper(old_entity_nameplate.setScale, "setScale");
    new_entity_nameplate.setPivot = np_wrapper(old_entity_nameplate.setPivot, "setPivot");
    new_entity_nameplate.setOutline = np_wrapper(old_entity_nameplate.setOutline, "setOutline");
    new_entity_nameplate.setOutlineColor = np_wrapper(old_entity_nameplate.setOutlineColor, "setOutlineColor");
    new_entity_nameplate.setBackgroundColor = np_wrapper(old_entity_nameplate.setBackgroundColor, "setBackgroundColor");
    new_entity_nameplate.setLight = np_wrapper(old_entity_nameplate.setLight, "setLight");
    new_entity_nameplate.setShadow = np_wrapper(old_entity_nameplate.setShadow, "setShadow");
    new_entity_nameplate.setVisible = np_wrapper(old_entity_nameplate.setVisible, "setVisible");
    new_entity_nameplate.setText = np_wrapper(old_entity_nameplate.setText, "setText");
    new_entity_nameplate.pos = np_wrapper(old_entity_nameplate.setPos, "setPos");
    new_entity_nameplate.scale = np_wrapper(old_entity_nameplate.setScale, "setScale");
    new_entity_nameplate.pivot = np_wrapper(old_entity_nameplate.setPivot, "setPivot");
    new_entity_nameplate.outline = np_wrapper(old_entity_nameplate.setOutline, "setOutline");
    new_entity_nameplate.outlineColor = np_wrapper(old_entity_nameplate.setOutlineColor, "setOutlineColor");
    new_entity_nameplate.backgroundColor = np_wrapper(old_entity_nameplate.setBackgroundColor, "setBackgroundColor");
    new_entity_nameplate.light = np_wrapper(old_entity_nameplate.setLight, "setLight");
    new_entity_nameplate.shadow = np_wrapper(old_entity_nameplate.setShadow, "setShadow");
    new_entity_nameplate.visible = np_wrapper(old_entity_nameplate.setVisible, "setVisible");
    
    figuraMetatables.EntityNameplateCustomization.__index = setmetatable(new_entity_nameplate, {__index=old_entity_nameplate})
    
    local old_group_nameplate = figuraMetatables.NameplateCustomizationGroup.__index;
    
    local new_group_nameplate = {};
    
    function new_group_nameplate:setText(...)
        local ret = old_group_nameplate.setText(self, ...);
        local cur_env = env_control.current_env();
        cur_env.nameplates.entity.setText = {...};
        return ret;
    end
    
    figuraMetatables.NameplateCustomizationGroup.__index = setmetatable(new_group_nameplate, {__index=old_group_nameplate});     
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
    if modules.modelparts then
        -- Environment root is always not nil, except for ___ROOT___, which is never going through initialization.
        local model_root = env.model_root --[[@as ModelPart]];
        -- Setting root visibility to true at first initialization of environment
        model_root:setVisible(true);
    end

    log(("Initializing %s"):format(env.id), "DEBUG");
    -- Initializing autoscripts
    for _, script_name in ipairs(env.auto_scripts) do
        -- Using the env_require function to properly setup script environment and etc.
        local success, error = pcall(env_require, script_name);
        -- If error occurred during initialization of any script - removing the environment. 
        if not success then
            log(environment_init_error:format(active_environment, error or "UNKNOWN"), "ERROR", active_environment);
            switch_environment(); -- Switching to root
            env_control.remove_env(env.id);
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

local function index(self, indexed, field)
    if type(indexed) == "function" then
        return indexed(self, field)
    else
        return indexed[field]
    end
end

local function restore_keybinds(env)
    for _, keybind in ipairs(env.keybinds) do
        keybind.kb:setEnabled(keybind.state);
    end
end

---comment
---@param env EnvTable
local function restore_parts(env)
    for part, env_part in pairs(env.vanilla_parts) do
        for field, value in pairs(env_part.values) do
            index(part, env_part.indexer, field)(part, table.unpack(value));
        end
    end
end

---@param env EnvTable
local function restore_nameplates(env)
    nameplate.CHAT:setText(env.nameplates.chat);
    nameplate.LIST:setText(env.nameplates.list);
    local entity_nameplate = nameplate.ENTITY;
    for field, value in pairs(env.nameplates.entity) do
        local func = old_entity_nameplate[field];
        func(entity_nameplate, table.unpack(value))
    end
end

---@param env EnvTable Environment
function env_control.load_env(env)
    if not env.initialized then
        env_control.init_env(env);
    else
        -- Registering events for this environment
        if modules.events then
            local handlers = env.events;
            for event, handlers in pairs(handlers) do
                for _, handler in ipairs(handlers) do
                    old_event.register(event, handler.f, handler.n);
                end
            end
        end
        
        -- Restoring action wheel page
        if modules.action_wheel then action_wheel:setPage(env.action_wheel); end

        if modules.modelparts then
            -- Restoring environment root visibility state
            local model_root = env.model_root;
            if model_root ~= nil then
                model_root:setVisible(env.root_visibility);
            end
        end

        if modules.avatar_vars then restore_avatar_variables(env.avatar_vars); end
        if modules.pings then restore_pings(env.pings); end
        if modules.keybinds then restore_keybinds(env); end
        if modules.vanilla_parts then restore_parts(env); end
        if modules.nameplates then restore_nameplates(env); end
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

local function clear_keybinds(env)
    for _, keybind in ipairs(env.keybinds) do
        keybind.state = keybind.kb:isEnabled();
        keybind.kb:setEnabled(false);
    end
end

---comment
---@param env EnvTable
local function clear_parts(env)
    for part, env_part in pairs(env.vanilla_parts) do
        for field, _ in pairs(env_part.values) do
            index(part, env_part.indexer, field)(part);
        end
    end
end

---@param env EnvTable
local function clear_nameplates(env)
    env.nameplates.chat = nameplate.CHAT:getText();
    nameplate.CHAT:setText(nil);
    env.nameplates.list = nameplate.LIST:getText();
    nameplate.LIST:setText(nil);
    local entity_nameplate = nameplate.ENTITY;
    for field, _ in pairs(env.nameplates.entity) do
        local func = old_entity_nameplate[field];
        func(entity_nameplate)
    end
end

---@param env EnvTable Environment
function env_control.unload_env(env)
    if modules.events then
        -- Unregistering current environment events
        for event, _ in pairs(env.events) do
            old_event.clear(event);
        end
    end
    if modules.action_wheel then
        -- Saving current action wheel page
        env.action_wheel = action_wheel:getCurrentPage();
        -- Setting current action wheel page to nil
        action_wheel:setPage(nil);
    end

    if modules.modelparts then
        local model_root = env.model_root;
        if model_root ~= nil then -- Checking if environment root is nil (for example, for ___ROOT___ it is nil)
            local visible = model_root:getVisible();
            -- Saving visibility state of this environment root
            env.root_visibility = visible;
            model_root:setVisible(false);
        end
    end
    if modules.avatar_vars then env.avatar_vars = clear_avatar_variables(); end
    if modules.pings then clear_pings(env.pings); end
    if modules.keybinds then clear_keybinds(env); end
    if modules.vanilla_parts then clear_parts(env); end
    if modules.nameplates then clear_nameplates(env); end
end

function env_control.current_env()
    return environments[environment_id()]
end

---Switches the current environment
---@param name string? ID of the environment. Default - id of the root environment;
function switch_environment(name)
    local name = name or "___ROOT___";
    if environments[name] ~= nil then
        local env_name = environment_id();
        if env_name == name then
            return;
        end

        local old_env = env_control.current_env();
        env_control.unload_env(old_env);

        active_environment = name;

        local new_env = env_control.current_env();

        env_control.load_env(new_env);

        log("Switched environment", "DEBUG", active_environment);
    else
        log(("Environment with id \"%s\" does not exist."):format(name), "ERROR", environment_id());
    end
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

if modules.shared then
    __SHARED = {}
end

switch_environment(default_environment);