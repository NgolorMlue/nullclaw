const std = @import("std");

// ── Autonomy Level ──────────────────────────────────────────────

pub const AutonomyLevel = enum {
    read_only,
    supervised,
    full,
};

// ── Hardware Transport ──────────────────────────────────────────

pub const HardwareTransport = enum {
    none,
    native,
    serial,
    probe,
};

// ── Sandbox Backend ─────────────────────────────────────────────

pub const SandboxBackend = enum {
    auto,
    landlock,
    firejail,
    bubblewrap,
    docker,
    none,
};

// ── Provider entry (for "providers" config section) ─────────────

pub const ProviderEntry = struct {
    name: []const u8,
    api_key: ?[]const u8 = null,
    api_base: ?[]const u8 = null,
};

// ── Transcription config ────────────────────────────────────────

pub const TranscriptionConfig = struct {
    provider: []const u8 = "groq",
    model: []const u8 = "whisper-large-v3",
    endpoint: ?[]const u8 = null,
    language: ?[]const u8 = null,
};

// ── Sub-config structs ──────────────────────────────────────────

pub const ObservabilityConfig = struct {
    backend: []const u8 = "none",
    otel_endpoint: ?[]const u8 = null,
    otel_service_name: ?[]const u8 = null,
};

pub const AutonomyConfig = struct {
    level: AutonomyLevel = .supervised,
    workspace_only: bool = true,
    max_actions_per_hour: u32 = 20,
    max_cost_per_day_cents: u32 = 500,
    require_approval_for_medium_risk: bool = true,
    block_high_risk_commands: bool = true,
    allowed_commands: []const []const u8 = &.{},
    forbidden_paths: []const []const u8 = &.{},
    /// Additional directories (absolute paths) the agent may access beyond workspace_dir.
    /// Resolved via realpath at check time; system-critical paths are always blocked.
    allowed_paths: []const []const u8 = &.{},
};

pub const DockerRuntimeConfig = struct {
    image: []const u8 = "alpine:3.20",
    network: []const u8 = "none",
    memory_limit_mb: ?u64 = 512,
    cpu_limit: ?f64 = 1.0,
    read_only_rootfs: bool = true,
    mount_workspace: bool = true,
};

pub const RuntimeConfig = struct {
    kind: []const u8 = "native",
    docker: DockerRuntimeConfig = .{},
};

pub const ModelFallbackEntry = struct {
    model: []const u8,
    fallbacks: []const []const u8,
};

pub const ReliabilityConfig = struct {
    provider_retries: u32 = 2,
    provider_backoff_ms: u64 = 500,
    channel_initial_backoff_secs: u64 = 2,
    channel_max_backoff_secs: u64 = 60,
    scheduler_poll_secs: u64 = 15,
    scheduler_retries: u32 = 2,
    fallback_providers: []const []const u8 = &.{},
    api_keys: []const []const u8 = &.{},
    model_fallbacks: []const ModelFallbackEntry = &.{},
};

pub const SchedulerConfig = struct {
    enabled: bool = true,
    max_tasks: u32 = 64,
    max_concurrent: u32 = 4,
};

pub const AgentConfig = struct {
    compact_context: bool = false,
    max_tool_iterations: u32 = 10,
    max_history_messages: u32 = 50,
    parallel_tools: bool = false,
    tool_dispatcher: []const u8 = "auto",
    token_limit: u64 = 128_000,
    session_idle_timeout_secs: u64 = 1800, // evict idle sessions after 30 min
    compaction_keep_recent: u32 = 20,
    compaction_max_summary_chars: u32 = 2_000,
    compaction_max_source_chars: u32 = 12_000,
    /// Max seconds to wait for an LLM HTTP response (curl --max-time). 0 = no limit.
    message_timeout_secs: u64 = 300,
};

pub const ToolsConfig = struct {
    shell_timeout_secs: u64 = 60,
    shell_max_output_bytes: u32 = 1_048_576, // 1MB
    max_file_size_bytes: u32 = 10_485_760, // 10MB — shared file_read/edit/append
    web_fetch_max_chars: u32 = 50_000,
};

pub const ModelRouteConfig = struct {
    hint: []const u8,
    provider: []const u8,
    model: []const u8,
    api_key: ?[]const u8 = null,
};

pub const HeartbeatConfig = struct {
    enabled: bool = false,
    interval_minutes: u32 = 30,
};

pub const CronConfig = struct {
    enabled: bool = false,
    interval_minutes: u32 = 30,
    max_run_history: u32 = 50,
};

// ── Channel configs ─────────────────────────────────────────────

pub const TelegramConfig = struct {
    bot_token: []const u8,
    allowed_users: []const []const u8 = &.{},
    /// Use reply-to in private (1:1) chats. Groups always use reply-to.
    reply_in_private: bool = true,
    /// Optional SOCKS5/HTTP proxy URL for all Telegram API requests (e.g. "socks5://host:port").
    proxy: ?[]const u8 = null,
};

pub const DiscordConfig = struct {
    bot_token: []const u8,
    guild_id: ?[]const u8 = null,
    listen_to_bots: bool = false,
    allowed_users: []const []const u8 = &.{},
    mention_only: bool = false,
    intents: u32 = 37377, // GUILDS|GUILD_MESSAGES|MESSAGE_CONTENT|DIRECT_MESSAGES
};

pub const SlackConfig = struct {
    bot_token: []const u8,
    app_token: ?[]const u8 = null,
    channel_id: ?[]const u8 = null,
    allowed_users: []const []const u8 = &.{},
    dm_policy: []const u8 = "allow",
    group_policy: []const u8 = "mention_only",
};

pub const WebhookConfig = struct {
    port: u16 = 8080,
    secret: ?[]const u8 = null,
};

pub const IMessageConfig = struct {
    allowed_contacts: []const []const u8 = &.{},
    enabled: bool = false,
};

pub const MatrixConfig = struct {
    homeserver: []const u8,
    access_token: []const u8,
    room_id: []const u8,
    allowed_users: []const []const u8 = &.{},
};

pub const WhatsAppConfig = struct {
    access_token: []const u8,
    phone_number_id: []const u8,
    verify_token: []const u8,
    app_secret: ?[]const u8 = null,
    allowed_numbers: []const []const u8 = &.{},
};

pub const IrcConfig = struct {
    server: []const u8,
    port: u16 = 6697,
    nickname: []const u8,
    username: ?[]const u8 = null,
    channels: []const []const u8 = &.{},
    allowed_users: []const []const u8 = &.{},
    server_password: ?[]const u8 = null,
    nickserv_password: ?[]const u8 = null,
    sasl_password: ?[]const u8 = null,
    verify_tls: bool = true,
};

pub const LarkReceiveMode = enum {
    websocket,
    webhook,
};

pub const LarkConfig = struct {
    app_id: []const u8,
    app_secret: []const u8,
    encrypt_key: ?[]const u8 = null,
    verification_token: ?[]const u8 = null,
    use_feishu: bool = false,
    allowed_users: []const []const u8 = &.{},
    receive_mode: LarkReceiveMode = .websocket,
    port: ?u16 = null,
};

pub const DingTalkConfig = struct {
    client_id: []const u8,
    client_secret: []const u8,
    allowed_users: []const []const u8 = &.{},
};

pub const ChannelsConfig = struct {
    cli: bool = true,
    telegram: ?TelegramConfig = null,
    discord: ?DiscordConfig = null,
    slack: ?SlackConfig = null,
    webhook: ?WebhookConfig = null,
    imessage: ?IMessageConfig = null,
    matrix: ?MatrixConfig = null,
    whatsapp: ?WhatsAppConfig = null,
    irc: ?IrcConfig = null,
    lark: ?LarkConfig = null,
    dingtalk: ?DingTalkConfig = null,
};

// ── Memory config ───────────────────────────────────────────────

pub const MemoryConfig = struct {
    backend: []const u8 = "sqlite",
    auto_save: bool = true,
    hygiene_enabled: bool = true,
    archive_after_days: u32 = 7,
    purge_after_days: u32 = 30,
    conversation_retention_days: u32 = 30,
    embedding_provider: []const u8 = "none",
    embedding_model: []const u8 = "text-embedding-3-small",
    embedding_dimensions: u32 = 1536,
    vector_weight: f64 = 0.7,
    keyword_weight: f64 = 0.3,
    embedding_cache_size: u32 = 10_000,
    chunk_max_tokens: u32 = 512,
    response_cache_enabled: bool = false,
    response_cache_ttl_minutes: u32 = 60,
    response_cache_max_entries: u32 = 5_000,
    snapshot_enabled: bool = false,
    snapshot_on_hygiene: bool = false,
    auto_hydrate: bool = true,
};

// ── Tunnel config ───────────────────────────────────────────────

pub const TunnelConfig = struct {
    provider: []const u8 = "none",
};

// ── Gateway config ──────────────────────────────────────────────

pub const GatewayConfig = struct {
    port: u16 = 3000,
    host: []const u8 = "127.0.0.1",
    require_pairing: bool = true,
    allow_public_bind: bool = false,
    pair_rate_limit_per_minute: u32 = 10,
    webhook_rate_limit_per_minute: u32 = 60,
    idempotency_ttl_secs: u64 = 300,
    paired_tokens: []const []const u8 = &.{},
};

// ── Composio config ─────────────────────────────────────────────

pub const ComposioConfig = struct {
    enabled: bool = false,
    api_key: ?[]const u8 = null,
    entity_id: []const u8 = "default",
};

// ── Secrets config ──────────────────────────────────────────────

pub const SecretsConfig = struct {
    encrypt: bool = true,
};

// ── Browser config ──────────────────────────────────────────────

pub const BrowserComputerUseConfig = struct {
    endpoint: []const u8 = "http://127.0.0.1:8787/v1/actions",
    api_key: ?[]const u8 = null,
    timeout_ms: u64 = 15_000,
    allow_remote_endpoint: bool = false,
    max_coordinate_x: ?i64 = null,
    max_coordinate_y: ?i64 = null,
};

pub const BrowserConfig = struct {
    enabled: bool = false,
    session_name: ?[]const u8 = null,
    backend: []const u8 = "agent_browser",
    native_headless: bool = true,
    native_webdriver_url: []const u8 = "http://127.0.0.1:9515",
    native_chrome_path: ?[]const u8 = null,
    computer_use: BrowserComputerUseConfig = .{},
    allowed_domains: []const []const u8 = &.{},
};

// ── HTTP request config ─────────────────────────────────────────

pub const HttpRequestConfig = struct {
    enabled: bool = false,
    max_response_size: u32 = 1_000_000,
    timeout_secs: u64 = 30,
    allowed_domains: []const []const u8 = &.{},
};

// ── Identity config ─────────────────────────────────────────────

pub const IdentityConfig = struct {
    format: []const u8 = "openclaw",
    aieos_path: ?[]const u8 = null,
    aieos_inline: ?[]const u8 = null,
};

// ── Cost config ─────────────────────────────────────────────────

pub const CostConfig = struct {
    enabled: bool = false,
    daily_limit_usd: f64 = 10.0,
    monthly_limit_usd: f64 = 100.0,
    warn_at_percent: u8 = 80,
    allow_override: bool = false,
};

// ── Peripherals config ──────────────────────────────────────────

pub const PeripheralBoardConfig = struct {
    board: []const u8 = "",
    transport: []const u8 = "serial",
    path: ?[]const u8 = null,
    baud: u32 = 115200,
};

pub const PeripheralsConfig = struct {
    enabled: bool = false,
    datasheet_dir: ?[]const u8 = null,
    boards: []const PeripheralBoardConfig = &.{},
};

// ── Hardware config ─────────────────────────────────────────────

pub const HardwareConfig = struct {
    enabled: bool = false,
    transport: HardwareTransport = .none,
    serial_port: ?[]const u8 = null,
    baud_rate: u32 = 115200,
    probe_target: ?[]const u8 = null,
    workspace_datasheets: bool = false,
};

// ── Security sub-configs ────────────────────────────────────────

pub const SandboxConfig = struct {
    enabled: ?bool = null,
    backend: SandboxBackend = .auto,
    firejail_args: []const []const u8 = &.{},
};

pub const ResourceLimitsConfig = struct {
    max_memory_mb: u32 = 512,
    max_cpu_percent: u32 = 80,
    max_disk_mb: u32 = 1024,
    max_cpu_time_seconds: u64 = 60,
    max_subprocesses: u32 = 10,
    memory_monitoring: bool = true,
};

pub const AuditConfig = struct {
    enabled: bool = true,
    log_file: ?[]const u8 = null,
    log_path: []const u8 = "audit.log",
    retention_days: u32 = 90,
    max_size_mb: u32 = 100,
    sign_events: bool = false,
};

pub const SecurityConfig = struct {
    sandbox: SandboxConfig = .{},
    resources: ResourceLimitsConfig = .{},
    audit: AuditConfig = .{},
};

// ── Delegate agent config ───────────────────────────────────────

pub const DelegateAgentConfig = struct {
    name: []const u8 = "",
    provider: []const u8,
    model: []const u8,
    system_prompt: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    temperature: ?f64 = null,
    max_depth: u32 = 3,
};

// ── Named agent config (for agents map in JSON) ────────────────

pub const NamedAgentConfig = struct {
    name: []const u8,
    provider: []const u8,
    model: []const u8,
    system_prompt: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    temperature: ?f64 = null,
    max_depth: u32 = 3,
};

// ── MCP Server Config ──────────────────────────────────────────

pub const McpServerConfig = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: []const McpEnvEntry = &.{},

    pub const McpEnvEntry = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ── Model Pricing ──────────────────────────────────────────────

pub const ModelPricing = struct {
    model: []const u8 = "",
    input_cost_per_1k: f64 = 0.0,
    output_cost_per_1k: f64 = 0.0,
};
