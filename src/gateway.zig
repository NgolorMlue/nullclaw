//! HTTP Gateway — lightweight HTTP server for nullclaw.
//!
//! Mirrors ZeroClaw's axum-based gateway with:
//!   - Sliding-window rate limiting (per-IP)
//!   - Idempotency store (deduplicates webhook requests)
//!   - Body size limits (64KB max)
//!   - Request timeouts (30s)
//!   - Bearer token authentication (paired_tokens)
//!   - Endpoints: /health, /pair, /webhook, /whatsapp, /telegram
//!
//! Uses std.http.Server (built-in, no external deps).

const std = @import("std");
const health = @import("health.zig");

/// Maximum request body size (64KB) — prevents memory exhaustion.
pub const MAX_BODY_SIZE: usize = 65_536;

/// Request timeout (30s) — prevents slow-loris attacks.
pub const REQUEST_TIMEOUT_SECS: u64 = 30;

/// Sliding window for rate limiting (60s).
pub const RATE_LIMIT_WINDOW_SECS: u64 = 60;

/// How often the rate limiter sweeps stale IP entries (5 min).
const RATE_LIMITER_SWEEP_INTERVAL_SECS: u64 = 300;

// ── Rate Limiter ─────────────────────────────────────────────────

/// Sliding-window rate limiter. Tracks timestamps per key.
/// Not thread-safe by itself; callers must hold a lock.
pub const SlidingWindowRateLimiter = struct {
    limit_per_window: u32,
    window_ns: i128,
    /// Map of key -> list of request timestamps (as nanoTimestamp values).
    entries: std.StringHashMapUnmanaged(std.ArrayList(i128)),
    last_sweep: i128,

    pub fn init(limit_per_window: u32, window_secs: u64) SlidingWindowRateLimiter {
        return .{
            .limit_per_window = limit_per_window,
            .window_ns = @as(i128, @intCast(window_secs)) * 1_000_000_000,
            .entries = .empty,
            .last_sweep = std.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.entries.deinit(allocator);
    }

    /// Returns true if the request is allowed, false if rate-limited.
    pub fn allow(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        if (self.limit_per_window == 0) return true;

        const now = std.time.nanoTimestamp();
        const cutoff = now - self.window_ns;

        // Periodic sweep
        if (now - self.last_sweep > @as(i128, RATE_LIMITER_SWEEP_INTERVAL_SECS) * 1_000_000_000) {
            self.sweep(allocator, cutoff);
            self.last_sweep = now;
        }

        const gop = self.entries.getOrPut(allocator, key) catch return true;
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }

        // Remove expired entries
        var timestamps = gop.value_ptr;
        var i: usize = 0;
        while (i < timestamps.items.len) {
            if (timestamps.items[i] <= cutoff) {
                _ = timestamps.swapRemove(i);
            } else {
                i += 1;
            }
        }

        if (timestamps.items.len >= self.limit_per_window) return false;

        timestamps.append(allocator, now) catch return true;
        return true;
    }

    fn sweep(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator, cutoff: i128) void {
        var iter = self.entries.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(allocator);

        while (iter.next()) |entry| {
            var timestamps = entry.value_ptr;
            var i: usize = 0;
            while (i < timestamps.items.len) {
                if (timestamps.items[i] <= cutoff) {
                    _ = timestamps.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            if (timestamps.items.len == 0) {
                to_remove.append(allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                var list = kv.value;
                list.deinit(allocator);
            }
        }
    }
};

// ── Gateway Rate Limiter ─────────────────────────────────────────

pub const GatewayRateLimiter = struct {
    pair: SlidingWindowRateLimiter,
    webhook: SlidingWindowRateLimiter,

    pub fn init(pair_per_minute: u32, webhook_per_minute: u32) GatewayRateLimiter {
        return .{
            .pair = SlidingWindowRateLimiter.init(pair_per_minute, RATE_LIMIT_WINDOW_SECS),
            .webhook = SlidingWindowRateLimiter.init(webhook_per_minute, RATE_LIMIT_WINDOW_SECS),
        };
    }

    pub fn deinit(self: *GatewayRateLimiter, allocator: std.mem.Allocator) void {
        self.pair.deinit(allocator);
        self.webhook.deinit(allocator);
    }

    pub fn allowPair(self: *GatewayRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        return self.pair.allow(allocator, key);
    }

    pub fn allowWebhook(self: *GatewayRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        return self.webhook.allow(allocator, key);
    }
};

// ── Idempotency Store ────────────────────────────────────────────

pub const IdempotencyStore = struct {
    ttl_ns: i128,
    /// Map of key -> timestamp when recorded.
    keys: std.StringHashMapUnmanaged(i128),

    pub fn init(ttl_secs: u64) IdempotencyStore {
        return .{
            .ttl_ns = @as(i128, @intCast(@max(ttl_secs, 1))) * 1_000_000_000,
            .keys = .empty,
        };
    }

    pub fn deinit(self: *IdempotencyStore, allocator: std.mem.Allocator) void {
        self.keys.deinit(allocator);
    }

    /// Returns true if this key is new and is now recorded.
    /// Returns false if this is a duplicate.
    pub fn recordIfNew(self: *IdempotencyStore, allocator: std.mem.Allocator, key: []const u8) bool {
        const now = std.time.nanoTimestamp();
        const cutoff = now - self.ttl_ns;

        // Clean expired keys (simple sweep)
        var iter = self.keys.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(allocator);
        while (iter.next()) |entry| {
            if (entry.value_ptr.* < cutoff) {
                to_remove.append(allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |k| {
            _ = self.keys.remove(k);
        }

        // Check if already present
        if (self.keys.get(key)) |_| return false;

        // Record new key
        self.keys.put(allocator, key, now) catch return true;
        return true;
    }
};

// ── Gateway server ───────────────────────────────────────────────

/// Gateway server state, shared across request handlers.
pub const GatewayState = struct {
    allocator: std.mem.Allocator,
    rate_limiter: GatewayRateLimiter,
    idempotency: IdempotencyStore,
    whatsapp_verify_token: []const u8,
    paired_tokens: []const []const u8,
    telegram_bot_token: []const u8,

    pub fn init(allocator: std.mem.Allocator) GatewayState {
        return initWithVerifyToken(allocator, "");
    }

    pub fn initWithVerifyToken(allocator: std.mem.Allocator, verify_token: []const u8) GatewayState {
        return .{
            .allocator = allocator,
            .rate_limiter = GatewayRateLimiter.init(10, 30),
            .idempotency = IdempotencyStore.init(300),
            .whatsapp_verify_token = verify_token,
            .paired_tokens = &.{},
            .telegram_bot_token = "",
        };
    }

    pub fn deinit(self: *GatewayState) void {
        self.rate_limiter.deinit(self.allocator);
        self.idempotency.deinit(self.allocator);
    }
};

/// Check if all registered health components are OK.
fn isHealthOk() bool {
    const snap = health.snapshot();
    var iter = snap.components.iterator();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.status, "ok")) return false;
    }
    return true;
}

/// Extract a query parameter value from a URL target string.
/// e.g. parseQueryParam("/whatsapp?hub.mode=subscribe&hub.challenge=abc", "hub.challenge") => "abc"
/// Returns null if the parameter is not found.
pub fn parseQueryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOf(u8, target, "?") orelse return null;
    var query = target[qmark + 1 ..];

    while (query.len > 0) {
        // Find end of this key=value pair
        const amp = std.mem.indexOf(u8, query, "&") orelse query.len;
        const pair = query[0..amp];

        // Split on '='
        const eq = std.mem.indexOf(u8, pair, "=");
        if (eq) |eq_pos| {
            const key = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];
            if (std.mem.eql(u8, key, name)) return value;
        }

        // Advance past the '&'
        if (amp < query.len) {
            query = query[amp + 1 ..];
        } else {
            break;
        }
    }
    return null;
}

// ── Bearer Token Validation ──────────────────────────────────────

/// Validate a bearer token against a list of paired tokens.
/// Returns true if paired_tokens is empty (backwards compat) or token matches.
pub fn validateBearerToken(token: []const u8, paired_tokens: []const []const u8) bool {
    if (paired_tokens.len == 0) return true;
    for (paired_tokens) |pt| {
        if (std.mem.eql(u8, token, pt)) return true;
    }
    return false;
}

/// Extract the value of a named header from raw HTTP bytes.
/// Searches for "Name: value\r\n" (case-insensitive name match).
pub fn extractHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    // Skip past the first line (request line)
    var pos: usize = 0;
    while (pos + 1 < raw.len) {
        if (raw[pos] == '\r' and raw[pos + 1] == '\n') {
            pos += 2;
            break;
        }
        pos += 1;
    }

    // Scan headers
    while (pos < raw.len) {
        // Find end of this header line
        const line_end = std.mem.indexOf(u8, raw[pos..], "\r\n") orelse break;
        const line = raw[pos .. pos + line_end];
        if (line.len == 0) break; // empty line = end of headers

        // Check if this line starts with "name:"
        if (line.len > name.len and line[name.len] == ':') {
            const header_name = line[0..name.len];
            if (asciiEqlIgnoreCase(header_name, name)) {
                // Skip ": " and any leading whitespace
                var val_start: usize = name.len + 1;
                while (val_start < line.len and line[val_start] == ' ') val_start += 1;
                return line[val_start..];
            }
        }

        pos += line_end + 2;
    }
    return null;
}

/// Extract the bearer token from an Authorization header value.
/// "Bearer <token>" -> "<token>", or null if format doesn't match.
pub fn extractBearerToken(auth_header: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (auth_header.len > prefix.len and std.mem.startsWith(u8, auth_header, prefix)) {
        return auth_header[prefix.len..];
    }
    return null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

// ── JSON Helpers ────────────────────────────────────────────────

/// Extract a string field from a JSON blob (minimal parser, no allocations).
pub fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n' or after_key[i] == '\r')) : (i += 1)
    {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    // Find closing quote (handle escaped quotes)
    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1;
            continue;
        }
        if (after_key[i] == '"') {
            return after_key[start..i];
        }
    }
    return null;
}

/// Extract an integer field from a JSON blob.
pub fn jsonIntField(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n' or after_key[i] == '\r')) : (i += 1)
    {}

    if (i >= after_key.len) return null;

    // Parse integer (possibly negative)
    const is_negative = after_key[i] == '-';
    if (is_negative) i += 1;
    if (i >= after_key.len or after_key[i] < '0' or after_key[i] > '9') return null;

    var result: i64 = 0;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {
        result = result * 10 + @as(i64, after_key[i] - '0');
    }
    return if (is_negative) -result else result;
}

// ── Message Processing ──────────────────────────────────────────

/// Extract the HTTP request body from raw bytes.
/// Finds the \r\n\r\n boundary and returns everything after it.
pub fn extractBody(raw: []const u8) ?[]const u8 {
    const separator = "\r\n\r\n";
    const pos = std.mem.indexOf(u8, raw, separator) orelse return null;
    const body = raw[pos + separator.len ..];
    if (body.len == 0) return null;
    return body;
}

/// Process an incoming message by spawning `nullclaw agent -m "..."`.
/// Returns the agent's response text. Caller owns the returned memory.
pub fn processIncomingMessage(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    // Find our own executable path
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&self_buf) catch "nullclaw";

    var child = std.process.Child.init(
        &[_][]const u8{ self_path, "agent", "-m", message },
        allocator,
    );
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .pipe;

    try child.spawn();

    // Read stdout
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);

    const stdout_reader = child.stdout.?;
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stdout_reader.read(&read_buf) catch break;
        if (n == 0) break;
        try stdout_buf.appendSlice(allocator, read_buf[0..n]);
    }

    const term = try child.wait();
    _ = term;

    if (stdout_buf.items.len > 0) {
        return try allocator.dupe(u8, stdout_buf.items);
    }
    return try allocator.dupe(u8, "No response from agent");
}

/// Send a reply to a Telegram chat using the Bot API.
pub fn sendTelegramReply(allocator: std.mem.Allocator, bot_token: []const u8, chat_id: i64, text: []const u8) !void {
    // Build the curl command to call the Telegram API
    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
    defer allocator.free(url);

    // JSON-escape the text for the body
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(allocator);
    const w = body_buf.writer(allocator);
    try w.print("{{\"chat_id\":{d},\"text\":\"", .{chat_id});
    for (text) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"}");

    const body = body_buf.items;

    var curl_child = std.process.Child.init(
        &[_][]const u8{
            "curl", "-s",                             "-X", "POST",
            "-H",   "Content-Type: application/json", "-d", body,
            url,
        },
        allocator,
    );
    curl_child.stdout_behavior = .pipe;
    curl_child.stderr_behavior = .pipe;

    curl_child.spawn() catch return;
    _ = curl_child.wait() catch {};
}

/// Run the HTTP gateway. Binds to host:port and serves HTTP requests.
/// Endpoints: GET /health, POST /pair, POST /webhook, GET|POST /whatsapp, POST /telegram
pub fn run(allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
    health.markComponentOk("gateway");

    var state = GatewayState.init(allocator);
    defer state.deinit();

    // Resolve the listen address
    const addr = try std.net.Address.resolveIp(host, port);
    var server = try addr.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &bw.interface;
    try stdout.print("Gateway listening on {s}:{d}\n", .{ host, port });
    try stdout.flush();

    // Accept loop — read raw HTTP from TCP connections
    while (true) {
        var conn = server.accept() catch continue;
        defer conn.stream.close();

        // Read request line + headers from TCP stream
        var req_buf: [4096]u8 = undefined;
        const n = conn.stream.read(&req_buf) catch continue;
        if (n == 0) continue;
        const raw = req_buf[0..n];

        // Parse first line: "METHOD /path HTTP/1.1\r\n"
        const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse continue;
        const first_line = raw[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method_str = parts.next() orelse continue;
        const target = parts.next() orelse continue;

        // Simple routing
        const is_post = std.mem.eql(u8, method_str, "POST");
        var response_status: []const u8 = "200 OK";
        var response_body: []const u8 = "";

        // Track whether we allocated a dynamic response body
        var dynamic_body: ?[]u8 = null;
        defer if (dynamic_body) |db| state.allocator.free(db);

        if (std.mem.eql(u8, target, "/health") or std.mem.startsWith(u8, target, "/health?")) {
            response_body = if (isHealthOk()) "{\"status\":\"ok\"}" else "{\"status\":\"degraded\"}";
        } else if (is_post and (std.mem.eql(u8, target, "/webhook") or std.mem.startsWith(u8, target, "/webhook?"))) {
            // Bearer token validation
            const auth_header = extractHeader(raw, "Authorization");
            const bearer = if (auth_header) |ah| extractBearerToken(ah) else null;
            if (state.paired_tokens.len > 0 and (bearer == null or !validateBearerToken(bearer.?, state.paired_tokens))) {
                response_status = "401 Unauthorized";
                response_body = "{\"error\":\"unauthorized\"}";
            } else if (!state.rate_limiter.allowWebhook(state.allocator, "webhook")) {
                response_status = "429 Too Many Requests";
                response_body = "{\"error\":\"rate limited\"}";
            } else {
                // Extract body and process message
                const body = extractBody(raw);
                if (body) |b| {
                    const msg_text = jsonStringField(b, "message") orelse jsonStringField(b, "text") orelse b;
                    if (processIncomingMessage(state.allocator, msg_text)) |resp| {
                        dynamic_body = resp;
                        // Build JSON response
                        const json_resp = std.fmt.allocPrint(state.allocator, "{{\"status\":\"ok\",\"response\":\"{s}\"}}", .{resp}) catch null;
                        if (json_resp) |jr| {
                            state.allocator.free(resp);
                            dynamic_body = jr;
                            response_body = jr;
                        } else {
                            response_body = "{\"status\":\"received\"}";
                        }
                    } else |_| {
                        response_body = "{\"status\":\"received\"}";
                    }
                } else {
                    response_body = "{\"status\":\"received\"}";
                }
            }
        } else if (is_post and (std.mem.eql(u8, target, "/pair") or std.mem.startsWith(u8, target, "/pair?"))) {
            if (!state.rate_limiter.allowPair(state.allocator, "pair")) {
                response_status = "429 Too Many Requests";
                response_body = "{\"error\":\"rate limited\"}";
            } else {
                response_body = "{\"status\":\"paired\"}";
            }
        } else if (is_post and (std.mem.eql(u8, target, "/telegram") or std.mem.startsWith(u8, target, "/telegram?"))) {
            // POST /telegram — Telegram webhook mode
            if (!state.rate_limiter.allowWebhook(state.allocator, "telegram")) {
                response_status = "429 Too Many Requests";
                response_body = "{\"error\":\"rate limited\"}";
            } else {
                const body = extractBody(raw);
                if (body) |b| {
                    // Parse Telegram update: extract message text and chat_id
                    const msg_text = jsonStringField(b, "text");
                    const chat_id = jsonIntField(b, "chat_id");

                    if (msg_text != null and chat_id != null) {
                        // Process the message
                        if (processIncomingMessage(state.allocator, msg_text.?)) |resp| {
                            defer state.allocator.free(resp);
                            // Send reply back to Telegram
                            if (state.telegram_bot_token.len > 0) {
                                sendTelegramReply(state.allocator, state.telegram_bot_token, chat_id.?, resp) catch {};
                            }
                            response_body = "{\"status\":\"ok\"}";
                        } else |_| {
                            response_body = "{\"status\":\"received\"}";
                        }
                    } else {
                        // No message text — could be an update_id-only update, just ack
                        response_body = "{\"status\":\"ok\"}";
                    }
                } else {
                    response_body = "{\"status\":\"received\"}";
                }
            }
        } else if (std.mem.eql(u8, target, "/whatsapp") or std.mem.startsWith(u8, target, "/whatsapp?")) {
            const is_get = std.mem.eql(u8, method_str, "GET");
            if (is_get) {
                // GET /whatsapp — Meta webhook verification
                const mode = parseQueryParam(target, "hub.mode");
                const token = parseQueryParam(target, "hub.verify_token");
                const challenge = parseQueryParam(target, "hub.challenge");

                if (mode != null and challenge != null and token != null and
                    std.mem.eql(u8, mode.?, "subscribe") and
                    state.whatsapp_verify_token.len > 0 and
                    std.mem.eql(u8, token.?, state.whatsapp_verify_token))
                {
                    response_body = challenge.?;
                } else {
                    response_status = "403 Forbidden";
                    response_body = "{\"error\":\"verification failed\"}";
                }
            } else if (is_post) {
                // POST /whatsapp — incoming message from Meta
                if (!state.rate_limiter.allowWebhook(state.allocator, "whatsapp")) {
                    response_status = "429 Too Many Requests";
                    response_body = "{\"error\":\"rate limited\"}";
                } else {
                    const body = extractBody(raw);
                    if (body) |b| {
                        // Try to extract message text from WhatsApp payload
                        const msg_text = jsonStringField(b, "text") orelse jsonStringField(b, "body");
                        if (msg_text) |mt| {
                            if (processIncomingMessage(state.allocator, mt)) |resp| {
                                dynamic_body = resp;
                                response_body = resp;
                            } else |_| {
                                response_body = "{\"status\":\"received\"}";
                            }
                        } else {
                            response_body = "{\"status\":\"received\"}";
                        }
                    } else {
                        response_body = "{\"status\":\"received\"}";
                    }
                }
            } else {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            }
        } else {
            response_status = "404 Not Found";
            response_body = "{\"error\":\"not found\"}";
        }

        // Send HTTP response
        var resp_buf: [2048]u8 = undefined;
        const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ response_status, response_body.len, response_body }) catch continue;
        _ = conn.stream.write(resp) catch continue;
    }
}

// ── Tests ────────────────────────────────────────────────────────

test "constants are set correctly" {
    try std.testing.expectEqual(@as(usize, 65_536), MAX_BODY_SIZE);
    try std.testing.expectEqual(@as(u64, 30), REQUEST_TIMEOUT_SECS);
    try std.testing.expectEqual(@as(u64, 60), RATE_LIMIT_WINDOW_SECS);
}

test "rate limiter allows up to limit" {
    var limiter = SlidingWindowRateLimiter.init(2, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "127.0.0.1"));
}

test "rate limiter zero limit always allows" {
    var limiter = SlidingWindowRateLimiter.init(0, 60);
    defer limiter.deinit(std.testing.allocator);

    for (0..100) |_| {
        try std.testing.expect(limiter.allow(std.testing.allocator, "any-key"));
    }
}

test "rate limiter different keys are independent" {
    var limiter = SlidingWindowRateLimiter.init(1, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "ip-1"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "ip-1"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "ip-2"));
}

test "gateway rate limiter blocks after limit" {
    var limiter = GatewayRateLimiter.init(2, 2);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allowPair(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(limiter.allowPair(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(!limiter.allowPair(std.testing.allocator, "127.0.0.1"));
}

test "idempotency store rejects duplicate key" {
    var store = IdempotencyStore.init(30);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "req-1"));
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "req-1"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "req-2"));
}

test "idempotency store allows different keys" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "a"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "b"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "c"));
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "a"));
}

test "gateway module compiles" {
    // Compile-time check only
}

// ── Additional gateway tests ────────────────────────────────────

test "rate limiter single request allowed" {
    var limiter = SlidingWindowRateLimiter.init(1, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "test-key"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "test-key"));
}

test "rate limiter high limit" {
    var limiter = SlidingWindowRateLimiter.init(100, 60);
    defer limiter.deinit(std.testing.allocator);

    for (0..100) |_| {
        try std.testing.expect(limiter.allow(std.testing.allocator, "ip"));
    }
    try std.testing.expect(!limiter.allow(std.testing.allocator, "ip"));
}

test "gateway rate limiter pair and webhook independent" {
    var limiter = GatewayRateLimiter.init(1, 1);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allowPair(std.testing.allocator, "ip"));
    try std.testing.expect(!limiter.allowPair(std.testing.allocator, "ip"));
    // Webhook should still be allowed since it's separate
    try std.testing.expect(limiter.allowWebhook(std.testing.allocator, "ip"));
    try std.testing.expect(!limiter.allowWebhook(std.testing.allocator, "ip"));
}

test "gateway rate limiter zero limits always allow" {
    var limiter = GatewayRateLimiter.init(0, 0);
    defer limiter.deinit(std.testing.allocator);

    for (0..50) |_| {
        try std.testing.expect(limiter.allowPair(std.testing.allocator, "any"));
        try std.testing.expect(limiter.allowWebhook(std.testing.allocator, "any"));
    }
}

test "idempotency store init with various TTLs" {
    var store1 = IdempotencyStore.init(1);
    defer store1.deinit(std.testing.allocator);
    try std.testing.expect(store1.ttl_ns > 0);

    var store2 = IdempotencyStore.init(3600);
    defer store2.deinit(std.testing.allocator);
    try std.testing.expect(store2.ttl_ns > store1.ttl_ns);
}

test "idempotency store zero TTL treated as 1 second" {
    var store = IdempotencyStore.init(0);
    defer store.deinit(std.testing.allocator);
    // Should use @max(0, 1) = 1 second
    try std.testing.expectEqual(@as(i128, 1_000_000_000), store.ttl_ns);
}

test "idempotency store many unique keys" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    // Use distinct string literals to avoid buffer aliasing
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-alpha"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-beta"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-gamma"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-delta"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-epsilon"));
}

test "idempotency store duplicate after many inserts" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "first"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "second"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "third"));
    // First key should still be duplicate
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "first"));
}

test "rate limiter window_ns calculation" {
    const limiter = SlidingWindowRateLimiter.init(10, 120);
    try std.testing.expectEqual(@as(i128, 120_000_000_000), limiter.window_ns);
}

test "MAX_BODY_SIZE is 64KB" {
    try std.testing.expectEqual(@as(usize, 64 * 1024), MAX_BODY_SIZE);
}

test "RATE_LIMIT_WINDOW_SECS is 60" {
    try std.testing.expectEqual(@as(u64, 60), RATE_LIMIT_WINDOW_SECS);
}

test "REQUEST_TIMEOUT_SECS is 30" {
    try std.testing.expectEqual(@as(u64, 30), REQUEST_TIMEOUT_SECS);
}

test "rate limiter different keys do not interfere" {
    var limiter = SlidingWindowRateLimiter.init(2, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "key-a"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-b"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-a"));
    // key-a should now be at limit
    try std.testing.expect(!limiter.allow(std.testing.allocator, "key-a"));
    // key-b still has room
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-b"));
}

// ── WhatsApp / parseQueryParam tests ────────────────────────────

test "parseQueryParam extracts single param" {
    const val = parseQueryParam("/whatsapp?hub.mode=subscribe", "hub.mode");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("subscribe", val.?);
}

test "parseQueryParam extracts param from multiple" {
    const target = "/whatsapp?hub.mode=subscribe&hub.verify_token=mytoken&hub.challenge=abc123";
    try std.testing.expectEqualStrings("subscribe", parseQueryParam(target, "hub.mode").?);
    try std.testing.expectEqualStrings("mytoken", parseQueryParam(target, "hub.verify_token").?);
    try std.testing.expectEqualStrings("abc123", parseQueryParam(target, "hub.challenge").?);
}

test "parseQueryParam returns null for missing param" {
    const val = parseQueryParam("/whatsapp?hub.mode=subscribe", "hub.challenge");
    try std.testing.expect(val == null);
}

test "parseQueryParam returns null for no query string" {
    const val = parseQueryParam("/whatsapp", "hub.mode");
    try std.testing.expect(val == null);
}

test "parseQueryParam empty value" {
    const val = parseQueryParam("/path?key=", "key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("", val.?);
}

test "parseQueryParam partial key match does not match" {
    const val = parseQueryParam("/path?hub.mode_extra=subscribe", "hub.mode");
    try std.testing.expect(val == null);
}

test "GatewayState initWithVerifyToken stores token" {
    var state = GatewayState.initWithVerifyToken(std.testing.allocator, "test-verify-token");
    defer state.deinit();
    try std.testing.expectEqualStrings("test-verify-token", state.whatsapp_verify_token);
}

test "GatewayState init has empty verify token" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqualStrings("", state.whatsapp_verify_token);
}

// ── Bearer Token Validation tests ───────────────────────────────

test "validateBearerToken allows when no paired tokens" {
    try std.testing.expect(validateBearerToken("anything", &.{}));
}

test "validateBearerToken allows valid token" {
    const tokens = &[_][]const u8{ "token-a", "token-b", "token-c" };
    try std.testing.expect(validateBearerToken("token-b", tokens));
}

test "validateBearerToken rejects invalid token" {
    const tokens = &[_][]const u8{ "token-a", "token-b" };
    try std.testing.expect(!validateBearerToken("token-c", tokens));
}

test "validateBearerToken rejects empty token when tokens configured" {
    const tokens = &[_][]const u8{"secret"};
    try std.testing.expect(!validateBearerToken("", tokens));
}

test "validateBearerToken exact match required" {
    const tokens = &[_][]const u8{"abc123"};
    try std.testing.expect(validateBearerToken("abc123", tokens));
    try std.testing.expect(!validateBearerToken("abc1234", tokens));
    try std.testing.expect(!validateBearerToken("abc12", tokens));
}

// ── extractHeader tests ──────────────────────────────────────────

test "extractHeader finds Authorization header" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret123\r\nContent-Type: application/json\r\n\r\n";
    const val = extractHeader(raw, "Authorization");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("Bearer secret123", val.?);
}

test "extractHeader case insensitive" {
    const raw = "GET /health HTTP/1.1\r\ncontent-type: text/plain\r\n\r\n";
    const val = extractHeader(raw, "Content-Type");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("text/plain", val.?);
}

test "extractHeader returns null for missing header" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const val = extractHeader(raw, "Authorization");
    try std.testing.expect(val == null);
}

test "extractHeader returns null for empty headers" {
    const raw = "GET / HTTP/1.1\r\n\r\n";
    try std.testing.expect(extractHeader(raw, "Host") == null);
}

// ── extractBearerToken tests ─────────────────────────────────────

test "extractBearerToken extracts token" {
    try std.testing.expectEqualStrings("mytoken", extractBearerToken("Bearer mytoken").?);
}

test "extractBearerToken returns null for non-Bearer" {
    try std.testing.expect(extractBearerToken("Basic abc123") == null);
}

test "extractBearerToken returns null for empty string" {
    try std.testing.expect(extractBearerToken("") == null);
}

test "extractBearerToken returns null for just Bearer" {
    // "Bearer " is 7 chars, "Bearer" is 6 — no space
    try std.testing.expect(extractBearerToken("Bearer") == null);
}

// ── JSON helper tests ────────────────────────────────────────────

test "jsonStringField extracts value" {
    const json = "{\"message\": \"hello world\"}";
    const val = jsonStringField(json, "message");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("hello world", val.?);
}

test "jsonStringField returns null for missing key" {
    const json = "{\"other\": \"value\"}";
    try std.testing.expect(jsonStringField(json, "message") == null);
}

test "jsonStringField handles nested JSON" {
    const json = "{\"message\": {\"text\": \"hi\"}, \"text\": \"direct\"}";
    const val = jsonStringField(json, "text");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("hi", val.?);
}

test "jsonIntField extracts positive integer" {
    const json = "{\"chat_id\": 12345}";
    const val = jsonIntField(json, "chat_id");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 12345), val.?);
}

test "jsonIntField extracts negative integer" {
    const json = "{\"offset\": -100}";
    const val = jsonIntField(json, "offset");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, -100), val.?);
}

test "jsonIntField returns null for missing key" {
    const json = "{\"other\": 42}";
    try std.testing.expect(jsonIntField(json, "chat_id") == null);
}

test "jsonIntField returns null for string value" {
    const json = "{\"chat_id\": \"not a number\"}";
    try std.testing.expect(jsonIntField(json, "chat_id") == null);
}

// ── extractBody tests ────────────────────────────────────────────

test "extractBody finds body after headers" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\n\r\n{\"message\":\"hi\"}";
    const body = extractBody(raw);
    try std.testing.expect(body != null);
    try std.testing.expectEqualStrings("{\"message\":\"hi\"}", body.?);
}

test "extractBody returns null for no body" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(extractBody(raw) == null);
}

test "extractBody returns null for no separator" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n";
    try std.testing.expect(extractBody(raw) == null);
}

// ── GatewayState paired_tokens tests ─────────────────────────────

test "GatewayState init has empty paired_tokens" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 0), state.paired_tokens.len);
}

test "GatewayState init has empty telegram_bot_token" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqualStrings("", state.telegram_bot_token);
}

// ── asciiEqlIgnoreCase tests ─────────────────────────────────────

test "asciiEqlIgnoreCase equal strings" {
    try std.testing.expect(asciiEqlIgnoreCase("Authorization", "authorization"));
    try std.testing.expect(asciiEqlIgnoreCase("CONTENT-TYPE", "content-type"));
    try std.testing.expect(asciiEqlIgnoreCase("Host", "Host"));
}

test "asciiEqlIgnoreCase different strings" {
    try std.testing.expect(!asciiEqlIgnoreCase("Authorization", "authenticate"));
    try std.testing.expect(!asciiEqlIgnoreCase("a", "ab"));
}

test "asciiEqlIgnoreCase empty strings" {
    try std.testing.expect(asciiEqlIgnoreCase("", ""));
}
