const std = @import("std");
const types = @import("config_types.zig");

// Forward-reference to the Config struct defined in config.zig.
// Zig handles circular @import lazily, so this works as long as there is
// no comptime-initialization cycle.
const config_mod = @import("config.zig");
const Config = config_mod.Config;

/// Parse a JSON array of strings into an allocated slice.
pub fn parseStringArray(allocator: std.mem.Allocator, arr: std.json.Array) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    try list.ensureTotalCapacity(allocator, @intCast(arr.items.len));
    for (arr.items) |item| {
        if (item == .string) {
            try list.append(allocator, try allocator.dupe(u8, item.string));
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// Parse JSON content into the given Config.
pub fn parseJson(self: *Config, content: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Top-level fields
    if (root.get("default_provider")) |v| {
        if (v == .string) self.default_provider = try self.allocator.dupe(u8, v.string);
    }
    if (root.get("default_model")) |v| {
        if (v == .string) self.default_model = try self.allocator.dupe(u8, v.string);
    }
    if (root.get("default_temperature")) |v| {
        if (v == .float) self.default_temperature = v.float;
        if (v == .integer) self.default_temperature = @floatFromInt(v.integer);
    }
    if (root.get("max_tokens")) |v| {
        if (v == .integer) self.max_tokens = @intCast(v.integer);
    }

    // Model routes
    if (root.get("model_routes")) |v| {
        if (v == .array) {
            var list: std.ArrayListUnmanaged(types.ModelRouteConfig) = .empty;
            try list.ensureTotalCapacity(self.allocator, @intCast(v.array.items.len));
            for (v.array.items) |item| {
                if (item == .object) {
                    const hint = item.object.get("hint") orelse continue;
                    const provider = item.object.get("provider") orelse continue;
                    const model = item.object.get("model") orelse continue;
                    if (hint != .string or provider != .string or model != .string) continue;
                    var route = types.ModelRouteConfig{
                        .hint = try self.allocator.dupe(u8, hint.string),
                        .provider = try self.allocator.dupe(u8, provider.string),
                        .model = try self.allocator.dupe(u8, model.string),
                    };
                    if (item.object.get("api_key")) |ak| {
                        if (ak == .string) route.api_key = try self.allocator.dupe(u8, ak.string);
                    }
                    try list.append(self.allocator, route);
                }
            }
            self.model_routes = try list.toOwnedSlice(self.allocator);
        }
    }

    // Agents
    if (root.get("agents")) |v| {
        if (v == .array) {
            var list: std.ArrayListUnmanaged(types.NamedAgentConfig) = .empty;
            try list.ensureTotalCapacity(self.allocator, @intCast(v.array.items.len));
            for (v.array.items) |item| {
                if (item == .object) {
                    const name = item.object.get("name") orelse continue;
                    const provider = item.object.get("provider") orelse continue;
                    const model = item.object.get("model") orelse continue;
                    if (name != .string or provider != .string or model != .string) continue;
                    var agent_cfg = types.NamedAgentConfig{
                        .name = try self.allocator.dupe(u8, name.string),
                        .provider = try self.allocator.dupe(u8, provider.string),
                        .model = try self.allocator.dupe(u8, model.string),
                    };
                    if (item.object.get("system_prompt")) |sp| {
                        if (sp == .string) agent_cfg.system_prompt = try self.allocator.dupe(u8, sp.string);
                    }
                    if (item.object.get("api_key")) |ak| {
                        if (ak == .string) agent_cfg.api_key = try self.allocator.dupe(u8, ak.string);
                    }
                    if (item.object.get("temperature")) |t| {
                        if (t == .float) agent_cfg.temperature = t.float;
                        if (t == .integer) agent_cfg.temperature = @floatFromInt(t.integer);
                    }
                    if (item.object.get("max_depth")) |md| {
                        if (md == .integer) agent_cfg.max_depth = @intCast(md.integer);
                    }
                    try list.append(self.allocator, agent_cfg);
                }
            }
            self.agents = try list.toOwnedSlice(self.allocator);
        }
    }

    // MCP servers (object-of-objects format, compatible with Claude Desktop / Cursor)
    if (root.get("mcp_servers")) |mcp_val| {
        if (mcp_val == .object) {
            var mcp_list: std.ArrayListUnmanaged(types.McpServerConfig) = .empty;
            var mcp_it = mcp_val.object.iterator();
            while (mcp_it.next()) |entry| {
                const server_name = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                if (val != .object) continue;
                const cmd = val.object.get("command") orelse continue;
                if (cmd != .string) continue;

                var mcp_cfg = types.McpServerConfig{
                    .name = try self.allocator.dupe(u8, server_name),
                    .command = try self.allocator.dupe(u8, cmd.string),
                };

                // args: string array
                if (val.object.get("args")) |a| {
                    if (a == .array) mcp_cfg.args = try parseStringArray(self.allocator, a.array);
                }

                // env: object of string→string
                if (val.object.get("env")) |e| {
                    if (e == .object) {
                        var env_list: std.ArrayListUnmanaged(types.McpServerConfig.McpEnvEntry) = .empty;
                        var eit = e.object.iterator();
                        while (eit.next()) |ee| {
                            if (ee.value_ptr.* == .string) {
                                try env_list.append(self.allocator, .{
                                    .key = try self.allocator.dupe(u8, ee.key_ptr.*),
                                    .value = try self.allocator.dupe(u8, ee.value_ptr.string),
                                });
                            }
                        }
                        mcp_cfg.env = try env_list.toOwnedSlice(self.allocator);
                    }
                }

                try mcp_list.append(self.allocator, mcp_cfg);
            }
            self.mcp_servers = try mcp_list.toOwnedSlice(self.allocator);
        }
    }

    // Observability
    if (root.get("observability")) |obs| {
        if (obs == .object) {
            if (obs.object.get("backend")) |v| {
                if (v == .string) self.observability.backend = try self.allocator.dupe(u8, v.string);
            }
            if (obs.object.get("otel_endpoint")) |v| {
                if (v == .string) self.observability.otel_endpoint = try self.allocator.dupe(u8, v.string);
            }
            if (obs.object.get("otel_service_name")) |v| {
                if (v == .string) self.observability.otel_service_name = try self.allocator.dupe(u8, v.string);
            }
        }
    }

    // Autonomy
    if (root.get("autonomy")) |aut| {
        if (aut == .object) {
            if (aut.object.get("workspace_only")) |v| {
                if (v == .bool) self.autonomy.workspace_only = v.bool;
            }
            if (aut.object.get("max_actions_per_hour")) |v| {
                if (v == .integer) self.autonomy.max_actions_per_hour = @intCast(v.integer);
            }
            if (aut.object.get("max_cost_per_day_cents")) |v| {
                if (v == .integer) self.autonomy.max_cost_per_day_cents = @intCast(v.integer);
            }
            if (aut.object.get("require_approval_for_medium_risk")) |v| {
                if (v == .bool) self.autonomy.require_approval_for_medium_risk = v.bool;
            }
            if (aut.object.get("block_high_risk_commands")) |v| {
                if (v == .bool) self.autonomy.block_high_risk_commands = v.bool;
            }
            if (aut.object.get("level")) |v| {
                if (v == .string) {
                    if (std.mem.eql(u8, v.string, "read_only")) {
                        self.autonomy.level = .read_only;
                    } else if (std.mem.eql(u8, v.string, "supervised")) {
                        self.autonomy.level = .supervised;
                    } else if (std.mem.eql(u8, v.string, "full")) {
                        self.autonomy.level = .full;
                    }
                }
            }
            if (aut.object.get("allowed_commands")) |v| {
                if (v == .array) self.autonomy.allowed_commands = try parseStringArray(self.allocator, v.array);
            }
            if (aut.object.get("forbidden_paths")) |v| {
                if (v == .array) self.autonomy.forbidden_paths = try parseStringArray(self.allocator, v.array);
            }
            if (aut.object.get("allowed_paths")) |v| {
                if (v == .array) self.autonomy.allowed_paths = try parseStringArray(self.allocator, v.array);
            }
        }
    }

    // Runtime
    if (root.get("runtime")) |rt| {
        if (rt == .object) {
            if (rt.object.get("kind")) |v| {
                if (v == .string) self.runtime.kind = try self.allocator.dupe(u8, v.string);
            }
            if (rt.object.get("docker")) |dk| {
                if (dk == .object) {
                    if (dk.object.get("image")) |v| {
                        if (v == .string) self.runtime.docker.image = try self.allocator.dupe(u8, v.string);
                    }
                    if (dk.object.get("network")) |v| {
                        if (v == .string) self.runtime.docker.network = try self.allocator.dupe(u8, v.string);
                    }
                    if (dk.object.get("memory_limit_mb")) |v| {
                        if (v == .integer) self.runtime.docker.memory_limit_mb = @intCast(v.integer);
                    }
                    if (dk.object.get("read_only_rootfs")) |v| {
                        if (v == .bool) self.runtime.docker.read_only_rootfs = v.bool;
                    }
                    if (dk.object.get("mount_workspace")) |v| {
                        if (v == .bool) self.runtime.docker.mount_workspace = v.bool;
                    }
                }
            }
        }
    }

    // Reliability
    if (root.get("reliability")) |rel| {
        if (rel == .object) {
            if (rel.object.get("provider_retries")) |v| {
                if (v == .integer) self.reliability.provider_retries = @intCast(v.integer);
            }
            if (rel.object.get("provider_backoff_ms")) |v| {
                if (v == .integer) self.reliability.provider_backoff_ms = @intCast(v.integer);
            }
            if (rel.object.get("channel_initial_backoff_secs")) |v| {
                if (v == .integer) self.reliability.channel_initial_backoff_secs = @intCast(v.integer);
            }
            if (rel.object.get("channel_max_backoff_secs")) |v| {
                if (v == .integer) self.reliability.channel_max_backoff_secs = @intCast(v.integer);
            }
            if (rel.object.get("scheduler_poll_secs")) |v| {
                if (v == .integer) self.reliability.scheduler_poll_secs = @intCast(v.integer);
            }
            if (rel.object.get("scheduler_retries")) |v| {
                if (v == .integer) self.reliability.scheduler_retries = @intCast(v.integer);
            }
        }
    }

    // Scheduler
    if (root.get("scheduler")) |sch| {
        if (sch == .object) {
            if (sch.object.get("enabled")) |v| {
                if (v == .bool) self.scheduler.enabled = v.bool;
            }
            if (sch.object.get("max_tasks")) |v| {
                if (v == .integer) self.scheduler.max_tasks = @intCast(v.integer);
            }
            if (sch.object.get("max_concurrent")) |v| {
                if (v == .integer) self.scheduler.max_concurrent = @intCast(v.integer);
            }
        }
    }

    // Agent
    if (root.get("agent")) |ag| {
        if (ag == .object) {
            if (ag.object.get("compact_context")) |v| {
                if (v == .bool) self.agent.compact_context = v.bool;
            }
            if (ag.object.get("max_tool_iterations")) |v| {
                if (v == .integer) self.agent.max_tool_iterations = @intCast(v.integer);
            }
            if (ag.object.get("max_history_messages")) |v| {
                if (v == .integer) self.agent.max_history_messages = @intCast(v.integer);
            }
            if (ag.object.get("parallel_tools")) |v| {
                if (v == .bool) self.agent.parallel_tools = v.bool;
            }
            if (ag.object.get("tool_dispatcher")) |v| {
                if (v == .string) self.agent.tool_dispatcher = try self.allocator.dupe(u8, v.string);
            }
            if (ag.object.get("session_idle_timeout_secs")) |v| {
                if (v == .integer) self.agent.session_idle_timeout_secs = @intCast(v.integer);
            }
            if (ag.object.get("compaction_keep_recent")) |v| {
                if (v == .integer) self.agent.compaction_keep_recent = @intCast(v.integer);
            }
            if (ag.object.get("compaction_max_summary_chars")) |v| {
                if (v == .integer) self.agent.compaction_max_summary_chars = @intCast(v.integer);
            }
            if (ag.object.get("compaction_max_source_chars")) |v| {
                if (v == .integer) self.agent.compaction_max_source_chars = @intCast(v.integer);
            }
            if (ag.object.get("message_timeout_secs")) |v| {
                if (v == .integer) self.agent.message_timeout_secs = @intCast(v.integer);
            }
        }
    }

    // Tools
    if (root.get("tools")) |tl| {
        if (tl == .object) {
            if (tl.object.get("shell_timeout_secs")) |v| {
                if (v == .integer) self.tools.shell_timeout_secs = @intCast(v.integer);
            }
            if (tl.object.get("shell_max_output_bytes")) |v| {
                if (v == .integer) self.tools.shell_max_output_bytes = @intCast(v.integer);
            }
            if (tl.object.get("max_file_size_bytes")) |v| {
                if (v == .integer) self.tools.max_file_size_bytes = @intCast(v.integer);
            }
            if (tl.object.get("web_fetch_max_chars")) |v| {
                if (v == .integer) self.tools.web_fetch_max_chars = @intCast(v.integer);
            }
        }
    }

    // Heartbeat
    if (root.get("heartbeat")) |hb| {
        if (hb == .object) {
            if (hb.object.get("enabled")) |v| {
                if (v == .bool) self.heartbeat.enabled = v.bool;
            }
            if (hb.object.get("interval_minutes")) |v| {
                if (v == .integer) self.heartbeat.interval_minutes = @intCast(v.integer);
            }
        }
    }

    // Memory
    if (root.get("memory")) |mem| {
        if (mem == .object) {
            if (mem.object.get("backend")) |v| {
                if (v == .string) self.memory.backend = try self.allocator.dupe(u8, v.string);
            }
            if (mem.object.get("auto_save")) |v| {
                if (v == .bool) self.memory.auto_save = v.bool;
            }
            if (mem.object.get("hygiene_enabled")) |v| {
                if (v == .bool) self.memory.hygiene_enabled = v.bool;
            }
            if (mem.object.get("archive_after_days")) |v| {
                if (v == .integer) self.memory.archive_after_days = @intCast(v.integer);
            }
            if (mem.object.get("purge_after_days")) |v| {
                if (v == .integer) self.memory.purge_after_days = @intCast(v.integer);
            }
            if (mem.object.get("conversation_retention_days")) |v| {
                if (v == .integer) self.memory.conversation_retention_days = @intCast(v.integer);
            }
            if (mem.object.get("embedding_provider")) |v| {
                if (v == .string) self.memory.embedding_provider = try self.allocator.dupe(u8, v.string);
            }
            if (mem.object.get("embedding_model")) |v| {
                if (v == .string) self.memory.embedding_model = try self.allocator.dupe(u8, v.string);
            }
            if (mem.object.get("embedding_dimensions")) |v| {
                if (v == .integer) self.memory.embedding_dimensions = @intCast(v.integer);
            }
            if (mem.object.get("vector_weight")) |v| {
                if (v == .float) self.memory.vector_weight = v.float;
            }
            if (mem.object.get("keyword_weight")) |v| {
                if (v == .float) self.memory.keyword_weight = v.float;
            }
            if (mem.object.get("embedding_cache_size")) |v| {
                if (v == .integer) self.memory.embedding_cache_size = @intCast(v.integer);
            }
            if (mem.object.get("chunk_max_tokens")) |v| {
                if (v == .integer) self.memory.chunk_max_tokens = @intCast(v.integer);
            }
            if (mem.object.get("response_cache_enabled")) |v| {
                if (v == .bool) self.memory.response_cache_enabled = v.bool;
            }
            if (mem.object.get("response_cache_ttl_minutes")) |v| {
                if (v == .integer) self.memory.response_cache_ttl_minutes = @intCast(v.integer);
            }
            if (mem.object.get("response_cache_max_entries")) |v| {
                if (v == .integer) self.memory.response_cache_max_entries = @intCast(v.integer);
            }
            if (mem.object.get("snapshot_enabled")) |v| {
                if (v == .bool) self.memory.snapshot_enabled = v.bool;
            }
            if (mem.object.get("snapshot_on_hygiene")) |v| {
                if (v == .bool) self.memory.snapshot_on_hygiene = v.bool;
            }
            if (mem.object.get("auto_hydrate")) |v| {
                if (v == .bool) self.memory.auto_hydrate = v.bool;
            }
        }
    }

    // Gateway
    if (root.get("gateway")) |gw| {
        if (gw == .object) {
            if (gw.object.get("port")) |v| {
                if (v == .integer) self.gateway.port = @intCast(v.integer);
            }
            if (gw.object.get("host")) |v| {
                if (v == .string) self.gateway.host = try self.allocator.dupe(u8, v.string);
            }
            if (gw.object.get("require_pairing")) |v| {
                if (v == .bool) self.gateway.require_pairing = v.bool;
            }
            if (gw.object.get("allow_public_bind")) |v| {
                if (v == .bool) self.gateway.allow_public_bind = v.bool;
            }
            if (gw.object.get("pair_rate_limit_per_minute")) |v| {
                if (v == .integer) self.gateway.pair_rate_limit_per_minute = @intCast(v.integer);
            }
            if (gw.object.get("webhook_rate_limit_per_minute")) |v| {
                if (v == .integer) self.gateway.webhook_rate_limit_per_minute = @intCast(v.integer);
            }
            if (gw.object.get("idempotency_ttl_secs")) |v| {
                if (v == .integer) self.gateway.idempotency_ttl_secs = @intCast(v.integer);
            }
            if (gw.object.get("paired_tokens")) |v| {
                if (v == .array) self.gateway.paired_tokens = try parseStringArray(self.allocator, v.array);
            }
        }
    }

    // Cost
    if (root.get("cost")) |co| {
        if (co == .object) {
            if (co.object.get("enabled")) |v| {
                if (v == .bool) self.cost.enabled = v.bool;
            }
            if (co.object.get("daily_limit_usd")) |v| {
                if (v == .float) self.cost.daily_limit_usd = v.float;
                if (v == .integer) self.cost.daily_limit_usd = @floatFromInt(v.integer);
            }
            if (co.object.get("monthly_limit_usd")) |v| {
                if (v == .float) self.cost.monthly_limit_usd = v.float;
                if (v == .integer) self.cost.monthly_limit_usd = @floatFromInt(v.integer);
            }
            if (co.object.get("warn_at_percent")) |v| {
                if (v == .integer) self.cost.warn_at_percent = @intCast(v.integer);
            }
            if (co.object.get("allow_override")) |v| {
                if (v == .bool) self.cost.allow_override = v.bool;
            }
        }
    }

    // Identity
    if (root.get("identity")) |id| {
        if (id == .object) {
            if (id.object.get("format")) |v| {
                if (v == .string) self.identity.format = try self.allocator.dupe(u8, v.string);
            }
            if (id.object.get("aieos_path")) |v| {
                if (v == .string) self.identity.aieos_path = try self.allocator.dupe(u8, v.string);
            }
            if (id.object.get("aieos_inline")) |v| {
                if (v == .string) self.identity.aieos_inline = try self.allocator.dupe(u8, v.string);
            }
        }
    }

    // Composio
    if (root.get("composio")) |comp| {
        if (comp == .object) {
            if (comp.object.get("enabled")) |v| {
                if (v == .bool) self.composio.enabled = v.bool;
            }
            if (comp.object.get("api_key")) |v| {
                if (v == .string) self.composio.api_key = try self.allocator.dupe(u8, v.string);
            }
            if (comp.object.get("entity_id")) |v| {
                if (v == .string) self.composio.entity_id = try self.allocator.dupe(u8, v.string);
            }
        }
    }

    // Secrets
    if (root.get("secrets")) |sec| {
        if (sec == .object) {
            if (sec.object.get("encrypt")) |v| {
                if (v == .bool) self.secrets.encrypt = v.bool;
            }
        }
    }

    // Browser
    if (root.get("browser")) |br| {
        if (br == .object) {
            if (br.object.get("enabled")) |v| {
                if (v == .bool) self.browser.enabled = v.bool;
            }
            if (br.object.get("backend")) |v| {
                if (v == .string) self.browser.backend = try self.allocator.dupe(u8, v.string);
            }
            if (br.object.get("native_headless")) |v| {
                if (v == .bool) self.browser.native_headless = v.bool;
            }
            if (br.object.get("native_webdriver_url")) |v| {
                if (v == .string) self.browser.native_webdriver_url = try self.allocator.dupe(u8, v.string);
            }
            if (br.object.get("native_chrome_path")) |v| {
                if (v == .string) self.browser.native_chrome_path = try self.allocator.dupe(u8, v.string);
            }
            if (br.object.get("session_name")) |v| {
                if (v == .string) self.browser.session_name = try self.allocator.dupe(u8, v.string);
            }
            if (br.object.get("allowed_domains")) |v| {
                if (v == .array) self.browser.allowed_domains = try parseStringArray(self.allocator, v.array);
            }
        }
    }

    // HTTP Request
    if (root.get("http_request")) |hr| {
        if (hr == .object) {
            if (hr.object.get("enabled")) |v| {
                if (v == .bool) self.http_request.enabled = v.bool;
            }
            if (hr.object.get("max_response_size")) |v| {
                if (v == .integer) self.http_request.max_response_size = @intCast(v.integer);
            }
            if (hr.object.get("timeout_secs")) |v| {
                if (v == .integer) self.http_request.timeout_secs = @intCast(v.integer);
            }
        }
    }

    // Hardware
    if (root.get("hardware")) |hw| {
        if (hw == .object) {
            if (hw.object.get("enabled")) |v| {
                if (v == .bool) self.hardware.enabled = v.bool;
            }
            if (hw.object.get("serial_port")) |v| {
                if (v == .string) self.hardware.serial_port = try self.allocator.dupe(u8, v.string);
            }
            if (hw.object.get("baud_rate")) |v| {
                if (v == .integer) self.hardware.baud_rate = @intCast(v.integer);
            }
            if (hw.object.get("probe_target")) |v| {
                if (v == .string) self.hardware.probe_target = try self.allocator.dupe(u8, v.string);
            }
            if (hw.object.get("workspace_datasheets")) |v| {
                if (v == .bool) self.hardware.workspace_datasheets = v.bool;
            }
            if (hw.object.get("transport")) |v| {
                if (v == .string) {
                    if (std.mem.eql(u8, v.string, "none")) {
                        self.hardware.transport = .none;
                    } else if (std.mem.eql(u8, v.string, "native")) {
                        self.hardware.transport = .native;
                    } else if (std.mem.eql(u8, v.string, "serial")) {
                        self.hardware.transport = .serial;
                    } else if (std.mem.eql(u8, v.string, "probe")) {
                        self.hardware.transport = .probe;
                    }
                }
            }
        }
    }

    // Peripherals
    if (root.get("peripherals")) |per| {
        if (per == .object) {
            if (per.object.get("enabled")) |v| {
                if (v == .bool) self.peripherals.enabled = v.bool;
            }
            if (per.object.get("datasheet_dir")) |v| {
                if (v == .string) self.peripherals.datasheet_dir = try self.allocator.dupe(u8, v.string);
            }
        }
    }

    // Security
    if (root.get("security")) |sec| {
        if (sec == .object) {
            if (sec.object.get("sandbox")) |sb| {
                if (sb == .object) {
                    if (sb.object.get("enabled")) |v| {
                        if (v == .bool) self.security.sandbox.enabled = v.bool;
                    }
                    if (sb.object.get("backend")) |v| {
                        if (v == .string) {
                            if (std.mem.eql(u8, v.string, "auto")) {
                                self.security.sandbox.backend = .auto;
                            } else if (std.mem.eql(u8, v.string, "landlock")) {
                                self.security.sandbox.backend = .landlock;
                            } else if (std.mem.eql(u8, v.string, "firejail")) {
                                self.security.sandbox.backend = .firejail;
                            } else if (std.mem.eql(u8, v.string, "bubblewrap")) {
                                self.security.sandbox.backend = .bubblewrap;
                            } else if (std.mem.eql(u8, v.string, "docker")) {
                                self.security.sandbox.backend = .docker;
                            } else if (std.mem.eql(u8, v.string, "none")) {
                                self.security.sandbox.backend = .none;
                            }
                        }
                    }
                }
            }
            if (sec.object.get("resources")) |res| {
                if (res == .object) {
                    if (res.object.get("max_memory_mb")) |v| {
                        if (v == .integer) self.security.resources.max_memory_mb = @intCast(v.integer);
                    }
                    if (res.object.get("max_cpu_time_seconds")) |v| {
                        if (v == .integer) self.security.resources.max_cpu_time_seconds = @intCast(v.integer);
                    }
                    if (res.object.get("max_subprocesses")) |v| {
                        if (v == .integer) self.security.resources.max_subprocesses = @intCast(v.integer);
                    }
                    if (res.object.get("memory_monitoring")) |v| {
                        if (v == .bool) self.security.resources.memory_monitoring = v.bool;
                    }
                }
            }
            if (sec.object.get("audit")) |aud| {
                if (aud == .object) {
                    if (aud.object.get("enabled")) |v| {
                        if (v == .bool) self.security.audit.enabled = v.bool;
                    }
                    if (aud.object.get("log_path")) |v| {
                        if (v == .string) self.security.audit.log_path = try self.allocator.dupe(u8, v.string);
                    }
                    if (aud.object.get("max_size_mb")) |v| {
                        if (v == .integer) self.security.audit.max_size_mb = @intCast(v.integer);
                    }
                    if (aud.object.get("sign_events")) |v| {
                        if (v == .bool) self.security.audit.sign_events = v.bool;
                    }
                }
            }
        }
    }

    // Tunnel
    if (root.get("tunnel")) |tun| {
        if (tun == .object) {
            if (tun.object.get("provider")) |v| {
                if (v == .string) self.tunnel.provider = try self.allocator.dupe(u8, v.string);
            }
        }
    }

    // Providers (object-of-objects: {"openrouter": {"api_key": "..."}, ...})
    if (root.get("providers")) |prov| {
        if (prov == .object) {
            var prov_list: std.ArrayListUnmanaged(types.ProviderEntry) = .empty;
            var prov_it = prov.object.iterator();
            while (prov_it.next()) |entry| {
                const prov_name = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                if (val != .object) continue;
                var pe = types.ProviderEntry{
                    .name = try self.allocator.dupe(u8, prov_name),
                };
                if (val.object.get("api_key")) |ak| {
                    if (ak == .string) pe.api_key = try self.allocator.dupe(u8, ak.string);
                }
                if (val.object.get("api_base")) |ab| {
                    if (ab == .string) pe.api_base = try self.allocator.dupe(u8, ab.string);
                }
                try prov_list.append(self.allocator, pe);
            }
            self.providers = try prov_list.toOwnedSlice(self.allocator);
        }
    }

    // Transcription
    if (root.get("transcription")) |tr| {
        if (tr == .object) {
            if (tr.object.get("provider")) |v| {
                if (v == .string) self.transcription.provider = try self.allocator.dupe(u8, v.string);
            }
            if (tr.object.get("model")) |v| {
                if (v == .string) self.transcription.model = try self.allocator.dupe(u8, v.string);
            }
            if (tr.object.get("endpoint")) |v| {
                if (v == .string) self.transcription.endpoint = try self.allocator.dupe(u8, v.string);
            }
            if (tr.object.get("language")) |v| {
                if (v == .string) self.transcription.language = try self.allocator.dupe(u8, v.string);
            }
        }
    }

    // ── Legacy auto-migration ────────────────────────────────────
    // Top-level "api_key" → providers.{default_provider}.api_key
    if (root.get("api_key")) |v| {
        if (v == .string and v.string.len > 0) {
            if (self.getProviderKey(self.default_provider) == null) {
                std.log.warn("DEPRECATED: top-level 'api_key' found. Please move to 'providers.<provider>.api_key'", .{});
                try appendProviderField(self, self.default_provider, try self.allocator.dupe(u8, v.string), null);
            }
        }
    }
    // Top-level "api_url" → providers.{default_provider}.api_base
    if (root.get("api_url")) |v| {
        if (v == .string and v.string.len > 0) {
            if (self.getProviderBase(self.default_provider) == null) {
                std.log.warn("DEPRECATED: top-level 'api_url' found. Please move to 'providers.<provider>.api_base'", .{});
                try appendProviderField(self, self.default_provider, null, try self.allocator.dupe(u8, v.string));
            }
        }
    }
    // Top-level "groq_api_key" → providers.groq.api_key
    if (root.get("groq_api_key")) |v| {
        if (v == .string and v.string.len > 0) {
            if (self.getProviderKey("groq") == null) {
                std.log.warn("DEPRECATED: top-level 'groq_api_key' found. Please move to 'providers.<provider>.api_key'", .{});
                try appendProviderField(self, "groq", try self.allocator.dupe(u8, v.string), null);
            }
        }
    }

    // Channels
    if (root.get("channels")) |ch| {
        if (ch == .object) {
            if (ch.object.get("cli")) |v| {
                if (v == .bool) self.channels.cli = v.bool;
            }
            if (ch.object.get("telegram")) |tg| {
                if (tg == .object) {
                    if (tg.object.get("bot_token")) |tok| {
                        if (tok == .string) {
                            self.channels.telegram = .{ .bot_token = try self.allocator.dupe(u8, tok.string) };
                        }
                    }
                    if (self.channels.telegram) |*tg_cfg| {
                        if (tg.object.get("allowed_users")) |v| {
                            if (v == .array) tg_cfg.allowed_users = try parseStringArray(self.allocator, v.array);
                        }
                        if (tg.object.get("reply_in_private")) |v| {
                            if (v == .bool) tg_cfg.reply_in_private = v.bool;
                        }
                        if (tg.object.get("proxy")) |v| {
                            if (v == .string) tg_cfg.proxy = try self.allocator.dupe(u8, v.string);
                        }
                    }
                }
            }
        }
    }
}

/// Helper: append or merge a ProviderEntry for the given provider name.
/// If a provider with that name already exists, merge missing fields; otherwise create a new entry.
fn appendProviderField(self: *Config, name: []const u8, api_key: ?[]const u8, api_base: ?[]const u8) !void {
    const old = self.providers;
    var list: std.ArrayListUnmanaged(types.ProviderEntry) = .empty;
    try list.ensureTotalCapacity(self.allocator, @intCast(old.len + 1));

    var found = false;
    for (old) |e| {
        if (std.mem.eql(u8, e.name, name)) {
            found = true;
            // Merge: keep existing values, fill in missing ones
            try list.append(self.allocator, .{
                .name = e.name,
                .api_key = e.api_key orelse api_key,
                .api_base = e.api_base orelse api_base,
            });
        } else {
            try list.append(self.allocator, e);
        }
    }

    if (!found) {
        try list.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .api_key = api_key,
            .api_base = api_base,
        });
    }

    self.providers = try list.toOwnedSlice(self.allocator);
    // Free old slice (not the elements — they're reused)
    if (old.len > 0) self.allocator.free(old);
}
