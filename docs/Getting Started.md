## Setting up EnvSwitcher
In order to start using EnvSwitcher, you have to add some fields to your `avatar.json`.
```json
{
    ...
    "resources": [
        "envswitcher.json",
        ".scripts/**"
    ],
    "autoScripts": [
        "envswitcher"
    ]
    ...
}
```
That way Figura will include EnvSwitcher config right into your avatar data. The `".scripts/**"` here is a folder that contains all your scripts. Some examples will be shown in the next section.

## Configuring EnvSwitcher
Before starting actually setting up your avatar, you need to configure the EnvSwitcher. Config has to be located at the root folder of the avatar, and it's file must be called exactly `envswitcher.json`. Here's the example config:
```json
{
    "scripts_dir": ".scripts",
    "global_script_dirs": [
        "global",
        "libraries"
    ],
    "environments": [
        {
            "id": "foo",
            "default": true,
            "script_dir": "foo",
            "auto_scripts": [
                "main"
            ],
            "models": [
                "top_hat"
            ]
        },
        {
            "id": "bar",
            "script_dirs": ["bar", "baz"],
            "auto_scripts": [
                "main"
            ]
        }
    ],
    "modules": {
        "nameplate": false,
        "shared": true,
    },
    "unix_path_format": true,
    "__debug": false
}
```
* `scripts_dir` - Name of the folder that contains all your scripts that will be used in avatar. It is recommended it to be a folder which name is starting with `.`, so the scripts are not included in avatar itself. Default value of this field is `.scripts`.
* `global_script_dirs` - List of directories that will be used for searching scripts for all environments, if the script wasn't found in their local script folders. Directories that goes first has more priority.
* `environments` - List of environments descriptors, which's fields are:
    * `id` - Required field. Name that will be used internally for switching to this environment. If descriptor doesn't have this field, or value of this field is `"___ROOT___"`, this descriptor will be skipped.
    * `default` - In case if this field is `true`, this environment will be your default environment after initialization of EnvSwitcher. Default value of this field is `false`
    * `script_dir` - Name of directory with scripts for this environment. All paths provided to `require()` function will be relative to this directory. If script is not found by relative path in specified directory, `require()` will search for the script by same path, but this time relative to directories in `global_script_dirs`.
    * `script_dirs` - The same as `script_dir`, but allows specifying multiple directories. Directories that goes first has more priority.
    * `auto_scripts` - List of script names that will be required when environment is being active for the first time. This field is not required, but, if you want for any scripts in environment to run, there has to be at least one, root script.
    * `models` - List of names of models that will be included in this environment. Each model can be included in environment only once. Models not included in any environment will be hidden.
* `modules` - Modules descriptor. Available modules are:
    * `action_wheel` - If `true`, action wheel will be switched between environments. Default - `true`.
    * `events` - If `true`, events will be switched between environments. Default - `true`.
    * `modelparts` - If `true`, each environment will have it's own `models` variable, and the models that haven't been specified in any of environments will be inaccessible and invisible. If `false` - `models` list in environment descriptors will be ignored. Default - `true`.
    * `pings` - If `true`, each environment will have different set of pings handlers. Please note - ping handlers from other environments won't be executed if ping is received. Default - `true`.
    * `keybinds` - If `true`, each environment will have it's own set of keybinds, all the keybinds will be prefixed with environment ID, and keybinds from other environments will be disabled. Default - `true`.
    * `avatar_vars` - If `true`, each environment will have it's own set of avatar variables set with `avatar:store`. Default - `true`.
    * `vanilla_parts` - If `true`, each environment will have it's own set of vanilla modelparts states. Default - `true`.
    * `ordered_vanilla_parts` - Can be used only with `vanilla_parts` module. If `true` - enables the ordered switching backend which ensures saving the changes in the right order. This can increase the ammount of instructions and make your avatar less performant, so, turn on only if you are sure that your changes might break, for example if you are using vanilla parts groups. Default - `false`.
    * `nameplates` - If `true`, each environment will have it's own set of nameplates. Default - `true`.
    * `host` - If `true`, some values set by host, such as `chatColor` and `unlockCursor` will be switched between environments. Default - `true`.
    * `shared` - If `true`, each environment will have access to the global `__SHARED` variable, which is persistent between all the environments. Default - `false`.
* `unix_path_format` - Setting this field to `true` will make `require()` function accept unix-like paths, instead of Lua-like ones. For example `foo.bar` turns into `foo/bar`. This also allows having dots in script and directory names, for example: `foo/.bar`.
* `__debug` - Setting this field to `true` will turn on debug logs.

## EnvSwitcher functions
* `switch_environment(id: string?)` - Switches the current environment. Id is the id of environment you will be switched to. Providing `nil` or id of environment that doesn't exist will cause switching to root environment, which's only purpose is having an action wheel that can be used to switch between registered environments.
* `environment_id() -> string` - Returns the id of current environment.
* `environment_list() -> string[]` - Returns the list of available environment ids.