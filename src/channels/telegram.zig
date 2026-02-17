const std = @import("std");
const root = @import("root.zig");

// ════════════════════════════════════════════════════════════════════════════
// Attachment Types
// ════════════════════════════════════════════════════════════════════════════

pub const AttachmentKind = enum {
    image,
    document,
    video,
    audio,
    voice,

    /// Return the Telegram API method name for this attachment kind.
    pub fn apiMethod(self: AttachmentKind) []const u8 {
        return switch (self) {
            .image => "sendPhoto",
            .document => "sendDocument",
            .video => "sendVideo",
            .audio => "sendAudio",
            .voice => "sendVoice",
        };
    }

    /// Return the multipart form field name for this attachment kind.
    pub fn formField(self: AttachmentKind) []const u8 {
        return switch (self) {
            .image => "photo",
            .document => "document",
            .video => "video",
            .audio => "audio",
            .voice => "voice",
        };
    }
};

pub const Attachment = struct {
    kind: AttachmentKind,
    target: []const u8, // path or URL
    caption: ?[]const u8 = null,
};

pub const ParsedMessage = struct {
    attachments: []Attachment,
    remaining_text: []const u8,

    pub fn deinit(self: *const ParsedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.attachments);
        allocator.free(self.remaining_text);
    }
};

/// Infer attachment kind from file extension.
pub fn inferAttachmentKindFromExtension(path: []const u8) AttachmentKind {
    // Strip query string and fragment
    const without_query = if (std.mem.indexOf(u8, path, "?")) |i| path[0..i] else path;
    const without_fragment = if (std.mem.indexOf(u8, without_query, "#")) |i| without_query[0..i] else without_query;

    // Find last '.' for extension
    const dot_pos = std.mem.lastIndexOf(u8, without_fragment, ".") orelse return .document;
    const ext = without_fragment[dot_pos + 1 ..];

    // Compare lowercase
    if (eqlLower(ext, "png") or eqlLower(ext, "jpg") or eqlLower(ext, "jpeg") or
        eqlLower(ext, "gif") or eqlLower(ext, "webp") or eqlLower(ext, "bmp"))
        return .image;

    if (eqlLower(ext, "mp4") or eqlLower(ext, "mov") or eqlLower(ext, "avi") or
        eqlLower(ext, "mkv") or eqlLower(ext, "webm"))
        return .video;

    if (eqlLower(ext, "mp3") or eqlLower(ext, "m4a") or eqlLower(ext, "wav") or
        eqlLower(ext, "flac"))
        return .audio;

    if (eqlLower(ext, "ogg") or eqlLower(ext, "oga") or eqlLower(ext, "opus"))
        return .voice;

    if (eqlLower(ext, "pdf") or eqlLower(ext, "doc") or eqlLower(ext, "docx") or
        eqlLower(ext, "txt") or eqlLower(ext, "md") or eqlLower(ext, "csv") or
        eqlLower(ext, "json") or eqlLower(ext, "zip") or eqlLower(ext, "tar") or
        eqlLower(ext, "gz") or eqlLower(ext, "xls") or eqlLower(ext, "xlsx") or
        eqlLower(ext, "ppt") or eqlLower(ext, "pptx"))
        return .document;

    return .document;
}

fn eqlLower(a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != bc) return false;
    }
    return true;
}

/// Parse attachment markers from LLM response text.
/// Scans for [IMAGE:...], [DOCUMENT:...], [VIDEO:...], [AUDIO:...], [VOICE:...] markers.
/// Returns extracted attachments and the remaining text with markers removed.
pub fn parseAttachmentMarkers(allocator: std.mem.Allocator, text: []const u8) !ParsedMessage {
    var attachments: std.ArrayListUnmanaged(Attachment) = .empty;
    errdefer attachments.deinit(allocator);

    var remaining: std.ArrayListUnmanaged(u8) = .empty;
    errdefer remaining.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < text.len) {
        // Find next '['
        const open_pos = std.mem.indexOfPos(u8, text, cursor, "[") orelse {
            try remaining.appendSlice(allocator, text[cursor..]);
            break;
        };

        // Append text before the bracket
        try remaining.appendSlice(allocator, text[cursor..open_pos]);

        // Find matching ']'
        const close_pos = std.mem.indexOfPos(u8, text, open_pos, "]") orelse {
            try remaining.appendSlice(allocator, text[open_pos..]);
            break;
        };

        const marker = text[open_pos + 1 .. close_pos];

        // Try to parse as KIND:target
        if (std.mem.indexOf(u8, marker, ":")) |colon_pos| {
            const kind_str = marker[0..colon_pos];
            const target_raw = marker[colon_pos + 1 ..];
            const target = std.mem.trim(u8, target_raw, " ");

            if (target.len > 0) {
                if (parseMarkerKind(kind_str)) |kind| {
                    try attachments.append(allocator, .{
                        .kind = kind,
                        .target = target,
                    });
                    cursor = close_pos + 1;
                    continue;
                }
            }
        }

        // Not a valid marker — keep original text including brackets
        try remaining.appendSlice(allocator, text[open_pos .. close_pos + 1]);
        cursor = close_pos + 1;
    }

    // Trim whitespace from remaining text
    const trimmed = std.mem.trim(u8, remaining.items, " \t\n\r");
    const remaining_owned = try allocator.dupe(u8, trimmed);
    remaining.deinit(allocator);

    return .{
        .attachments = try attachments.toOwnedSlice(allocator),
        .remaining_text = remaining_owned,
    };
}

fn parseMarkerKind(kind_str: []const u8) ?AttachmentKind {
    if (eqlLower(kind_str, "image") or eqlLower(kind_str, "photo")) return .image;
    if (eqlLower(kind_str, "document") or eqlLower(kind_str, "file")) return .document;
    if (eqlLower(kind_str, "video")) return .video;
    if (eqlLower(kind_str, "audio")) return .audio;
    if (eqlLower(kind_str, "voice")) return .voice;
    return null;
}

// ════════════════════════════════════════════════════════════════════════════
// Smart Message Splitting
// ════════════════════════════════════════════════════════════════════════════

/// Split a message into chunks respecting the max byte limit.
/// Prefers splitting at word boundaries (newline, then space) over mid-word.
pub fn smartSplitMessage(msg: []const u8, max_bytes: usize) SmartSplitIterator {
    return .{ .remaining = msg, .max = max_bytes };
}

pub const SmartSplitIterator = struct {
    remaining: []const u8,
    max: usize,

    pub fn next(self: *SmartSplitIterator) ?[]const u8 {
        if (self.remaining.len == 0) return null;
        if (self.remaining.len <= self.max) {
            const chunk = self.remaining;
            self.remaining = self.remaining[self.remaining.len..];
            return chunk;
        }

        const search_area = self.remaining[0..self.max];

        // Prefer splitting at newline in the second half
        const half = self.max / 2;
        var split_at: usize = self.max;

        // Search for last newline
        if (std.mem.lastIndexOf(u8, search_area, "\n")) |nl_pos| {
            if (nl_pos >= half) {
                split_at = nl_pos + 1;
            } else {
                // Newline too early; try space instead
                if (std.mem.lastIndexOf(u8, search_area, " ")) |sp_pos| {
                    split_at = sp_pos + 1;
                }
            }
        } else if (std.mem.lastIndexOf(u8, search_area, " ")) |sp_pos| {
            split_at = sp_pos + 1;
        }

        const chunk = self.remaining[0..split_at];
        self.remaining = self.remaining[split_at..];
        return chunk;
    }
};

/// Telegram channel — uses the Bot API with long-polling (getUpdates).
/// Splits messages at 4096 chars (Telegram limit).
pub const TelegramChannel = struct {
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    allowed_users: []const []const u8,
    last_update_id: i64,

    pub const MAX_MESSAGE_LEN: usize = 4096;

    pub fn init(allocator: std.mem.Allocator, bot_token: []const u8, allowed_users: []const []const u8) TelegramChannel {
        return .{
            .allocator = allocator,
            .bot_token = bot_token,
            .allowed_users = allowed_users,
            .last_update_id = 0,
        };
    }

    pub fn channelName(_: *TelegramChannel) []const u8 {
        return "telegram";
    }

    /// Build the Telegram API URL for a method.
    pub fn apiUrl(self: *const TelegramChannel, buf: []u8, method: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print("https://api.telegram.org/bot{s}/{s}", .{ self.bot_token, method });
        return fbs.getWritten();
    }

    /// Build a sendMessage JSON body.
    pub fn buildSendBody(
        buf: []u8,
        chat_id: []const u8,
        text: []const u8,
    ) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print("{{\"chat_id\":{s},\"text\":\"{s}\"}}", .{ chat_id, text });
        return fbs.getWritten();
    }

    pub fn isUserAllowed(self: *const TelegramChannel, sender: []const u8) bool {
        return root.isAllowedExact(self.allowed_users, sender);
    }

    pub fn healthCheck(_: *TelegramChannel) bool {
        // Would normally call getMe; just return true for now
        return true;
    }

    // ── Typing indicator ────────────────────────────────────────────

    /// Send a "typing" chat action. Best-effort: errors are ignored.
    pub fn sendTypingIndicator(self: *TelegramChannel, chat_id: []const u8) void {
        var url_buf: [512]u8 = undefined;
        const url = self.apiUrl(&url_buf, "sendChatAction") catch return;

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);

        body_list.appendSlice(self.allocator, "{\"chat_id\":") catch return;
        body_list.appendSlice(self.allocator, chat_id) catch return;
        body_list.appendSlice(self.allocator, ",\"action\":\"typing\"}") catch return;

        const resp = curlPost(self.allocator, url, body_list.items, null) catch return;
        self.allocator.free(resp);
    }

    // ── Markdown fallback ───────────────────────────────────────────

    /// Send text with Markdown parse_mode; on failure, retry as plain text.
    fn sendWithMarkdownFallback(self: *TelegramChannel, chat_id: []const u8, text: []const u8) !void {
        var url_buf: [512]u8 = undefined;
        const url = try self.apiUrl(&url_buf, "sendMessage");

        // Build Markdown body
        var md_body: std.ArrayListUnmanaged(u8) = .empty;
        defer md_body.deinit(self.allocator);

        try md_body.appendSlice(self.allocator, "{\"chat_id\":");
        try md_body.appendSlice(self.allocator, chat_id);
        try md_body.appendSlice(self.allocator, ",\"text\":\"");
        try appendJsonEscaped(&md_body, self.allocator, text);
        try md_body.appendSlice(self.allocator, "\",\"parse_mode\":\"Markdown\"}");

        const md_resp = curlPost(self.allocator, url, md_body.items, null) catch {
            // Network error — fall through to plain send
            try self.sendChunkPlain(chat_id, text);
            return;
        };

        // Check if response indicates error (contains "error_code")
        if (std.mem.indexOf(u8, md_resp, "\"error_code\"") != null) {
            // Markdown failed, retry as plain text
            try self.sendChunkPlain(chat_id, text);
            return;
        }
    }

    fn sendChunkPlain(self: *TelegramChannel, chat_id: []const u8, text: []const u8) !void {
        var url_buf: [512]u8 = undefined;
        const url = try self.apiUrl(&url_buf, "sendMessage");

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);

        try body_list.appendSlice(self.allocator, "{\"chat_id\":");
        try body_list.appendSlice(self.allocator, chat_id);
        try body_list.appendSlice(self.allocator, ",\"text\":\"");
        try appendJsonEscaped(&body_list, self.allocator, text);
        try body_list.appendSlice(self.allocator, "\"}");

        _ = try curlPost(self.allocator, url, body_list.items, null);
    }

    // ── Media sending ───────────────────────────────────────────────

    /// Send a photo via curl multipart form POST.
    pub fn sendPhoto(self: *TelegramChannel, chat_id: []const u8, allocator: std.mem.Allocator, photo_path: []const u8, caption: ?[]const u8) !void {
        try self.sendMediaMultipart(chat_id, allocator, .image, photo_path, caption);
    }

    /// Send a document via curl multipart form POST.
    pub fn sendDocument(self: *TelegramChannel, chat_id: []const u8, allocator: std.mem.Allocator, doc_path: []const u8, caption: ?[]const u8) !void {
        try self.sendMediaMultipart(chat_id, allocator, .document, doc_path, caption);
    }

    /// Send any media type via curl multipart form POST.
    fn sendMediaMultipart(
        self: *TelegramChannel,
        chat_id: []const u8,
        allocator: std.mem.Allocator,
        kind: AttachmentKind,
        file_path: []const u8,
        caption: ?[]const u8,
    ) !void {
        var url_buf: [512]u8 = undefined;
        const url = try self.apiUrl(&url_buf, kind.apiMethod());

        // Build file form field: field=@path
        var file_arg_buf: [1024]u8 = undefined;
        var file_fbs = std.io.fixedBufferStream(&file_arg_buf);
        try file_fbs.writer().print("{s}=@{s}", .{ kind.formField(), file_path });
        const file_arg = file_fbs.getWritten();

        // Build chat_id form field
        var chatid_arg_buf: [128]u8 = undefined;
        var chatid_fbs = std.io.fixedBufferStream(&chatid_arg_buf);
        try chatid_fbs.writer().print("chat_id={s}", .{chat_id});
        const chatid_arg = chatid_fbs.getWritten();

        // Build argv
        var argv_buf: [16][]const u8 = undefined;
        var argc: usize = 0;
        argv_buf[argc] = "curl";
        argc += 1;
        argv_buf[argc] = "-s";
        argc += 1;
        argv_buf[argc] = "-F";
        argc += 1;
        argv_buf[argc] = chatid_arg;
        argc += 1;
        argv_buf[argc] = "-F";
        argc += 1;
        argv_buf[argc] = file_arg;
        argc += 1;

        // Optional caption
        var caption_arg_buf: [1024]u8 = undefined;
        if (caption) |cap| {
            var cap_fbs = std.io.fixedBufferStream(&caption_arg_buf);
            try cap_fbs.writer().print("caption={s}", .{cap});
            argv_buf[argc] = "-F";
            argc += 1;
            argv_buf[argc] = cap_fbs.getWritten();
            argc += 1;
        }

        argv_buf[argc] = url;
        argc += 1;

        var child = std.process.Child.init(argv_buf[0..argc], allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        _ = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch return error.CurlReadError;
        const term = child.wait() catch return error.CurlWaitError;
        if (term != .Exited or term.Exited != 0) return error.CurlFailed;
    }

    // ── Channel vtable ──────────────────────────────────────────────

    /// Send a message to a Telegram chat via the Bot API.
    /// Parses attachment markers, sends typing indicator, uses smart splitting
    /// with Markdown fallback.
    pub fn sendMessage(self: *TelegramChannel, chat_id: []const u8, text: []const u8) !void {
        // Send typing indicator (best-effort)
        self.sendTypingIndicator(chat_id);

        // Parse attachment markers
        const parsed = try parseAttachmentMarkers(self.allocator, text);
        defer parsed.deinit(self.allocator);

        // Send remaining text (if any) with smart splitting
        if (parsed.remaining_text.len > 0) {
            var it = smartSplitMessage(parsed.remaining_text, MAX_MESSAGE_LEN);
            while (it.next()) |chunk| {
                try self.sendWithMarkdownFallback(chat_id, chunk);
            }
        }

        // Send attachments
        for (parsed.attachments) |att| {
            self.sendMediaMultipart(chat_id, self.allocator, att.kind, att.target, att.caption) catch {
                // Log failure but continue with other attachments
                continue;
            };
        }
    }

    fn sendChunk(self: *TelegramChannel, chat_id: []const u8, text: []const u8) !void {
        // Build URL
        var url_buf: [512]u8 = undefined;
        const url = try self.apiUrl(&url_buf, "sendMessage");

        // Build JSON body with escaped text
        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);

        try body_list.appendSlice(self.allocator, "{\"chat_id\":");
        try body_list.appendSlice(self.allocator, chat_id);
        try body_list.appendSlice(self.allocator, ",\"text\":\"");
        try appendJsonEscaped(&body_list, self.allocator, text);
        try body_list.appendSlice(self.allocator, "\"}");

        _ = try curlPost(self.allocator, url, body_list.items, null);
    }

    /// Poll for updates using long-polling (getUpdates) via curl.
    /// Returns a slice of ChannelMessages allocated on the given allocator.
    pub fn pollUpdates(self: *TelegramChannel, allocator: std.mem.Allocator) ![]root.ChannelMessage {
        var url_buf: [512]u8 = undefined;
        const url = try self.apiUrl(&url_buf, "getUpdates");

        // Build body with offset and timeout
        var body_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&body_buf);
        try fbs.writer().print("{{\"offset\":{d},\"timeout\":30,\"allowed_updates\":[\"message\"]}}", .{self.last_update_id});
        const body = fbs.getWritten();

        const resp_body = try curlPost(allocator, url, body, null);

        // Parse JSON response to extract messages
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp_body, .{}) catch return &.{};
        defer parsed.deinit();

        const result_array = (parsed.value.object.get("result") orelse return &.{}).array.items;

        var messages: std.ArrayListUnmanaged(root.ChannelMessage) = .empty;
        errdefer messages.deinit(allocator);

        for (result_array) |update| {
            // Advance offset
            if (update.object.get("update_id")) |uid| {
                if (uid == .integer) {
                    self.last_update_id = uid.integer + 1;
                }
            }

            const message = update.object.get("message") orelse continue;
            const text_val = (message.object.get("text")) orelse continue;
            const text_str = if (text_val == .string) text_val.string else continue;

            // Get sender info
            const from_obj = message.object.get("from") orelse continue;
            const username_val = from_obj.object.get("username");
            const username = if (username_val) |uv| (if (uv == .string) uv.string else "unknown") else "unknown";

            // Check allowlist
            if (!self.isUserAllowed(username)) continue;

            // Get chat_id
            const chat_obj = message.object.get("chat") orelse continue;
            const chat_id_val = chat_obj.object.get("id") orelse continue;
            var chat_id_buf: [32]u8 = undefined;
            const chat_id_str = blk: {
                if (chat_id_val == .integer) {
                    break :blk std.fmt.bufPrint(&chat_id_buf, "{d}", .{chat_id_val.integer}) catch continue;
                }
                continue;
            };

            try messages.append(allocator, .{
                .id = try allocator.dupe(u8, username),
                .sender = try allocator.dupe(u8, chat_id_str),
                .content = try allocator.dupe(u8, text_str),
                .channel = "telegram",
                .timestamp = root.nowEpochSecs(),
            });
        }

        return messages.toOwnedSlice(allocator);
    }

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *TelegramChannel = @ptrCast(@alignCast(ptr));
        // Verify bot token by calling getMe
        var url_buf: [512]u8 = undefined;
        const url = self.apiUrl(&url_buf, "getMe") catch return;

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        _ = client.fetch(.{
            .location = .{ .url = url },
        }) catch return;
        // If getMe fails, we still start — healthCheck will report issues
    }

    fn vtableStop(ptr: *anyopaque) void {
        _ = ptr;
        // Nothing to clean up for HTTP polling
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8) anyerror!void {
        const self: *TelegramChannel = @ptrCast(@alignCast(ptr));
        try self.sendMessage(target, message);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *TelegramChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *TelegramChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *TelegramChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════════════════

/// Append JSON-escaped text to an ArrayList.
fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
}

/// HTTP POST via curl subprocess (avoids Zig 0.15 std.http.Client segfaults).
fn curlPost(allocator: std.mem.Allocator, url: []const u8, body: []const u8, auth_header: ?[]const u8) ![]u8 {
    var argv_buf: [16][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-s";
    argc += 1;
    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = "POST";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Content-Type: application/json";
    argc += 1;

    if (auth_header) |hdr| {
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = hdr;
        argc += 1;
    }

    argv_buf[argc] = "-d";
    argc += 1;
    argv_buf[argc] = body;
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
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

test "telegram channel name" {
    var ch = TelegramChannel.init(std.testing.allocator, "123:ABC", &.{});
    try std.testing.expectEqualStrings("telegram", ch.channelName());
}

test "telegram api url" {
    const ch = TelegramChannel.init(std.testing.allocator, "123:ABC", &.{});
    var buf: [256]u8 = undefined;
    const url = try ch.apiUrl(&buf, "getUpdates");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABC/getUpdates", url);
}

test "telegram user allowed wildcard" {
    const users = [_][]const u8{"*"};
    const ch = TelegramChannel.init(std.testing.allocator, "tok", &users);
    try std.testing.expect(ch.isUserAllowed("anyone"));
}

test "telegram user allowed specific" {
    const users = [_][]const u8{ "alice", "bob" };
    const ch = TelegramChannel.init(std.testing.allocator, "tok", &users);
    try std.testing.expect(ch.isUserAllowed("alice"));
    try std.testing.expect(!ch.isUserAllowed("eve"));
}

test "telegram user denied empty" {
    const ch = TelegramChannel.init(std.testing.allocator, "tok", &.{});
    try std.testing.expect(!ch.isUserAllowed("anyone"));
}

test "telegram vtable interface" {
    var ch = TelegramChannel.init(std.testing.allocator, "tok", &.{});
    const iface = ch.channel();
    try std.testing.expectEqualStrings("telegram", iface.name());
}

test "telegram message splitting" {
    var it = root.splitMessage("hello world", TelegramChannel.MAX_MESSAGE_LEN);
    try std.testing.expectEqualStrings("hello world", it.next().?);
    try std.testing.expect(it.next() == null);
}

// ════════════════════════════════════════════════════════════════════════════
// Additional Telegram Tests (ported from ZeroClaw Rust)
// ════════════════════════════════════════════════════════════════════════════

test "telegram api url sendDocument" {
    const ch = TelegramChannel.init(std.testing.allocator, "123:ABC", &.{});
    var buf: [256]u8 = undefined;
    const url = try ch.apiUrl(&buf, "sendDocument");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABC/sendDocument", url);
}

test "telegram api url sendPhoto" {
    const ch = TelegramChannel.init(std.testing.allocator, "123:ABC", &.{});
    var buf: [256]u8 = undefined;
    const url = try ch.apiUrl(&buf, "sendPhoto");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABC/sendPhoto", url);
}

test "telegram api url sendVideo" {
    const ch = TelegramChannel.init(std.testing.allocator, "123:ABC", &.{});
    var buf: [256]u8 = undefined;
    const url = try ch.apiUrl(&buf, "sendVideo");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABC/sendVideo", url);
}

test "telegram api url sendAudio" {
    const ch = TelegramChannel.init(std.testing.allocator, "123:ABC", &.{});
    var buf: [256]u8 = undefined;
    const url = try ch.apiUrl(&buf, "sendAudio");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABC/sendAudio", url);
}

test "telegram api url sendVoice" {
    const ch = TelegramChannel.init(std.testing.allocator, "123:ABC", &.{});
    var buf: [256]u8 = undefined;
    const url = try ch.apiUrl(&buf, "sendVoice");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABC/sendVoice", url);
}

test "telegram user exact match not substring" {
    const users = [_][]const u8{"alice"};
    const ch = TelegramChannel.init(std.testing.allocator, "tok", &users);
    try std.testing.expect(!ch.isUserAllowed("alice_bot"));
    try std.testing.expect(!ch.isUserAllowed("alic"));
    try std.testing.expect(!ch.isUserAllowed("malice"));
}

test "telegram user empty string denied" {
    const users = [_][]const u8{"alice"};
    const ch = TelegramChannel.init(std.testing.allocator, "tok", &users);
    try std.testing.expect(!ch.isUserAllowed(""));
}

test "telegram user case sensitive" {
    const users = [_][]const u8{"Alice"};
    const ch = TelegramChannel.init(std.testing.allocator, "tok", &users);
    try std.testing.expect(ch.isUserAllowed("Alice"));
    try std.testing.expect(!ch.isUserAllowed("alice"));
    try std.testing.expect(!ch.isUserAllowed("ALICE"));
}

test "telegram wildcard with specific users" {
    const users = [_][]const u8{ "alice", "*" };
    const ch = TelegramChannel.init(std.testing.allocator, "tok", &users);
    try std.testing.expect(ch.isUserAllowed("alice"));
    try std.testing.expect(ch.isUserAllowed("bob"));
    try std.testing.expect(ch.isUserAllowed("anyone"));
}

test "telegram numeric id authorization" {
    const users = [_][]const u8{"123456789"};
    const ch = TelegramChannel.init(std.testing.allocator, "tok", &users);
    try std.testing.expect(ch.isUserAllowed("123456789"));
    try std.testing.expect(!ch.isUserAllowed("987654321"));
}

test "telegram max message len constant" {
    try std.testing.expectEqual(@as(usize, 4096), TelegramChannel.MAX_MESSAGE_LEN);
}

test "telegram split exact limit" {
    const msg = "a" ** 4096;
    var it = root.splitMessage(msg, TelegramChannel.MAX_MESSAGE_LEN);
    const chunk = it.next().?;
    try std.testing.expectEqual(@as(usize, 4096), chunk.len);
    try std.testing.expect(it.next() == null);
}

test "telegram split over limit" {
    const msg = "a" ** 4196;
    var it = root.splitMessage(msg, TelegramChannel.MAX_MESSAGE_LEN);
    const chunk1 = it.next().?;
    try std.testing.expectEqual(@as(usize, 4096), chunk1.len);
    const chunk2 = it.next().?;
    try std.testing.expectEqual(@as(usize, 100), chunk2.len);
    try std.testing.expect(it.next() == null);
}

test "telegram split empty message" {
    var it = root.splitMessage("", TelegramChannel.MAX_MESSAGE_LEN);
    try std.testing.expect(it.next() == null);
}

test "telegram split very long message all within limit" {
    const msg = "x" ** 12288; // 3 * 4096
    var it = root.splitMessage(msg, TelegramChannel.MAX_MESSAGE_LEN);
    var count: usize = 0;
    while (it.next()) |chunk| {
        try std.testing.expect(chunk.len <= TelegramChannel.MAX_MESSAGE_LEN);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "telegram build send body" {
    var buf: [512]u8 = undefined;
    const body = try TelegramChannel.buildSendBody(&buf, "12345", "Hello!");
    try std.testing.expectEqualStrings("{\"chat_id\":12345,\"text\":\"Hello!\"}", body);
}

test "telegram health check returns true" {
    var ch = TelegramChannel.init(std.testing.allocator, "tok", &.{});
    try std.testing.expect(ch.healthCheck());
}

test "telegram init stores fields" {
    const users = [_][]const u8{ "alice", "bob" };
    const ch = TelegramChannel.init(std.testing.allocator, "123:ABC-DEF", &users);
    try std.testing.expectEqualStrings("123:ABC-DEF", ch.bot_token);
    try std.testing.expectEqual(@as(i64, 0), ch.last_update_id);
    try std.testing.expectEqual(@as(usize, 2), ch.allowed_users.len);
}

// ════════════════════════════════════════════════════════════════════════════
// Attachment Marker Parsing Tests
// ════════════════════════════════════════════════════════════════════════════

test "telegram parseAttachmentMarkers extracts IMAGE marker" {
    const parsed = try parseAttachmentMarkers(std.testing.allocator, "Check this [IMAGE:/tmp/photo.png] out");
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.attachments.len);
    try std.testing.expectEqual(AttachmentKind.image, parsed.attachments[0].kind);
    try std.testing.expectEqualStrings("/tmp/photo.png", parsed.attachments[0].target);
    try std.testing.expectEqualStrings("Check this  out", parsed.remaining_text);
}

test "telegram parseAttachmentMarkers extracts multiple markers" {
    const parsed = try parseAttachmentMarkers(
        std.testing.allocator,
        "Here [IMAGE:/tmp/a.png] and [DOCUMENT:https://example.com/a.pdf]",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.attachments.len);
    try std.testing.expectEqual(AttachmentKind.image, parsed.attachments[0].kind);
    try std.testing.expectEqualStrings("/tmp/a.png", parsed.attachments[0].target);
    try std.testing.expectEqual(AttachmentKind.document, parsed.attachments[1].kind);
    try std.testing.expectEqualStrings("https://example.com/a.pdf", parsed.attachments[1].target);
}

test "telegram parseAttachmentMarkers returns remaining text without markers" {
    const parsed = try parseAttachmentMarkers(
        std.testing.allocator,
        "Before [VIDEO:/tmp/v.mp4] after",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Before  after", parsed.remaining_text);
    try std.testing.expectEqual(@as(usize, 1), parsed.attachments.len);
}

test "telegram parseAttachmentMarkers keeps invalid markers in text" {
    const parsed = try parseAttachmentMarkers(
        std.testing.allocator,
        "Report [UNKNOWN:/tmp/a.bin]",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Report [UNKNOWN:/tmp/a.bin]", parsed.remaining_text);
    try std.testing.expectEqual(@as(usize, 0), parsed.attachments.len);
}

test "telegram parseAttachmentMarkers no markers returns full text" {
    const parsed = try parseAttachmentMarkers(
        std.testing.allocator,
        "Hello, no attachments here!",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Hello, no attachments here!", parsed.remaining_text);
    try std.testing.expectEqual(@as(usize, 0), parsed.attachments.len);
}

test "telegram parseAttachmentMarkers AUDIO and VOICE" {
    const parsed = try parseAttachmentMarkers(
        std.testing.allocator,
        "[AUDIO:/tmp/song.mp3] [VOICE:/tmp/msg.ogg]",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.attachments.len);
    try std.testing.expectEqual(AttachmentKind.audio, parsed.attachments[0].kind);
    try std.testing.expectEqual(AttachmentKind.voice, parsed.attachments[1].kind);
}

test "telegram parseAttachmentMarkers case insensitive kind" {
    const parsed = try parseAttachmentMarkers(
        std.testing.allocator,
        "[image:/tmp/a.png] [Image:/tmp/b.png]",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.attachments.len);
    try std.testing.expectEqual(AttachmentKind.image, parsed.attachments[0].kind);
    try std.testing.expectEqual(AttachmentKind.image, parsed.attachments[1].kind);
}

test "telegram parseAttachmentMarkers empty text" {
    const parsed = try parseAttachmentMarkers(std.testing.allocator, "");
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), parsed.attachments.len);
    try std.testing.expectEqualStrings("", parsed.remaining_text);
}

test "telegram parseAttachmentMarkers PHOTO alias" {
    const parsed = try parseAttachmentMarkers(
        std.testing.allocator,
        "[PHOTO:/tmp/snap.jpg]",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.attachments.len);
    try std.testing.expectEqual(AttachmentKind.image, parsed.attachments[0].kind);
}

test "telegram parseAttachmentMarkers FILE alias" {
    const parsed = try parseAttachmentMarkers(
        std.testing.allocator,
        "[FILE:/tmp/report.pdf]",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.attachments.len);
    try std.testing.expectEqual(AttachmentKind.document, parsed.attachments[0].kind);
}

// ════════════════════════════════════════════════════════════════════════════
// inferAttachmentKindFromExtension Tests
// ════════════════════════════════════════════════════════════════════════════

test "telegram inferAttachmentKindFromExtension png is image" {
    try std.testing.expectEqual(AttachmentKind.image, inferAttachmentKindFromExtension("/tmp/photo.png"));
}

test "telegram inferAttachmentKindFromExtension jpg is image" {
    try std.testing.expectEqual(AttachmentKind.image, inferAttachmentKindFromExtension("/tmp/photo.jpg"));
}

test "telegram inferAttachmentKindFromExtension pdf is document" {
    try std.testing.expectEqual(AttachmentKind.document, inferAttachmentKindFromExtension("/tmp/report.pdf"));
}

test "telegram inferAttachmentKindFromExtension mp4 is video" {
    try std.testing.expectEqual(AttachmentKind.video, inferAttachmentKindFromExtension("/tmp/clip.mp4"));
}

test "telegram inferAttachmentKindFromExtension mp3 is audio" {
    try std.testing.expectEqual(AttachmentKind.audio, inferAttachmentKindFromExtension("/tmp/song.mp3"));
}

test "telegram inferAttachmentKindFromExtension ogg is voice" {
    try std.testing.expectEqual(AttachmentKind.voice, inferAttachmentKindFromExtension("/tmp/voice.ogg"));
}

test "telegram inferAttachmentKindFromExtension unknown is document" {
    try std.testing.expectEqual(AttachmentKind.document, inferAttachmentKindFromExtension("/tmp/file.xyz"));
}

test "telegram inferAttachmentKindFromExtension no extension is document" {
    try std.testing.expectEqual(AttachmentKind.document, inferAttachmentKindFromExtension("/tmp/noext"));
}

test "telegram inferAttachmentKindFromExtension strips query string" {
    try std.testing.expectEqual(AttachmentKind.document, inferAttachmentKindFromExtension("https://example.com/specs.pdf?download=1"));
}

test "telegram inferAttachmentKindFromExtension case insensitive" {
    try std.testing.expectEqual(AttachmentKind.image, inferAttachmentKindFromExtension("/tmp/photo.PNG"));
    try std.testing.expectEqual(AttachmentKind.image, inferAttachmentKindFromExtension("/tmp/photo.Jpg"));
}

// ════════════════════════════════════════════════════════════════════════════
// Smart Split Tests
// ════════════════════════════════════════════════════════════════════════════

test "telegram smartSplitMessage splits at word boundary not mid-word" {
    const msg = "Hello World! Goodbye Friend";
    var it = smartSplitMessage(msg, 20);
    const chunk1 = it.next().?;
    // Should split at a space, not in the middle of "Goodbye"
    try std.testing.expect(chunk1.len <= 20);
    try std.testing.expect(chunk1[chunk1.len - 1] == ' ' or chunk1.len == 20);

    const chunk2 = it.next().?;
    try std.testing.expect(chunk2.len > 0);
    try std.testing.expect(it.next() == null);

    // Verify all content preserved
    const total = chunk1.len + chunk2.len;
    try std.testing.expectEqual(msg.len, total);
}

test "telegram smartSplitMessage splits at newline if available" {
    const msg = "First line\nSecond line that is longer than needed";
    var it = smartSplitMessage(msg, 20);
    const chunk1 = it.next().?;
    // Should prefer newline at position 10 (which is >= half of 20)
    try std.testing.expectEqualStrings("First line\n", chunk1);
}

test "telegram smartSplitMessage short message no split" {
    var it = smartSplitMessage("short", 100);
    try std.testing.expectEqualStrings("short", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "telegram smartSplitMessage empty returns null" {
    var it = smartSplitMessage("", 100);
    try std.testing.expect(it.next() == null);
}

test "telegram smartSplitMessage no word boundary falls back to hard cut" {
    const msg = "abcdefghijklmnopqrstuvwxyz";
    var it = smartSplitMessage(msg, 10);
    const chunk1 = it.next().?;
    try std.testing.expectEqual(@as(usize, 10), chunk1.len);
}

test "telegram smartSplitMessage preserves total content" {
    const msg = "word " ** 100;
    var it = smartSplitMessage(msg, 50);
    var total: usize = 0;
    while (it.next()) |chunk| {
        try std.testing.expect(chunk.len <= 50);
        total += chunk.len;
    }
    try std.testing.expectEqual(msg.len, total);
}

// ════════════════════════════════════════════════════════════════════════════
// Typing Indicator Test
// ════════════════════════════════════════════════════════════════════════════

test "telegram sendTypingIndicator does not crash with invalid token" {
    var ch = TelegramChannel.init(std.testing.allocator, "invalid:token", &.{});
    ch.sendTypingIndicator("12345");
}

// ════════════════════════════════════════════════════════════════════════════
// Allowed Users Tests
// ════════════════════════════════════════════════════════════════════════════

test "telegram allowed_users empty denies all" {
    const ch = TelegramChannel.init(std.testing.allocator, "tok", &.{});
    try std.testing.expect(!ch.isUserAllowed("anyone"));
    try std.testing.expect(!ch.isUserAllowed("admin"));
}

test "telegram allowed_users non-empty filters correctly" {
    const users = [_][]const u8{ "alice", "bob" };
    const ch = TelegramChannel.init(std.testing.allocator, "tok", &users);
    try std.testing.expect(ch.isUserAllowed("alice"));
    try std.testing.expect(ch.isUserAllowed("bob"));
    try std.testing.expect(!ch.isUserAllowed("eve"));
    try std.testing.expect(!ch.isUserAllowed(""));
}

// ════════════════════════════════════════════════════════════════════════════
// AttachmentKind Method Tests
// ════════════════════════════════════════════════════════════════════════════

test "telegram AttachmentKind apiMethod returns correct methods" {
    try std.testing.expectEqualStrings("sendPhoto", AttachmentKind.image.apiMethod());
    try std.testing.expectEqualStrings("sendDocument", AttachmentKind.document.apiMethod());
    try std.testing.expectEqualStrings("sendVideo", AttachmentKind.video.apiMethod());
    try std.testing.expectEqualStrings("sendAudio", AttachmentKind.audio.apiMethod());
    try std.testing.expectEqualStrings("sendVoice", AttachmentKind.voice.apiMethod());
}

test "telegram AttachmentKind formField returns correct fields" {
    try std.testing.expectEqualStrings("photo", AttachmentKind.image.formField());
    try std.testing.expectEqualStrings("document", AttachmentKind.document.formField());
    try std.testing.expectEqualStrings("video", AttachmentKind.video.formField());
    try std.testing.expectEqualStrings("audio", AttachmentKind.audio.formField());
    try std.testing.expectEqualStrings("voice", AttachmentKind.voice.formField());
}
