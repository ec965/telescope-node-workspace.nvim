local json = require "node-workspace.json"
local pickers = require "telescope.pickers"
local finders = require "telescope.finders"
local conf = require("telescope.config").values
local actions = require "telescope.actions"
local action_state = require "telescope.actions.state"

--- Decode json safely with proper error message
---@param raw string
---@return boolean|string|number|table|nil
local function json_decode(raw)
    local parsed
    if not pcall(function()
        parsed = json.decode(raw)
    end) then
        error("Failed to parse json\n" .. raw)
    end
    return parsed
end

--- list workspace directories
---@param package_manager string one of 'npm', 'yarn', 'yarn-berry', or 'pnpm'
---@param workspace_root string path to workspace root
---@return string[][] table of package name to path and an array of package names
local function list_workspaces(package_manager, workspace_root)
    local workspaces = {}

    if package_manager == "yarn-berry" then
        local lines =
            vim.fn.systemlist { "yarn", "workspaces", "list", "--json" }
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
        local lines = vim.fn.systemlist { "yarn", "workspaces", "info" }
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
        local raw = vim.fn.system { "pnpm", "ls", "--json", "-r" }
        -- output comes as properly formatted JSON
        local parsed = json_decode(raw)

        for _, v in ipairs(parsed) do
            table.insert(workspaces, { v.name, v.path })
        end
    else -- npm
        local original_cwd = vim.fn.getcwd()

        -- we need our cwd to be the repo root to get proper JSON output
        vim.api.nvim_set_current_dir(workspace_root)
        local raw =
            vim.fn.system { "npm", "list", "-json", "-depth", "1", "-omit=dev" }
        vim.api.nvim_set_current_dir(original_cwd)

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

    -- we need to normalize relative paths for other package managers
    if package_manager ~= "pnpm" then
        for i in ipairs(workspaces) do
            workspaces[i][2] =
                vim.fs.normalize(workspace_root .. "/" .. workspaces[i][2])
        end
    end

    return workspaces
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
---@param root_path string path to workspace root
---@param package_json table parsed package.json
---@return string one of 'npm', 'yarn', or 'pnpm'
local function detect_package_manager(root_path, package_json)
    local res = "npm"
    if file_exists(root_path .. "/yarn.lock") then
        res = "yarn"
    elseif file_exists(root_path .. "/pnpm-lock.yaml") then
        res = "pnpm"
    end

    if res == "yarn" then
        -- check packagejson for packageManager to see if yarn berry
        if
            package_json.packageManager ~= nil
            and package_json.packageManager[6] ~= "1"
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
    local f = io.open(path, "r")
    if f == nil then
        return nil
    end
    local j = f:read "*all"
    f:close()

    return json_decode(j)
end

--- search up the file system from the cwd for the top level package.json
---@param cwd string|nil
---@return string|nil,table|nil path and parsed package_json as a lua table
local function find_workspace_package_json(cwd)
    local package_jsons = vim.fs.find(
        "package.json",
        { upward = true, limit = math.huge, path = cwd }
    )

    for i = #package_jsons, 1, -1 do
        local j = read_json(package_jsons[i])
        if type(j) == "table" then
            if
                j.workspaces ~= nil
                or file_exists(
                    vim.fs.dirname(package_jsons[i]) .. "/pnpm-workspace.yaml"
                )
            then
                return package_jsons[i], j
            end
        end
    end

    return nil, nil
end

return function(opts)
    opts = opts or {}
    local package_json_path, package_json = find_workspace_package_json()

    if package_json_path == nil or package_json == nil then
        print "Error: You are not in a NodeJS workspace"
        return
    end

    local workspace_root = vim.fs.dirname(package_json_path)
    local package_manager = detect_package_manager(workspace_root, package_json)

    local workspaces = list_workspaces(package_manager, workspace_root)

    pickers
        .new(opts, {
            prompt_title = "Node Workspaces - " .. package_manager,
            finder = finders.new_table {
                results = workspaces,
                entry_maker = function(entry)
                    return {
                        path = vim.fs.normalize(entry[2] .. "/package.json"),
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
                    vim.api.nvim_set_current_dir(selection.value)
                end)
                return true
            end,
        })
        :find()
end
