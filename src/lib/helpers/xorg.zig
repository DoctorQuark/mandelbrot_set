pub fn getAtom(conn: *xcb.connection_t, name: [:0]const u8) error{OutOfMemory}!xcb.atom_t {
    const cookie = xcb.intern_atom(conn, 0, @intCast(name.len), name.ptr);
    if (xcb.intern_atom_reply(conn, cookie, null)) |r| {
        defer std.c.free(r);
        return r.atom;
    }
    return error.OutOfMemory;
}

const std = @import("std");
const root = @import("root");
const lib = root.lib;
const xcb = lib.xcb;
