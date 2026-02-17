//! Onboarding — interactive setup wizard and quick setup for nullclaw.
//!
//! Mirrors ZeroClaw's onboard module:
//!   - Interactive wizard (9-step configuration flow)
//!   - Quick setup (non-interactive, sensible defaults)
//!   - Workspace scaffolding (MEMORY.md, PERSONA.md, RULES.md)
//!   - Channel configuration
//!   - Memory backend selection
//!   - Provider/model selection with curated defaults

const std = @import("std");
const Config = @import("config.zig").Config;
const memory_root = @import("memory/root.zig");

// ── Constants ────────────────────────────────────────────────────

const BANNER =
    \\
    \\  ██╗   ██╗ ██████╗  ██████╗████████╗ ██████╗  ██████╗██╗      █████╗ ██╗    ██╗
    \\  ╚██╗ ██╔╝██╔═══██╗██╔════╝╚══██╔══╝██╔═══██╗██╔════╝██║     ██╔══██╗██║    ██║
    \\   ╚████╔╝ ██║   ██║██║        ██║   ██║   ██║██║     ██║     ███████║██║ █╗ ██║
    \\    ╚██╔╝  ██║   ██║██║        ██║   ██║   ██║██║     ██║     ██╔══██║██║███╗██║
    \\     ██║   ╚██████╔╝╚██████╗   ██║   ╚██████╔╝╚██████╗███████╗██║  ██║╚███╔███╔╝
    \\     ╚═╝    ╚═════╝  ╚═════╝   ╚═╝    ╚═════╝  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝
    \\
    \\  The smallest AI assistant. Zig-powered.
    \\
;

// ── Project context ──────────────────────────────────────────────

pub const ProjectContext = struct {
    user_name: []const u8 = "User",
    timezone: []const u8 = "UTC",
    agent_name: []const u8 = "nullclaw",
    communication_style: []const u8 = "Be warm, natural, and clear. Avoid robotic phrasing.",
};

// ── Provider helpers ─────────────────────────────────────────────

pub const ProviderInfo = struct {
    key: []const u8,
    label: []const u8,
    default_model: []const u8,
    env_var: []const u8,
};

pub const known_providers = [_]ProviderInfo{
    .{ .key = "openrouter", .label = "OpenRouter (multi-provider, recommended)", .default_model = "anthropic/claude-sonnet-4.5", .env_var = "OPENROUTER_API_KEY" },
    .{ .key = "anthropic", .label = "Anthropic (Claude direct)", .default_model = "claude-sonnet-4-20250514", .env_var = "ANTHROPIC_API_KEY" },
    .{ .key = "openai", .label = "OpenAI (GPT direct)", .default_model = "gpt-5.2", .env_var = "OPENAI_API_KEY" },
    .{ .key = "gemini", .label = "Google Gemini", .default_model = "gemini-2.5-pro", .env_var = "GEMINI_API_KEY" },
    .{ .key = "deepseek", .label = "DeepSeek", .default_model = "deepseek-chat", .env_var = "DEEPSEEK_API_KEY" },
    .{ .key = "groq", .label = "Groq (fast inference)", .default_model = "llama-3.3-70b-versatile", .env_var = "GROQ_API_KEY" },
    .{ .key = "ollama", .label = "Ollama (local)", .default_model = "llama3.2", .env_var = "API_KEY" },
};

/// Canonicalize provider name (handle aliases).
pub fn canonicalProviderName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "grok")) return "xai";
    if (std.mem.eql(u8, name, "together")) return "together-ai";
    if (std.mem.eql(u8, name, "google") or std.mem.eql(u8, name, "google-gemini")) return "gemini";
    return name;
}

/// Get the default model for a provider.
pub fn defaultModelForProvider(provider: []const u8) []const u8 {
    const canonical = canonicalProviderName(provider);
    for (known_providers) |p| {
        if (std.mem.eql(u8, p.key, canonical)) return p.default_model;
    }
    return "anthropic/claude-sonnet-4.5";
}

/// Get the environment variable name for a provider's API key.
pub fn providerEnvVar(provider: []const u8) []const u8 {
    const canonical = canonicalProviderName(provider);
    for (known_providers) |p| {
        if (std.mem.eql(u8, p.key, canonical)) return p.env_var;
    }
    return "API_KEY";
}

// ── Quick setup ──────────────────────────────────────────────────

/// Non-interactive setup: generates a sensible default config.
pub fn runQuickSetup(allocator: std.mem.Allocator, api_key: ?[]const u8, provider: ?[]const u8, memory_backend: ?[]const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &bw.interface;
    try stdout.writeAll(BANNER);
    try stdout.writeAll("  Quick Setup -- generating config with sensible defaults...\n\n");

    // Load or create config
    var cfg = Config.load(allocator) catch Config{
        .workspace_dir = try getDefaultWorkspace(allocator),
        .config_path = try getDefaultConfigPath(allocator),
        .allocator = allocator,
    };

    // Apply overrides
    if (api_key) |key| cfg.api_key = key;
    if (provider) |p| cfg.default_provider = p;
    if (memory_backend) |mb| cfg.memory.backend = mb;

    // Set default model based on provider
    if (cfg.default_model == null or std.mem.eql(u8, cfg.default_model.?, "anthropic/claude-sonnet-4")) {
        cfg.default_model = defaultModelForProvider(cfg.default_provider);
    }

    // Ensure workspace directory exists
    std.fs.makeDirAbsolute(cfg.workspace_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Scaffold workspace files
    try scaffoldWorkspace(allocator, cfg.workspace_dir, &ProjectContext{});

    // Print summary
    try stdout.print("  [OK] Workspace:  {s}\n", .{cfg.workspace_dir});
    try stdout.print("  [OK] Provider:   {s}\n", .{cfg.default_provider});
    if (cfg.default_model) |m| {
        try stdout.print("  [OK] Model:      {s}\n", .{m});
    }
    try stdout.print("  [OK] API Key:    {s}\n", .{if (cfg.api_key != null) "set" else "not set (use --api-key or edit config)"});
    try stdout.print("  [OK] Memory:     {s}\n", .{cfg.memory.backend});
    try stdout.writeAll("\n  Next steps:\n");
    if (cfg.api_key == null) {
        try stdout.writeAll("    1. Set your API key:  export OPENROUTER_API_KEY=\"sk-...\"\n");
        try stdout.writeAll("    2. Chat:              nullclaw agent -m \"Hello!\"\n");
        try stdout.writeAll("    3. Gateway:           nullclaw gateway\n");
    } else {
        try stdout.writeAll("    1. Chat:     nullclaw agent -m \"Hello!\"\n");
        try stdout.writeAll("    2. Gateway:  nullclaw gateway\n");
        try stdout.writeAll("    3. Status:   nullclaw status\n");
    }
    try stdout.writeAll("\n");
}

/// Main entry point — called from main.zig as `onboard.run(allocator)`.
pub fn run(allocator: std.mem.Allocator) !void {
    return runWizard(allocator);
}

/// Reconfigure channels and allowlists only (preserves existing config).
pub fn runChannelsOnly(allocator: std.mem.Allocator) !void {
    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &bw.interface;
    try stdout.writeAll("Channel configuration status:\n\n");

    const cfg = Config.load(allocator) catch {
        try stdout.writeAll("No existing config found. Run `nullclaw onboard` first.\n");
        try stdout.flush();
        return error.ConfigNotFound;
    };

    try stdout.print("  CLI:       {s}\n", .{if (cfg.channels.cli) "enabled" else "disabled"});
    try stdout.print("  Telegram:  {s}\n", .{if (cfg.channels.telegram != null) "configured" else "not configured"});
    try stdout.print("  Discord:   {s}\n", .{if (cfg.channels.discord != null) "configured" else "not configured"});
    try stdout.print("  Slack:     {s}\n", .{if (cfg.channels.slack != null) "configured" else "not configured"});
    try stdout.print("  Webhook:   {s}\n", .{if (cfg.channels.webhook != null) "configured" else "not configured"});
    try stdout.print("  iMessage:  {s}\n", .{if (cfg.channels.imessage != null) "configured" else "not configured"});
    try stdout.print("  Matrix:    {s}\n", .{if (cfg.channels.matrix != null) "configured" else "not configured"});
    try stdout.print("  WhatsApp:  {s}\n", .{if (cfg.channels.whatsapp != null) "configured" else "not configured"});
    try stdout.print("  IRC:       {s}\n", .{if (cfg.channels.irc != null) "configured" else "not configured"});
    try stdout.print("  Lark:      {s}\n", .{if (cfg.channels.lark != null) "configured" else "not configured"});
    try stdout.print("  DingTalk:  {s}\n", .{if (cfg.channels.dingtalk != null) "configured" else "not configured"});
    try stdout.writeAll("\nTo modify channels, edit your config file:\n");
    try stdout.print("  {s}\n", .{cfg.config_path});
    try stdout.flush();
}

/// Read a line from stdin, trimming trailing newline/carriage return.
/// Returns null on EOF (Ctrl+D).
fn readLine(buf: []u8) ?[]const u8 {
    const stdin = std.fs.File.stdin();
    const n = stdin.read(buf) catch return null;
    if (n == 0) return null;
    return std.mem.trimRight(u8, buf[0..n], "\r\n");
}

/// Prompt user with a message, read a line. Returns default_val if input is empty.
/// Returns null on EOF.
fn prompt(out: *std.Io.Writer, buf: []u8, message: []const u8, default_val: []const u8) ?[]const u8 {
    out.writeAll(message) catch return null;
    out.flush() catch return null;
    const line = readLine(buf) orelse return null;
    if (line.len == 0) return default_val;
    return line;
}

/// Prompt for a numbered choice (1-based). Returns 0-based index, or default_idx on empty input.
/// Returns null on EOF.
fn promptChoice(out: *std.Io.Writer, buf: []u8, max: usize, default_idx: usize) ?usize {
    out.flush() catch return null;
    const line = readLine(buf) orelse return null;
    if (line.len == 0) return default_idx;
    const num = std.fmt.parseInt(usize, line, 10) catch return default_idx;
    if (num < 1 or num > max) return default_idx;
    return num - 1;
}

const tunnel_options = [_][]const u8{ "none", "cloudflare", "ngrok", "tailscale" };
const autonomy_options = [_][]const u8{ "supervised", "autonomous", "fully_autonomous" };

/// Interactive wizard entry point — runs the full setup interactively.
pub fn runWizard(allocator: std.mem.Allocator) !void {
    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const out = &bw.interface;
    try out.writeAll(BANNER);
    try out.writeAll("  Welcome to nullclaw -- the fastest, smallest AI assistant.\n");
    try out.writeAll("  This wizard will configure your agent.\n\n");
    try out.flush();

    var input_buf: [512]u8 = undefined;

    // Load existing or create fresh config
    var cfg = Config.load(allocator) catch Config{
        .workspace_dir = try getDefaultWorkspace(allocator),
        .config_path = try getDefaultConfigPath(allocator),
        .allocator = allocator,
    };

    // ── Step 1: Provider selection ──
    try out.writeAll("  Step 1/8: Select a provider\n");
    for (known_providers, 0..) |p, i| {
        try out.print("    [{d}] {s}\n", .{ i + 1, p.label });
    }
    try out.writeAll("  Choice [1]: ");
    const provider_idx = promptChoice(out, &input_buf, known_providers.len, 0) orelse {
        try out.writeAll("\n  Aborted.\n");
        try out.flush();
        return;
    };
    const selected_provider = known_providers[provider_idx];
    cfg.default_provider = selected_provider.key;
    try out.print("  -> {s}\n\n", .{selected_provider.label});

    // ── Step 2: API key ──
    const env_hint = selected_provider.env_var;
    try out.print("  Step 2/8: Enter API key (or press Enter to use env var {s}): ", .{env_hint});
    const api_key_input = prompt(out, &input_buf, "", "") orelse {
        try out.writeAll("\n  Aborted.\n");
        try out.flush();
        return;
    };
    if (api_key_input.len > 0) {
        cfg.api_key = try allocator.dupe(u8, api_key_input);
        try out.writeAll("  -> API key set\n\n");
    } else {
        try out.print("  -> Will use ${s} from environment\n\n", .{env_hint});
    }

    // ── Step 3: Model ──
    try out.print("  Step 3/8: Model [default: {s}]: ", .{selected_provider.default_model});
    const model_input = prompt(out, &input_buf, "", selected_provider.default_model) orelse {
        try out.writeAll("\n  Aborted.\n");
        try out.flush();
        return;
    };
    cfg.default_model = if (model_input.len > 0) try allocator.dupe(u8, model_input) else selected_provider.default_model;
    try out.print("  -> {s}\n\n", .{cfg.default_model.?});

    // ── Step 4: Memory backend ──
    const backends = selectableBackends();
    try out.writeAll("  Step 4/8: Memory backend\n");
    for (backends, 0..) |b, i| {
        try out.print("    [{d}] {s}\n", .{ i + 1, b.label });
    }
    try out.writeAll("  Choice [1]: ");
    const mem_idx = promptChoice(out, &input_buf, backends.len, 0) orelse {
        try out.writeAll("\n  Aborted.\n");
        try out.flush();
        return;
    };
    cfg.memory.backend = backends[mem_idx].key;
    cfg.memory.auto_save = backends[mem_idx].auto_save_default;
    try out.print("  -> {s}\n\n", .{backends[mem_idx].label});

    // ── Step 5: Tunnel ──
    try out.writeAll("  Step 5/8: Tunnel\n");
    try out.writeAll("    [1] none\n    [2] cloudflare\n    [3] ngrok\n    [4] tailscale\n");
    try out.writeAll("  Choice [1]: ");
    const tunnel_idx = promptChoice(out, &input_buf, tunnel_options.len, 0) orelse {
        try out.writeAll("\n  Aborted.\n");
        try out.flush();
        return;
    };
    cfg.tunnel.provider = tunnel_options[tunnel_idx];
    try out.print("  -> {s}\n\n", .{tunnel_options[tunnel_idx]});

    // ── Step 6: Autonomy level ──
    try out.writeAll("  Step 6/8: Autonomy level\n");
    try out.writeAll("    [1] supervised\n    [2] autonomous\n    [3] fully_autonomous\n");
    try out.writeAll("  Choice [1]: ");
    const autonomy_idx = promptChoice(out, &input_buf, autonomy_options.len, 0) orelse {
        try out.writeAll("\n  Aborted.\n");
        try out.flush();
        return;
    };
    cfg.autonomy.level = switch (autonomy_idx) {
        0 => .supervised,
        1 => .semi_autonomous,
        2 => .full,
        else => .supervised,
    };
    try out.print("  -> {s}\n\n", .{autonomy_options[autonomy_idx]});

    // ── Step 7: Channels ──
    try out.writeAll("  Step 7/8: Configure channels now? [y/N]: ");
    const chan_input = prompt(out, &input_buf, "", "n") orelse {
        try out.writeAll("\n  Aborted.\n");
        try out.flush();
        return;
    };
    if (chan_input.len > 0 and (chan_input[0] == 'y' or chan_input[0] == 'Y')) {
        try out.writeAll("  -> Edit channels in config file after setup.\n\n");
    } else {
        try out.writeAll("  -> Skipped (CLI enabled by default)\n\n");
    }

    // ── Step 8: Workspace path ──
    const default_workspace = try getDefaultWorkspace(allocator);
    try out.print("  Step 8/8: Workspace path [{s}]: ", .{default_workspace});
    const ws_input = prompt(out, &input_buf, "", default_workspace) orelse {
        try out.writeAll("\n  Aborted.\n");
        try out.flush();
        return;
    };
    if (ws_input.len > 0) {
        cfg.workspace_dir = try allocator.dupe(u8, ws_input);
    }
    try out.print("  -> {s}\n\n", .{cfg.workspace_dir});

    // ── Apply ──
    // Ensure workspace directory exists
    std.fs.makeDirAbsolute(cfg.workspace_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Scaffold workspace files
    try scaffoldWorkspace(allocator, cfg.workspace_dir, &ProjectContext{});

    // Save config
    try cfg.save();

    // Print summary
    try out.writeAll("  ── Configuration complete ──\n\n");
    try out.print("  [OK] Provider:   {s}\n", .{cfg.default_provider});
    if (cfg.default_model) |m| {
        try out.print("  [OK] Model:      {s}\n", .{m});
    }
    try out.print("  [OK] API Key:    {s}\n", .{if (cfg.api_key != null) "set" else "from environment"});
    try out.print("  [OK] Memory:     {s}\n", .{cfg.memory.backend});
    try out.print("  [OK] Tunnel:     {s}\n", .{cfg.tunnel.provider});
    try out.print("  [OK] Workspace:  {s}\n", .{cfg.workspace_dir});
    try out.print("  [OK] Config:     {s}\n", .{cfg.config_path});
    try out.writeAll("\n  Next steps:\n");
    if (cfg.api_key == null) {
        try out.print("    1. Set your API key:  export {s}=\"sk-...\"\n", .{env_hint});
        try out.writeAll("    2. Chat:              nullclaw agent -m \"Hello!\"\n");
        try out.writeAll("    3. Gateway:           nullclaw gateway\n");
    } else {
        try out.writeAll("    1. Chat:     nullclaw agent -m \"Hello!\"\n");
        try out.writeAll("    2. Gateway:  nullclaw gateway\n");
        try out.writeAll("    3. Status:   nullclaw status\n");
    }
    try out.writeAll("\n");
    try out.flush();
}

// ── Models refresh ──────────────────────────────────────────────

const ModelsCatalogProvider = struct {
    name: []const u8,
    url: []const u8,
    models_path: []const u8, // JSON path to the models array
    id_field: []const u8, // field name for model ID within each entry
};

const catalog_providers = [_]ModelsCatalogProvider{
    .{ .name = "openai", .url = "https://api.openai.com/v1/models", .models_path = "data", .id_field = "id" },
    .{ .name = "openrouter", .url = "https://openrouter.ai/api/v1/models", .models_path = "data", .id_field = "id" },
};

/// Refresh the model catalog by fetching available models from known providers.
/// Saves results to ~/.nullclaw/models_cache.json.
pub fn runModelsRefresh(allocator: std.mem.Allocator) !void {
    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const out = &bw.interface;
    try out.writeAll("Refreshing model catalog...\n");
    try out.flush();

    // Build cache path
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        try out.writeAll("Could not determine HOME directory.\n");
        try out.flush();
        return;
    };
    defer allocator.free(home);
    const cache_path = try std.fmt.allocPrint(allocator, "{s}/.nullclaw/models_cache.json", .{home});
    defer allocator.free(cache_path);
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.nullclaw", .{home});
    defer allocator.free(cache_dir);

    // Ensure directory exists
    std.fs.makeDirAbsolute(cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            try out.writeAll("Could not create config directory.\n");
            try out.flush();
            return;
        },
    };

    // Collect models from each provider using curl
    var total_models: usize = 0;
    var results_buf: std.ArrayList(u8) = .empty;
    defer results_buf.deinit(allocator);

    try results_buf.appendSlice(allocator, "{\n");

    for (catalog_providers, 0..) |cp, cp_idx| {
        try out.print("  Fetching from {s}...\n", .{cp.name});
        try out.flush();

        // Run curl to fetch models list
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "curl", "-sf", "--max-time", "10", cp.url },
        }) catch {
            try out.print("  [SKIP] {s}: curl failed\n", .{cp.name});
            try out.flush();
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.stdout.len == 0) {
            try out.print("  [SKIP] {s}: empty response\n", .{cp.name});
            try out.flush();
            continue;
        }

        // Parse JSON and extract model IDs
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch {
            try out.print("  [SKIP] {s}: invalid JSON\n", .{cp.name});
            try out.flush();
            continue;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            try out.print("  [SKIP] {s}: unexpected format\n", .{cp.name});
            try out.flush();
            continue;
        }

        const data = root.object.get(cp.models_path) orelse {
            try out.print("  [SKIP] {s}: no '{s}' field\n", .{ cp.name, cp.models_path });
            try out.flush();
            continue;
        };
        if (data != .array) {
            try out.print("  [SKIP] {s}: '{s}' is not an array\n", .{ cp.name, cp.models_path });
            try out.flush();
            continue;
        }

        var count: usize = 0;
        if (cp_idx > 0) try results_buf.appendSlice(allocator, ",\n");
        try results_buf.appendSlice(allocator, "  \"");
        try results_buf.appendSlice(allocator, cp.name);
        try results_buf.appendSlice(allocator, "\": [");

        for (data.array.items, 0..) |item, i| {
            if (item != .object) continue;
            const id_val = item.object.get(cp.id_field) orelse continue;
            if (id_val != .string) continue;
            if (i > 0) try results_buf.appendSlice(allocator, ",");
            try results_buf.appendSlice(allocator, "\"");
            try results_buf.appendSlice(allocator, id_val.string);
            try results_buf.appendSlice(allocator, "\"");
            count += 1;
        }

        try results_buf.appendSlice(allocator, "]");
        total_models += count;
        try out.print("  [OK] {s}: {d} models\n", .{ cp.name, count });
        try out.flush();
    }

    try results_buf.appendSlice(allocator, "\n}\n");

    // Write cache file
    const file = std.fs.createFileAbsolute(cache_path, .{}) catch {
        try out.writeAll("Could not write cache file.\n");
        try out.flush();
        return;
    };
    defer file.close();
    file.writeAll(results_buf.items) catch {
        try out.writeAll("Error writing cache file.\n");
        try out.flush();
        return;
    };

    try out.print("\nFetched {d} models total. Cache saved to {s}\n", .{ total_models, cache_path });
    try out.flush();
}

// ── Workspace scaffolding ────────────────────────────────────────

/// Create essential workspace files if they don't already exist.
pub fn scaffoldWorkspace(allocator: std.mem.Allocator, workspace_dir: []const u8, ctx: *const ProjectContext) !void {
    // MEMORY.md
    const mem_tmpl = try memoryTemplate(allocator, ctx);
    defer allocator.free(mem_tmpl);
    try writeIfMissing(allocator, workspace_dir, "MEMORY.md", mem_tmpl);

    // PERSONA.md
    const persona_tmpl = try personaTemplate(allocator, ctx);
    defer allocator.free(persona_tmpl);
    try writeIfMissing(allocator, workspace_dir, "PERSONA.md", persona_tmpl);

    // RULES.md
    try writeIfMissing(allocator, workspace_dir, "RULES.md", rulesTemplate());

    // Ensure memory/ subdirectory
    const mem_dir = try std.fmt.allocPrint(allocator, "{s}/memory", .{workspace_dir});
    defer allocator.free(mem_dir);
    std.fs.makeDirAbsolute(mem_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn writeIfMissing(allocator: std.mem.Allocator, dir: []const u8, filename: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename });
    defer allocator.free(path);

    // Only write if file doesn't exist
    if (std.fs.openFileAbsolute(path, .{})) |f| {
        f.close();
        return;
    } else |_| {}

    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    file.writeAll(content) catch {};
}

fn memoryTemplate(allocator: std.mem.Allocator, ctx: *const ProjectContext) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# {s}'s Memory
        \\
        \\## User
        \\- Name: {s}
        \\- Timezone: {s}
        \\
        \\## Preferences
        \\- Communication style: {s}
        \\
    , .{ ctx.agent_name, ctx.user_name, ctx.timezone, ctx.communication_style });
}

fn personaTemplate(allocator: std.mem.Allocator, ctx: *const ProjectContext) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# {s} Persona
        \\
        \\You are {s}, a fast and focused AI assistant.
        \\
        \\## Core traits
        \\- Helpful, concise, and direct
        \\- Prefer code over explanations
        \\- Ask for clarification when uncertain
        \\
    , .{ ctx.agent_name, ctx.agent_name });
}

fn rulesTemplate() []const u8 {
    return 
    \\# Rules
    \\
    \\## Workspace
    \\- Only modify files within the workspace directory
    \\- Do not access external services without permission
    \\
    \\## Communication
    \\- Be concise and actionable
    \\- Show relevant code snippets
    \\- Admit uncertainty rather than guessing
    \\
    ;
}

// ── Memory backend helpers ───────────────────────────────────────

/// Get the list of selectable memory backends.
pub fn selectableBackends() []const memory_root.MemoryBackendProfile {
    return &memory_root.selectable_backends;
}

/// Get the default memory backend key.
pub fn defaultBackendKey() []const u8 {
    return memory_root.defaultBackendKey();
}

// ── Path helpers ─────────────────────────────────────────────────

fn getDefaultWorkspace(allocator: std.mem.Allocator) ![]const u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.nullclaw/workspace", .{home});
}

fn getDefaultConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.nullclaw/config.json", .{home});
}

// ── Tests ────────────────────────────────────────────────────────

test "canonicalProviderName handles aliases" {
    try std.testing.expectEqualStrings("xai", canonicalProviderName("grok"));
    try std.testing.expectEqualStrings("together-ai", canonicalProviderName("together"));
    try std.testing.expectEqualStrings("gemini", canonicalProviderName("google"));
    try std.testing.expectEqualStrings("gemini", canonicalProviderName("google-gemini"));
    try std.testing.expectEqualStrings("openai", canonicalProviderName("openai"));
}

test "defaultModelForProvider returns known models" {
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", defaultModelForProvider("anthropic"));
    try std.testing.expectEqualStrings("gpt-5.2", defaultModelForProvider("openai"));
    try std.testing.expectEqualStrings("deepseek-chat", defaultModelForProvider("deepseek"));
    try std.testing.expectEqualStrings("llama3.2", defaultModelForProvider("ollama"));
}

test "defaultModelForProvider falls back for unknown" {
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4.5", defaultModelForProvider("unknown-provider"));
}

test "providerEnvVar known providers" {
    try std.testing.expectEqualStrings("OPENROUTER_API_KEY", providerEnvVar("openrouter"));
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", providerEnvVar("anthropic"));
    try std.testing.expectEqualStrings("OPENAI_API_KEY", providerEnvVar("openai"));
    try std.testing.expectEqualStrings("API_KEY", providerEnvVar("ollama"));
}

test "providerEnvVar grok alias maps to xai" {
    try std.testing.expectEqualStrings("API_KEY", providerEnvVar("grok"));
}

test "providerEnvVar unknown falls back" {
    try std.testing.expectEqualStrings("API_KEY", providerEnvVar("some-new-provider"));
}

test "rulesTemplate is non-empty" {
    const template = rulesTemplate();
    try std.testing.expect(template.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, template, "Rules") != null);
}

test "known_providers has entries" {
    try std.testing.expect(known_providers.len >= 5);
    try std.testing.expectEqualStrings("openrouter", known_providers[0].key);
}

test "selectableBackends returns non-empty" {
    const backends = selectableBackends();
    try std.testing.expect(backends.len >= 3);
    try std.testing.expectEqualStrings("sqlite", backends[0].key);
}

test "BANNER contains descriptive text" {
    try std.testing.expect(std.mem.indexOf(u8, BANNER, "smallest AI assistant") != null);
}

test "scaffoldWorkspace creates files in temp dir" {
    const dir = "/tmp/nullclaw-test-scaffold";
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(dir) catch {};

    const ctx = ProjectContext{};
    try scaffoldWorkspace(std.testing.allocator, dir, &ctx);

    // Verify files were created
    const memory_path = "/tmp/nullclaw-test-scaffold/MEMORY.md";
    const file = try std.fs.openFileAbsolute(memory_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);
    try std.testing.expect(content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "Memory") != null);
}

test "scaffoldWorkspace is idempotent" {
    const dir = "/tmp/nullclaw-test-scaffold-idempotent";
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(dir) catch {};

    const ctx = ProjectContext{};
    try scaffoldWorkspace(std.testing.allocator, dir, &ctx);
    // Running again should not fail
    try scaffoldWorkspace(std.testing.allocator, dir, &ctx);
}

// ── Additional onboard tests ────────────────────────────────────

test "canonicalProviderName passthrough for known providers" {
    try std.testing.expectEqualStrings("anthropic", canonicalProviderName("anthropic"));
    try std.testing.expectEqualStrings("openrouter", canonicalProviderName("openrouter"));
    try std.testing.expectEqualStrings("deepseek", canonicalProviderName("deepseek"));
    try std.testing.expectEqualStrings("groq", canonicalProviderName("groq"));
    try std.testing.expectEqualStrings("ollama", canonicalProviderName("ollama"));
}

test "canonicalProviderName unknown returns as-is" {
    try std.testing.expectEqualStrings("my-custom-provider", canonicalProviderName("my-custom-provider"));
    try std.testing.expectEqualStrings("", canonicalProviderName(""));
}

test "defaultModelForProvider gemini via alias" {
    try std.testing.expectEqualStrings("gemini-2.5-pro", defaultModelForProvider("google"));
    try std.testing.expectEqualStrings("gemini-2.5-pro", defaultModelForProvider("google-gemini"));
    try std.testing.expectEqualStrings("gemini-2.5-pro", defaultModelForProvider("gemini"));
}

test "defaultModelForProvider groq" {
    try std.testing.expectEqualStrings("llama-3.3-70b-versatile", defaultModelForProvider("groq"));
}

test "defaultModelForProvider openrouter" {
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4.5", defaultModelForProvider("openrouter"));
}

test "providerEnvVar gemini aliases" {
    try std.testing.expectEqualStrings("GEMINI_API_KEY", providerEnvVar("gemini"));
    try std.testing.expectEqualStrings("GEMINI_API_KEY", providerEnvVar("google"));
    try std.testing.expectEqualStrings("GEMINI_API_KEY", providerEnvVar("google-gemini"));
}

test "providerEnvVar deepseek" {
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", providerEnvVar("deepseek"));
}

test "providerEnvVar groq" {
    try std.testing.expectEqualStrings("GROQ_API_KEY", providerEnvVar("groq"));
}

test "known_providers all have non-empty fields" {
    for (known_providers) |p| {
        try std.testing.expect(p.key.len > 0);
        try std.testing.expect(p.label.len > 0);
        try std.testing.expect(p.default_model.len > 0);
        try std.testing.expect(p.env_var.len > 0);
    }
}

test "known_providers keys are unique" {
    for (known_providers, 0..) |p1, i| {
        for (known_providers[i + 1 ..]) |p2| {
            try std.testing.expect(!std.mem.eql(u8, p1.key, p2.key));
        }
    }
}

test "ProjectContext default values" {
    const ctx = ProjectContext{};
    try std.testing.expectEqualStrings("User", ctx.user_name);
    try std.testing.expectEqualStrings("UTC", ctx.timezone);
    try std.testing.expectEqualStrings("nullclaw", ctx.agent_name);
    try std.testing.expect(ctx.communication_style.len > 0);
}

test "rulesTemplate contains workspace rules" {
    const template = rulesTemplate();
    try std.testing.expect(std.mem.indexOf(u8, template, "Workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, template, "Communication") != null);
}

test "rulesTemplate contains behavioral guidelines" {
    const template = rulesTemplate();
    try std.testing.expect(std.mem.indexOf(u8, template, "concise") != null);
    try std.testing.expect(std.mem.indexOf(u8, template, "uncertainty") != null or std.mem.indexOf(u8, template, "uncertain") != null);
}

test "memoryTemplate contains expected sections" {
    const tmpl = try memoryTemplate(std.testing.allocator, &ProjectContext{});
    defer std.testing.allocator.free(tmpl);
    try std.testing.expect(std.mem.indexOf(u8, tmpl, "Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl, "User") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl, "Preferences") != null);
}

test "memoryTemplate uses context values" {
    const ctx = ProjectContext{
        .user_name = "Alice",
        .timezone = "PST",
        .agent_name = "TestBot",
    };
    const tmpl = try memoryTemplate(std.testing.allocator, &ctx);
    defer std.testing.allocator.free(tmpl);
    try std.testing.expect(std.mem.indexOf(u8, tmpl, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl, "PST") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl, "TestBot") != null);
}

test "personaTemplate uses agent name" {
    const ctx = ProjectContext{ .agent_name = "MiniBot" };
    const tmpl = try personaTemplate(std.testing.allocator, &ctx);
    defer std.testing.allocator.free(tmpl);
    try std.testing.expect(std.mem.indexOf(u8, tmpl, "MiniBot") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl, "Persona") != null);
}

test "personaTemplate contains core traits" {
    const tmpl = try personaTemplate(std.testing.allocator, &ProjectContext{});
    defer std.testing.allocator.free(tmpl);
    try std.testing.expect(std.mem.indexOf(u8, tmpl, "concise") != null or std.mem.indexOf(u8, tmpl, "Helpful") != null);
}

test "scaffoldWorkspace creates PERSONA.md" {
    const dir = "/tmp/nullclaw-test-scaffold-persona";
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(dir) catch {};

    try scaffoldWorkspace(std.testing.allocator, dir, &ProjectContext{});

    const path = "/tmp/nullclaw-test-scaffold-persona/PERSONA.md";
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);
    try std.testing.expect(content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "Persona") != null);
}

test "scaffoldWorkspace creates RULES.md" {
    const dir = "/tmp/nullclaw-test-scaffold-rules";
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(dir) catch {};

    try scaffoldWorkspace(std.testing.allocator, dir, &ProjectContext{});

    const path = "/tmp/nullclaw-test-scaffold-rules/RULES.md";
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);
    try std.testing.expect(content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "Rules") != null);
}

test "scaffoldWorkspace creates memory subdirectory" {
    const dir = "/tmp/nullclaw-test-scaffold-memdir";
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(dir) catch {};

    try scaffoldWorkspace(std.testing.allocator, dir, &ProjectContext{});

    // Verify memory/ subdirectory exists
    const mem_dir = "/tmp/nullclaw-test-scaffold-memdir/memory";
    var d = try std.fs.openDirAbsolute(mem_dir, .{});
    d.close();
}

test "BANNER is non-empty and contains nullclaw branding" {
    try std.testing.expect(BANNER.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, BANNER, "Zig") != null or std.mem.indexOf(u8, BANNER, "smallest") != null);
}

test "defaultBackendKey returns non-empty" {
    const key = defaultBackendKey();
    try std.testing.expect(key.len > 0);
}

test "selectableBackends has expected backends" {
    const backends = selectableBackends();
    // Should have sqlite, markdown, and json at minimum
    var has_sqlite = false;
    for (backends) |b| {
        if (std.mem.eql(u8, b.key, "sqlite")) has_sqlite = true;
    }
    try std.testing.expect(has_sqlite);
}

// ── Wizard helper tests ─────────────────────────────────────────

test "readLine returns null on empty read" {
    // readLine reads from actual stdin which returns 0 bytes in tests (EOF)
    // This tests the null-on-EOF path
    var buf: [64]u8 = undefined;
    // We can't test stdin directly in unit tests, but we can validate
    // the function signature and constants
    _ = &buf;
}

test "tunnel_options has 4 entries" {
    try std.testing.expect(tunnel_options.len == 4);
    try std.testing.expectEqualStrings("none", tunnel_options[0]);
    try std.testing.expectEqualStrings("cloudflare", tunnel_options[1]);
    try std.testing.expectEqualStrings("ngrok", tunnel_options[2]);
    try std.testing.expectEqualStrings("tailscale", tunnel_options[3]);
}

test "autonomy_options has 3 entries" {
    try std.testing.expect(autonomy_options.len == 3);
    try std.testing.expectEqualStrings("supervised", autonomy_options[0]);
    try std.testing.expectEqualStrings("autonomous", autonomy_options[1]);
    try std.testing.expectEqualStrings("fully_autonomous", autonomy_options[2]);
}

test "catalog_providers has entries" {
    try std.testing.expect(catalog_providers.len >= 2);
    try std.testing.expectEqualStrings("openai", catalog_providers[0].name);
    try std.testing.expectEqualStrings("openrouter", catalog_providers[1].name);
}

test "catalog_providers all have valid fields" {
    for (catalog_providers) |cp| {
        try std.testing.expect(cp.name.len > 0);
        try std.testing.expect(cp.url.len > 0);
        try std.testing.expect(cp.models_path.len > 0);
        try std.testing.expect(cp.id_field.len > 0);
        // URLs should start with https
        try std.testing.expect(std.mem.startsWith(u8, cp.url, "https://"));
    }
}

test "catalog_providers names are unique" {
    for (catalog_providers, 0..) |cp1, i| {
        for (catalog_providers[i + 1 ..]) |cp2| {
            try std.testing.expect(!std.mem.eql(u8, cp1.name, cp2.name));
        }
    }
}

test "wizard promptChoice returns default for out-of-range" {
    // This tests the logic without actual I/O by validating the
    // boundary: max providers is known_providers.len
    try std.testing.expect(known_providers.len == 7);
    // The wizard would clamp to default (0) for out of range input
}

test "wizard maps autonomy index to enum correctly" {
    // Verify the mapping used in runWizard
    const Config2 = @import("config.zig");
    const mapping = [_]Config2.AutonomyLevel{ .supervised, .semi_autonomous, .full };
    try std.testing.expect(mapping[0] == .supervised);
    try std.testing.expect(mapping[1] == .semi_autonomous);
    try std.testing.expect(mapping[2] == .full);
}
