queue: std.ArrayList(Message),
mutex: std.Thread.Mutex,

pub fn init(allocator: Allocator, capacity: u32) !@This() {
    const queue = try std.ArrayList(Message).initCapacity(allocator, capacity);
    const mutex = std.Thread.Mutex{};
    return @This(){ .queue = queue, .mutex = mutex };
}

pub fn deinit(self: @This()) void {
    self.queue.deinit();
}

pub fn post(self: *@This(), message: Message) !void {
    self.lock();
    defer self.unlock();
    try self.queue.append(message);
}

pub fn receive(self: *@This()) ?Message {
    if (self.queue.items.len == 0) return null;
    self.lock();
    defer self.unlock();
    return self.queue.pop();
}

pub fn lock(self: *@This()) void {
    self.mutex.lock();
}

pub fn unlock(self: *@This()) void {
    self.mutex.unlock();
}

pub const Message = enum { exit, extent_changed, key_press, drag, autozoom };

const std = @import("std");
const Allocator = std.mem.Allocator;
