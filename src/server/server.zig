const std = @import("std");
const net = std.net;
const fs = std.fs;
const Allocator = std.mem.Allocator;

pub const io_mode = .evented;

const Client = struct {
    file: fs.File,
    handleFrame: @Frame(handle),

    pub fn handle(self: *Client, room: *Room, allocator: *Allocator) !void {
        const size = try self.file.write("Server: Welcome!\n");

        while (true) {
            var buf: [100]u8 = undefined;
            const amt: u64 = try self.file.read(&buf);

            if (amt == 0) {
                self.file.close();
                try room.kick(self, allocator);
                return;
            }

            const msg: []u8 = buf[0..amt];
            try room.broadcast(msg, self);
        }
    }
};

const Room = struct {
    clients: std.ArrayList(*Client),
    toRemove: std.ArrayList(*Client),
    lock: std.Mutex,

    pub fn broadcast(room: *Room, msg: []const u8, sender: *Client) !void {
        var lock = room.lock.acquire();
        defer lock.release();

        for (room.clients.items) |client| {
            if (client == sender) continue;

            const size = try client.file.write(msg);
        }
    }

    pub fn kick(self: *Room, client: *Client, allocator: *Allocator) !void {
        var lock = self.lock.acquire();
        defer lock.release();

        for (self.clients.items) |c, i| {
            if (c == client) {
                _ = self.clients.orderedRemove(i);
                _ = try self.toRemove.append(c);
                break;
            }
        }

        return;
    }

    pub fn cleanClients(self: *Room, allocator: *Allocator) void {
        const lock = self.lock.acquire();
        defer lock.release();

        var i = self.toRemove.items.len;

        while (i > 0) : (i -= 1) {
            allocator.destroy(self.toRemove.items[i - 1]);
            _ = self.toRemove.orderedRemove(i - 1);
        }

        return;
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    const listenAddress = net.Address.parseIp4("127.0.0.1", 0) catch unreachable;

    var server = net.StreamServer.init(net.StreamServer.Options{});
    defer server.deinit();

    try server.listen(listenAddress);
    std.debug.warn("Listening at {}\n", .{server.listen_address});

    var room = Room{
        .clients = std.ArrayList(*Client).init(allocator),
        .toRemove = std.ArrayList(*Client).init(allocator),
        .lock = std.Mutex.init(),
    };

    while (true) {
        const clientFile = try server.accept();
        const client = try allocator.create(Client);
        client.* = Client{
            .file = clientFile.file,
            .handleFrame = async client.handle(&room, allocator),
        };

        var lock = room.lock.acquire();
        _ = try room.clients.append(client);
        lock.release();

        room.cleanClients(allocator);
    }
}
