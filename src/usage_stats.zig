//! Persistent local usage statistics for sushi.
//! Aggregates completed requests by local day and model, with 400-day retention.
//! Supports Session vs All-Time views and date-range filtering (Today, Yesterday, 7d, 30d, All).

const std = @import("std");

pub const RETENTION_DAYS: usize = 400;
pub const MAX_MODELS_PER_DAY: usize = 16;
pub const MAX_MODEL_NAME_LEN: usize = 64;

pub const Range = enum {
    today,
    yesterday,
    days_7,
    days_30,
    all,

    pub fn fromString(str: []const u8) Range {
        if (std.mem.eql(u8, str, "today")) return .today;
        if (std.mem.eql(u8, str, "yesterday")) return .yesterday;
        if (std.mem.eql(u8, str, "7d") or std.mem.eql(u8, str, "days_7")) return .days_7;
        if (std.mem.eql(u8, str, "30d") or std.mem.eql(u8, str, "days_30")) return .days_30;
        return .all;
    }

    pub fn asString(self: Range) []const u8 {
        return switch (self) {
            .today => "today",
            .yesterday => "yesterday",
            .days_7 => "7d",
            .days_30 => "30d",
            .all => "all",
        };
    }
};

pub const tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const isize, result: *tm) ?*tm;

/// Formats unix seconds into local date "YYYY-MM-DD".
pub fn formatDateLocal(buf: *[10]u8, ts_sec: i64) []const u8 {
    const t: isize = @intCast(ts_sec);
    var tm_val: tm = undefined;
    if (localtime_r(&t, &tm_val) == null) {
        @memcpy(buf, "1970-01-01");
        return buf;
    }
    const year = @as(u32, @intCast(tm_val.tm_year + 1900));
    const mon = @as(u32, @intCast(tm_val.tm_mon + 1));
    const mday = @as(u32, @intCast(tm_val.tm_mday));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, mon, mday }) catch "1970-01-01";
}

pub const ModelStats = struct {
    requests: u64 = 0,
    prompt_tokens: u64 = 0,
    cached_tokens: u64 = 0,
    output_tokens: u64 = 0,
    prefill_time_ms: u64 = 0,
    decode_time_ms: u64 = 0,

    pub fn add(self: *ModelStats, other: ModelStats) void {
        self.requests +|= other.requests;
        self.prompt_tokens +|= other.prompt_tokens;
        self.cached_tokens +|= other.cached_tokens;
        self.output_tokens +|= other.output_tokens;
        self.prefill_time_ms +|= other.prefill_time_ms;
        self.decode_time_ms +|= other.decode_time_ms;
    }

    pub fn totalTokens(self: ModelStats) u64 {
        return self.prompt_tokens +| self.output_tokens;
    }

    /// Cache efficiency in percent (0.0 to 100.0)
    pub fn cacheEfficiency(self: ModelStats) f64 {
        if (self.prompt_tokens == 0) return 0.0;
        const c: f64 = @floatFromInt(self.cached_tokens);
        const p: f64 = @floatFromInt(self.prompt_tokens);
        return @min(100.0, (c / p) * 100.0);
    }

    /// Prompt processing rate (excl. cached tokens) in tokens per second
    pub fn promptProcessingTokPerSec(self: ModelStats) f64 {
        if (self.prefill_time_ms == 0) return 0.0;
        const non_cached = if (self.prompt_tokens > self.cached_tokens) self.prompt_tokens - self.cached_tokens else 0;
        const tok: f64 = @floatFromInt(non_cached);
        const sec: f64 = @as(f64, @floatFromInt(self.prefill_time_ms)) / 1000.0;
        return tok / sec;
    }

    /// Token generation rate in tokens per second
    pub fn tokenGenerationTokPerSec(self: ModelStats) f64 {
        if (self.decode_time_ms == 0) return 0.0;
        const tok: f64 = @floatFromInt(self.output_tokens);
        const sec: f64 = @as(f64, @floatFromInt(self.decode_time_ms)) / 1000.0;
        return tok / sec;
    }
};

pub const ModelEntry = struct {
    name: [MAX_MODEL_NAME_LEN]u8 = undefined,
    name_len: u8 = 0,
    stats: ModelStats = .{},

    pub fn getName(self: *const ModelEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const DayBucket = struct {
    date: [10]u8 = undefined, // "YYYY-MM-DD"
    models: [MAX_MODELS_PER_DAY]ModelEntry = undefined,
    models_len: usize = 0,
    total: ModelStats = .{},

    pub fn record(self: *DayBucket, model_name: []const u8, stats: ModelStats) void {
        self.total.add(stats);
        for (self.models[0..self.models_len]) |*m| {
            if (std.mem.eql(u8, m.getName(), model_name)) {
                m.stats.add(stats);
                return;
            }
        }
        if (self.models_len < MAX_MODELS_PER_DAY) {
            var entry = &self.models[self.models_len];
            const copy_len = @min(model_name.len, entry.name.len);
            @memcpy(entry.name[0..copy_len], model_name[0..copy_len]);
            entry.name_len = @intCast(copy_len);
            entry.stats = stats;
            self.models_len += 1;
        }
    }

    pub fn query(self: *const DayBucket, model_filter: ?[]const u8) ModelStats {
        if (model_filter) |filter| {
            if (filter.len == 0 or std.mem.eql(u8, filter, "all") or std.mem.eql(u8, filter, "All Models")) {
                return self.total;
            }
            for (self.models[0..self.models_len]) |*m| {
                if (std.mem.eql(u8, m.getName(), filter) or std.mem.endsWith(u8, filter, m.getName())) {
                    return m.stats;
                }
            }
            return .{};
        }
        return self.total;
    }
};

pub const UsageStore = struct {
    mutex: std.c.pthread_mutex_t = .{},
    days: [RETENTION_DAYS]DayBucket = undefined,
    days_len: usize = 0,
    dirty: bool = false,

    fn lock(self: *UsageStore) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }

    fn unlock(self: *UsageStore) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    /// Finds or creates a DayBucket for the given date. Caller must hold lock.
    fn findOrCreateDay(self: *UsageStore, date: []const u8) ?*DayBucket {
        for (self.days[0..self.days_len]) |*b| {
            if (std.mem.eql(u8, &b.date, date)) return b;
        }
        if (self.days_len < RETENTION_DAYS) {
            const b = &self.days[self.days_len];
            @memcpy(&b.date, date);
            b.models_len = 0;
            b.total = .{};
            self.days_len += 1;
            return b;
        }
        // Purge oldest day (shift left)
        std.mem.copyForwards(DayBucket, self.days[0 .. RETENTION_DAYS - 1], self.days[1..RETENTION_DAYS]);
        const b = &self.days[RETENTION_DAYS - 1];
        @memcpy(&b.date, date);
        b.models_len = 0;
        b.total = .{};
        return b;
    }

    pub fn recordRequest(
        self: *UsageStore,
        timestamp_ms: i64,
        model_name: []const u8,
        prompt_tokens: u32,
        cached_tokens: u32,
        completion_tokens: u32,
        prefill_ns: u64,
        decode_ns: u64,
    ) void {
        self.lock();
        defer self.unlock();

        var date_buf: [10]u8 = undefined;
        const date = formatDateLocal(&date_buf, @divTrunc(timestamp_ms, 1000));

        const bucket = self.findOrCreateDay(date) orelse return;
        const stats: ModelStats = .{
            .requests = 1,
            .prompt_tokens = prompt_tokens,
            .cached_tokens = @min(cached_tokens, prompt_tokens),
            .output_tokens = completion_tokens,
            .prefill_time_ms = @divTrunc(prefill_ns, 1_000_000),
            .decode_time_ms = @divTrunc(decode_ns, 1_000_000),
        };
        bucket.record(model_name, stats);
        self.dirty = true;
    }

    pub fn query(self: *UsageStore, now_sec: i64, range: Range, model_filter: ?[]const u8) ModelStats {
        self.lock();
        defer self.unlock();

        var today_buf: [10]u8 = undefined;
        var yest_buf: [10]u8 = undefined;
        var cut7_buf: [10]u8 = undefined;
        var cut30_buf: [10]u8 = undefined;

        const today = formatDateLocal(&today_buf, now_sec);
        const yest = formatDateLocal(&yest_buf, now_sec - 86400);
        const cut7 = formatDateLocal(&cut7_buf, now_sec - 6 * 86400);
        const cut30 = formatDateLocal(&cut30_buf, now_sec - 29 * 86400);

        var agg: ModelStats = .{};
        for (self.days[0..self.days_len]) |*b| {
            const b_date: []const u8 = &b.date;
            const match = switch (range) {
                .today => std.mem.order(u8, b_date, today) != .lt,
                .yesterday => std.mem.eql(u8, b_date, yest),
                .days_7 => std.mem.order(u8, b_date, cut7) != .lt,
                .days_30 => std.mem.order(u8, b_date, cut30) != .lt,
                .all => true,
            };
            if (match) {
                agg.add(b.query(model_filter));
            }
        }
        return agg;
    }

    /// Emits JSON payload for `/v1/usage`.
    pub fn writeJson(
        self: *UsageStore,
        now_sec: i64,
        range: Range,
        model_filter: ?[]const u8,
        w: *std.Io.Writer,
    ) !void {
        const stats = self.query(now_sec, range, model_filter);

        try w.print("{{\"range\":\"{s}\",\"requests\":{d},\"total_tokens\":{d},\"prompt_tokens\":{d},\"output_tokens\":{d},\"cached_tokens\":{d},\"cache_efficiency_pct\":{d:.1},\"prefill_speed_tok_s\":{d:.1},\"decode_speed_tok_s\":{d:.1},\"models\":[", .{
            range.asString(),
            stats.requests,
            stats.totalTokens(),
            stats.prompt_tokens,
            stats.output_tokens,
            stats.cached_tokens,
            stats.cacheEfficiency(),
            stats.promptProcessingTokPerSec(),
            stats.tokenGenerationTokPerSec(),
        });

        // Collect distinct models
        self.lock();
        defer self.unlock();

        var first = true;
        var distinct_buf: [128][]const u8 = undefined;
        var distinct_len: usize = 0;

        for (self.days[0..self.days_len]) |*b| {
            for (b.models[0..b.models_len]) |*m| {
                const name = m.getName();
                var seen = false;
                for (distinct_buf[0..distinct_len]) |s| {
                    if (std.mem.eql(u8, s, name)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    if (distinct_len < distinct_buf.len) {
                        distinct_buf[distinct_len] = name;
                        distinct_len += 1;
                    }
                    if (first) {
                        try w.print("\"{s}\"", .{name});
                        first = false;
                    } else {
                        try w.print(",\"{s}\"", .{name});
                    }
                }
            }
        }
        try w.writeAll("]}");
    }

    /// Encodes usage history to JSON for disk persistence.
    pub fn writePersistence(self: *UsageStore, w: *std.Io.Writer) !void {
        self.lock();
        defer self.unlock();

        try w.writeAll("{\"version\":1,\"days\":[");
        for (self.days[0..self.days_len], 0..) |*b, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"date\":\"{s}\",\"total\":{{\"requests\":{d},\"prompt_tokens\":{d},\"cached_tokens\":{d},\"output_tokens\":{d},\"prefill_time_ms\":{d},\"decode_time_ms\":{d}}},\"models\":[", .{
                b.date,
                b.total.requests,
                b.total.prompt_tokens,
                b.total.cached_tokens,
                b.total.output_tokens,
                b.total.prefill_time_ms,
                b.total.decode_time_ms,
            });
            for (b.models[0..b.models_len], 0..) |*m, j| {
                if (j > 0) try w.writeAll(",");
                try w.print("{{\"name\":\"{s}\",\"requests\":{d},\"prompt_tokens\":{d},\"cached_tokens\":{d},\"output_tokens\":{d},\"prefill_time_ms\":{d},\"decode_time_ms\":{d}}}", .{
                    m.getName(),
                    m.stats.requests,
                    m.stats.prompt_tokens,
                    m.stats.cached_tokens,
                    m.stats.output_tokens,
                    m.stats.prefill_time_ms,
                    m.stats.decode_time_ms,
                });
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }

    /// Loads history from JSON bytes.
    pub fn loadFromJson(self: *UsageStore, json_bytes: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_bytes, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidFormat;
        const days_val = root.object.get("days") orelse return;
        if (days_val != .array) return;

        self.lock();
        defer self.unlock();

        self.days_len = 0;
        for (days_val.array.items) |item| {
            if (self.days_len >= RETENTION_DAYS) break;
            if (item != .object) continue;
            const date_str = item.object.get("date") orelse continue;
            if (date_str != .string or date_str.string.len != 10) continue;

            var bucket = &self.days[self.days_len];
            @memcpy(&bucket.date, date_str.string[0..10]);
            bucket.models_len = 0;
            bucket.total = .{};

            if (item.object.get("total")) |tot| {
                if (tot == .object) {
                    bucket.total = parseStats(tot);
                }
            }

            if (item.object.get("models")) |models_arr| {
                if (models_arr == .array) {
                    for (models_arr.array.items) |m_obj| {
                        if (bucket.models_len >= MAX_MODELS_PER_DAY) break;
                        if (m_obj != .object) continue;
                        const name_val = m_obj.object.get("name") orelse continue;
                        if (name_val != .string) continue;

                        var entry = &bucket.models[bucket.models_len];
                        const c_len = @min(name_val.string.len, entry.name.len);
                        @memcpy(entry.name[0..c_len], name_val.string[0..c_len]);
                        entry.name_len = @intCast(c_len);
                        entry.stats = parseStats(m_obj);
                        bucket.models_len += 1;
                    }
                }
            }
            self.days_len += 1;
        }
    }

    pub fn nowMs() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
    }

    pub fn recordRequestNow(
        self: *UsageStore,
        model_name: []const u8,
        prompt_tokens: u32,
        cached_tokens: u32,
        completion_tokens: u32,
        prefill_ns: u64,
        decode_ns: u64,
    ) void {
        self.recordRequest(nowMs(), model_name, prompt_tokens, cached_tokens, completion_tokens, prefill_ns, decode_ns);
    }

    pub fn loadDefault(self: *UsageStore) void {
        const home = homeDir();
        var path_buf: [512]u8 = undefined;
        const path_slice = std.fmt.bufPrint(&path_buf, "{s}/.sushi/usage_history.json\x00", .{home}) catch return;
        const fd = std.c.open(@ptrCast(path_slice.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return;
        defer _ = std.c.close(fd);

        var buf: [1024 * 1024]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) return;
        self.loadFromJson(buf[0..@intCast(n)]) catch return;
    }

    pub fn storeDefault(self: *UsageStore) void {
        if (!self.dirty) return;
        const home = homeDir();

        var dir_buf: [512]u8 = undefined;
        const dir_slice = std.fmt.bufPrint(&dir_buf, "{s}/.sushi\x00", .{home}) catch return;
        _ = std.c.mkdir(@ptrCast(dir_slice.ptr), 0o755);

        var tmp_path_buf: [512]u8 = undefined;
        var final_path_buf: [512]u8 = undefined;
        const tmp_slice = std.fmt.bufPrint(&tmp_path_buf, "{s}/.sushi/usage_history.json.tmp\x00", .{home}) catch return;
        const final_slice = std.fmt.bufPrint(&final_path_buf, "{s}/.sushi/usage_history.json\x00", .{home}) catch return;

        var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer out.deinit();
        self.writePersistence(&out.writer) catch return;

        const fd = std.c.open(@ptrCast(tmp_slice.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return;
        _ = std.c.write(fd, out.written().ptr, out.written().len);
        _ = std.c.close(fd);

        _ = std.c.rename(@ptrCast(tmp_slice.ptr), @ptrCast(final_slice.ptr));
        self.dirty = false;
    }
};

fn parseStats(obj: std.json.Value) ModelStats {
    var s: ModelStats = .{};
    if (obj.object.get("requests")) |v| if (v == .integer) { s.requests = @intCast(v.integer); };
    if (obj.object.get("prompt_tokens")) |v| if (v == .integer) { s.prompt_tokens = @intCast(v.integer); };
    if (obj.object.get("cached_tokens")) |v| if (v == .integer) { s.cached_tokens = @intCast(v.integer); };
    if (obj.object.get("output_tokens")) |v| if (v == .integer) { s.output_tokens = @intCast(v.integer); };
    if (obj.object.get("prefill_time_ms")) |v| if (v == .integer) { s.prefill_time_ms = @intCast(v.integer); };
    if (obj.object.get("decode_time_ms")) |v| if (v == .integer) { s.decode_time_ms = @intCast(v.integer); };
    return s;
}

fn homeDir() []const u8 {
    return std.mem.span(std.c.getenv("HOME") orelse return "/tmp");
}

pub var global_store: UsageStore = .{};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "formatDateLocal formats unix timestamp to YYYY-MM-DD" {
    var buf: [10]u8 = undefined;
    const d = formatDateLocal(&buf, 1700000000); // 2023-11-14 or 2023-11-15 depending on tz
    try testing.expectEqual(@as(usize, 10), d.len);
    try testing.expect(d[4] == '-' and d[7] == '-');
}

test "UsageStore records requests and aggregates by date and range" {
    var store: UsageStore = .{};
    const now_ms: i64 = 1730592000000; // a known timestamp
    const now_sec: i64 = @divTrunc(now_ms, 1000);

    store.recordRequest(now_ms, "qwen4_exp", 1000, 800, 200, 500_000_000, 2_000_000_000);
    store.recordRequest(now_ms, "qwen4_exp", 500, 0, 100, 300_000_000, 1_000_000_000);

    const today_stats = store.query(now_sec, .today, null);
    try testing.expectEqual(@as(u64, 2), today_stats.requests);
    try testing.expectEqual(@as(u64, 1500), today_stats.prompt_tokens);
    try testing.expectEqual(@as(u64, 800), today_stats.cached_tokens);
    try testing.expectEqual(@as(u64, 300), today_stats.output_tokens);
    try testing.expectEqual(@as(u64, 1800), today_stats.totalTokens());

    // Efficiency: 800 / 1500 = 53.33%
    const eff = today_stats.cacheEfficiency();
    try testing.expect(eff > 53.0 and eff < 54.0);
}

test "UsageStore serialization and deserialization roundtrip" {
    var store: UsageStore = .{};
    const now_ms: i64 = 1730592000000;
    store.recordRequest(now_ms, "qwen4_exp", 1000, 900, 50, 100_000_000, 500_000_000);

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try store.writePersistence(&writer);
    const json_str = writer.buffered();

    var loaded: UsageStore = .{};
    try loaded.loadFromJson(json_str);

    try testing.expectEqual(@as(usize, 1), loaded.days_len);
    try testing.expectEqual(@as(u64, 1), loaded.days[0].total.requests);
    try testing.expectEqual(@as(u64, 1000), loaded.days[0].total.prompt_tokens);
    try testing.expectEqual(@as(u64, 900), loaded.days[0].total.cached_tokens);
    try testing.expectEqual(@as(u64, 50), loaded.days[0].total.output_tokens);
}
