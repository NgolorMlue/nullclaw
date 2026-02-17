const std = @import("std");
const Tool = @import("root.zig").Tool;
const ToolResult = @import("root.zig").ToolResult;
const parseStringField = @import("shell.zig").parseStringField;

/// HTTP request tool for API interactions.
/// Supports GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS methods with
/// domain allowlisting, SSRF protection, and header redaction.
pub const HttpRequestTool = struct {
    allowed_domains: []const []const u8 = &.{}, // empty = allow all

    const vtable = Tool.VTable{
        .execute = &vtableExecute,
        .name = &vtableName,
        .description = &vtableDesc,
        .parameters_json = &vtableParams,
    };

    pub fn tool(self: *HttpRequestTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableExecute(ptr: *anyopaque, allocator: std.mem.Allocator, args_json: []const u8) anyerror!ToolResult {
        const self: *HttpRequestTool = @ptrCast(@alignCast(ptr));
        return self.execute(allocator, args_json);
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "http_request";
    }

    fn vtableDesc(_: *anyopaque) []const u8 {
        return "Make HTTP requests to external APIs. Supports GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS methods. " ++
            "Security: allowlist-only domains, no local/private hosts, SSRF protection.";
    }

    fn vtableParams(_: *anyopaque) []const u8 {
        return 
        \\{"type":"object","properties":{"url":{"type":"string","description":"HTTP or HTTPS URL to request"},"method":{"type":"string","description":"HTTP method (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS)","default":"GET"},"headers":{"type":"object","description":"Optional HTTP headers as key-value pairs"},"body":{"type":"string","description":"Optional request body"}},"required":["url"]}
        ;
    }

    fn execute(self: *HttpRequestTool, allocator: std.mem.Allocator, args_json: []const u8) !ToolResult {
        const url = parseStringField(args_json, "url") orelse
            return ToolResult.fail("Missing 'url' parameter");

        const method_str = parseStringField(args_json, "method") orelse "GET";

        // Validate URL scheme
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            return ToolResult.fail("Only http:// and https:// URLs are allowed");
        }

        // Block localhost/private IPs (SSRF protection)
        const host = extractHost(url) orelse
            return ToolResult.fail("Invalid URL: cannot extract host");

        if (isLocalHost(host)) {
            return ToolResult.fail("Blocked local/private host");
        }

        // Check domain allowlist
        if (self.allowed_domains.len > 0) {
            if (!hostMatchesAllowlist(host, self.allowed_domains)) {
                return ToolResult.fail("Host is not in http_request.allowed_domains");
            }
        }

        // Validate method
        const method = validateMethod(method_str) orelse {
            const msg = try std.fmt.allocPrint(allocator, "Unsupported HTTP method: {s}", .{method_str});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        // Build URI
        const uri = std.Uri.parse(url) catch
            return ToolResult.fail("Invalid URL format");

        // Parse custom headers
        const headers_json = parseStringField(args_json, "headers");
        const custom_headers = parseHeaders(allocator, headers_json) catch
            return ToolResult.fail("Invalid headers format");
        defer {
            for (custom_headers) |h| {
                allocator.free(h[0]);
                allocator.free(h[1]);
            }
            allocator.free(custom_headers);
        }

        // Execute request using std.http.Client (Zig 0.15 API)
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        const body = parseStringField(args_json, "body");

        // Build extra headers
        var extra_headers_buf: [32]std.http.Header = undefined;
        var extra_count: usize = 0;
        for (custom_headers) |h| {
            if (extra_count >= extra_headers_buf.len) break;
            extra_headers_buf[extra_count] = .{ .name = h[0], .value = h[1] };
            extra_count += 1;
        }

        var req = client.request(method, uri, .{
            .extra_headers = extra_headers_buf[0..extra_count],
        }) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "HTTP request failed: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer req.deinit();

        // Send body if present, otherwise send bodiless
        if (body) |b| {
            const body_dup = try allocator.dupe(u8, b);
            defer allocator.free(body_dup);
            req.sendBodyComplete(body_dup) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to send body: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
        } else {
            req.sendBodiless() catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to send request: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
        }

        // Receive response head
        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to receive response: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        const status_code = @intFromEnum(response.head.status);
        const success = status_code >= 200 and status_code < 300;

        // Read response body (limit to 1MB)
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = reader.readAlloc(allocator, 1_048_576) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to read response body: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(response_body);

        // Build redacted headers display for custom request headers
        const redacted = redactHeadersForDisplay(allocator, custom_headers) catch "";
        defer if (redacted.len > 0) allocator.free(redacted);

        const output = if (redacted.len > 0)
            try std.fmt.allocPrint(
                allocator,
                "Status: {d}\nRequest Headers: {s}\n\nResponse Body:\n{s}",
                .{ status_code, redacted, response_body },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "Status: {d}\n\nResponse Body:\n{s}",
                .{ status_code, response_body },
            );

        if (success) {
            return ToolResult{ .success = true, .output = output };
        } else {
            const err_msg = try std.fmt.allocPrint(allocator, "HTTP {d}", .{status_code});
            return ToolResult{ .success = false, .output = output, .error_msg = err_msg };
        }
    }
};

fn validateMethod(method: []const u8) ?std.http.Method {
    if (std.ascii.eqlIgnoreCase(method, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(method, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(method, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(method, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(method, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(method, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) return .OPTIONS;
    return null;
}

fn extractHost(url: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, url, "https://"))
        url[8..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url[7..]
    else
        return null;

    // Find end of authority (first / or ? or #)
    var end: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#') {
            end = i;
            break;
        }
    }
    const authority = rest[0..end];
    if (authority.len == 0) return null;

    // Strip port
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        return authority[0..colon];
    }
    return authority;
}

/// Check if a host matches the allowlist.
/// Supports exact match and wildcard subdomain patterns ("*.example.com").
fn hostMatchesAllowlist(host: []const u8, allowed: []const []const u8) bool {
    if (allowed.len == 0) return true; // empty allowlist = allow all
    for (allowed) |pattern| {
        // Exact match
        if (std.mem.eql(u8, host, pattern)) return true;
        // Wildcard subdomain: "*.example.com" matches "api.example.com"
        if (std.mem.startsWith(u8, pattern, "*.")) {
            const domain = pattern[2..]; // strip "*."
            if (std.mem.endsWith(u8, host, domain)) {
                const prefix_len = host.len - domain.len;
                if (prefix_len > 0 and host[prefix_len - 1] == '.') return true;
            }
        }
        // Also allow implicit subdomain match (like browser_open does)
        if (host.len > pattern.len) {
            const offset = host.len - pattern.len;
            if (std.mem.eql(u8, host[offset..], pattern) and host[offset - 1] == '.') {
                return true;
            }
        }
    }
    return false;
}

/// SSRF: check if host is localhost or a private/reserved IP.
fn isLocalHost(host: []const u8) bool {
    // Strip brackets from IPv6 addresses like [::1]
    const bare = if (std.mem.startsWith(u8, host, "[") and std.mem.endsWith(u8, host, "]"))
        host[1 .. host.len - 1]
    else
        host;

    if (std.mem.eql(u8, bare, "localhost")) return true;
    if (std.mem.endsWith(u8, bare, ".localhost")) return true;
    // .local TLD
    if (std.mem.endsWith(u8, bare, ".local")) return true;

    // Try to parse as IPv4
    if (parseIpv4(bare)) |octets| {
        return isNonGlobalV4(octets);
    }

    // Try to parse as IPv6
    if (parseIpv6(bare)) |segments| {
        return isNonGlobalV6(segments);
    }

    return false;
}

/// Returns true if the IPv4 address is not globally routable.
fn isNonGlobalV4(addr: [4]u8) bool {
    const a = addr[0];
    const b = addr[1];
    const c = addr[2];
    // 127.0.0.0/8 (loopback)
    if (a == 127) return true;
    // 10.0.0.0/8 (private)
    if (a == 10) return true;
    // 172.16.0.0/12 (private)
    if (a == 172 and b >= 16 and b <= 31) return true;
    // 192.168.0.0/16 (private)
    if (a == 192 and b == 168) return true;
    // 0.0.0.0/8 (unspecified)
    if (a == 0) return true;
    // 169.254.0.0/16 (link-local)
    if (a == 169 and b == 254) return true;
    // 224.0.0.0/4 (multicast) through 255.255.255.255 (broadcast)
    if (a >= 224) return true;
    // 240.0.0.0/4 (reserved) — covered by >= 224 above
    // 100.64.0.0/10 (shared address space, RFC 6598)
    if (a == 100 and b >= 64 and b <= 127) return true;
    // 192.0.2.0/24 (documentation, TEST-NET-1, RFC 5737)
    if (a == 192 and b == 0 and c == 2) return true;
    // 198.51.100.0/24 (documentation, TEST-NET-2, RFC 5737)
    if (a == 198 and b == 51 and c == 100) return true;
    // 203.0.113.0/24 (documentation, TEST-NET-3, RFC 5737)
    if (a == 203 and b == 0 and c == 113) return true;
    // 198.18.0.0/15 (benchmarking, RFC 2544)
    if (a == 198 and (b == 18 or b == 19)) return true;
    // 192.0.0.0/24 (IETF protocol assignments)
    if (a == 192 and b == 0 and c == 0) return true;
    return false;
}

/// Returns true if the IPv6 address is not globally routable.
fn isNonGlobalV6(segs: [8]u16) bool {
    // ::1 (loopback)
    if (segs[0] == 0 and segs[1] == 0 and segs[2] == 0 and segs[3] == 0 and
        segs[4] == 0 and segs[5] == 0 and segs[6] == 0 and segs[7] == 1)
        return true;
    // :: (unspecified)
    if (segs[0] == 0 and segs[1] == 0 and segs[2] == 0 and segs[3] == 0 and
        segs[4] == 0 and segs[5] == 0 and segs[6] == 0 and segs[7] == 0)
        return true;
    // ff00::/8 (multicast)
    if (segs[0] & 0xff00 == 0xff00) return true;
    // fc00::/7 (unique local: fc00:: - fdff::)
    if (segs[0] & 0xfe00 == 0xfc00) return true;
    // fe80::/10 (link-local)
    if (segs[0] & 0xffc0 == 0xfe80) return true;
    // 2001:db8::/32 (documentation)
    if (segs[0] == 0x2001 and segs[1] == 0x0db8) return true;
    // ::ffff:0:0/96 (IPv4-mapped) — check the IPv4 part
    if (segs[0] == 0 and segs[1] == 0 and segs[2] == 0 and segs[3] == 0 and
        segs[4] == 0 and segs[5] == 0xffff)
    {
        const ipv4 = [4]u8{
            @truncate(segs[6] >> 8),
            @truncate(segs[6] & 0xff),
            @truncate(segs[7] >> 8),
            @truncate(segs[7] & 0xff),
        };
        return isNonGlobalV4(ipv4);
    }
    return false;
}

/// Parse a dotted-decimal IPv4 address string into 4 octets.
fn parseIpv4(s: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var count: u8 = 0;
    var start: usize = 0;

    for (s, 0..) |c, i| {
        if (c == '.') {
            if (count >= 3) return null;
            octets[count] = std.fmt.parseInt(u8, s[start..i], 10) catch return null;
            count += 1;
            start = i + 1;
        } else if (c < '0' or c > '9') {
            return null;
        }
    }
    if (count != 3) return null;
    octets[3] = std.fmt.parseInt(u8, s[start..], 10) catch return null;
    return octets;
}

/// Parse an IPv6 address string into 8 segments.
/// Supports :: abbreviation and mixed IPv4 notation (::ffff:1.2.3.4).
fn parseIpv6(s: []const u8) ?[8]u16 {
    if (s.len == 0) return null;

    // Check for :: and split around it
    const double_colon = std.mem.indexOf(u8, s, "::");

    var segs: [8]u16 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var seg_count: usize = 0;

    if (double_colon) |dc_pos| {
        // Parse segments before ::
        if (dc_pos > 0) {
            seg_count = parseIpv6Groups(s[0..dc_pos], &segs, 0) orelse return null;
        }
        // Parse segments after ::
        const after = s[dc_pos + 2 ..];
        if (after.len > 0) {
            // Check if the tail contains an IPv4 address (for ::ffff:x.x.x.x)
            if (std.mem.indexOfScalar(u8, after, '.') != null) {
                // Find last colon to separate groups from IPv4
                if (std.mem.lastIndexOfScalar(u8, after, ':')) |last_colon| {
                    const groups_part = after[0..last_colon];
                    const ipv4_part = after[last_colon + 1 ..];
                    // Parse IPv6 groups in the tail
                    var tail_segs: [8]u16 = undefined;
                    const tail_count = parseIpv6Groups(groups_part, &tail_segs, 0) orelse return null;
                    // Parse IPv4
                    const ipv4 = parseIpv4(ipv4_part) orelse return null;
                    // Total segments = seg_count + tail_count + 2 (for IPv4)
                    const total = seg_count + tail_count + 2;
                    if (total > 8) return null;
                    const gap = 8 - total;
                    // Place tail segments
                    for (0..tail_count) |i| {
                        segs[seg_count + gap + i] = tail_segs[i];
                    }
                    // Place IPv4 as last 2 segments
                    segs[6] = (@as(u16, ipv4[0]) << 8) | ipv4[1];
                    segs[7] = (@as(u16, ipv4[2]) << 8) | ipv4[3];
                } else {
                    // Just IPv4 after ::
                    const ipv4 = parseIpv4(after) orelse return null;
                    segs[6] = (@as(u16, ipv4[0]) << 8) | ipv4[1];
                    segs[7] = (@as(u16, ipv4[2]) << 8) | ipv4[3];
                }
            } else {
                var tail_segs: [8]u16 = undefined;
                const tail_count = parseIpv6Groups(after, &tail_segs, 0) orelse return null;
                if (seg_count + tail_count > 8) return null;
                const gap = 8 - seg_count - tail_count;
                for (0..tail_count) |i| {
                    segs[seg_count + gap + i] = tail_segs[i];
                }
            }
        }
        // Middle is filled with zeros (already initialized)
    } else {
        // No :: — must have exactly 8 groups (or 6 groups + IPv4)
        if (std.mem.indexOfScalar(u8, s, '.') != null) {
            // Mixed notation: groups:groups:...:x.x.x.x
            if (std.mem.lastIndexOfScalar(u8, s, ':')) |last_colon| {
                const groups_part = s[0..last_colon];
                const ipv4_part = s[last_colon + 1 ..];
                seg_count = parseIpv6Groups(groups_part, &segs, 0) orelse return null;
                if (seg_count != 6) return null;
                const ipv4 = parseIpv4(ipv4_part) orelse return null;
                segs[6] = (@as(u16, ipv4[0]) << 8) | ipv4[1];
                segs[7] = (@as(u16, ipv4[2]) << 8) | ipv4[3];
            } else return null;
        } else {
            seg_count = parseIpv6Groups(s, &segs, 0) orelse return null;
            if (seg_count != 8) return null;
        }
    }
    return segs;
}

/// Parse colon-separated hex groups into segments array starting at offset.
/// Returns number of segments parsed, or null on error.
fn parseIpv6Groups(s: []const u8, segs: []u16, start_idx: usize) ?usize {
    var idx = start_idx;
    var seg_start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == ':') {
            if (idx >= segs.len) return null;
            segs[idx] = std.fmt.parseInt(u16, s[seg_start..i], 16) catch return null;
            idx += 1;
            seg_start = i + 1;
        }
    }
    // Last segment
    if (seg_start <= s.len) {
        if (idx >= segs.len) return null;
        segs[idx] = std.fmt.parseInt(u16, s[seg_start..], 16) catch return null;
        idx += 1;
    }
    return idx - start_idx;
}

/// Parse headers from a JSON object string: {"Key": "Value", ...}
/// Returns array of [2][]const u8 pairs. Caller owns memory.
fn parseHeaders(allocator: std.mem.Allocator, headers_json: ?[]const u8) ![]const [2][]const u8 {
    const json = headers_json orelse return &.{};
    if (json.len < 2) return &.{};

    var list: std.ArrayList([2][]const u8) = .{};
    errdefer {
        for (list.items) |h| {
            allocator.free(h[0]);
            allocator.free(h[1]);
        }
        list.deinit(allocator);
    }

    // Simple JSON object parser: find "key": "value" pairs
    var pos: usize = 0;
    while (pos < json.len) {
        // Find next key (quoted string)
        const key_start = std.mem.indexOfScalarPos(u8, json, pos, '"') orelse break;
        const key_end = std.mem.indexOfScalarPos(u8, json, key_start + 1, '"') orelse break;
        const key = json[key_start + 1 .. key_end];

        // Skip to colon and value
        pos = key_end + 1;
        const colon = std.mem.indexOfScalarPos(u8, json, pos, ':') orelse break;
        pos = colon + 1;

        // Skip whitespace
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\n')) : (pos += 1) {}

        if (pos >= json.len or json[pos] != '"') {
            pos += 1;
            continue;
        }
        const val_start = pos;
        const val_end = std.mem.indexOfScalarPos(u8, json, val_start + 1, '"') orelse break;
        const value = json[val_start + 1 .. val_end];
        pos = val_end + 1;

        try list.append(allocator, .{
            try allocator.dupe(u8, key),
            try allocator.dupe(u8, value),
        });
    }

    return list.toOwnedSlice(allocator);
}

/// Redact sensitive headers for display output.
/// Headers with names containing authorization, api-key, apikey, token, secret,
/// or password (case-insensitive) get their values replaced with "***REDACTED***".
fn redactHeadersForDisplay(allocator: std.mem.Allocator, headers: []const [2][]const u8) ![]const u8 {
    if (headers.len == 0) return "";

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    for (headers, 0..) |h, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, h[0]);
        try buf.appendSlice(allocator, ": ");
        if (isSensitiveHeader(h[0])) {
            try buf.appendSlice(allocator, "***REDACTED***");
        } else {
            try buf.appendSlice(allocator, h[1]);
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Check if a header name is sensitive (case-insensitive substring check).
fn isSensitiveHeader(name: []const u8) bool {
    // Convert to lowercase for comparison
    var lower_buf: [256]u8 = undefined;
    if (name.len > lower_buf.len) return false;
    const lower = lower_buf[0..name.len];
    for (name, 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
    }
    if (std.mem.indexOf(u8, lower, "authorization") != null) return true;
    if (std.mem.indexOf(u8, lower, "api-key") != null) return true;
    if (std.mem.indexOf(u8, lower, "apikey") != null) return true;
    if (std.mem.indexOf(u8, lower, "token") != null) return true;
    if (std.mem.indexOf(u8, lower, "secret") != null) return true;
    if (std.mem.indexOf(u8, lower, "password") != null) return true;
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────

test "http_request tool name" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    try std.testing.expectEqualStrings("http_request", t.name());
}

test "http_request tool description not empty" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    try std.testing.expect(t.description().len > 0);
}

test "http_request schema has url" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "url") != null);
}

test "http_request schema has headers" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "headers") != null);
}

test "validateMethod accepts valid methods" {
    try std.testing.expect(validateMethod("GET") != null);
    try std.testing.expect(validateMethod("POST") != null);
    try std.testing.expect(validateMethod("PUT") != null);
    try std.testing.expect(validateMethod("DELETE") != null);
    try std.testing.expect(validateMethod("PATCH") != null);
    try std.testing.expect(validateMethod("HEAD") != null);
    try std.testing.expect(validateMethod("OPTIONS") != null);
    try std.testing.expect(validateMethod("get") != null); // case insensitive
}

test "validateMethod rejects invalid" {
    try std.testing.expect(validateMethod("INVALID") == null);
}

test "extractHost basic" {
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com/path").?);
    try std.testing.expectEqualStrings("example.com", extractHost("http://example.com").?);
    try std.testing.expectEqualStrings("api.example.com", extractHost("https://api.example.com/v1").?);
}

test "extractHost with port" {
    try std.testing.expectEqualStrings("localhost", extractHost("http://localhost:8080/api").?);
}

test "extractHost returns null for non-http scheme" {
    try std.testing.expect(extractHost("ftp://example.com") == null);
    try std.testing.expect(extractHost("file:///etc/passwd") == null);
}

test "extractHost returns null for empty host" {
    try std.testing.expect(extractHost("http:///path") == null);
    try std.testing.expect(extractHost("https:///") == null);
}

test "extractHost handles query and fragment" {
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com?q=1").?);
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com#frag").?);
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com/path?q=1#frag").?);
}

// ── isLocalHost / isNonGlobalV4 tests ──────────────────────────

test "isLocalHost detects localhost" {
    try std.testing.expect(isLocalHost("localhost"));
    try std.testing.expect(isLocalHost("foo.localhost"));
    try std.testing.expect(isLocalHost("127.0.0.1"));
    try std.testing.expect(isLocalHost("0.0.0.0"));
    try std.testing.expect(isLocalHost("::1"));
}

test "isLocalHost detects private ranges" {
    try std.testing.expect(isLocalHost("10.0.0.1"));
    try std.testing.expect(isLocalHost("192.168.1.1"));
    try std.testing.expect(isLocalHost("172.16.0.1"));
}

test "isLocalHost allows public" {
    try std.testing.expect(!isLocalHost("8.8.8.8"));
    try std.testing.expect(!isLocalHost("example.com"));
    try std.testing.expect(!isLocalHost("1.1.1.1"));
}

test "isLocalHost detects [::1] bracketed" {
    try std.testing.expect(isLocalHost("[::1]"));
}

test "isLocalHost detects 172.16-31 range" {
    try std.testing.expect(isLocalHost("172.16.0.1"));
    try std.testing.expect(isLocalHost("172.31.255.255"));
    try std.testing.expect(!isLocalHost("172.15.0.1"));
    try std.testing.expect(!isLocalHost("172.32.0.1"));
}

test "isLocalHost detects 127.x.x.x range" {
    try std.testing.expect(isLocalHost("127.0.0.1"));
    try std.testing.expect(isLocalHost("127.0.0.2"));
    try std.testing.expect(isLocalHost("127.255.255.255"));
}

test "isLocalHost detects .local TLD" {
    try std.testing.expect(isLocalHost("myhost.local"));
}

// ── Enhanced SSRF: isNonGlobalV4 ──────────────────────────────

test "isNonGlobalV4 blocks 169.254.x.x link-local" {
    try std.testing.expect(isNonGlobalV4(.{ 169, 254, 1, 1 }));
    try std.testing.expect(isNonGlobalV4(.{ 169, 254, 0, 0 }));
}

test "isNonGlobalV4 blocks 100.64.0.1 shared address space" {
    try std.testing.expect(isNonGlobalV4(.{ 100, 64, 0, 1 }));
    try std.testing.expect(isNonGlobalV4(.{ 100, 127, 255, 255 }));
    try std.testing.expect(!isNonGlobalV4(.{ 100, 63, 0, 1 })); // below range
    try std.testing.expect(!isNonGlobalV4(.{ 100, 128, 0, 1 })); // above range
}

test "isNonGlobalV4 blocks 224.0.0.1 multicast" {
    try std.testing.expect(isNonGlobalV4(.{ 224, 0, 0, 1 }));
    try std.testing.expect(isNonGlobalV4(.{ 239, 255, 255, 255 }));
}

test "isNonGlobalV4 allows 8.8.8.8 public" {
    try std.testing.expect(!isNonGlobalV4(.{ 8, 8, 8, 8 }));
    try std.testing.expect(!isNonGlobalV4(.{ 1, 1, 1, 1 }));
    try std.testing.expect(!isNonGlobalV4(.{ 93, 184, 216, 34 }));
}

test "isNonGlobalV4 blocks broadcast" {
    try std.testing.expect(isNonGlobalV4(.{ 255, 255, 255, 255 }));
}

test "isNonGlobalV4 blocks reserved" {
    try std.testing.expect(isNonGlobalV4(.{ 240, 0, 0, 1 }));
    try std.testing.expect(isNonGlobalV4(.{ 250, 1, 2, 3 }));
}

test "isNonGlobalV4 blocks documentation ranges" {
    try std.testing.expect(isNonGlobalV4(.{ 192, 0, 2, 1 })); // TEST-NET-1
    try std.testing.expect(isNonGlobalV4(.{ 198, 51, 100, 1 })); // TEST-NET-2
    try std.testing.expect(isNonGlobalV4(.{ 203, 0, 113, 1 })); // TEST-NET-3
}

test "isNonGlobalV4 blocks benchmarking range" {
    try std.testing.expect(isNonGlobalV4(.{ 198, 18, 0, 1 }));
    try std.testing.expect(isNonGlobalV4(.{ 198, 19, 255, 255 }));
}

// ── isNonGlobalV6 tests ──────────────────────────────────────

test "isNonGlobalV6 blocks ::1 loopback" {
    try std.testing.expect(isNonGlobalV6(.{ 0, 0, 0, 0, 0, 0, 0, 1 }));
}

test "isNonGlobalV6 blocks fc00::1 unique local" {
    try std.testing.expect(isNonGlobalV6(.{ 0xfc00, 0, 0, 0, 0, 0, 0, 1 }));
    try std.testing.expect(isNonGlobalV6(.{ 0xfd00, 0, 0, 0, 0, 0, 0, 1 }));
}

test "isNonGlobalV6 blocks fe80::1 link-local" {
    try std.testing.expect(isNonGlobalV6(.{ 0xfe80, 0, 0, 0, 0, 0, 0, 1 }));
}

test "isNonGlobalV6 blocks 2001:db8:: documentation" {
    try std.testing.expect(isNonGlobalV6(.{ 0x2001, 0x0db8, 0, 0, 0, 0, 0, 1 }));
}

test "isNonGlobalV6 blocks :: unspecified" {
    try std.testing.expect(isNonGlobalV6(.{ 0, 0, 0, 0, 0, 0, 0, 0 }));
}

test "isNonGlobalV6 blocks ff02::1 multicast" {
    try std.testing.expect(isNonGlobalV6(.{ 0xff02, 0, 0, 0, 0, 0, 0, 1 }));
}

test "isNonGlobalV6 blocks IPv4-mapped private" {
    // ::ffff:127.0.0.1 => segs[5]=0xffff, segs[6]=(127<<8|0), segs[7]=(0<<8|1)
    try std.testing.expect(isNonGlobalV6(.{ 0, 0, 0, 0, 0, 0xffff, 0x7f00, 0x0001 }));
    // ::ffff:192.168.1.1
    try std.testing.expect(isNonGlobalV6(.{ 0, 0, 0, 0, 0, 0xffff, 0xc0a8, 0x0101 }));
}

test "isNonGlobalV6 allows public" {
    // 2607:f8b0:4004:0800::200e (Google)
    try std.testing.expect(!isNonGlobalV6(.{ 0x2607, 0xf8b0, 0x4004, 0x0800, 0, 0, 0, 0x200e }));
}

// ── hostMatchesAllowlist tests ──────────────────────────────

test "hostMatchesAllowlist exact match works" {
    const domains = [_][]const u8{"example.com"};
    try std.testing.expect(hostMatchesAllowlist("example.com", &domains));
}

test "hostMatchesAllowlist wildcard subdomain match works" {
    const domains = [_][]const u8{"*.example.com"};
    try std.testing.expect(hostMatchesAllowlist("api.example.com", &domains));
    try std.testing.expect(hostMatchesAllowlist("deep.sub.example.com", &domains));
}

test "hostMatchesAllowlist wildcard does not match wrong domain" {
    const domains = [_][]const u8{"*.example.com"};
    try std.testing.expect(!hostMatchesAllowlist("evil.com", &domains));
    try std.testing.expect(!hostMatchesAllowlist("notexample.com", &domains));
}

test "hostMatchesAllowlist empty allowlist allows all" {
    const empty: []const []const u8 = &.{};
    try std.testing.expect(hostMatchesAllowlist("anything.com", empty));
}

test "hostMatchesAllowlist implicit subdomain match" {
    const domains = [_][]const u8{"example.com"};
    try std.testing.expect(hostMatchesAllowlist("api.example.com", &domains));
    try std.testing.expect(!hostMatchesAllowlist("notexample.com", &domains));
}

// ── redactHeadersForDisplay tests ──────────────────────────

test "redactHeadersForDisplay redacts Authorization" {
    const headers = [_][2][]const u8{
        .{ "Authorization", "Bearer secret-token" },
    };
    const result = try redactHeadersForDisplay(std.testing.allocator, &headers);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "***REDACTED***") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "secret-token") == null);
}

test "redactHeadersForDisplay preserves Content-Type" {
    const headers = [_][2][]const u8{
        .{ "Content-Type", "application/json" },
    };
    const result = try redactHeadersForDisplay(std.testing.allocator, &headers);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "REDACTED") == null);
}

test "redactHeadersForDisplay redacts api-key and token" {
    const headers = [_][2][]const u8{
        .{ "X-API-Key", "my-key" },
        .{ "X-Secret-Token", "tok-123" },
    };
    const result = try redactHeadersForDisplay(std.testing.allocator, &headers);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "my-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "tok-123") == null);
}

test "redactHeadersForDisplay empty returns empty" {
    const result = try redactHeadersForDisplay(std.testing.allocator, &.{});
    try std.testing.expectEqualStrings("", result);
}

test "isSensitiveHeader checks" {
    try std.testing.expect(isSensitiveHeader("Authorization"));
    try std.testing.expect(isSensitiveHeader("X-API-Key"));
    try std.testing.expect(isSensitiveHeader("X-Secret-Token"));
    try std.testing.expect(isSensitiveHeader("password-header"));
    try std.testing.expect(!isSensitiveHeader("Content-Type"));
    try std.testing.expect(!isSensitiveHeader("Accept"));
}

// ── execute-level tests ──────────────────────────────────────

test "execute rejects missing url parameter" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const result = try t.execute(std.testing.allocator, "{}");
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "url") != null);
}

test "execute rejects non-http scheme" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const result = try t.execute(std.testing.allocator, "{\"url\": \"ftp://example.com\"}");
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "http") != null);
}

test "execute rejects localhost SSRF" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const result = try t.execute(std.testing.allocator, "{\"url\": \"http://127.0.0.1:8080/admin\"}");
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "local") != null);
}

test "execute rejects private IP SSRF" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const result = try t.execute(std.testing.allocator, "{\"url\": \"http://192.168.1.1/admin\"}");
    try std.testing.expect(!result.success);
}

test "execute rejects 10.x private range" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const result = try t.execute(std.testing.allocator, "{\"url\": \"http://10.0.0.1/secret\"}");
    try std.testing.expect(!result.success);
}

test "execute rejects unsupported method" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const result = try t.execute(std.testing.allocator, "{\"url\": \"https://example.com\", \"method\": \"INVALID\"}");
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unsupported") != null);
}

test "execute rejects invalid URL format" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const result = try t.execute(std.testing.allocator, "{\"url\": \"http://\"}");
    try std.testing.expect(!result.success);
}

test "execute rejects non-allowlisted domain" {
    const domains = [_][]const u8{"example.com"};
    var ht = HttpRequestTool{ .allowed_domains = &domains };
    const t = ht.tool();
    const result = try t.execute(std.testing.allocator, "{\"url\": \"https://evil.com/path\"}");
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "allowed_domains") != null);
}

test "http_request parameters JSON is valid" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const schema = t.parametersJson();
    try std.testing.expect(schema[0] == '{');
    try std.testing.expect(std.mem.indexOf(u8, schema, "method") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "body") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "headers") != null);
}

test "validateMethod case insensitive" {
    try std.testing.expect(validateMethod("get") != null);
    try std.testing.expect(validateMethod("Post") != null);
    try std.testing.expect(validateMethod("pUt") != null);
    try std.testing.expect(validateMethod("delete") != null);
    try std.testing.expect(validateMethod("patch") != null);
    try std.testing.expect(validateMethod("head") != null);
    try std.testing.expect(validateMethod("options") != null);
}

test "validateMethod rejects empty string" {
    try std.testing.expect(validateMethod("") == null);
}

test "validateMethod rejects CONNECT TRACE" {
    try std.testing.expect(validateMethod("CONNECT") == null);
    try std.testing.expect(validateMethod("TRACE") == null);
}

// ── parseIpv4 tests ───────────────────────────────────────────

test "parseIpv4 basic" {
    const octets = parseIpv4("192.168.1.1").?;
    try std.testing.expectEqual(@as(u8, 192), octets[0]);
    try std.testing.expectEqual(@as(u8, 168), octets[1]);
    try std.testing.expectEqual(@as(u8, 1), octets[2]);
    try std.testing.expectEqual(@as(u8, 1), octets[3]);
}

test "parseIpv4 rejects invalid" {
    try std.testing.expect(parseIpv4("not-an-ip") == null);
    try std.testing.expect(parseIpv4("256.1.1.1") == null);
    try std.testing.expect(parseIpv4("1.2.3") == null);
}

// ── parseIpv6 tests ───────────────────────────────────────────

test "parseIpv6 loopback" {
    const segs = parseIpv6("::1").?;
    try std.testing.expectEqual(@as(u16, 0), segs[0]);
    try std.testing.expectEqual(@as(u16, 1), segs[7]);
}

test "parseIpv6 link-local" {
    const segs = parseIpv6("fe80::1").?;
    try std.testing.expectEqual(@as(u16, 0xfe80), segs[0]);
    try std.testing.expectEqual(@as(u16, 1), segs[7]);
}

test "parseIpv6 unique-local" {
    const segs = parseIpv6("fd00::1").?;
    try std.testing.expectEqual(@as(u16, 0xfd00), segs[0]);
}

test "parseIpv6 full address" {
    const segs = parseIpv6("2607:f8b0:4004:0800:0000:0000:0000:200e").?;
    try std.testing.expectEqual(@as(u16, 0x2607), segs[0]);
    try std.testing.expectEqual(@as(u16, 0x200e), segs[7]);
}

// ── parseHeaders tests ──────────────────────────────────────

test "parseHeaders basic" {
    const headers = try parseHeaders(std.testing.allocator, "{\"Content-Type\": \"application/json\"}");
    defer {
        for (headers) |h| {
            std.testing.allocator.free(h[0]);
            std.testing.allocator.free(h[1]);
        }
        std.testing.allocator.free(headers);
    }
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("Content-Type", headers[0][0]);
    try std.testing.expectEqualStrings("application/json", headers[0][1]);
}

test "parseHeaders null returns empty" {
    const headers = try parseHeaders(std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 0), headers.len);
}

// ── SSRF integration via isLocalHost ──────────────────────────

test "isLocalHost blocks link-local 169.254.x.x" {
    try std.testing.expect(isLocalHost("169.254.1.1"));
}

test "isLocalHost blocks shared address space 100.64.x.x" {
    try std.testing.expect(isLocalHost("100.64.0.1"));
    try std.testing.expect(isLocalHost("100.127.255.255"));
    try std.testing.expect(!isLocalHost("100.63.0.1"));
    try std.testing.expect(!isLocalHost("100.128.0.1"));
}

test "isLocalHost blocks multicast 224.x" {
    try std.testing.expect(isLocalHost("224.0.0.1"));
    try std.testing.expect(isLocalHost("239.255.255.255"));
}

test "isLocalHost blocks documentation ranges" {
    try std.testing.expect(isLocalHost("192.0.2.1"));
    try std.testing.expect(isLocalHost("198.51.100.1"));
    try std.testing.expect(isLocalHost("203.0.113.1"));
}

test "isLocalHost blocks benchmarking range" {
    try std.testing.expect(isLocalHost("198.18.0.1"));
    try std.testing.expect(isLocalHost("198.19.255.255"));
}

test "isLocalHost blocks IPv6 loopback" {
    try std.testing.expect(isLocalHost("::1"));
    try std.testing.expect(isLocalHost("[::1]"));
}

test "isLocalHost blocks IPv6 unique-local" {
    try std.testing.expect(isLocalHost("fd00::1"));
}

test "isLocalHost blocks IPv6 link-local" {
    try std.testing.expect(isLocalHost("fe80::1"));
}

test "isLocalHost blocks IPv6 documentation" {
    try std.testing.expect(isLocalHost("2001:db8::1"));
}

test "isLocalHost blocks IPv6 multicast" {
    try std.testing.expect(isLocalHost("ff02::1"));
}

test "URL extraction works correctly" {
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com").?);
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com:443/path").?);
    try std.testing.expectEqualStrings("sub.example.com", extractHost("http://sub.example.com/").?);
    try std.testing.expect(extractHost("ftp://nope.com") == null);
    try std.testing.expect(extractHost("https:///") == null);
}
