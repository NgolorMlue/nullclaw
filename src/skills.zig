const std = @import("std");
const platform = @import("platform.zig");

// Skills — user-defined capabilities loaded from disk.
//
// Each skill lives in ~/.nullclaw/workspace/skills/<name>/ with:
//   - skill.json  — manifest (name, version, description, author)
//   - SKILL.md    — optional instruction text
//
// The skillforge module handles discovery and evaluation;
// this module handles definition, loading, installation, and removal.

// ── Types ───────────────────────────────────────────────────────

pub const Skill = struct {
    name: []const u8,
    version: []const u8 = "0.0.1",
    description: []const u8 = "",
    author: []const u8 = "",
    instructions: []const u8 = "",
    enabled: bool = true,
    /// If true, full instructions are always included in the system prompt.
    /// If false, only an XML summary is included and the agent must use read_file to load instructions.
    always: bool = false,
    /// List of CLI binaries required by this skill (e.g. "docker", "git").
    requires_bins: []const []const u8 = &.{},
    /// List of environment variables required by this skill (e.g. "OPENAI_API_KEY").
    requires_env: []const []const u8 = &.{},
    /// Whether all requirements are satisfied. Set by checkRequirements().
    available: bool = true,
    /// Human-readable description of missing dependencies. Set by checkRequirements().
    missing_deps: []const u8 = "",
    /// Path to the skill directory on disk (for read_file references).
    path: []const u8 = "",
};

pub const SkillManifest = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    always: bool = false,
    requires_bins: []const []const u8 = &.{},
    requires_env: []const []const u8 = &.{},
};

// ── JSON Parsing (manual, no allocations) ───────────────────────

/// Extract a string field value from a JSON blob (minimal parser — no allocations).
/// Same pattern as tools/shell.zig parseStringField.
fn parseStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1)
    {}

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

/// Extract a boolean field value from a JSON blob (true/false literal).
fn parseBoolField(json: []const u8, key: []const u8) ?bool {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1)
    {}

    if (i + 4 <= after_key.len and std.mem.eql(u8, after_key[i..][0..4], "true")) return true;
    if (i + 5 <= after_key.len and std.mem.eql(u8, after_key[i..][0..5], "false")) return false;
    return null;
}

/// Parse a JSON string array field, returning allocated slices.
/// E.g. for `"requires_bins": ["docker", "git"]` returns &["docker", "git"].
/// Caller owns the returned outer slice and each inner slice.
fn parseStringArray(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]const []const u8 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return &.{};
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return &.{};
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon to find '['
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1)
    {}
    if (i >= after_key.len or after_key[i] != '[') return &.{};
    i += 1; // skip '['

    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    while (i < after_key.len) {
        // Skip whitespace and commas
        while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ',' or
            after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1)
        {}
        if (i >= after_key.len or after_key[i] == ']') break;
        if (after_key[i] != '"') break; // unexpected token
        i += 1; // skip opening quote

        const start = i;
        while (i < after_key.len) : (i += 1) {
            if (after_key[i] == '\\' and i + 1 < after_key.len) {
                i += 1;
                continue;
            }
            if (after_key[i] == '"') break;
        }
        if (i >= after_key.len) break;
        const value = after_key[start..i];
        i += 1; // skip closing quote
        try items.append(allocator, try allocator.dupe(u8, value));
    }

    return try items.toOwnedSlice(allocator);
}

/// Free a string array returned by parseStringArray.
fn freeStringArray(allocator: std.mem.Allocator, arr: []const []const u8) void {
    for (arr) |item| allocator.free(item);
    allocator.free(arr);
}

/// Parse a skill.json manifest from raw JSON bytes.
/// Returns slices pointing into the original json_bytes (no allocations needed
/// beyond what the caller already owns for json_bytes).
/// Note: requires_bins and requires_env are heap-allocated; caller must use allocator version.
pub fn parseManifest(json_bytes: []const u8) !SkillManifest {
    const name = parseStringField(json_bytes, "name") orelse return error.MissingField;
    const version = parseStringField(json_bytes, "version") orelse "0.0.1";
    const description = parseStringField(json_bytes, "description") orelse "";
    const author = parseStringField(json_bytes, "author") orelse "";

    return SkillManifest{
        .name = name,
        .version = version,
        .description = description,
        .author = author,
        .always = parseBoolField(json_bytes, "always") orelse false,
    };
}

/// Parse a skill.json manifest with allocator support for array fields.
pub fn parseManifestAlloc(allocator: std.mem.Allocator, json_bytes: []const u8) !SkillManifest {
    var m = try parseManifest(json_bytes);
    m.requires_bins = parseStringArray(allocator, json_bytes, "requires_bins") catch &.{};
    m.requires_env = parseStringArray(allocator, json_bytes, "requires_env") catch &.{};
    return m;
}

// ── Skill Loading ───────────────────────────────────────────────

/// Load a single skill from a directory.
/// Reads skill.json (required) and SKILL.md (optional) from skill_dir_path.
pub fn loadSkill(allocator: std.mem.Allocator, skill_dir_path: []const u8) !Skill {
    // Read skill.json
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/skill.json", .{skill_dir_path});
    defer allocator.free(manifest_path);

    const manifest_bytes = std.fs.cwd().readFileAlloc(allocator, manifest_path, 64 * 1024) catch
        return error.ManifestNotFound;
    defer allocator.free(manifest_bytes);

    const manifest = parseManifestAlloc(allocator, manifest_bytes) catch
        (parseManifest(manifest_bytes) catch return error.InvalidManifest);

    // Dupe all strings so they outlive the manifest_bytes buffer
    const name = try allocator.dupe(u8, manifest.name);
    errdefer allocator.free(name);
    const version = try allocator.dupe(u8, manifest.version);
    errdefer allocator.free(version);
    const description = try allocator.dupe(u8, manifest.description);
    errdefer allocator.free(description);
    const author = try allocator.dupe(u8, manifest.author);
    errdefer allocator.free(author);
    const path = try allocator.dupe(u8, skill_dir_path);
    errdefer allocator.free(path);

    // Try to read SKILL.md (optional)
    const instructions_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir_path});
    defer allocator.free(instructions_path);

    const instructions = std.fs.cwd().readFileAlloc(allocator, instructions_path, 256 * 1024) catch
        try allocator.dupe(u8, "");

    return Skill{
        .name = name,
        .version = version,
        .description = description,
        .author = author,
        .instructions = instructions,
        .enabled = true,
        .always = manifest.always,
        .requires_bins = manifest.requires_bins,
        .requires_env = manifest.requires_env,
        .path = path,
    };
}

/// Free all heap-allocated fields of a Skill.
pub fn freeSkill(allocator: std.mem.Allocator, skill: *const Skill) void {
    if (skill.name.len > 0) allocator.free(skill.name);
    if (skill.version.len > 0) allocator.free(skill.version);
    if (skill.description.len > 0) allocator.free(skill.description);
    if (skill.author.len > 0) allocator.free(skill.author);
    allocator.free(skill.instructions);
    if (skill.path.len > 0) allocator.free(skill.path);
    if (skill.missing_deps.len > 0) allocator.free(skill.missing_deps);
    if (skill.requires_bins.len > 0) freeStringArray(allocator, skill.requires_bins);
    if (skill.requires_env.len > 0) freeStringArray(allocator, skill.requires_env);
}

/// Free a slice of skills and all their contents.
pub fn freeSkills(allocator: std.mem.Allocator, skills_slice: []Skill) void {
    for (skills_slice) |*s| {
        freeSkill(allocator, s);
    }
    allocator.free(skills_slice);
}

// ── Requirement Checking ────────────────────────────────────────

/// Check whether a skill's required binaries and env vars are available.
/// Updates skill.available and skill.missing_deps in place.
pub fn checkRequirements(allocator: std.mem.Allocator, skill: *Skill) void {
    var missing: std.ArrayListUnmanaged(u8) = .empty;

    // Check required binaries via `which`
    for (skill.requires_bins) |bin| {
        const found = checkBinaryExists(allocator, bin);
        if (!found) {
            if (missing.items.len > 0) missing.append(allocator, ',') catch {};
            missing.append(allocator, ' ') catch {};
            missing.appendSlice(allocator, "bin:") catch {};
            missing.appendSlice(allocator, bin) catch {};
        }
    }

    // Check required environment variables
    for (skill.requires_env) |env_name| {
        const val = platform.getEnvOrNull(allocator, env_name);
        defer if (val) |v| allocator.free(v);
        if (val == null) {
            if (missing.items.len > 0) missing.append(allocator, ',') catch {};
            missing.append(allocator, ' ') catch {};
            missing.appendSlice(allocator, "env:") catch {};
            missing.appendSlice(allocator, env_name) catch {};
        }
    }

    if (missing.items.len > 0) {
        skill.available = false;
        skill.missing_deps = missing.toOwnedSlice(allocator) catch "";
    } else {
        skill.available = true;
        missing.deinit(allocator);
    }
}

/// Check if a binary exists on PATH using `which`.
fn checkBinaryExists(allocator: std.mem.Allocator, bin_name: []const u8) bool {
    var child = std.process.Child.init(&.{ "which", bin_name }, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

// ── Listing ─────────────────────────────────────────────────────

/// Scan workspace_dir/skills/ for subdirectories, loading each as a Skill.
/// Returns owned slice; caller must free with freeSkills().
pub fn listSkills(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]Skill {
    const skills_dir_path = try std.fmt.allocPrint(allocator, "{s}/skills", .{workspace_dir});
    defer allocator.free(skills_dir_path);

    var skills_list: std.ArrayList(Skill) = .empty;
    errdefer {
        for (skills_list.items) |*s| freeSkill(allocator, s);
        skills_list.deinit(allocator);
    }

    const dir = std.fs.cwd().openDir(skills_dir_path, .{ .iterate = true }) catch {
        // Directory doesn't exist or can't be opened — return empty
        return try skills_list.toOwnedSlice(allocator);
    };
    // Note: openDir returns by value in Zig 0.15, no need to dereference
    var dir_mut = dir;
    defer dir_mut.close();

    var it = dir_mut.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ skills_dir_path, entry.name });
        defer allocator.free(sub_path);

        if (loadSkill(allocator, sub_path)) |skill| {
            try skills_list.append(allocator, skill);
        } else |_| {
            // Skip directories without valid skill.json
            continue;
        }
    }

    return try skills_list.toOwnedSlice(allocator);
}

/// Load skills from two sources: built-in and workspace.
/// Workspace skills with the same name override built-in skills.
/// Also runs checkRequirements() on each loaded skill.
pub fn listSkillsMerged(allocator: std.mem.Allocator, builtin_dir: []const u8, workspace_dir: []const u8) ![]Skill {
    // Load built-in skills first
    const builtin = listSkills(allocator, builtin_dir) catch try allocator.alloc(Skill, 0);

    // Load workspace skills
    const workspace = listSkills(allocator, workspace_dir) catch try allocator.alloc(Skill, 0);

    // Build a set of workspace skill names for override detection
    var ws_names = std.StringHashMap(void).init(allocator);
    defer ws_names.deinit();
    for (workspace) |s| {
        ws_names.put(s.name, {}) catch {};
    }

    // Merge: keep built-in skills that are NOT overridden
    var merged: std.ArrayList(Skill) = .empty;
    errdefer {
        for (merged.items) |*s| freeSkill(allocator, s);
        merged.deinit(allocator);
    }

    for (builtin) |s| {
        if (ws_names.contains(s.name)) {
            // Overridden by workspace — free the built-in copy
            var s_mut = s;
            freeSkill(allocator, &s_mut);
        } else {
            try merged.append(allocator, s);
        }
    }
    allocator.free(builtin); // free outer slice only (items moved into merged or freed)

    // Add all workspace skills
    for (workspace) |s| {
        try merged.append(allocator, s);
    }
    allocator.free(workspace);

    // Check requirements for all skills
    for (merged.items) |*s| {
        checkRequirements(allocator, s);
    }

    return try merged.toOwnedSlice(allocator);
}

// ── Installation ────────────────────────────────────────────────

/// Install a skill by copying its directory into workspace_dir/skills/<name>/.
/// source_path must contain a valid skill.json.
pub fn installSkillFromPath(allocator: std.mem.Allocator, source_path: []const u8, workspace_dir: []const u8) !void {
    // Validate source has a manifest
    const src_manifest_path = try std.fmt.allocPrint(allocator, "{s}/skill.json", .{source_path});
    defer allocator.free(src_manifest_path);

    const manifest_bytes = std.fs.cwd().readFileAlloc(allocator, src_manifest_path, 64 * 1024) catch
        return error.ManifestNotFound;
    defer allocator.free(manifest_bytes);

    const manifest = parseManifest(manifest_bytes) catch return error.InvalidManifest;

    // Sanitize skill name for safe path usage
    for (manifest.name) |c| {
        if (c == '/' or c == '\\' or c == 0) return error.UnsafeName;
    }
    if (manifest.name.len == 0 or std.mem.eql(u8, manifest.name, "..")) return error.UnsafeName;

    // Ensure skills directory exists
    const skills_dir_path = try std.fmt.allocPrint(allocator, "{s}/skills", .{workspace_dir});
    defer allocator.free(skills_dir_path);
    std.fs.makeDirAbsolute(skills_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Create target directory
    const target_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}", .{ workspace_dir, manifest.name });
    defer allocator.free(target_path);
    std.fs.makeDirAbsolute(target_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Copy skill.json
    const dst_manifest = try std.fmt.allocPrint(allocator, "{s}/skill.json", .{target_path});
    defer allocator.free(dst_manifest);
    try copyFileAbsolute(src_manifest_path, dst_manifest);

    // Copy SKILL.md if present
    const src_instructions = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{source_path});
    defer allocator.free(src_instructions);
    const dst_instructions = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{target_path});
    defer allocator.free(dst_instructions);
    copyFileAbsolute(src_instructions, dst_instructions) catch {
        // SKILL.md is optional, ignore if missing
    };
}

/// Copy a file from src to dst using absolute paths.
fn copyFileAbsolute(src: []const u8, dst: []const u8) !void {
    const src_file = try std.fs.openFileAbsolute(src, .{});
    defer src_file.close();

    const dst_file = try std.fs.createFileAbsolute(dst, .{});
    defer dst_file.close();

    // Read and write in chunks
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = src_file.read(&buf) catch return error.ReadError;
        if (n == 0) break;
        dst_file.writeAll(buf[0..n]) catch return error.WriteError;
    }
}

// ── Removal ─────────────────────────────────────────────────────

/// Remove a skill by deleting its directory from workspace_dir/skills/<name>/.
pub fn removeSkill(allocator: std.mem.Allocator, name: []const u8, workspace_dir: []const u8) !void {
    // Sanitize name
    for (name) |c| {
        if (c == '/' or c == '\\' or c == 0) return error.UnsafeName;
    }
    if (name.len == 0 or std.mem.eql(u8, name, "..")) return error.UnsafeName;

    const skill_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}", .{ workspace_dir, name });
    defer allocator.free(skill_path);

    // Verify the skill directory actually exists before deleting
    std.fs.accessAbsolute(skill_path, .{}) catch return error.SkillNotFound;

    std.fs.deleteTreeAbsolute(skill_path) catch |err| {
        return err;
    };
}

// ── Community Skills Sync ────────────────────────────────────────

pub const OPEN_SKILLS_REPO_URL = "https://github.com/besoeasy/open-skills";
pub const COMMUNITY_SYNC_INTERVAL_DAYS: u64 = 7;

pub const CommunitySkillsSync = struct {
    enabled: bool,
    skills_dir: []const u8,
    sync_marker_path: []const u8,
};

/// Parse integer field from minimal JSON like {"last_sync": 12345}.
fn parseIntField(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1)
    {}

    if (i >= after_key.len) return null;

    const start = i;
    while (i < after_key.len and (after_key[i] >= '0' and after_key[i] <= '9')) : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(i64, after_key[start..i], 10) catch null;
}

/// Read the last_sync timestamp from a marker file.
/// Returns null if file doesn't exist or can't be parsed.
fn readSyncMarker(marker_path: []const u8, buf: []u8) ?i64 {
    const f = std.fs.cwd().openFile(marker_path, .{}) catch return null;
    defer f.close();
    const n = f.read(buf) catch return null;
    if (n == 0) return null;
    return parseIntField(buf[0..n], "last_sync");
}

/// Write a timestamp into the marker file, creating parent directories as needed.
fn writeSyncMarkerWithTimestamp(allocator: std.mem.Allocator, marker_path: []const u8, timestamp: i64) !void {
    if (std.mem.lastIndexOfScalar(u8, marker_path, '/')) |sep| {
        std.fs.makeDirAbsolute(marker_path[0..sep]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const content = try std.fmt.allocPrint(allocator, "{{\"last_sync\": {d}}}", .{timestamp});
    defer allocator.free(content);

    const f = try std.fs.createFileAbsolute(marker_path, .{});
    defer f.close();
    try f.writeAll(content);
}

/// Write current timestamp into the marker file.
fn writeSyncMarker(allocator: std.mem.Allocator, marker_path: []const u8) !void {
    return writeSyncMarkerWithTimestamp(allocator, marker_path, std.time.timestamp());
}

/// Synchronize community skills from the open-skills repository.
/// Gracefully returns without error if git is unavailable or sync is disabled.
pub fn syncCommunitySkills(allocator: std.mem.Allocator, workspace_dir: []const u8) !void {
    // Check if enabled via env var
    const enabled_env = platform.getEnvOrNull(allocator, "NULLCLAW_OPEN_SKILLS_ENABLED");
    defer if (enabled_env) |v| allocator.free(v);
    if (enabled_env == null) return; // not set — disabled
    if (std.mem.eql(u8, enabled_env.?, "false")) return;

    // Determine community skills directory
    const community_dir = blk: {
        if (platform.getEnvOrNull(allocator, "NULLCLAW_OPEN_SKILLS_DIR")) |dir| {
            break :blk dir;
        }
        break :blk try std.fmt.allocPrint(allocator, "{s}/skills/community", .{workspace_dir});
    };
    defer allocator.free(community_dir);

    // Marker file path
    const marker_path = try std.fmt.allocPrint(allocator, "{s}/state/skills_sync.json", .{workspace_dir});
    defer allocator.free(marker_path);

    // Check if sync is needed
    const now = std.time.timestamp();
    const interval: i64 = @intCast(COMMUNITY_SYNC_INTERVAL_DAYS * 24 * 3600);
    var marker_buf: [256]u8 = undefined;
    if (readSyncMarker(marker_path, &marker_buf)) |last_sync| {
        if (now - last_sync < interval) return; // still fresh
    }

    // Determine if community_dir exists
    const dir_exists = blk: {
        std.fs.accessAbsolute(community_dir, .{}) catch break :blk false;
        break :blk true;
    };

    if (!dir_exists) {
        // Clone
        _ = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "clone", "--depth", "1", OPEN_SKILLS_REPO_URL, community_dir },
            .max_output_bytes = 8192,
        }) catch return; // git unavailable — graceful degradation
    } else {
        // Pull
        _ = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", community_dir, "pull", "--ff-only" },
            .max_output_bytes = 8192,
        }) catch return; // git unavailable — graceful degradation
    }

    // Update marker
    writeSyncMarker(allocator, marker_path) catch {};
}

/// Load community skills from .md files in the community directory.
/// Returns owned slice; caller must free with freeSkills().
pub fn loadCommunitySkills(allocator: std.mem.Allocator, community_dir: []const u8) ![]Skill {
    var skills_list: std.ArrayList(Skill) = .empty;
    errdefer {
        for (skills_list.items) |*s| freeSkill(allocator, s);
        skills_list.deinit(allocator);
    }

    const dir = std.fs.cwd().openDir(community_dir, .{ .iterate = true }) catch {
        return try skills_list.toOwnedSlice(allocator);
    };
    var dir_mut = dir;
    defer dir_mut.close();

    var it = dir_mut.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const name_slice = entry.name;
        if (!std.mem.endsWith(u8, name_slice, ".md")) continue;

        // Skill name = filename without .md extension
        const skill_name = name_slice[0 .. name_slice.len - 3];
        if (skill_name.len == 0) continue;

        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ community_dir, name_slice });
        defer allocator.free(file_path);

        const content = std.fs.cwd().readFileAlloc(allocator, file_path, 256 * 1024) catch continue;

        const duped_name = try allocator.dupe(u8, skill_name);
        errdefer allocator.free(duped_name);
        const duped_ver = try allocator.dupe(u8, "0.0.1");
        errdefer allocator.free(duped_ver);

        try skills_list.append(allocator, Skill{
            .name = duped_name,
            .version = duped_ver,
            .instructions = content,
        });
    }

    return try skills_list.toOwnedSlice(allocator);
}

/// Merge community skills into workspace skills, with workspace skills taking priority.
/// Returns a new slice; caller must free with freeSkills().
/// The input slices are consumed (caller must NOT free them separately).
pub fn mergeCommunitySkills(allocator: std.mem.Allocator, workspace_skills: []Skill, community_skills: []Skill) ![]Skill {
    var merged: std.ArrayList(Skill) = .empty;
    errdefer {
        for (merged.items) |*s| freeSkill(allocator, s);
        merged.deinit(allocator);
    }

    // Add all workspace skills first (they have priority)
    for (workspace_skills) |s| {
        try merged.append(allocator, s);
    }

    // Add community skills that don't conflict by name
    for (community_skills) |cs| {
        var found = false;
        for (workspace_skills) |ws| {
            if (std.mem.eql(u8, ws.name, cs.name)) {
                found = true;
                break;
            }
        }
        if (found) {
            // Community skill shadowed by workspace — free it
            var mutable_cs = cs;
            freeSkill(allocator, &mutable_cs);
        } else {
            try merged.append(allocator, cs);
        }
    }

    // Free the input slice containers (but NOT elements — they've been moved)
    allocator.free(workspace_skills);
    allocator.free(community_skills);

    return try merged.toOwnedSlice(allocator);
}

// ── Sync Result API ─────────────────────────────────────────────

pub const SyncResult = struct {
    synced: bool,
    skills_count: u32,
    message: []u8,
};

/// Count .md files in a directory (non-recursive).
fn countMdFiles(dir_path: []const u8) u32 {
    const dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return 0;
    var dir_mut = dir;
    defer dir_mut.close();

    var count: u32 = 0;
    var it = dir_mut.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".md")) count += 1;
    }
    return count;
}

/// Synchronize community skills and return a result struct with sync status.
/// This wraps syncCommunitySkills with additional information about the outcome.
pub fn syncCommunitySkillsResult(allocator: std.mem.Allocator, workspace_dir: []const u8) !SyncResult {
    // Check if enabled via env var
    const enabled_env = platform.getEnvOrNull(allocator, "NULLCLAW_OPEN_SKILLS_ENABLED");
    defer if (enabled_env) |v| allocator.free(v);
    if (enabled_env == null) {
        return SyncResult{
            .synced = false,
            .skills_count = 0,
            .message = try allocator.dupe(u8, "community skills sync disabled (env not set)"),
        };
    }
    if (std.mem.eql(u8, enabled_env.?, "false")) {
        return SyncResult{
            .synced = false,
            .skills_count = 0,
            .message = try allocator.dupe(u8, "community skills sync disabled"),
        };
    }

    // Determine community skills directory
    const community_dir = blk: {
        if (platform.getEnvOrNull(allocator, "NULLCLAW_OPEN_SKILLS_DIR")) |dir| {
            break :blk dir;
        }
        break :blk try std.fmt.allocPrint(allocator, "{s}/skills/community", .{workspace_dir});
    };
    defer allocator.free(community_dir);

    // Marker file path
    const marker_path = try std.fmt.allocPrint(allocator, "{s}/state/skills_sync.json", .{workspace_dir});
    defer allocator.free(marker_path);

    // Check if sync is needed (7-day interval)
    const now = std.time.timestamp();
    const interval: i64 = @intCast(COMMUNITY_SYNC_INTERVAL_DAYS * 24 * 3600);
    var marker_buf: [256]u8 = undefined;
    if (readSyncMarker(marker_path, &marker_buf)) |last_sync| {
        if (now - last_sync < interval) {
            const count = countMdFiles(community_dir);
            return SyncResult{
                .synced = false,
                .skills_count = count,
                .message = try allocator.dupe(u8, "sync skipped, still fresh"),
            };
        }
    }

    // Determine if community_dir exists
    const dir_exists = blk: {
        std.fs.accessAbsolute(community_dir, .{}) catch break :blk false;
        break :blk true;
    };

    if (!dir_exists) {
        _ = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "clone", "--depth", "1", OPEN_SKILLS_REPO_URL, community_dir },
            .max_output_bytes = 8192,
        }) catch {
            return SyncResult{
                .synced = false,
                .skills_count = 0,
                .message = try allocator.dupe(u8, "git clone failed"),
            };
        };
    } else {
        _ = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", community_dir, "pull", "--ff-only" },
            .max_output_bytes = 8192,
        }) catch {
            const count = countMdFiles(community_dir);
            return SyncResult{
                .synced = false,
                .skills_count = count,
                .message = try allocator.dupe(u8, "git pull failed"),
            };
        };
    }

    // Update marker
    writeSyncMarker(allocator, marker_path) catch {};

    const count = countMdFiles(community_dir);
    return SyncResult{
        .synced = true,
        .skills_count = count,
        .message = try std.fmt.allocPrint(allocator, "synced {d} community skills", .{count}),
    };
}

/// Free a SyncResult's heap-allocated message.
pub fn freeSyncResult(allocator: std.mem.Allocator, result: *const SyncResult) void {
    allocator.free(result.message);
}

// ── Tests ───────────────────────────────────────────────────────

test "parseManifest full JSON" {
    const json =
        \\{"name": "code-review", "version": "1.2.0", "description": "Automated code review", "author": "nullclaw"}
    ;
    const m = try parseManifest(json);
    try std.testing.expectEqualStrings("code-review", m.name);
    try std.testing.expectEqualStrings("1.2.0", m.version);
    try std.testing.expectEqualStrings("Automated code review", m.description);
    try std.testing.expectEqualStrings("nullclaw", m.author);
}

test "parseManifest minimal JSON (name only)" {
    const json =
        \\{"name": "minimal-skill"}
    ;
    const m = try parseManifest(json);
    try std.testing.expectEqualStrings("minimal-skill", m.name);
    try std.testing.expectEqualStrings("0.0.1", m.version);
    try std.testing.expectEqualStrings("", m.description);
    try std.testing.expectEqualStrings("", m.author);
}

test "parseManifest missing name returns error" {
    const json =
        \\{"version": "1.0.0", "description": "no name"}
    ;
    try std.testing.expectError(error.MissingField, parseManifest(json));
}

test "parseManifest empty JSON object returns error" {
    try std.testing.expectError(error.MissingField, parseManifest("{}"));
}

test "parseManifest handles whitespace in JSON" {
    const json =
        \\{
        \\  "name": "spaced-skill",
        \\  "version": "0.1.0",
        \\  "description": "A skill with whitespace",
        \\  "author": "tester"
        \\}
    ;
    const m = try parseManifest(json);
    try std.testing.expectEqualStrings("spaced-skill", m.name);
    try std.testing.expectEqualStrings("0.1.0", m.version);
    try std.testing.expectEqualStrings("A skill with whitespace", m.description);
    try std.testing.expectEqualStrings("tester", m.author);
}

test "parseManifest handles escaped quotes" {
    const json =
        \\{"name": "escape-test", "description": "says \"hello\""}
    ;
    const m = try parseManifest(json);
    try std.testing.expectEqualStrings("escape-test", m.name);
    try std.testing.expectEqualStrings("says \\\"hello\\\"", m.description);
}

test "parseStringField basic" {
    const json = "{\"command\": \"echo hello\", \"other\": \"val\"}";
    const val = parseStringField(json, "command");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("echo hello", val.?);
}

test "parseStringField missing key" {
    const json = "{\"other\": \"val\"}";
    try std.testing.expect(parseStringField(json, "command") == null);
}

test "parseStringField non-string value" {
    const json = "{\"count\": 42}";
    try std.testing.expect(parseStringField(json, "count") == null);
}

test "Skill struct defaults" {
    const s = Skill{ .name = "test" };
    try std.testing.expectEqualStrings("test", s.name);
    try std.testing.expectEqualStrings("0.0.1", s.version);
    try std.testing.expectEqualStrings("", s.description);
    try std.testing.expectEqualStrings("", s.author);
    try std.testing.expectEqualStrings("", s.instructions);
    try std.testing.expect(s.enabled);
}

test "Skill struct custom values" {
    const s = Skill{
        .name = "custom",
        .version = "2.0.0",
        .description = "A custom skill",
        .author = "dev",
        .instructions = "Do the thing",
        .enabled = false,
    };
    try std.testing.expectEqualStrings("custom", s.name);
    try std.testing.expectEqualStrings("2.0.0", s.version);
    try std.testing.expectEqualStrings("A custom skill", s.description);
    try std.testing.expectEqualStrings("dev", s.author);
    try std.testing.expectEqualStrings("Do the thing", s.instructions);
    try std.testing.expect(!s.enabled);
}

test "SkillManifest fields" {
    const m = SkillManifest{
        .name = "test",
        .version = "1.0.0",
        .description = "desc",
        .author = "author",
    };
    try std.testing.expectEqualStrings("test", m.name);
    try std.testing.expectEqualStrings("1.0.0", m.version);
}

test "listSkills from nonexistent directory" {
    const allocator = std.testing.allocator;
    const skills = try listSkills(allocator, "/tmp/nullclaw-test-skills-nonexistent-dir");
    defer freeSkills(allocator, skills);
    try std.testing.expectEqual(@as(usize, 0), skills.len);
}

test "listSkills from empty directory" {
    const allocator = std.testing.allocator;
    const base = "/tmp/nullclaw-test-skills-empty";
    const skills_dir = "/tmp/nullclaw-test-skills-empty/skills";

    // Create the skills directory
    std.fs.makeDirAbsolute(base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(base) catch {};
    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const skills = try listSkills(allocator, base);
    defer freeSkills(allocator, skills);
    try std.testing.expectEqual(@as(usize, 0), skills.len);
}

test "loadSkill reads manifest and instructions" {
    const allocator = std.testing.allocator;
    const skill_dir = "/tmp/nullclaw-test-skills-load/skills/test-skill";

    // Setup: create skill directory with manifest and instructions
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-skills-load") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-skills-load/skills") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute("/tmp/nullclaw-test-skills-load") catch {};

    // Write skill.json
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-load/skills/test-skill/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"test-skill\", \"version\": \"1.0.0\", \"description\": \"A test\", \"author\": \"tester\"}");
    }

    // Write SKILL.md
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-load/skills/test-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll("# Test Skill\nDo the test thing.");
    }

    const skill = try loadSkill(allocator, skill_dir);
    defer freeSkill(allocator, &skill);

    try std.testing.expectEqualStrings("test-skill", skill.name);
    try std.testing.expectEqualStrings("1.0.0", skill.version);
    try std.testing.expectEqualStrings("A test", skill.description);
    try std.testing.expectEqualStrings("tester", skill.author);
    try std.testing.expectEqualStrings("# Test Skill\nDo the test thing.", skill.instructions);
    try std.testing.expect(skill.enabled);
}

test "loadSkill without SKILL.md still works" {
    const allocator = std.testing.allocator;
    const skill_dir = "/tmp/nullclaw-test-skills-nomd/skills/bare-skill";

    std.fs.makeDirAbsolute("/tmp/nullclaw-test-skills-nomd") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-skills-nomd/skills") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute("/tmp/nullclaw-test-skills-nomd") catch {};

    // Write only skill.json, no SKILL.md
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-nomd/skills/bare-skill/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"bare-skill\", \"version\": \"0.5.0\"}");
    }

    const skill = try loadSkill(allocator, skill_dir);
    defer freeSkill(allocator, &skill);

    try std.testing.expectEqualStrings("bare-skill", skill.name);
    try std.testing.expectEqualStrings("0.5.0", skill.version);
    try std.testing.expectEqualStrings("", skill.instructions);
}

test "loadSkill missing manifest returns error" {
    const allocator = std.testing.allocator;
    const skill_dir = "/tmp/nullclaw-test-skills-nomanifest";

    std.fs.makeDirAbsolute(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(skill_dir) catch {};

    try std.testing.expectError(error.ManifestNotFound, loadSkill(allocator, skill_dir));
}

test "listSkills discovers skills in subdirectories" {
    const allocator = std.testing.allocator;
    const base = "/tmp/nullclaw-test-skills-list";
    const skills_dir = "/tmp/nullclaw-test-skills-list/skills";

    std.fs.makeDirAbsolute(base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(base) catch {};

    // Create two skill directories
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-skills-list/skills/alpha") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-list/skills/alpha/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"alpha\", \"version\": \"1.0.0\", \"description\": \"First skill\", \"author\": \"dev\"}");
    }

    std.fs.makeDirAbsolute("/tmp/nullclaw-test-skills-list/skills/beta") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-list/skills/beta/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"beta\", \"version\": \"2.0.0\", \"description\": \"Second skill\", \"author\": \"dev2\"}");
    }

    // Also create a regular file (should be skipped)
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-list/skills/README.md", .{});
        defer f.close();
        try f.writeAll("Not a skill directory");
    }

    const skills = try listSkills(allocator, base);
    defer freeSkills(allocator, skills);

    try std.testing.expectEqual(@as(usize, 2), skills.len);

    // Skills may come in any order from directory iteration
    var found_alpha = false;
    var found_beta = false;
    for (skills) |s| {
        if (std.mem.eql(u8, s.name, "alpha")) found_alpha = true;
        if (std.mem.eql(u8, s.name, "beta")) found_beta = true;
    }
    try std.testing.expect(found_alpha);
    try std.testing.expect(found_beta);
}

test "listSkills skips directories without valid manifest" {
    const allocator = std.testing.allocator;
    const base = "/tmp/nullclaw-test-skills-skip";
    const skills_dir = "/tmp/nullclaw-test-skills-skip/skills";

    std.fs.makeDirAbsolute(base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(base) catch {};

    // One valid skill
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-skills-skip/skills/valid") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-skip/skills/valid/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"valid\"}");
    }

    // One empty directory (no manifest)
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-skills-skip/skills/broken") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const skills = try listSkills(allocator, base);
    defer freeSkills(allocator, skills);

    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("valid", skills[0].name);
}

test "installSkillFromPath and removeSkill roundtrip" {
    const allocator = std.testing.allocator;
    const workspace = "/tmp/nullclaw-test-skills-install";
    const source = "/tmp/nullclaw-test-skills-install-src";

    // Setup workspace
    std.fs.makeDirAbsolute(workspace) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(workspace) catch {};

    // Setup source skill
    std.fs.makeDirAbsolute(source) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(source) catch {};

    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-install-src/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"installable\", \"version\": \"1.0.0\", \"description\": \"Test install\", \"author\": \"dev\"}");
    }
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-install-src/SKILL.md", .{});
        defer f.close();
        try f.writeAll("# Instructions\nInstall me.");
    }

    // Install
    try installSkillFromPath(allocator, source, workspace);

    // Verify installed skill loads
    const skills = try listSkills(allocator, workspace);
    defer freeSkills(allocator, skills);
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("installable", skills[0].name);
    try std.testing.expectEqualStrings("# Instructions\nInstall me.", skills[0].instructions);

    // Remove
    try removeSkill(allocator, "installable", workspace);

    // Verify removal
    const after = try listSkills(allocator, workspace);
    defer freeSkills(allocator, after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "installSkillFromPath rejects missing manifest" {
    const allocator = std.testing.allocator;
    const source = "/tmp/nullclaw-test-skills-install-bad";

    std.fs.makeDirAbsolute(source) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(source) catch {};

    try std.testing.expectError(error.ManifestNotFound, installSkillFromPath(allocator, source, "/tmp/nullclaw-test-ws"));
}

test "removeSkill nonexistent returns SkillNotFound" {
    const allocator = std.testing.allocator;
    const workspace = "/tmp/nullclaw-test-skills-remove-none";

    std.fs.makeDirAbsolute(workspace) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-skills-remove-none/skills") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(workspace) catch {};

    try std.testing.expectError(error.SkillNotFound, removeSkill(allocator, "nonexistent", workspace));
}

test "removeSkill rejects unsafe names" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsafeName, removeSkill(allocator, "../etc", "/tmp"));
    try std.testing.expectError(error.UnsafeName, removeSkill(allocator, "foo/bar", "/tmp"));
    try std.testing.expectError(error.UnsafeName, removeSkill(allocator, "", "/tmp"));
    try std.testing.expectError(error.UnsafeName, removeSkill(allocator, "..", "/tmp"));
}

test "installSkillFromPath rejects unsafe skill names" {
    const allocator = std.testing.allocator;
    const source = "/tmp/nullclaw-test-skills-unsafe-name";

    std.fs.makeDirAbsolute(source) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(source) catch {};

    // Write a manifest with a malicious name
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-unsafe-name/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"../../../etc/passwd\"}");
    }

    try std.testing.expectError(error.UnsafeName, installSkillFromPath(allocator, source, "/tmp/nullclaw-test-ws"));
}

// ── Community Sync Tests ────────────────────────────────────────

test "parseIntField basic" {
    const json = "{\"last_sync\": 1700000000}";
    const val = parseIntField(json, "last_sync");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 1700000000), val.?);
}

test "parseIntField missing key" {
    const json = "{\"other\": 42}";
    try std.testing.expect(parseIntField(json, "last_sync") == null);
}

test "parseIntField non-numeric value" {
    const json = "{\"last_sync\": \"not_a_number\"}";
    try std.testing.expect(parseIntField(json, "last_sync") == null);
}

test "sync marker read/write roundtrip" {
    const allocator = std.testing.allocator;
    const base = "/tmp/nullclaw-test-sync-marker";
    const marker = "/tmp/nullclaw-test-sync-marker/state/skills_sync.json";

    std.fs.makeDirAbsolute(base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(base) catch {};

    // Write marker with known timestamp
    try writeSyncMarkerWithTimestamp(allocator, marker, 1700000000);

    // Read it back
    var buf: [256]u8 = undefined;
    const ts = readSyncMarker(marker, &buf);
    try std.testing.expect(ts != null);
    try std.testing.expectEqual(@as(i64, 1700000000), ts.?);
}

test "readSyncMarker returns null for nonexistent file" {
    var buf: [256]u8 = undefined;
    const ts = readSyncMarker("/tmp/nullclaw-nonexistent-marker-file.json", &buf);
    try std.testing.expect(ts == null);
}

test "syncCommunitySkills disabled when env not set" {
    // NULLCLAW_OPEN_SKILLS_ENABLED is not set in test environment,
    // so syncCommunitySkills should return immediately without doing anything
    const allocator = std.testing.allocator;
    try syncCommunitySkills(allocator, "/tmp/nullclaw-test-sync-disabled");
    // No error = success (function returned early)
}

test "loadCommunitySkills from nonexistent directory" {
    const allocator = std.testing.allocator;
    const skills = try loadCommunitySkills(allocator, "/tmp/nullclaw-test-community-nonexistent");
    defer freeSkills(allocator, skills);
    try std.testing.expectEqual(@as(usize, 0), skills.len);
}

test "loadCommunitySkills loads .md files" {
    const allocator = std.testing.allocator;
    const community_dir = "/tmp/nullclaw-test-community-load";

    std.fs.makeDirAbsolute(community_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(community_dir) catch {};

    // Create two .md files and one non-.md file
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-community-load/code-review.md", .{});
        defer f.close();
        try f.writeAll("Review code carefully.");
    }
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-community-load/refactor.md", .{});
        defer f.close();
        try f.writeAll("Refactor for clarity.");
    }
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-community-load/README.txt", .{});
        defer f.close();
        try f.writeAll("Not a skill.");
    }

    const skills = try loadCommunitySkills(allocator, community_dir);
    defer freeSkills(allocator, skills);

    try std.testing.expectEqual(@as(usize, 2), skills.len);

    var found_review = false;
    var found_refactor = false;
    for (skills) |s| {
        if (std.mem.eql(u8, s.name, "code-review")) {
            found_review = true;
            try std.testing.expectEqualStrings("Review code carefully.", s.instructions);
        }
        if (std.mem.eql(u8, s.name, "refactor")) {
            found_refactor = true;
            try std.testing.expectEqualStrings("Refactor for clarity.", s.instructions);
        }
    }
    try std.testing.expect(found_review);
    try std.testing.expect(found_refactor);
}

test "mergeCommunitySkills workspace takes priority" {
    const allocator = std.testing.allocator;

    // Create workspace skills (must dupe version since freeSkill frees it)
    var ws = try allocator.alloc(Skill, 1);
    ws[0] = Skill{
        .name = try allocator.dupe(u8, "my-skill"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .instructions = try allocator.dupe(u8, "workspace version"),
    };

    // Create community skills with one overlap and one unique
    var cs = try allocator.alloc(Skill, 2);
    cs[0] = Skill{
        .name = try allocator.dupe(u8, "my-skill"),
        .version = try allocator.dupe(u8, "0.0.1"),
        .instructions = try allocator.dupe(u8, "community version"),
    };
    cs[1] = Skill{
        .name = try allocator.dupe(u8, "community-only"),
        .version = try allocator.dupe(u8, "0.0.1"),
        .instructions = try allocator.dupe(u8, "from community"),
    };

    const merged = try mergeCommunitySkills(allocator, ws, cs);
    defer freeSkills(allocator, merged);

    // Should have 2 skills: workspace "my-skill" + community "community-only"
    try std.testing.expectEqual(@as(usize, 2), merged.len);

    var found_ws = false;
    var found_community = false;
    for (merged) |s| {
        if (std.mem.eql(u8, s.name, "my-skill")) {
            found_ws = true;
            try std.testing.expectEqualStrings("workspace version", s.instructions);
        }
        if (std.mem.eql(u8, s.name, "community-only")) {
            found_community = true;
            try std.testing.expectEqualStrings("from community", s.instructions);
        }
    }
    try std.testing.expect(found_ws);
    try std.testing.expect(found_community);
}

test "CommunitySkillsSync struct" {
    const sync = CommunitySkillsSync{
        .enabled = true,
        .skills_dir = "/tmp/skills/community",
        .sync_marker_path = "/tmp/state/skills_sync.json",
    };
    try std.testing.expect(sync.enabled);
    try std.testing.expectEqualStrings("/tmp/skills/community", sync.skills_dir);
}

test "OPEN_SKILLS_REPO_URL is set" {
    try std.testing.expectEqualStrings("https://github.com/besoeasy/open-skills", OPEN_SKILLS_REPO_URL);
}

test "COMMUNITY_SYNC_INTERVAL_DAYS is 7" {
    try std.testing.expectEqual(@as(u64, 7), COMMUNITY_SYNC_INTERVAL_DAYS);
}

// ── Progressive Loading Tests ───────────────────────────────────

test "parseBoolField true" {
    const json = "{\"always\": true}";
    try std.testing.expectEqual(@as(?bool, true), parseBoolField(json, "always"));
}

test "parseBoolField false" {
    const json = "{\"always\": false}";
    try std.testing.expectEqual(@as(?bool, false), parseBoolField(json, "always"));
}

test "parseBoolField missing returns null" {
    const json = "{\"name\": \"test\"}";
    try std.testing.expect(parseBoolField(json, "always") == null);
}

test "parseStringArray basic" {
    const allocator = std.testing.allocator;
    const json = "{\"requires_bins\": [\"docker\", \"git\"]}";
    const arr = try parseStringArray(allocator, json, "requires_bins");
    defer freeStringArray(allocator, arr);

    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("docker", arr[0]);
    try std.testing.expectEqualStrings("git", arr[1]);
}

test "parseStringArray empty array" {
    const allocator = std.testing.allocator;
    const json = "{\"requires_bins\": []}";
    const arr = try parseStringArray(allocator, json, "requires_bins");
    defer if (arr.len > 0) freeStringArray(allocator, arr);

    try std.testing.expectEqual(@as(usize, 0), arr.len);
}

test "parseStringArray missing key" {
    const allocator = std.testing.allocator;
    const json = "{\"name\": \"test\"}";
    const arr = try parseStringArray(allocator, json, "requires_bins");
    defer if (arr.len > 0) freeStringArray(allocator, arr);

    try std.testing.expectEqual(@as(usize, 0), arr.len);
}

test "parseStringArray single element" {
    const allocator = std.testing.allocator;
    const json = "{\"requires_env\": [\"API_KEY\"]}";
    const arr = try parseStringArray(allocator, json, "requires_env");
    defer freeStringArray(allocator, arr);

    try std.testing.expectEqual(@as(usize, 1), arr.len);
    try std.testing.expectEqualStrings("API_KEY", arr[0]);
}

test "parseManifest reads always field" {
    const json =
        \\{"name": "deploy", "always": true}
    ;
    const m = try parseManifest(json);
    try std.testing.expect(m.always);
}

test "parseManifest always defaults to false" {
    const json =
        \\{"name": "helper"}
    ;
    const m = try parseManifest(json);
    try std.testing.expect(!m.always);
}

test "parseManifestAlloc reads requires_bins" {
    const allocator = std.testing.allocator;
    const json = "{\"name\": \"deploy\", \"requires_bins\": [\"docker\", \"kubectl\"]}";
    const m = try parseManifestAlloc(allocator, json);
    defer freeStringArray(allocator, m.requires_bins);

    try std.testing.expectEqual(@as(usize, 2), m.requires_bins.len);
    try std.testing.expectEqualStrings("docker", m.requires_bins[0]);
    try std.testing.expectEqualStrings("kubectl", m.requires_bins[1]);
}

test "parseManifestAlloc reads requires_env" {
    const allocator = std.testing.allocator;
    const json = "{\"name\": \"deploy\", \"requires_env\": [\"AWS_KEY\"]}";
    const m = try parseManifestAlloc(allocator, json);
    defer freeStringArray(allocator, m.requires_env);

    try std.testing.expectEqual(@as(usize, 1), m.requires_env.len);
    try std.testing.expectEqualStrings("AWS_KEY", m.requires_env[0]);
}

test "Skill struct progressive loading defaults" {
    const s = Skill{ .name = "test" };
    try std.testing.expect(!s.always);
    try std.testing.expect(s.available);
    try std.testing.expectEqual(@as(usize, 0), s.requires_bins.len);
    try std.testing.expectEqual(@as(usize, 0), s.requires_env.len);
    try std.testing.expectEqualStrings("", s.missing_deps);
    try std.testing.expectEqualStrings("", s.path);
}

test "checkRequirements marks available when no requirements" {
    const allocator = std.testing.allocator;
    var skill = Skill{ .name = "simple" };
    checkRequirements(allocator, &skill);
    try std.testing.expect(skill.available);
    try std.testing.expectEqualStrings("", skill.missing_deps);
}

test "checkRequirements detects missing env var" {
    const allocator = std.testing.allocator;
    const env_arr = try allocator.alloc([]const u8, 1);
    env_arr[0] = try allocator.dupe(u8, "NULLCLAW_TEST_NONEXISTENT_VAR_XYZ123");
    var skill = Skill{
        .name = "needs-env",
        .requires_env = env_arr,
    };
    checkRequirements(allocator, &skill);
    defer if (skill.missing_deps.len > 0) allocator.free(skill.missing_deps);
    defer freeStringArray(allocator, skill.requires_env);

    try std.testing.expect(!skill.available);
    try std.testing.expect(std.mem.indexOf(u8, skill.missing_deps, "env:NULLCLAW_TEST_NONEXISTENT_VAR_XYZ123") != null);
}

test "checkBinaryExists finds common binary" {
    const allocator = std.testing.allocator;
    try std.testing.expect(checkBinaryExists(allocator, "ls"));
}

test "checkBinaryExists returns false for nonexistent binary" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!checkBinaryExists(allocator, "nullclaw_nonexistent_binary_xyz"));
}

test "loadSkill reads always field" {
    const allocator = std.testing.allocator;
    const skill_dir = "/tmp/nullclaw-test-skills-always";

    std.fs.makeDirAbsolute(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(skill_dir) catch {};

    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-skills-always/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"always-skill\", \"always\": true, \"requires_bins\": [\"ls\"]}");
    }

    const skill = try loadSkill(allocator, skill_dir);
    defer freeSkill(allocator, &skill);

    try std.testing.expect(skill.always);
    try std.testing.expectEqual(@as(usize, 1), skill.requires_bins.len);
    try std.testing.expectEqualStrings("ls", skill.requires_bins[0]);
    try std.testing.expectEqualStrings(skill_dir, skill.path);
}

test "listSkillsMerged workspace overrides builtin" {
    const allocator = std.testing.allocator;
    const builtin_base = "/tmp/nullclaw-test-merge-builtin";
    const ws_base = "/tmp/nullclaw-test-merge-ws";

    // Setup builtin
    std.fs.makeDirAbsolute(builtin_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-merge-builtin/skills") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-merge-builtin/skills/shared") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-merge-builtin/skills/builtin-only") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(builtin_base) catch {};

    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-merge-builtin/skills/shared/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"shared\", \"description\": \"builtin version\"}");
    }
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-merge-builtin/skills/builtin-only/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"builtin-only\", \"description\": \"only in builtin\"}");
    }

    // Setup workspace
    std.fs.makeDirAbsolute(ws_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-merge-ws/skills") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-merge-ws/skills/shared") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-merge-ws/skills/ws-only") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(ws_base) catch {};

    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-merge-ws/skills/shared/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"shared\", \"description\": \"workspace version\"}");
    }
    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-merge-ws/skills/ws-only/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"ws-only\", \"description\": \"only in workspace\"}");
    }

    const skills = try listSkillsMerged(allocator, builtin_base, ws_base);
    defer freeSkills(allocator, skills);

    // Should have 3 skills: builtin-only, shared (ws version), ws-only
    try std.testing.expectEqual(@as(usize, 3), skills.len);

    var found_builtin_only = false;
    var found_ws_only = false;
    var shared_desc: ?[]const u8 = null;
    for (skills) |s| {
        if (std.mem.eql(u8, s.name, "builtin-only")) found_builtin_only = true;
        if (std.mem.eql(u8, s.name, "ws-only")) found_ws_only = true;
        if (std.mem.eql(u8, s.name, "shared")) shared_desc = s.description;
    }
    try std.testing.expect(found_builtin_only);
    try std.testing.expect(found_ws_only);
    // Workspace version should win
    try std.testing.expectEqualStrings("workspace version", shared_desc.?);
}

test "listSkillsMerged with nonexistent dirs returns empty" {
    const allocator = std.testing.allocator;
    const skills = try listSkillsMerged(allocator, "/tmp/nullclaw-nonexistent-a", "/tmp/nullclaw-nonexistent-b");
    defer freeSkills(allocator, skills);
    try std.testing.expectEqual(@as(usize, 0), skills.len);
}

test "checkRequirements detects missing binary" {
    const allocator = std.testing.allocator;
    const bin_arr = try allocator.alloc([]const u8, 1);
    bin_arr[0] = try allocator.dupe(u8, "nullclaw_nonexistent_xyz_bin");
    var skill = Skill{
        .name = "needs-bin",
        .requires_bins = bin_arr,
    };
    checkRequirements(allocator, &skill);
    defer if (skill.missing_deps.len > 0) allocator.free(skill.missing_deps);
    defer freeStringArray(allocator, skill.requires_bins);

    try std.testing.expect(!skill.available);
    try std.testing.expect(std.mem.indexOf(u8, skill.missing_deps, "bin:nullclaw_nonexistent_xyz_bin") != null);
}

test "checkRequirements detects both missing bin and env" {
    const allocator = std.testing.allocator;
    const bin_arr = try allocator.alloc([]const u8, 1);
    bin_arr[0] = try allocator.dupe(u8, "nullclaw_missing_bin_abc");
    const env_arr = try allocator.alloc([]const u8, 1);
    env_arr[0] = try allocator.dupe(u8, "NULLCLAW_MISSING_ENV_ABC");
    var skill = Skill{
        .name = "needs-both",
        .requires_bins = bin_arr,
        .requires_env = env_arr,
    };
    checkRequirements(allocator, &skill);
    defer if (skill.missing_deps.len > 0) allocator.free(skill.missing_deps);
    defer freeStringArray(allocator, skill.requires_bins);
    defer freeStringArray(allocator, skill.requires_env);

    try std.testing.expect(!skill.available);
    try std.testing.expect(std.mem.indexOf(u8, skill.missing_deps, "bin:nullclaw_missing_bin_abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill.missing_deps, "env:NULLCLAW_MISSING_ENV_ABC") != null);
}

test "listSkillsMerged runs checkRequirements" {
    const allocator = std.testing.allocator;
    const builtin_base = "/tmp/nullclaw-test-merge-checkreq";
    const ws_base = "/tmp/nullclaw-test-merge-checkreq-ws";

    // Setup builtin with a skill that requires a nonexistent binary
    std.fs.makeDirAbsolute(builtin_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-merge-checkreq/skills") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute("/tmp/nullclaw-test-merge-checkreq/skills/needy") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(builtin_base) catch {};

    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-test-merge-checkreq/skills/needy/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"needy\", \"description\": \"needs stuff\", \"requires_bins\": [\"nullclaw_fake_bin_zzz\"]}");
    }

    // Empty workspace
    std.fs.makeDirAbsolute(ws_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(ws_base) catch {};

    const skills = try listSkillsMerged(allocator, builtin_base, ws_base);
    defer freeSkills(allocator, skills);

    try std.testing.expectEqual(@as(usize, 1), skills.len);
    // checkRequirements should have been called by listSkillsMerged
    try std.testing.expect(!skills[0].available);
    try std.testing.expect(std.mem.indexOf(u8, skills[0].missing_deps, "bin:nullclaw_fake_bin_zzz") != null);
}

// ── SyncResult API Tests ────────────────────────────────────────

test "SyncResult struct fields" {
    const allocator = std.testing.allocator;
    const msg = try allocator.dupe(u8, "test message");
    const result = SyncResult{
        .synced = true,
        .skills_count = 42,
        .message = msg,
    };
    defer freeSyncResult(allocator, &result);

    try std.testing.expect(result.synced);
    try std.testing.expectEqual(@as(u32, 42), result.skills_count);
    try std.testing.expectEqualStrings("test message", result.message);
}

test "syncCommunitySkillsResult disabled when env not set" {
    // NULLCLAW_OPEN_SKILLS_ENABLED is not set in test environment
    const allocator = std.testing.allocator;
    const result = try syncCommunitySkillsResult(allocator, "/tmp/nullclaw-test-sync-result-disabled");
    defer freeSyncResult(allocator, &result);

    try std.testing.expect(!result.synced);
    try std.testing.expectEqual(@as(u32, 0), result.skills_count);
    try std.testing.expectEqualStrings("community skills sync disabled (env not set)", result.message);
}

test "countMdFiles returns zero for nonexistent dir" {
    const count = countMdFiles("/tmp/nullclaw-test-countmd-nonexistent");
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "countMdFiles counts only .md files" {
    const dir = "/tmp/nullclaw-test-countmd";

    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(dir) catch {};

    // Create 3 .md files and 2 non-.md files
    inline for (.{ "a.md", "b.md", "c.md", "readme.txt", "data.json" }) |name| {
        const f = try std.fs.createFileAbsolute(dir ++ "/" ++ name, .{});
        f.close();
    }

    const count = countMdFiles(dir);
    try std.testing.expectEqual(@as(u32, 3), count);
}

test "freeSyncResult frees message" {
    const allocator = std.testing.allocator;
    const msg = try allocator.dupe(u8, "allocated message");
    const result = SyncResult{
        .synced = false,
        .skills_count = 0,
        .message = msg,
    };
    // freeSyncResult should not leak — testing allocator will catch leaks
    freeSyncResult(allocator, &result);
}
