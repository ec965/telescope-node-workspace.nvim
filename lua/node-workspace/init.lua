local pickers = require "telescope.pickers"
local finders = require "telescope.finders"
local conf = require("telescope.config").values
local actions = require "telescope.actions"
local action_state = require "telescope.actions.state"
local uv = vim.loop

--- List workspace directories
--- This function runs in a worker thread!!
---@param package_manager string one of 'npm', 'yarn', 'yarn-berry', or 'pnpm'
---@param workspace_path string path to workspace root
---@return string mpack message that is a string[][] of package name to path and an array of package names
local function worker_list_workspaces(package_manager, workspace_path)
    --- Decode json safely with proper error message
    ---@param raw string
    ---@return boolean|string|number|table|nil
    local function json_decode(raw)
        local ok, parsed = pcall(vim.json.decode, raw)
        if not ok then
            error("Failed to parse json\n" .. raw)
        end
        return parsed
    end

    --- Native verison of vim.fn.systemlist for async ctx
    ---@param cmd string
    local function systemlist(cmd)
        local handle = assert(io.popen(cmd, "r"))
        local lines = {}
        for line in handle:lines() do
            table.insert(lines, line)
        end
        return lines
    end

    --- Native version of vim.fn.system for async ctx
    ---@param cmd string
    ---@return string
    local function system(cmd)
        local handle = assert(io.popen(cmd, "r"))
        return handle:read "*a"
    end

    local workspaces = {}

    if package_manager == "yarn-berry" then
        local lines = systemlist "yarn workspaces list --json"
        -- output comes in the form of JSON split by lines
        -- { name: "name", location: "location" }
        -- { name: "name", location: "location" }
        -- { name: "name", location: "location" }

        for _, line in ipairs(lines) do
            local j = json_decode(line)
            if type(j) == "table" then
                table.insert(workspaces, { j.name, j.location })
            end
        end
    elseif package_manager == "yarn" then
        local lines = systemlist "yarn workspaces info"
        -- output comes in the form of JSON but we need to ignore the first and last lines
        local j = ""
        for i = 2, #lines - 1, 1 do
            j = j .. lines[i]
        end
        local parsed = json_decode(j)

        table.insert(workspaces, { "root", "." })

        for k, v in pairs(parsed) do
            table.insert(workspaces, { k, v.location })
        end
    elseif package_manager == "pnpm" then
        local raw = system "pnpm ls -json -r"
        -- output comes as properly formatted JSON
        local parsed = json_decode(raw)

        for _, v in ipairs(parsed) do
            table.insert(workspaces, { v.name, v.path })
        end
    else -- npm
        -- we need our cwd to be the repo root to get proper JSON output
        local raw = system(
            string.format(
                "cd %s && npm list -json -depth 1 -omit=dev",
                workspace_path
            )
        )

        local parsed = json_decode(raw)

        table.insert(workspaces, { "root", "." })

        if parsed ~= nil then
            for k, v in pairs(parsed.dependencies) do
                if v.resolved ~= nil then
                    table.insert(workspaces, { k, string.sub(v.resolved, 7) })
                end
            end
        end
    end

    return vim.mpack.encode(workspaces)
end

--- check if a file exists
---@param name string name of file
---@return boolean
local function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then
        io.close(f)
        return true
    end
    return false
end

--- detect which node package manager is being used
---@param workspace_path string path to workspace root
---@param package_json table parsed package.json
---@return string one of 'npm', 'yarn', or 'pnpm'
local function detect_package_manager(workspace_path, package_json)
    local res = "npm"
    if file_exists(workspace_path .. "/yarn.lock") then
        res = "yarn"
    elseif file_exists(workspace_path .. "/pnpm-lock.yaml") then
        res = "pnpm"
    end

    if res == "yarn" then
        -- check packagejson for packageManager to see if yarn berry
        if
            package_json.packageManager ~= nil
            and package_json.packageManager:sub(6, 6) ~= "1"
        then
            res = "yarn-berry"
        end
    end

    return res
end

--- read a json file
---@param path string
---@return table|boolean|string|number|nil
local function read_json(path)
    local f = assert(io.open(path, "r"))
    local raw = f:read "*a"
    f:close()

    local ok, parsed = pcall(vim.json.decode, raw)
    if not ok then
        error("Failed to parse json\n" .. raw)
    end
    return parsed
end

--- Verify that a package_json location is a workspace
---@param package_json table
---@return boolean
local function is_workspace(path, package_json)
    return package_json.workspaces ~= nil
        or file_exists(vim.fs.dirname(path) .. "/pnpm-workspace.yaml")
end

--- search up the file system from the cwd for the top level package.json
---@param cwd string
---@return string|nil,table|nil path and parsed package_json as a lua table
local function find_workspace_package_json(cwd)
    local package_json_paths = vim.fs.find(
        "package.json",
        { upward = true, limit = math.huge, path = cwd }
    )

    for i = #package_json_paths, 1, -1 do
        local curr_path = package_json_paths[i]
        local j = read_json(curr_path)
        if type(j) == "table" then
            if is_workspace(curr_path, j) then
                return curr_path, j
            end
        end
    end

    return nil, nil
end

--- Find cwd workspace information
---@return string|nil, string, string
local function find_cwd_workspace()
    local package_json_path, package_json =
        find_workspace_package_json(uv.cwd())

    if package_json_path == nil or package_json == nil then
        return nil
    end

    local workspace_path = vim.fs.dirname(package_json_path)
    local package_manager = detect_package_manager(workspace_path, package_json)

    return package_json_path, workspace_path, package_manager
end

return function(opts)
    opts = opts or {}

    local package_json_path, workspace_path, package_manager =
        find_cwd_workspace()

    if not package_json_path then
        vim.notify(
            "Error: You are not in a NodeJS workspace",
            vim.log.levels.ERROR
        )
        return
    end

    local ctx = uv.new_work(worker_list_workspaces, function(workspaces)
        workspaces = vim.mpack.decode(workspaces)

        vim.schedule(function()
            pickers
                .new(opts, {
                    prompt_title = "Node Workspaces - " .. package_manager,
                    finder = finders.new_table {
                        results = workspaces,
                        entry_maker = function(entry)
                            return {
                                path = vim.fs.normalize(
                                    entry[2] .. "/package.json"
                                ),
                                value = entry[2],
                                display = entry[1],
                                ordinal = entry[1],
                            }
                        end,
                    },
                    sorter = conf.generic_sorter(opts),
                    previewer = conf.file_previewer(opts),
                    attach_mappings = function(prompt_bufnr, _)
                        actions.select_default:replace(function()
                            actions.close(prompt_bufnr)
                            local selection = action_state.get_selected_entry()
                            local new_cwd = selection.value

                            -- we need to normalize relative paths for other package managers
                            if package_manager ~= "pnpm" then
                                new_cwd = vim.fs.normalize(
                                    workspace_path .. "/" .. selection.value
                                )
                            end

                            vim.api.nvim_set_current_dir(new_cwd)
                        end)
                        return true
                    end,
                })
                :find()
        end)
    end)

    ctx:queue(package_manager, workspace_path)
end
