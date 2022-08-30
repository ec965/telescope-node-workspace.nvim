return require("telescope").register_extension {
    exports = {
        ["node-workspace"] = require "node-workspace",
    },
}
