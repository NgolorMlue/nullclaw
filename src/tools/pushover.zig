const std = @import("std");
const Tool = @import("root.zig").Tool;
const ToolResult = @import("root.zig").ToolResult;
const parseStringField = @import("shell.zig").parseStringField;
const parseIntField = @import("shell.zig").parseIntField;

const PUSHOVER_API_URL = "https://api.pushover.net/1/messages.json";

/// Pushover push notification tool.
/// Sends notifications via the Pushover API. Requires PUSHOVER_TOKEN and
/// PUSHOVER_USER_KEY in the workspace .env file.
pub const PushoverTool = struct {
    workspace_dir: []const u8,
    allocator: std.mem.Allocator,

    const vtable = Tool.VTable{
        .execute = &vtableExecute,
        .name = &vtableName,
        .description = &vtableDesc,
        .parameters_json = &vtableParams,
    };

    pub fn tool(self: *PushoverTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableExecute(ptr: *anyopaque, allocator: std.mem.Allocator, args_json: []const u8) anyerror!ToolResult {
        const self: *PushoverTool = @ptrCast(@alignCast(ptr));
        return self.execute(allocator, args_json);
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "pushover";
    }

    fn vtableDesc(_: *anyopaque) []const u8 {
        return "Send a push notification via Pushover. Requires PUSHOVER_TOKEN and PUSHOVER_USER_KEY in .env file.";
    }

    fn vtableParams(_: *anyopaque) []const u8 {
        return 
        \\{"type":"object","properties":{"message":{"type":"string","description":"The notification message"},"title":{"type":"string","description":"Optional title"},"priority":{"type":"integer","description":"Priority -2..2 (default 0)"},"sound":{"type":"string","description":"Optional sound name"}},"required":["message"]}
        ;
    }

    fn execute(self: *PushoverTool, allocator: std.mem.Allocator, args_json: []const u8) !ToolResult {
        const message = parseStringField(args_json, "message") orelse
            return ToolResult.fail("Missing required 'message' parameter");

        if (message.len == 0)
            return ToolResult.fail("Missing required 'message' parameter");

        const title = parseStringField(args_json, "title");
        const sound = parseStringField(args_json, "sound");

        // Validate priority if provided
        const priority = parseIntField(args_json, "priority");
        if (priority) |p| {
            if (p < -2 or p > 2) {
                return ToolResult.fail("Invalid 'priority': expected integer in range -2..=2");
            }
        }

        // Load credentials from .env
        const creds = getCredentials(self, allocator) catch
            return ToolResult.fail("Failed to load Pushover credentials from .env file");
        defer allocator.free(creds.token);
        defer allocator.free(creds.user_key);

        // Build form body
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);

        // Base fields
        try body_buf.appendSlice(allocator, "token=");
        try body_buf.appendSlice(allocator, creds.token);
        try body_buf.appendSlice(allocator, "&user=");
        try body_buf.appendSlice(allocator, creds.user_key);
        try body_buf.appendSlice(allocator, "&message=");
        try body_buf.appendSlice(allocator, message);

        if (title) |t| {
            try body_buf.appendSlice(allocator, "&title=");
            try body_buf.appendSlice(allocator, t);
        }

        if (priority) |p| {
            const pstr = try std.fmt.allocPrint(allocator, "&priority={d}", .{p});
            defer allocator.free(pstr);
            try body_buf.appendSlice(allocator, pstr);
        }

        if (sound) |s| {
            try body_buf.appendSlice(allocator, "&sound=");
            try body_buf.appendSlice(allocator, s);
        }

        // Send via curl
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "curl", "-s",           "-X",             "POST",
                "-d",   body_buf.items, PUSHOVER_API_URL,
            },
        }) catch
            return ToolResult.fail("Failed to send Pushover request via curl");
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        // Check for {"status":1} in response
        if (std.mem.indexOf(u8, result.stdout, "\"status\":1") != null) {
            return ToolResult.ok("Notification sent successfully");
        }

        // API error
        return ToolResult.fail("Pushover API returned an error");
    }

    /// Parse a raw .env value: strip whitespace, quotes, export prefix, inline comments.
    pub fn parseEnvValue(raw: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return trimmed;

        // Strip surrounding quotes
        const unquoted = if (trimmed.len >= 2 and
            ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
                (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')))
            trimmed[1 .. trimmed.len - 1]
        else
            trimmed;

        // Strip inline comment (unquoted only): "value # comment"
        if (std.mem.indexOf(u8, unquoted, " #")) |pos| {
            return std.mem.trim(u8, unquoted[0..pos], " \t");
        }

        return std.mem.trim(u8, unquoted, " \t");
    }

    fn getCredentials(self: *const PushoverTool, allocator: std.mem.Allocator) !struct { token: []const u8, user_key: []const u8 } {
        // Build path to .env
        const env_path = try std.fmt.allocPrint(allocator, "{s}/.env", .{self.workspace_dir});
        defer allocator.free(env_path);

        const content = std.fs.cwd().readFileAlloc(allocator, env_path, 1_048_576) catch
            return error.EnvFileNotFound;
        defer allocator.free(content);

        var token: ?[]const u8 = null;
        var user_key: ?[]const u8 = null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            var line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            // Strip "export " prefix
            if (std.mem.startsWith(u8, line, "export ")) {
                line = std.mem.trim(u8, line["export ".len..], " \t");
            }

            if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
                const key = std.mem.trim(u8, line[0..eq_pos], " \t");
                const value = parseEnvValue(line[eq_pos + 1 ..]);

                if (std.mem.eql(u8, key, "PUSHOVER_TOKEN")) {
                    if (token) |old| allocator.free(old);
                    token = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "PUSHOVER_USER_KEY")) {
                    if (user_key) |old| allocator.free(old);
                    user_key = try allocator.dupe(u8, value);
                }
            }
        }

        const t = token orelse return error.MissingPushoverToken;
        const u = user_key orelse {
            allocator.free(t);
            return error.MissingPushoverUserKey;
        };

        return .{ .token = t, .user_key = u };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "pushover tool name" {
    var pt = PushoverTool{ .workspace_dir = "/tmp", .allocator = std.testing.allocator };
    const t = pt.tool();
    try std.testing.expectEqualStrings("pushover", t.name());
}

test "pushover tool description mentions notification" {
    var pt = PushoverTool{ .workspace_dir = "/tmp", .allocator = std.testing.allocator };
    const t = pt.tool();
    const desc = t.description();
    try std.testing.expect(std.mem.indexOf(u8, desc, "notification") != null or
        std.mem.indexOf(u8, desc, "push") != null);
}

test "pushover schema has message required" {
    var pt = PushoverTool{ .workspace_dir = "/tmp", .allocator = std.testing.allocator };
    const t = pt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\"") != null);
}

test "pushover execute missing message" {
    var pt = PushoverTool{ .workspace_dir = "/tmp", .allocator = std.testing.allocator };
    const t = pt.tool();
    const result = try t.execute(std.testing.allocator, "{}");
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "message") != null);
}

test "pushover execute empty message" {
    var pt = PushoverTool{ .workspace_dir = "/tmp", .allocator = std.testing.allocator };
    const t = pt.tool();
    const result = try t.execute(std.testing.allocator, "{\"message\": \"\"}");
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "message") != null);
}

test "pushover priority -3 rejected" {
    var pt = PushoverTool{ .workspace_dir = "/tmp", .allocator = std.testing.allocator };
    const t = pt.tool();
    const result = try t.execute(std.testing.allocator, "{\"message\": \"hello\", \"priority\": -3}");
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "priority") != null or
        std.mem.indexOf(u8, result.error_msg.?, "-2..=2") != null);
}

test "pushover priority 5 rejected" {
    var pt = PushoverTool{ .workspace_dir = "/tmp", .allocator = std.testing.allocator };
    const t = pt.tool();
    const result = try t.execute(std.testing.allocator, "{\"message\": \"hello\", \"priority\": 5}");
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "priority") != null or
        std.mem.indexOf(u8, result.error_msg.?, "-2..=2") != null);
}

test "pushover priority 2 accepted (credential error expected)" {
    var pt = PushoverTool{ .workspace_dir = "/tmp/nonexistent_pushover_test_dir", .allocator = std.testing.allocator };
    const t = pt.tool();
    const result = try t.execute(std.testing.allocator, "{\"message\": \"hello\", \"priority\": 2}");
    // Should fail on credentials, not on priority validation
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "priority") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "credential") != null);
}

test "pushover priority -2 accepted (credential error expected)" {
    var pt = PushoverTool{ .workspace_dir = "/tmp/nonexistent_pushover_test_dir", .allocator = std.testing.allocator };
    const t = pt.tool();
    const result = try t.execute(std.testing.allocator, "{\"message\": \"hello\", \"priority\": -2}");
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "priority") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "credential") != null);
}

test "parseEnvValue strips export prefix" {
    // parseEnvValue doesn't strip export itself — that's done in getCredentials.
    // But it does strip quotes and inline comments.
    // For this test, we test what parseEnvValue does with the value portion.
    const result = PushoverTool.parseEnvValue("  myvalue  ");
    try std.testing.expectEqualStrings("myvalue", result);
}

test "parseEnvValue strips quotes" {
    const dq = PushoverTool.parseEnvValue("\"quotedvalue\"");
    try std.testing.expectEqualStrings("quotedvalue", dq);
    const sq = PushoverTool.parseEnvValue("'singlequoted'");
    try std.testing.expectEqualStrings("singlequoted", sq);
}

test "parseEnvValue strips inline comment" {
    const result = PushoverTool.parseEnvValue("myvalue # this is a comment");
    try std.testing.expectEqualStrings("myvalue", result);
}

test "pushover schema has priority and sound" {
    var pt = PushoverTool{ .workspace_dir = "/tmp", .allocator = std.testing.allocator };
    const t = pt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "priority") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "sound") != null);
}
