const std = @import("std");
const tools_mod = @import("../tools/root.zig");
const Tool = tools_mod.Tool;
const skills_mod = @import("../skills.zig");

// ═══════════════════════════════════════════════════════════════════════════
// System Prompt Builder
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum characters to include from a single workspace identity file.
const BOOTSTRAP_MAX_CHARS: usize = 20_000;

/// Context passed to prompt sections during construction.
pub const PromptContext = struct {
    workspace_dir: []const u8,
    model_name: []const u8,
    tools: []const Tool,
};

/// Build the full system prompt from workspace identity files, tools, and runtime context.
pub fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    ctx: PromptContext,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Identity section — inject workspace MD files
    try buildIdentitySection(allocator, w, ctx.workspace_dir);

    // Tools section
    try buildToolsSection(w, ctx.tools);

    // Safety section
    try w.writeAll("## Safety\n\n");
    try w.writeAll("- Do not exfiltrate private data.\n");
    try w.writeAll("- Do not run destructive commands without asking.\n");
    try w.writeAll("- Do not bypass oversight or approval mechanisms.\n");
    try w.writeAll("- Prefer `trash` over `rm`.\n");
    try w.writeAll("- When in doubt, ask before acting externally.\n\n");

    // Skills section
    try appendSkillsSection(allocator, w, ctx.workspace_dir);

    // Workspace section
    try std.fmt.format(w, "## Workspace\n\nWorking directory: `{s}`\n\n", .{ctx.workspace_dir});

    // DateTime section
    try appendDateTimeSection(w);

    // Runtime section
    try std.fmt.format(w, "## Runtime\n\nOS: {s} | Model: {s}\n\n", .{
        @tagName(comptime std.Target.Os.Tag.macos),
        ctx.model_name,
    });

    return try buf.toOwnedSlice(allocator);
}

fn buildIdentitySection(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
) !void {
    try w.writeAll("## Project Context\n\n");
    try w.writeAll("The following workspace files define your identity, behavior, and context.\n\n");

    const identity_files = [_][]const u8{
        "AGENTS.md",
        "SOUL.md",
        "TOOLS.md",
        "IDENTITY.md",
        "USER.md",
        "HEARTBEAT.md",
        "BOOTSTRAP.md",
        "MEMORY.md",
    };

    for (identity_files) |filename| {
        try injectWorkspaceFile(allocator, w, workspace_dir, filename);
    }
}

fn buildToolsSection(w: anytype, tools: []const Tool) !void {
    try w.writeAll("## Tools\n\n");
    for (tools) |t| {
        try std.fmt.format(w, "- **{s}**: {s}\n  Parameters: `{s}`\n", .{
            t.name(),
            t.description(),
            t.parametersJson(),
        });
    }
    try w.writeAll("\n");
}

/// Append available skills as an XML block.
/// Scans workspace_dir/skills/ for installed skills. If none found, appends nothing.
fn appendSkillsSection(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
) !void {
    const skill_list = skills_mod.listSkills(allocator, workspace_dir) catch return;
    defer skills_mod.freeSkills(allocator, skill_list);

    if (skill_list.len == 0) return;

    try w.writeAll("## Available Skills\n\n<available_skills>\n");
    for (skill_list) |skill| {
        try std.fmt.format(
            w,
            "  <skill>\n    <name>{s}</name>\n    <description>{s}</description>\n    <location>{s}/skills/{s}/SKILL.md</location>\n  </skill>\n",
            .{ skill.name, skill.description, workspace_dir, skill.name },
        );
    }
    try w.writeAll("</available_skills>\n\n");
}

/// Append a human-readable UTC date/time section derived from the system clock.
fn appendDateTimeSection(w: anytype) !void {
    const timestamp = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const year = year_day.year;
    const month = @intFromEnum(month_day.month);
    const day = month_day.day_index + 1;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();

    try std.fmt.format(w, "## Current Date & Time\n\n{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC\n\n", .{
        year, month, day, hour, minute,
    });
}

/// Read a workspace file and append it to the prompt, truncating if too large.
fn injectWorkspaceFile(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
    filename: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ workspace_dir, filename });
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        try std.fmt.format(w, "### {s}\n\n[File not found: {s}]\n\n", .{ filename, filename });
        return;
    };
    defer file.close();

    // Read up to BOOTSTRAP_MAX_CHARS + some margin
    const content = file.readToEndAlloc(allocator, BOOTSTRAP_MAX_CHARS + 1024) catch {
        try std.fmt.format(w, "### {s}\n\n[Could not read: {s}]\n\n", .{ filename, filename });
        return;
    };
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return;

    try std.fmt.format(w, "### {s}\n\n", .{filename});

    if (trimmed.len > BOOTSTRAP_MAX_CHARS) {
        try w.writeAll(trimmed[0..BOOTSTRAP_MAX_CHARS]);
        try std.fmt.format(w, "\n\n[... truncated at {d} chars -- use `read` for full file]\n\n", .{BOOTSTRAP_MAX_CHARS});
    } else {
        try w.writeAll(trimmed);
        try w.writeAll("\n\n");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "buildSystemPrompt includes core sections" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "test-model",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Project Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Safety") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Current Date & Time") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "test-model") != null);
}

test "buildSystemPrompt includes workspace dir" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/my/workspace",
        .model_name = "claude",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "/my/workspace") != null);
}

test "appendDateTimeSection outputs UTC timestamp" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try appendDateTimeSection(w);

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "## Current Date & Time") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "UTC") != null);
    // Verify the year is plausible (2025+)
    try std.testing.expect(std.mem.indexOf(u8, output, "202") != null);
}

test "appendSkillsSection with no skills produces nothing" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, "/tmp/nullclaw-prompt-test-no-skills");

    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "appendSkillsSection renders skills XML" {
    const allocator = std.testing.allocator;
    const base = "/tmp/nullclaw-prompt-test-skills";
    const skills_dir = "/tmp/nullclaw-prompt-test-skills/skills";
    const skill_dir = "/tmp/nullclaw-prompt-test-skills/skills/greeter";

    // Setup
    std.fs.makeDirAbsolute(base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(base) catch {};

    {
        const f = try std.fs.createFileAbsolute("/tmp/nullclaw-prompt-test-skills/skills/greeter/skill.json", .{});
        defer f.close();
        try f.writeAll("{\"name\": \"greeter\", \"version\": \"1.0.0\", \"description\": \"Greets the user\", \"author\": \"dev\"}");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base);

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<name>greeter</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<description>Greets the user</description>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SKILL.md</location>") != null);
}

test "buildSystemPrompt datetime appears before runtime" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp/nonexistent",
        .model_name = "test-model",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    const dt_pos = std.mem.indexOf(u8, prompt, "## Current Date & Time") orelse unreachable;
    const rt_pos = std.mem.indexOf(u8, prompt, "## Runtime") orelse unreachable;
    try std.testing.expect(dt_pos < rt_pos);
}
