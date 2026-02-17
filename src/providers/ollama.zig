const std = @import("std");
const root = @import("root.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;

// ─── Tool Call Response Structures ───────────────────────────────────────────

const OllamaFunction = struct {
    name: []const u8 = "",
    arguments: std.json.Value = .null,
};

const OllamaToolCall = struct {
    id: ?[]const u8 = null,
    function: OllamaFunction = .{},
};

const OllamaMessage = struct {
    role: []const u8 = "",
    content: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    tool_calls: ?[]const OllamaToolCall = null,
};

const OllamaChatResponse = struct {
    message: OllamaMessage = .{},
};

// ─── Tool Call Helpers ───────────────────────────────────────────────────────

/// Extract actual tool name and arguments from potentially quirky tool call formats.
///
/// Handles 3 patterns local models commonly produce:
/// 1. Nested wrapper: {"name":"tool_call","arguments":{"name":"shell","arguments":{...}}}
/// 2. Prefixed names: "tool.shell" -> "shell"
/// 3. Normal: return as-is
fn extractToolNameAndArgs(
    name: []const u8,
    arguments: std.json.Value,
) struct { name: []const u8, args: std.json.Value } {
    // Pattern 1: Nested tool_call wrapper
    if (std.mem.eql(u8, name, "tool_call") or
        std.mem.eql(u8, name, "tool.call") or
        std.mem.startsWith(u8, name, "tool_call>") or
        std.mem.startsWith(u8, name, "tool_call<"))
    {
        if (arguments == .object) {
            if (arguments.object.get("name")) |nested_name_val| {
                if (nested_name_val == .string) {
                    const nested_args = if (arguments.object.get("arguments")) |a| a else std.json.Value{ .object = std.json.ObjectMap.init(std.heap.page_allocator) };
                    return .{ .name = nested_name_val.string, .args = nested_args };
                }
            }
        }
    }

    // Pattern 2: Prefixed tool name (tool.shell -> shell, tools.shell -> shell)
    if (std.mem.startsWith(u8, name, "tools.")) {
        return .{ .name = name["tools.".len..], .args = arguments };
    }
    if (std.mem.startsWith(u8, name, "tool.")) {
        return .{ .name = name["tool.".len..], .args = arguments };
    }

    // Pattern 3: Normal
    return .{ .name = name, .args = arguments };
}

/// Convert Ollama native tool calls to the JSON format expected by the agent loop.
///
/// Produces OpenAI-compatible JSON:
/// {"content":"","tool_calls":[{"id":"call_0","type":"function","function":{"name":"shell","arguments":"{...}"}}]}
fn formatToolCallsForLoop(
    allocator: std.mem.Allocator,
    message: OllamaMessage,
) ![]const u8 {
    const tool_calls = message.tool_calls orelse return try allocator.dupe(u8, message.content orelse "");
    if (tool_calls.len == 0) return try allocator.dupe(u8, message.content orelse "");

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"content\":\"\",\"tool_calls\":[");

    for (tool_calls, 0..) |tc, i| {
        if (i > 0) try result.append(allocator, ',');

        const extracted = extractToolNameAndArgs(tc.function.name, tc.function.arguments);

        // Serialize arguments to string
        const args_str = if (extracted.args == .null)
            try allocator.dupe(u8, "{}")
        else
            try std.json.Stringify.valueAlloc(allocator, extracted.args, .{});
        defer allocator.free(args_str);

        // Escape the args_str for embedding in JSON string
        const escaped_args = try jsonEscapeString(allocator, args_str);
        defer allocator.free(escaped_args);

        // Build the call ID
        const call_id = if (tc.id) |id|
            try allocator.dupe(u8, id)
        else
            try std.fmt.allocPrint(allocator, "call_{d}", .{i});
        defer allocator.free(call_id);

        try result.appendSlice(allocator, "{\"id\":\"");
        try result.appendSlice(allocator, call_id);
        try result.appendSlice(allocator, "\",\"type\":\"function\",\"function\":{\"name\":\"");
        try result.appendSlice(allocator, extracted.name);
        try result.appendSlice(allocator, "\",\"arguments\":\"");
        try result.appendSlice(allocator, escaped_args);
        try result.appendSlice(allocator, "\"}}");
    }

    try result.appendSlice(allocator, "]}");

    return try result.toOwnedSlice(allocator);
}

/// Escape a string for embedding inside a JSON string value.
fn jsonEscapeString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// Ollama local LLM provider.
///
/// Endpoints:
/// - POST {base_url}/api/chat
/// - No authentication required (local service)
pub const OllamaProvider = struct {
    base_url: []const u8,
    allocator: std.mem.Allocator,

    const DEFAULT_BASE_URL = "http://localhost:11434";

    pub fn init(allocator: std.mem.Allocator, base_url: ?[]const u8) OllamaProvider {
        const url = if (base_url) |u| trimTrailingSlash(u) else DEFAULT_BASE_URL;
        return .{
            .base_url = url,
            .allocator = allocator,
        };
    }

    fn trimTrailingSlash(s: []const u8) []const u8 {
        if (s.len > 0 and s[s.len - 1] == '/') {
            return s[0 .. s.len - 1];
        }
        return s;
    }

    /// Build the chat endpoint URL.
    pub fn chatUrl(self: OllamaProvider, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/api/chat", .{self.base_url});
    }

    /// Build an Ollama chat request JSON body.
    pub fn buildRequestBody(
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) ![]const u8 {
        if (system_prompt) |sys| {
            return std.fmt.allocPrint(allocator,
                \\{{"model":"{s}","messages":[{{"role":"system","content":"{s}"}},{{"role":"user","content":"{s}"}}],"stream":false,"options":{{"temperature":{d:.2}}}}}
            , .{ model, sys, message, temperature });
        } else {
            return std.fmt.allocPrint(allocator,
                \\{{"model":"{s}","messages":[{{"role":"user","content":"{s}"}}],"stream":false,"options":{{"temperature":{d:.2}}}}}
            , .{ model, message, temperature });
        }
    }

    /// Parse an Ollama response, handling tool calls, thinking-only, and plain text.
    pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSlice(OllamaChatResponse, allocator, body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const message = parsed.value.message;

        // If model returned tool calls, format them for the agent loop
        if (message.tool_calls) |tcs| {
            if (tcs.len > 0) {
                return formatToolCallsForLoop(allocator, message);
            }
        }

        // Plain text response
        if (message.content) |content| {
            if (content.len > 0) {
                return try allocator.dupe(u8, content);
            }
        }

        // Thinking-only response (model reasoned but produced no output)
        if (message.thinking) |thinking| {
            const preview_len = @min(thinking.len, 200);
            return try std.fmt.allocPrint(
                allocator,
                "I was thinking about this: {s}... but I didn't complete my response. Could you try asking again?",
                .{thinking[0..preview_len]},
            );
        }

        // Empty response
        return try allocator.dupe(u8, "");
    }

    /// Create a Provider interface from this OllamaProvider.
    pub fn provider(self: *OllamaProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) anyerror![]const u8 {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));

        const url = try self.chatUrl(allocator);
        defer allocator.free(url);

        const body = try buildRequestBody(allocator, system_prompt, message, model, temperature);
        defer allocator.free(body);

        const resp_body = curlPost(allocator, url, body) catch return error.OllamaApiError;
        defer allocator.free(resp_body);

        return parseResponse(allocator, resp_body);
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
    ) anyerror!ChatResponse {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));

        // Extract system prompt and last user message from the request
        var system_prompt: ?[]const u8 = null;
        var user_message: []const u8 = "";
        for (request.messages) |msg| {
            if (msg.role == .system) system_prompt = msg.content;
            if (msg.role == .user) user_message = msg.content;
        }

        const url = try self.chatUrl(allocator);
        defer allocator.free(url);

        const body = try buildRequestBody(allocator, system_prompt, user_message, model, temperature);
        defer allocator.free(body);

        const resp_body = curlPost(allocator, url, body) catch return error.OllamaApiError;
        defer allocator.free(resp_body);

        const text = try parseResponse(allocator, resp_body);
        return ChatResponse{ .content = text };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return false;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "Ollama";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

/// HTTP POST via curl subprocess (no auth needed for local Ollama).
fn curlPost(allocator: std.mem.Allocator, url: []const u8, body: []const u8) ![]u8 {
    var child = std.process.Child.init(&.{
        "curl", "-s",                             "-X", "POST",
        "-H",   "Content-Type: application/json", "-d", body,
        url,
    }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch return error.CurlReadError;

    const term = child.wait() catch return error.CurlWaitError;
    if (term != .Exited or term.Exited != 0) return error.CurlFailed;

    return stdout;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "default url" {
    const p = OllamaProvider.init(std.testing.allocator, null);
    try std.testing.expectEqualStrings("http://localhost:11434", p.base_url);
}

test "custom url trailing slash" {
    const p = OllamaProvider.init(std.testing.allocator, "http://192.168.1.100:11434/");
    try std.testing.expectEqualStrings("http://192.168.1.100:11434", p.base_url);
}

test "custom url no trailing slash" {
    const p = OllamaProvider.init(std.testing.allocator, "http://myserver:11434");
    try std.testing.expectEqualStrings("http://myserver:11434", p.base_url);
}

test "chat url is correct" {
    const p = OllamaProvider.init(std.testing.allocator, null);
    const url = try p.chatUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:11434/api/chat", url);
}

test "buildRequestBody with system" {
    const body = try OllamaProvider.buildRequestBody(std.testing.allocator, "You are helpful", "hello", "llama3", 0.7);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "llama3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "system") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "temperature") != null);
}

test "buildRequestBody without system" {
    const body = try OllamaProvider.buildRequestBody(std.testing.allocator, null, "test", "mistral", 0.0);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mistral") != null);
}

test "parseResponse extracts content" {
    const body =
        \\{"message":{"role":"assistant","content":"Hello from Ollama!"}}
    ;
    const result = try OllamaProvider.parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello from Ollama!", result);
}

test "parseResponse empty content" {
    const body =
        \\{"message":{"role":"assistant","content":""}}
    ;
    const result = try OllamaProvider.parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "supportsNativeTools returns false" {
    var p = OllamaProvider.init(std.testing.allocator, null);
    const prov = p.provider();
    try std.testing.expect(!prov.supportsNativeTools());
}

// ─── Tool Call Tests ─────────────────────────────────────────────────────────

test "extractToolNameAndArgs with normal name" {
    const result = extractToolNameAndArgs("shell", .null);
    try std.testing.expectEqualStrings("shell", result.name);
}

test "extractToolNameAndArgs with tool. prefix" {
    const result = extractToolNameAndArgs("tool.shell", .null);
    try std.testing.expectEqualStrings("shell", result.name);
}

test "extractToolNameAndArgs with tools. prefix" {
    const result = extractToolNameAndArgs("tools.file_read", .null);
    try std.testing.expectEqualStrings("file_read", result.name);
}

test "extractToolNameAndArgs with nested tool_call wrapper" {
    // Build a JSON object: {"name":"shell","arguments":{"command":"date"}}
    const json_str =
        \\{"name":"shell","arguments":{"command":"date"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer parsed.deinit();

    const result = extractToolNameAndArgs("tool_call", parsed.value);
    try std.testing.expectEqualStrings("shell", result.name);
    // The inner arguments should contain "command"
    try std.testing.expect(result.args == .object);
    const cmd = result.args.object.get("command") orelse unreachable;
    try std.testing.expect(cmd == .string);
    try std.testing.expectEqualStrings("date", cmd.string);
}

test "extractToolNameAndArgs with tool.call wrapper" {
    const json_str =
        \\{"name":"file_read","arguments":{"path":"/tmp"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer parsed.deinit();

    const result = extractToolNameAndArgs("tool.call", parsed.value);
    try std.testing.expectEqualStrings("file_read", result.name);
}

test "formatToolCallsForLoop with single tool call" {
    const alloc = std.testing.allocator;
    const json_str =
        \\{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_abc","function":{"name":"shell","arguments":{"command":"date"}}}]}}
    ;
    const parsed = try std.json.parseFromSlice(OllamaChatResponse, alloc, json_str, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const result = try formatToolCallsForLoop(alloc, parsed.value.message);
    defer alloc.free(result);

    // Verify it's valid JSON
    const verify = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer verify.deinit();

    // Should have tool_calls array
    const tool_calls = verify.value.object.get("tool_calls").?.array;
    try std.testing.expect(tool_calls.items.len == 1);

    // Check function name
    const func = tool_calls.items[0].object.get("function").?;
    try std.testing.expectEqualStrings("shell", func.object.get("name").?.string);

    // Arguments should be a string (JSON-encoded)
    try std.testing.expect(func.object.get("arguments").? == .string);

    // Check ID
    try std.testing.expectEqualStrings("call_abc", tool_calls.items[0].object.get("id").?.string);
}

test "formatToolCallsForLoop with no tool calls returns content" {
    const alloc = std.testing.allocator;
    const msg = OllamaMessage{
        .role = "assistant",
        .content = "Hello there!",
        .tool_calls = null,
    };
    const result = try formatToolCallsForLoop(alloc, msg);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Hello there!", result);
}

test "formatToolCallsForLoop with empty tool calls returns content" {
    const alloc = std.testing.allocator;
    const empty_tcs: []const OllamaToolCall = &.{};
    const msg = OllamaMessage{
        .role = "assistant",
        .content = "Fallback content",
        .tool_calls = empty_tcs,
    };
    const result = try formatToolCallsForLoop(alloc, msg);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Fallback content", result);
}

test "formatToolCallsForLoop generates call_N id when id is null" {
    const alloc = std.testing.allocator;
    const tcs = [_]OllamaToolCall{.{
        .id = null,
        .function = .{ .name = "shell", .arguments = .null },
    }};
    const msg = OllamaMessage{
        .role = "assistant",
        .content = "",
        .tool_calls = &tcs,
    };
    const result = try formatToolCallsForLoop(alloc, msg);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"call_0\"") != null);
}

test "parseResponse with tool calls produces formatted JSON" {
    const alloc = std.testing.allocator;
    const body =
        \\{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","function":{"name":"shell","arguments":{"command":"ls"}}}]}}
    ;
    const result = try OllamaProvider.parseResponse(alloc, body);
    defer alloc.free(result);

    // Should be valid JSON with tool_calls
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("tool_calls") != null);
}

test "parseResponse thinking-only returns fallback message" {
    const alloc = std.testing.allocator;
    const body =
        \\{"message":{"role":"assistant","content":"","thinking":"Let me reason about this carefully..."}}
    ;
    const result = try OllamaProvider.parseResponse(alloc, body);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "I was thinking about this") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Let me reason") != null);
}

test "parseResponse with tool_call nested wrapper unwraps correctly" {
    const alloc = std.testing.allocator;
    const body =
        \\{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"tool_call","arguments":{"name":"shell","arguments":{"command":"whoami"}}}}]}}
    ;
    const result = try OllamaProvider.parseResponse(alloc, body);
    defer alloc.free(result);

    // The formatted output should contain the unwrapped tool name "shell"
    try std.testing.expect(std.mem.indexOf(u8, result, "\"shell\"") != null);
    // And should NOT have "tool_call" as the function name
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"tool_call\"") == null);
}

test "jsonEscapeString escapes quotes and backslashes" {
    const alloc = std.testing.allocator;
    const result = try jsonEscapeString(alloc, "he said \"hello\\world\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("he said \\\"hello\\\\world\\\"", result);
}
