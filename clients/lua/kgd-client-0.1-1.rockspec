package = "kgd-client"
version = "0.1-1"

source = {
    url = "https://github.com/joshheyse/kgd/archive/refs/tags/v0.1.tar.gz",
    dir = "kgd-0.1/clients/lua",
}

description = {
    summary = "Lua client for kgd (Kitty Graphics Daemon)",
    detailed = [[
        Single-threaded, poll-based client library for communicating with the
        kgd daemon over Unix domain sockets using msgpack-RPC.  Provides all
        12 RPC methods and 4 server notification callbacks.
    ]],
    license = "MIT",
    homepage = "https://github.com/joshheyse/kgd",
}

dependencies = {
    "lua >= 5.1",
    "luasocket >= 3.0",
    "lua-messagepack >= 0.5",
}

build = {
    type = "builtin",
    modules = {
        ["kgd"]          = "kgd/init.lua",
        ["kgd.protocol"] = "kgd/protocol.lua",
        ["kgd.socket"]   = "kgd/socket.lua",
    },
}
