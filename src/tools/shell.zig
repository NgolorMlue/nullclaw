const std = @import("std");
const platform = @import("../platform.zig");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const isResolvedPathAllowed = @import("file_edit.zig").isResolvedPathAllowed;

/// Default maximum shell command execution time (nanoseconds).
const DEFAULT_SHELL_TIMEOUT_NS: u64 = 60 * std.time.ns_per_s;
/// Default maximum output size in bytes (1MB).
const DEFAULT_MAX_OUTPUT_BYTES: usize = 1_048_576;
/// Environment variables safe to pass to shell commands.
const SAFE_ENV_VARS = [_][]const u8{
    "PATH", "HOME", "TERM", "LANG", "LC_ALL", "LC_CTYPE", "USER", "SHELL", "TMPDIR",
};

/// Shell command execution tool with workspace scoping.
pub const ShellTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    timeout_ns: u64 = DEFAULT_SHELL_TIMEOUT_NS,
    max_output_bytes: usize = DEFAULT_MAX_OUTPUT_BYTES,

    const vtable = Tool.VTable{
        .execute = &vtableExecute,
        .name = &vtableName,
        .description = &vtableDesc,
        .parameters_json = &vtableParams,
    };

    pub fn tool(self: *ShellTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableExecute(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult {
        const self: *ShellTool = @ptrCast(@alignCast(ptr));
        return self.execute(allocator, args);
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "shell";
    }

    fn vtableDesc(_: *anyopaque) []const u8 {
        return "Execute a shell command in the workspace directory";
    }

    fn vtableParams(_: *anyopaque) []const u8 {
        return 
        \\{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"},"cwd":{"type":"string","description":"Working directory (absolute path within allowed paths; defaults to workspace)"}},"required":["command"]}
        ;
    }

    fn execute(self: *ShellTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        // Parse the command from the pre-parsed JSON object
        const command = root.getString(args, "command") orelse
            return ToolResult.fail("Missing 'command' parameter");

        // Determine working directory
        const effective_cwd = if (root.getString(args, "cwd")) |cwd| blk: {
            // cwd must be absolute
            if (cwd.len == 0 or cwd[0] != '/')
                return ToolResult.fail("cwd must be an absolute path");
            if (self.allowed_paths.len == 0)
                return ToolResult.fail("cwd not allowed (no allowed_paths configured)");
            // Resolve and validate
            const resolved_cwd = std.fs.cwd().realpathAlloc(allocator, cwd) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to resolve cwd: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            defer allocator.free(resolved_cwd);

            const ws_resolved: ?[]const u8 = std.fs.cwd().realpathAlloc(allocator, self.workspace_dir) catch null;
            defer if (ws_resolved) |wr| allocator.free(wr);

            if (!isResolvedPathAllowed(allocator, resolved_cwd, ws_resolved orelse "", self.allowed_paths))
                return ToolResult.fail("cwd is outside allowed areas");

            break :blk cwd;
        } else self.workspace_dir;

        // Execute via platform shell
        var child = std.process.Child.init(
            &.{ platform.getShell(), platform.getShellFlag(), command },
            allocator,
        );
        child.cwd = effective_cwd;

        // Clear environment to prevent leaking API keys (CWE-200),
        // then re-add only safe, functional variables.
        child.env_map = null;

        var env = std.process.EnvMap.init(allocator);
        defer env.deinit();
        for (&SAFE_ENV_VARS) |key| {
            if (platform.getEnvOrNull(allocator, key)) |val| {
                defer allocator.free(val);
                try env.put(key, val);
            }
        }
        child.env_map = &env;

        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Read stdout and stderr
        const stdout = try child.stdout.?.readToEndAlloc(allocator, self.max_output_bytes);
        defer allocator.free(stdout);
        const stderr = try child.stderr.?.readToEndAlloc(allocator, self.max_output_bytes);
        defer allocator.free(stderr);

        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    const out = try allocator.dupe(u8, if (stdout.len > 0) stdout else "(no output)");
                    return ToolResult{ .success = true, .output = out };
                } else {
                    const err_out = try allocator.dupe(u8, if (stderr.len > 0) stderr else "Command failed with non-zero exit code");
                    return ToolResult{ .success = false, .output = "", .error_msg = err_out };
                }
            },
            else => {
                return ToolResult{ .success = false, .output = "", .error_msg = "Command terminated by signal" };
            },
        }
    }
};

/// Extract a string field value from a JSON blob (minimal parser — no allocations).
/// NOTE: Prefer root.getString() with pre-parsed ObjectMap for tool implementations.
pub fn parseStringField(json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key": "value"
    // Build the search pattern: "key":"  or "key" : "
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    // Find closing quote (handle escaped quotes)
    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1; // skip escaped char
            continue;
        }
        if (after_key[i] == '"') {
            return after_key[start..i];
        }
    }
    return null;
}

/// Extract a boolean field value from a JSON blob.
pub fn parseBoolField(json: []const u8, key: []const u8) ?bool {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i + 4 <= after_key.len and std.mem.eql(u8, after_key[i..][0..4], "true")) return true;
    if (i + 5 <= after_key.len and std.mem.eql(u8, after_key[i..][0..5], "false")) return false;
    return null;
}

/// Extract an integer field value from a JSON blob.
pub fn parseIntField(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    const start = i;
    if (i < after_key.len and after_key[i] == '-') i += 1;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(i64, after_key[start..i], 10) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "shell tool name" {
    var st = ShellTool{ .workspace_dir = "/tmp" };
    const t = st.tool();
    try std.testing.expectEqualStrings("shell", t.name());
}

test "shell tool schema has command" {
    var st = ShellTool{ .workspace_dir = "/tmp" };
    const t = st.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "command") != null);
}

test "shell executes echo" {
    var st = ShellTool{ .workspace_dir = "/tmp" };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

test "shell captures failing command" {
    var st = ShellTool{ .workspace_dir = "/tmp" };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"ls /nonexistent_dir_xyz_42\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
}

test "shell missing command param" {
    var st = ShellTool{ .workspace_dir = "/tmp" };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "parseStringField basic" {
    const json = "{\"command\": \"echo hello\", \"other\": \"val\"}";
    const val = parseStringField(json, "command");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("echo hello", val.?);
}

test "parseStringField missing" {
    const json = "{\"other\": \"val\"}";
    try std.testing.expect(parseStringField(json, "command") == null);
}

test "parseBoolField true" {
    const json = "{\"cached\": true}";
    try std.testing.expectEqual(@as(?bool, true), parseBoolField(json, "cached"));
}

test "parseBoolField false" {
    const json = "{\"cached\": false}";
    try std.testing.expectEqual(@as(?bool, false), parseBoolField(json, "cached"));
}

test "parseIntField positive" {
    const json = "{\"limit\": 42}";
    try std.testing.expectEqual(@as(?i64, 42), parseIntField(json, "limit"));
}

test "parseIntField negative" {
    const json = "{\"offset\": -5}";
    try std.testing.expectEqual(@as(?i64, -5), parseIntField(json, "offset"));
}

test "shell cwd without allowed_paths is rejected" {
    var st = ShellTool{ .workspace_dir = "/tmp" };
    const parsed = try root.parseTestArgs("{\"command\": \"pwd\", \"cwd\": \"/tmp\"}");
    defer parsed.deinit();
    const result = try st.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no allowed_paths") != null);
}

test "shell cwd relative path is rejected" {
    var st = ShellTool{ .workspace_dir = "/tmp", .allowed_paths = &.{"/tmp"} };
    const parsed = try root.parseTestArgs("{\"command\": \"pwd\", \"cwd\": \"relative\"}");
    defer parsed.deinit();
    const result = try st.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "absolute") != null);
}

test "shell cwd with allowed_paths runs in cwd" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var args_buf: [512]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"command\": \"pwd\", \"cwd\": \"{s}\"}}", .{tmp_path});

    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();

    var st = ShellTool{ .workspace_dir = "/tmp", .allowed_paths = &.{tmp_path} };
    const result = try st.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, tmp_path) != null);
}
