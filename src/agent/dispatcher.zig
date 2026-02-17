const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// Dispatcher — tool call parsing and result formatting
// ═══════════════════════════════════════════════════════════════════════════

/// A parsed tool call extracted from an LLM response.
pub const ParsedToolCall = struct {
    name: []const u8,
    /// Raw JSON arguments string.
    arguments_json: []const u8,
    /// Optional tool_call_id for native tool-calling APIs.
    tool_call_id: ?[]const u8 = null,
};

/// Result of executing a single tool.
pub const ToolExecutionResult = struct {
    name: []const u8,
    output: []const u8,
    success: bool,
    tool_call_id: ?[]const u8 = null,
};

/// Parse tool calls from an LLM response using XML-style `<tool_call>` tags.
///
/// Expected format:
/// ```
/// Some text
/// <tool_call>
/// {"name": "shell", "arguments": {"command": "ls"}}
/// </tool_call>
/// More text
/// ```
///
/// Returns text portions (joined by newline) and extracted tool calls.
///
/// SECURITY: This function only extracts JSON from within explicit `<tool_call>` tags.
/// It does NOT parse raw JSON from the response body, which prevents prompt injection
/// where malicious content could include JSON mimicking a tool call.
pub fn parseToolCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
) !struct { text: []const u8, calls: []ParsedToolCall } {
    var text_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer text_parts.deinit(allocator);

    var calls: std.ArrayListUnmanaged(ParsedToolCall) = .empty;
    errdefer calls.deinit(allocator);

    var remaining = response;

    while (std.mem.indexOf(u8, remaining, "<tool_call>")) |start| {
        // Text before the tag
        const before = std.mem.trim(u8, remaining[0..start], " \t\r\n");
        if (before.len > 0) {
            try text_parts.append(allocator, before);
        }

        const after_open = remaining[start + 11 ..];
        if (std.mem.indexOf(u8, after_open, "</tool_call>")) |end| {
            const inner = std.mem.trim(u8, after_open[0..end], " \t\r\n");

            // Try to extract JSON object from inner content (may have markdown fences or preamble text)
            if (extractJsonObject(inner)) |json_slice| {
                // Parse the JSON to extract name and arguments
                if (parseToolCallJson(allocator, json_slice)) |call| {
                    try calls.append(allocator, call);
                } else |_| {
                    // Malformed JSON inside tag — skip silently
                }
            }

            remaining = after_open[end + 12 ..];
        } else {
            // Unclosed tag — stop parsing
            break;
        }
    }

    // Remaining text after last tool call
    const trailing = std.mem.trim(u8, remaining, " \t\r\n");
    if (trailing.len > 0) {
        try text_parts.append(allocator, trailing);
    }

    // Join text parts
    const text = if (text_parts.items.len == 0)
        ""
    else
        try std.mem.join(allocator, "\n", text_parts.items);

    return .{
        .text = text,
        .calls = try calls.toOwnedSlice(allocator),
    };
}

/// Format tool execution results as XML for the next LLM turn.
pub fn formatToolResults(allocator: std.mem.Allocator, results: []const ToolExecutionResult) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "[Tool results]\n");
    for (results) |result| {
        const status_str = if (result.success) "ok" else "error";
        try std.fmt.format(buf.writer(allocator), "<tool_result name=\"{s}\" status=\"{s}\">\n{s}\n</tool_result>\n", .{
            result.name,
            status_str,
            result.output,
        });
    }

    return try buf.toOwnedSlice(allocator);
}

/// Build tool use instructions for the system prompt.
pub fn buildToolInstructions(allocator: std.mem.Allocator, tools: anytype) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("\n## Tool Use Protocol\n\n");
    try w.writeAll("To use a tool, wrap a JSON object in <tool_call></tool_call> tags:\n\n");
    try w.writeAll("```\n<tool_call>\n{\"name\": \"tool_name\", \"arguments\": {\"param\": \"value\"}}\n</tool_call>\n```\n\n");
    try w.writeAll("CRITICAL: Output actual <tool_call> tags -- never describe steps or give examples.\n\n");
    try w.writeAll("You may use multiple tool calls in a single response. ");
    try w.writeAll("After tool execution, results appear in <tool_result> tags. ");
    try w.writeAll("Continue reasoning with the results until you can give a final answer.\n\n");
    try w.writeAll("### Available Tools\n\n");

    for (tools) |t| {
        try std.fmt.format(w, "**{s}**: {s}\nParameters: `{s}`\n\n", .{
            t.name(),
            t.description(),
            t.parametersJson(),
        });
    }

    return try buf.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Native Tool Dispatcher — OpenAI-format tool_calls support
// ═══════════════════════════════════════════════════════════════════════════

/// Dispatcher format kind.
pub const DispatcherKind = enum {
    xml,
    native,
};

/// Detect whether a response string is in OpenAI native tool-call format.
/// Looks for the `"tool_calls"` key inside a top-level JSON object.
pub fn isNativeFormat(response: []const u8) bool {
    // Quick heuristic: must contain "tool_calls" substring
    if (std.mem.indexOf(u8, response, "\"tool_calls\"") == null) return false;

    // Validate it's inside a parseable JSON object
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{}) catch return false;
    defer parsed.deinit();

    return switch (parsed.value) {
        .object => |obj| obj.get("tool_calls") != null,
        else => false,
    };
}

/// A single tool call in the OpenAI native format (within the `tool_calls` array).
const NativeToolCall = struct {
    id: []const u8,
    type: []const u8,
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

/// Parse tool calls from an OpenAI-format JSON response.
///
/// Expected input format (the full response JSON, or just the message object):
/// ```json
/// {
///   "content": "Some text",
///   "tool_calls": [
///     {
///       "id": "call_abc123",
///       "type": "function",
///       "function": {
///         "name": "shell",
///         "arguments": "{\"command\": \"ls -la\"}"
///       }
///     }
///   ]
/// }
/// ```
///
/// Returns text content and extracted tool calls (same shape as XML parser).
pub fn parseNativeToolCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
) !struct { text: []const u8, calls: []ParsedToolCall } {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidNativeFormat,
    };

    // Extract text content
    const text = if (obj.get("content")) |content_val| switch (content_val) {
        .string => |s| try allocator.dupe(u8, s),
        .null => try allocator.dupe(u8, ""),
        else => try allocator.dupe(u8, ""),
    } else try allocator.dupe(u8, "");

    // Extract tool_calls array
    const tool_calls_val = obj.get("tool_calls") orelse return .{
        .text = text,
        .calls = try allocator.alloc(ParsedToolCall, 0),
    };

    const tool_calls_arr = switch (tool_calls_val) {
        .array => |a| a,
        else => return .{
            .text = text,
            .calls = try allocator.alloc(ParsedToolCall, 0),
        },
    };

    var calls: std.ArrayListUnmanaged(ParsedToolCall) = .empty;
    errdefer {
        for (calls.items) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        calls.deinit(allocator);
    }

    for (tool_calls_arr.items) |tc_val| {
        const tc_obj = switch (tc_val) {
            .object => |o| o,
            else => continue,
        };

        // Extract the function object
        const func_val = tc_obj.get("function") orelse continue;
        const func_obj = switch (func_val) {
            .object => |o| o,
            else => continue,
        };

        // Extract function name
        const name_val = func_obj.get("name") orelse continue;
        const name_str = switch (name_val) {
            .string => |s| s,
            else => continue,
        };
        if (name_str.len == 0) continue;

        // Extract arguments (string)
        const args_str = if (func_obj.get("arguments")) |args_val| switch (args_val) {
            .string => |s| s,
            else => "{}",
        } else "{}";

        // Extract tool call id
        const tc_id = if (tc_obj.get("id")) |id_val| switch (id_val) {
            .string => |s| s,
            else => null,
        } else null;

        try calls.append(allocator, .{
            .name = try allocator.dupe(u8, name_str),
            .arguments_json = try allocator.dupe(u8, args_str),
            .tool_call_id = if (tc_id) |id| try allocator.dupe(u8, id) else null,
        });
    }

    return .{
        .text = text,
        .calls = try calls.toOwnedSlice(allocator),
    };
}

/// Format tool execution results as OpenAI-format JSON for the next API call.
///
/// Produces an array of tool result messages:
/// ```json
/// [
///   {"role": "tool", "tool_call_id": "call_abc123", "content": "output here"}
/// ]
/// ```
pub fn formatNativeToolResults(allocator: std.mem.Allocator, results: []const ToolExecutionResult) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("[");
    for (results, 0..) |result, i| {
        if (i > 0) try w.writeAll(",");
        const tc_id = result.tool_call_id orelse "unknown";

        // Serialize content as a JSON string value
        try std.fmt.format(w, "{{\"role\":\"tool\",\"tool_call_id\":{f},\"content\":{f}}}", .{
            std.json.fmt(tc_id, .{}),
            std.json.fmt(result.output, .{}),
        });
    }
    try w.writeAll("]");

    return try buf.toOwnedSlice(allocator);
}

// ── Internal helpers ────────────────────────────────────────────────────

/// Find the first JSON object `{...}` in a string, handling nesting.
fn extractJsonObject(input: []const u8) ?[]const u8 {
    // Strip markdown fences if present
    var trimmed = input;
    if (std.mem.indexOf(u8, trimmed, "```")) |fence_start| {
        // Skip to end of first line (after ```json or ```)
        const after_fence = trimmed[fence_start + 3 ..];
        if (std.mem.indexOfScalar(u8, after_fence, '\n')) |nl| {
            trimmed = after_fence[nl + 1 ..];
        }
        // Strip closing fence
        if (std.mem.lastIndexOf(u8, trimmed, "```")) |close| {
            trimmed = trimmed[0..close];
        }
    }

    // Find first '{'
    const start = std.mem.indexOfScalar(u8, trimmed, '{') orelse return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i: usize = start;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\' and in_string) {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (!in_string) {
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) return trimmed[start .. i + 1];
            }
        }
    }

    return null;
}

/// Parse a JSON tool call object: {"name": "...", "arguments": {...}}
fn parseToolCallJson(allocator: std.mem.Allocator, json_str: []const u8) !ParsedToolCall {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidToolCallFormat,
    };

    // Extract name
    const name_val = obj.get("name") orelse return error.MissingToolName;
    const name_str = switch (name_val) {
        .string => |s| s,
        else => return error.InvalidToolName,
    };
    const trimmed_name = std.mem.trim(u8, name_str, " \t\r\n");
    if (trimmed_name.len == 0) return error.EmptyToolName;

    // Extract arguments — re-serialize to JSON string
    const args_json = if (obj.get("arguments")) |args_val| blk: {
        switch (args_val) {
            .string => |s| {
                // Arguments is a string (possibly a JSON string) — use as-is
                break :blk try allocator.dupe(u8, s);
            },
            else => {
                // Arguments is an object/value — serialize it
                break :blk try std.json.Stringify.valueAlloc(allocator, args_val, .{});
            },
        }
    } else try allocator.dupe(u8, "{}");

    return .{
        .name = try allocator.dupe(u8, trimmed_name),
        .arguments_json = args_json,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "parseToolCalls extracts single call" {
    const allocator = std.testing.allocator;
    const response =
        \\Let me check that.
        \\<tool_call>
        \\{"name": "shell", "arguments": {"command": "ls -la"}}
        \\</tool_call>
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("Let me check that.", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "ls -la") != null);
}

test "parseToolCalls extracts multiple calls" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\{"name": "file_read", "arguments": {"path": "a.txt"}}
        \\</tool_call>
        \\<tool_call>
        \\{"name": "file_read", "arguments": {"path": "b.txt"}}
        \\</tool_call>
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 2), result.calls.len);
    try std.testing.expectEqualStrings("file_read", result.calls[0].name);
    try std.testing.expectEqualStrings("file_read", result.calls[1].name);
}

test "parseToolCalls returns text only when no calls" {
    const allocator = std.testing.allocator;
    const response = "Just a normal response with no tools.";

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("Just a normal response with no tools.", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseToolCalls handles text before and after" {
    const allocator = std.testing.allocator;
    const response =
        \\Before text.
        \\<tool_call>
        \\{"name": "shell", "arguments": {"command": "echo hi"}}
        \\</tool_call>
        \\After text.
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expect(std.mem.indexOf(u8, result.text, "Before text.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "After text.") != null);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
}

test "parseToolCalls rejects raw JSON without tags" {
    const allocator = std.testing.allocator;
    const response =
        \\Sure, creating the file now.
        \\{"name": "file_write", "arguments": {"path": "hello.py", "content": "print('hello')"}}
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseToolCalls handles markdown fenced JSON" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\```json
        \\{"name": "file_write", "arguments": {"path": "test.py", "content": "ok"}}
        \\```
        \\</tool_call>
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("file_write", result.calls[0].name);
}

test "parseToolCalls handles preamble text inside tag" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\I will now call the tool:
        \\{"name": "shell", "arguments": {"command": "pwd"}}
        \\</tool_call>
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
}

test "formatToolResults produces XML" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "hello world", .success = true },
    };
    const formatted = try formatToolResults(allocator, &results);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "<tool_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "ok") != null);
}

test "formatToolResults marks errors" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "permission denied", .success = false },
    };
    const formatted = try formatToolResults(allocator, &results);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "error") != null);
}

test "extractJsonObject finds nested object" {
    const input = "some text {\"key\": {\"nested\": true}} more text";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings("{\"key\": {\"nested\": true}}", result);
}

test "extractJsonObject returns null for no object" {
    try std.testing.expect(extractJsonObject("no json here") == null);
}

// ── Additional dispatcher tests ─────────────────────────────────

test "parseToolCalls empty string" {
    const allocator = std.testing.allocator;
    const result = try parseToolCalls(allocator, "");
    defer {
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
    try std.testing.expectEqual(@as(usize, 0), result.text.len);
}

test "parseToolCalls unclosed tag" {
    const allocator = std.testing.allocator;
    const response = "Some text <tool_call>{\"name\":\"shell\",\"arguments\":{}} and more";
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        allocator.free(result.calls);
    }
    // Unclosed tag should stop parsing, text before tag should be captured
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseToolCalls malformed JSON inside tag" {
    const allocator = std.testing.allocator;
    const response = "<tool_call>this is not json</tool_call>";
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        allocator.free(result.calls);
    }
    // Malformed JSON is skipped
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseToolCalls empty arguments defaults to empty object" {
    const allocator = std.testing.allocator;
    const response = "<tool_call>{\"name\": \"shell\"}</tool_call>";
    const result = try parseToolCalls(allocator, response);
    defer {
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expectEqualStrings("{}", result.calls[0].arguments_json);
}

test "parseToolCalls whitespace-only inside tag" {
    const allocator = std.testing.allocator;
    const response = "<tool_call>   \n   </tool_call>";
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "formatToolResults empty results" {
    const allocator = std.testing.allocator;
    const formatted = try formatToolResults(allocator, &.{});
    defer allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Tool results") != null);
}

test "formatToolResults multiple results" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "file1.txt", .success = true },
        .{ .name = "file_read", .output = "content here", .success = true },
        .{ .name = "search", .output = "not found", .success = false },
    };
    const formatted = try formatToolResults(allocator, &results);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "file_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "search") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "file1.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "not found") != null);
}

test "extractJsonObject with leading text" {
    const input = "Here is the result: {\"key\": \"value\"}";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings("{\"key\": \"value\"}", result);
}

test "extractJsonObject deeply nested" {
    const input = "{\"a\":{\"b\":{\"c\":true}}}";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings(input, result);
}

test "extractJsonObject with string containing braces" {
    const input = "{\"key\": \"value with { and } inside\"}";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings(input, result);
}

test "extractJsonObject empty string" {
    try std.testing.expect(extractJsonObject("") == null);
}

test "extractJsonObject unmatched brace" {
    try std.testing.expect(extractJsonObject("{unclosed") == null);
}

test "buildToolInstructions empty tools" {
    const allocator = std.testing.allocator;
    const MockTool = struct {
        fn name(_: @This()) []const u8 {
            return "mock";
        }
        fn description(_: @This()) []const u8 {
            return "A mock tool";
        }
        fn parametersJson(_: @This()) []const u8 {
            return "{}";
        }
    };
    const empty: []const MockTool = &.{};
    const instructions = try buildToolInstructions(allocator, empty);
    defer allocator.free(instructions);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "Tool Use Protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "tool_call") != null);
}

test "parseToolCalls three consecutive calls" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\{"name": "a", "arguments": {}}
        \\</tool_call>
        \\<tool_call>
        \\{"name": "b", "arguments": {}}
        \\</tool_call>
        \\<tool_call>
        \\{"name": "c", "arguments": {}}
        \\</tool_call>
    ;
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 3), result.calls.len);
    try std.testing.expectEqualStrings("a", result.calls[0].name);
    try std.testing.expectEqualStrings("b", result.calls[1].name);
    try std.testing.expectEqualStrings("c", result.calls[2].name);
}

test "formatToolResults with tool_call_id" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "ok", .success = true, .tool_call_id = "tc-123" },
    };
    const formatted = try formatToolResults(allocator, &results);
    defer allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "ok") != null);
}

test "ParsedToolCall default tool_call_id is null" {
    const call = ParsedToolCall{
        .name = "test",
        .arguments_json = "{}",
    };
    try std.testing.expect(call.tool_call_id == null);
}

test "ToolExecutionResult default tool_call_id is null" {
    const result = ToolExecutionResult{
        .name = "test",
        .output = "output",
        .success = true,
    };
    try std.testing.expect(result.tool_call_id == null);
}

// ── Native tool dispatcher tests ────────────────────────────────

test "isNativeFormat detects OpenAI tool_calls" {
    const native_response =
        \\{"content":"ok","tool_calls":[{"id":"call_1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls\"}"}}]}
    ;
    try std.testing.expect(isNativeFormat(native_response));
}

test "isNativeFormat rejects XML format" {
    const xml_response = "Let me check.\n<tool_call>\n{\"name\":\"shell\",\"arguments\":{}}\n</tool_call>";
    try std.testing.expect(!isNativeFormat(xml_response));
}

test "isNativeFormat rejects plain text" {
    try std.testing.expect(!isNativeFormat("Just a normal response."));
}

test "isNativeFormat rejects tool_calls in non-JSON context" {
    // Contains the substring but is not valid JSON
    try std.testing.expect(!isNativeFormat("The API returns \"tool_calls\" in the response."));
}

test "parseNativeToolCalls single call" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"I will list files.","tool_calls":[{"id":"call_abc","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls -la\"}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("I will list files.", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expectEqualStrings("call_abc", result.calls[0].tool_call_id.?);
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "ls -la") != null);
}

test "parseNativeToolCalls multiple calls" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"Reading files.","tool_calls":[{"id":"tc1","type":"function","function":{"name":"file_read","arguments":"{\"path\":\"a.txt\"}"}},{"id":"tc2","type":"function","function":{"name":"file_read","arguments":"{\"path\":\"b.txt\"}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 2), result.calls.len);
    try std.testing.expectEqualStrings("file_read", result.calls[0].name);
    try std.testing.expectEqualStrings("tc1", result.calls[0].tool_call_id.?);
    try std.testing.expectEqualStrings("file_read", result.calls[1].name);
    try std.testing.expectEqualStrings("tc2", result.calls[1].tool_call_id.?);
}

test "parseNativeToolCalls null content" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":null,"tool_calls":[{"id":"tc1","type":"function","function":{"name":"shell","arguments":"{}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
}

test "parseNativeToolCalls no tool_calls key" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"Just text, no tools."}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("Just text, no tools.", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseNativeToolCalls empty tool_calls array" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"Done.","tool_calls":[]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("Done.", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseNativeToolCalls skips entries without function field" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"","tool_calls":[{"id":"tc1","type":"function"},{"id":"tc2","type":"function","function":{"name":"shell","arguments":"{}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
}

test "parseNativeToolCalls skips entries with empty function name" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"","tool_calls":[{"id":"tc1","type":"function","function":{"name":"","arguments":"{}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseNativeToolCalls preserves tool_call_id" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"","tool_calls":[{"id":"call_xyz789","type":"function","function":{"name":"search","arguments":"{\"query\":\"test\"}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("call_xyz789", result.calls[0].tool_call_id.?);
}

test "formatNativeToolResults single result" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "hello world", .success = true, .tool_call_id = "call_1" },
    };
    const formatted = try formatNativeToolResults(allocator, &results);
    defer allocator.free(formatted);

    // Should be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, formatted, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.ExpectedArray,
    };

    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    const item = arr.items[0].object;
    try std.testing.expectEqualStrings("tool", item.get("role").?.string);
    try std.testing.expectEqualStrings("call_1", item.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("hello world", item.get("content").?.string);
}

test "formatNativeToolResults multiple results" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "ok", .success = true, .tool_call_id = "tc1" },
        .{ .name = "file_read", .output = "content", .success = true, .tool_call_id = "tc2" },
    };
    const formatted = try formatNativeToolResults(allocator, &results);
    defer allocator.free(formatted);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, formatted, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.ExpectedArray,
    };

    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("tc1", arr.items[0].object.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("tc2", arr.items[1].object.get("tool_call_id").?.string);
}

test "formatNativeToolResults missing tool_call_id defaults to unknown" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "ok", .success = true },
    };
    const formatted = try formatNativeToolResults(allocator, &results);
    defer allocator.free(formatted);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, formatted, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.ExpectedArray,
    };

    try std.testing.expectEqualStrings("unknown", arr.items[0].object.get("tool_call_id").?.string);
}

test "formatNativeToolResults empty results" {
    const allocator = std.testing.allocator;
    const formatted = try formatNativeToolResults(allocator, &.{});
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("[]", formatted);
}

test "formatNativeToolResults escapes special characters in output" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "line1\nline2\t\"quoted\"", .success = true, .tool_call_id = "tc1" },
    };
    const formatted = try formatNativeToolResults(allocator, &results);
    defer allocator.free(formatted);

    // Verify it's valid JSON (will fail if escaping is broken)
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, formatted, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqualStrings("line1\nline2\t\"quoted\"", arr.items[0].object.get("content").?.string);
}

test "DispatcherKind enum values" {
    try std.testing.expect(@intFromEnum(DispatcherKind.xml) != @intFromEnum(DispatcherKind.native));
}
