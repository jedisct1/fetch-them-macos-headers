const std = @import("std");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const process = std.process;
const assert = std.debug.assert;
const tmpDir = std.testing.tmpDir;

const Allocator = mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;
const OsTag = std.Target.Os.Tag;

const Arch = enum {
    any,
    aarch64,
    x86_64,

    fn fromTargetCpuArch(arch: std.Target.Cpu.Arch) Arch {
        return switch (arch) {
            .aarch64 => .aarch64,
            .x86_64 => .x86_64,
            else => unreachable,
        };
    }
};

const Abi = enum { any, none };

const OsVer = enum(u32) {
    any = 0,
    catalina = 10,
    big_sur = 11,
    monterey = 12,
};

const Target = struct {
    arch: Arch,
    os: OsTag = .macos,
    os_ver: OsVer,
    abi: Abi = .none,

    fn hash(a: Target) u32 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, a.arch);
        std.hash.autoHash(&hasher, a.os);
        std.hash.autoHash(&hasher, a.os_ver);
        std.hash.autoHash(&hasher, a.abi);
        return @truncate(u32, hasher.final());
    }

    fn eql(a: Target, b: Target) bool {
        return a.arch == b.arch and
            a.os == b.os and
            a.os_ver == b.os_ver and
            a.abi == b.abi;
    }

    fn name(self: Target, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{
            @tagName(self.arch),
            @tagName(self.os),
            @tagName(self.abi),
        });
    }

    fn fullName(self: Target, allocator: Allocator) ![]const u8 {
        if (self.os_ver == .any) return self.name(allocator);
        return std.fmt.allocPrint(allocator, "{s}-{s}.{d}-{s}", .{
            @tagName(self.arch),
            @tagName(self.os),
            @enumToInt(self.os_ver),
            @tagName(self.abi),
        });
    }

    fn fromStdTarget(std_target: std.Target) Target {
        const ver = std_target.os.version_range.semver;
        assert(ver.min.major == ver.max.major and ver.min.minor == ver.max.minor and ver.min.patch == ver.max.patch);
        const os_ver: OsVer = switch (ver.max.major) {
            10 => .catalina,
            11 => .big_sur,
            12 => .monterey,
            else => unreachable,
        };
        return .{
            .arch = Arch.fromTargetCpuArch(std_target.cpu.arch),
            .os_ver = os_ver,
        };
    }
};

const targets = [_]Target{
    Target{
        .arch = .any,
        .abi = .any,
        .os_ver = .any,
    },
    Target{
        .arch = .aarch64,
        .os_ver = .any,
    },
    Target{
        .arch = .x86_64,
        .os_ver = .any,
    },
    Target{
        .arch = .x86_64,
        .os_ver = .catalina,
    },
    Target{
        .arch = .x86_64,
        .os_ver = .big_sur,
    },
    Target{
        .arch = .x86_64,
        .os_ver = .monterey,
    },
    Target{
        .arch = .aarch64,
        .os_ver = .big_sur,
    },
    Target{
        .arch = .aarch64,
        .os_ver = .monterey,
    },
};

const headers_source_prefix: []const u8 = "headers";

const Contents = struct {
    bytes: []const u8,
    hit_count: usize,
    hash: []const u8,
    is_generic: bool,

    fn hitCountLessThan(context: void, lhs: *const Contents, rhs: *const Contents) bool {
        _ = context;
        return lhs.hit_count < rhs.hit_count;
    }
};

const TargetToHashContext = struct {
    pub fn hash(self: @This(), target: Target) u32 {
        _ = self;
        return target.hash();
    }
    pub fn eql(self: @This(), a: Target, b: Target, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return a.eql(b);
    }
};
const TargetToHash = std.ArrayHashMap(Target, []const u8, TargetToHashContext, true);

const HashToContents = std.StringHashMap(Contents);
const PathTable = std.StringHashMap(*TargetToHash);

/// The don't-dedup-list contains file paths with known problematic headers
/// which while contain the same contents between architectures, should not be
/// deduped since they contain includes, etc. which are relative and thus cannot be separated
/// into a shared include dir such as `any-macos-any`.
const dont_dedup_list = &[_][]const u8{
    "libkern/OSAtomic.h",
    "libkern/OSAtomicDeprecated.h",
    "libkern/OSSpinLockDeprecated.h",
    "libkern/OSAtomicQueue.h",
};

fn generateDontDedupMap(allocator: Allocator) !std.StringHashMap(void) {
    var map = std.StringHashMap(void).init(allocator);
    errdefer map.deinit();
    try map.ensureTotalCapacity(dont_dedup_list.len);
    for (dont_dedup_list) |path| {
        map.putAssumeCapacityNoClobber(path, {});
    }
    return map;
}

const usage =
    \\Usage: fetch_them_macos_headers fetch [cflags]
    \\       fetch_them_macos_headers generate <destination>
    \\
    \\Commands:
    \\  fetch [cflags]              Fetch libc headers into headers/<arch>-macos.<os_ver> dir
    \\  generate <destination>      Generate deduplicated dirs such as { aarch64-macos.11-none, x86_64-macos.11-none, any-macos.11-any }
    \\                              into a given <destination> path
    \\
    \\General Options:
    \\-h, --help                    Print this help and exit
;

const hint =
    \\Try:
    \\1. Add missing libc headers to src/headers.c
    \\2. Fetch them:
    \\   ./zig-out/bin/fetch_them_macos_headers fetch
    \\3. Generate deduplicated headers dirs in <destination> path:
    \\   ./zig-out/bin/fetch_them_macos_headers generate <destination>
    \\
    \\See -h/--help for more info.
;

fn mainArgs(allocator: Allocator, all_args: []const []const u8) !void {
    const args = all_args[1..];
    if (args.len == 0) {
        try io.getStdErr().writeAll("fatal: no command or option specified\n\n");
        try io.getStdOut().writeAll(hint);
        return;
    }

    const first_arg = args[0];
    if (mem.eql(u8, first_arg, "--help") or mem.eql(u8, first_arg, "-h")) {
        try io.getStdOut().writeAll(usage);
        return;
    } else if (mem.eql(u8, first_arg, "generate")) {
        return generateDedupDirs(allocator, args[1..]);
    } else if (mem.eql(u8, first_arg, "fetch")) {
        return fetchHeaders(allocator, args[1..]);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "fatal: unknown command or option: {s}", .{first_arg});
        try io.getStdErr().writeAll(msg);
        return;
    }
}

fn fetchHeaders(allocator: Allocator, args: []const []const u8) !void {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    const tmp_filename = "headers";
    const tmp_file_path = try fs.path.join(allocator, &[_][]const u8{ tmp_path, tmp_filename });

    const headers_list_filename = "headers.o.d";
    const headers_list_path = try fs.path.join(allocator, &[_][]const u8{ tmp_path, headers_list_filename });

    var argv = std.ArrayList([]const u8).init(allocator);
    try argv.appendSlice(&[_][]const u8{
        "cc",
        "-o",
        tmp_file_path,
        "src/headers.c",
        "-MD",
        "-MV",
        "-MF",
        headers_list_path,
    });
    try argv.appendSlice(args);

    // TODO instead of calling `cc` as a child process here,
    // hook in directly to `zig cc` API.
    const res = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = argv.items,
    });

    if (res.stderr.len != 0) {
        std.log.err("{s}", .{res.stderr});
    }

    // Read in the contents of `upgrade.o.d`
    const headers_list_file = try tmp.dir.openFile(headers_list_filename, .{});
    defer headers_list_file.close();

    var headers_dir = fs.cwd().openDir(headers_source_prefix, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            const msg = try std.fmt.allocPrint(
                allocator,
                "fatal: path '{s}' not found or not a directory. Did you accidentally delete it?",
                .{headers_source_prefix},
            );
            try io.getStdErr().writeAll(msg);
            process.exit(1);
        },
        else => return err,
    };
    defer headers_dir.close();

    const dest_target_info = try std.zig.system.NativeTargetInfo.detect(allocator, .{});
    const dest_target = Target.fromStdTarget(dest_target_info.target);
    const dest_path = try dest_target.fullName(allocator);
    try headers_dir.deleteTree(dest_path);

    var dest_dir = try headers_dir.makeOpenPath(dest_path, .{});
    var dirs = std.StringHashMap(fs.Dir).init(allocator);
    try dirs.putNoClobber(".", dest_dir);

    const headers_list_str = try headers_list_file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    const prefix = "/usr/include";

    var it = mem.split(u8, headers_list_str, "\n");
    while (it.next()) |line| {
        if (mem.lastIndexOf(u8, line, "clang") != null) continue;
        if (mem.lastIndexOf(u8, line, prefix[0..])) |idx| {
            const out_rel_path = line[idx + prefix.len + 1 ..];
            const out_rel_path_stripped = mem.trim(u8, out_rel_path, " \\");
            const dirname = fs.path.dirname(out_rel_path_stripped) orelse ".";
            const maybe_dir = try dirs.getOrPut(dirname);
            if (!maybe_dir.found_existing) {
                maybe_dir.value_ptr.* = try dest_dir.makeOpenPath(dirname, .{});
            }
            const basename = fs.path.basename(out_rel_path_stripped);

            const line_stripped = mem.trim(u8, line, " \\");
            const abs_dirname = fs.path.dirname(line_stripped).?;
            var orig_subdir = try fs.cwd().openDir(abs_dirname, .{});
            defer orig_subdir.close();

            try orig_subdir.copyFile(basename, maybe_dir.value_ptr.*, basename, .{});
        }
    }

    var dir_it = dirs.iterator();
    while (dir_it.next()) |entry| {
        entry.value_ptr.close();
    }
}

/// Dedups libs headers assuming the following layered structure:
/// layer 1: x86_64-macos.10 x86_64-macos.11 x86_64-macos.12 aarch64-macos.11 aarch64-macos.12
/// layer 2: any-macos.10 any-macos.11 any-macos.12
/// layer 3: any-macos
///
/// The first layer consists of headers specific to a CPU architecture AND macOS version. The second
/// layer consists of headers common to a macOS version across CPU architectures, and the final
/// layer consists of headers common to all libc headers.
fn generateDedupDirs(allocator: Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        try io.getStdErr().writeAll("fatal: no destination path specified");
        process.exit(1);
    }

    const dest_path = args[0];
    var dest_dir = fs.cwd().makeOpenPath(dest_path, .{}) catch |err| switch (err) {
        error.NotDir => {
            const msg = try std.fmt.allocPrint(allocator, "fatal: path '{s}' not a directory", .{dest_path});
            try io.getStdErr().writeAll(msg);
            process.exit(1);
        },
        else => return err,
    };
    defer dest_dir.close();

    var dont_dedup_map = try generateDontDedupMap(allocator);
    defer dont_dedup_map.deinit();

    var layer_2_targets = std.ArrayList(TargetWithPrefix).init(allocator);
    defer layer_2_targets.deinit();

    for (&[_]OsVer{ .catalina, .big_sur, .monterey }) |os_ver| {
        var layer_1_targets = std.ArrayList(TargetWithPrefix).init(allocator);
        defer layer_1_targets.deinit();

        for (targets) |target| {
            if (target.os_ver != os_ver) continue;
            try layer_1_targets.append(.{
                .prefix = headers_source_prefix,
                .target = target,
            });
        }

        if (layer_1_targets.items.len < 2) {
            try layer_2_targets.appendSlice(layer_1_targets.items);
            continue;
        }

        const layer_2_target = try dedupDirs(allocator, .{
            .os_ver = os_ver,
            .dest_path = dest_path,
            .dest_dir = dest_dir,
            .targets = layer_1_targets.items,
            .dont_dedup_map = &dont_dedup_map,
        });
        try layer_2_targets.append(layer_2_target);
    }

    const layer_3_target = try dedupDirs(allocator, .{
        .os_ver = .any,
        .dest_path = dest_path,
        .dest_dir = dest_dir,
        .targets = layer_2_targets.items,
        .dont_dedup_map = &dont_dedup_map,
    });
    assert(layer_3_target.target.eql(targets[0]));
}

const TargetWithPrefix = struct {
    prefix: []const u8,
    target: Target,
};

const DedupDirsArgs = struct {
    os_ver: OsVer,
    dest_path: []const u8,
    dest_dir: fs.Dir,
    targets: []const TargetWithPrefix,
    dont_dedup_map: *const std.StringHashMap(void),
};

fn dedupDirs(allocator: Allocator, args: DedupDirsArgs) !TargetWithPrefix {
    var tmp = tmpDir(.{
        .iterate = true,
    });
    defer tmp.cleanup();

    var path_table = PathTable.init(allocator);
    var hash_to_contents = HashToContents.init(allocator);

    var savings = FindResult{};
    for (args.targets) |target| {
        const res = try findDuplicates(target.target, allocator, target.prefix, &path_table, &hash_to_contents);
        savings.max_bytes_saved += res.max_bytes_saved;
        savings.total_bytes += res.total_bytes;
    }

    std.log.warn("summary: {} could be reduced to {}", .{
        std.fmt.fmtIntSizeBin(savings.total_bytes),
        std.fmt.fmtIntSizeBin(savings.total_bytes - savings.max_bytes_saved),
    });

    const output_target = Target{
        .arch = .any,
        .abi = .any,
        .os_ver = args.os_ver,
    };
    const common_name = try output_target.fullName(allocator);

    var missed_opportunity_bytes: usize = 0;
    // Iterate path_table. For each path, put all the hashes into a list. Sort by hit_count.
    // The hash with the highest hit_count gets to be the "generic" one. Everybody else
    // gets their header in a separate arch directory.
    var path_it = path_table.iterator();
    while (path_it.next()) |path_kv| {
        if (!args.dont_dedup_map.contains(path_kv.key_ptr.*)) {
            var contents_list = std.ArrayList(*Contents).init(allocator);
            {
                var hash_it = path_kv.value_ptr.*.iterator();
                while (hash_it.next()) |hash_kv| {
                    const contents = &hash_to_contents.getEntry(hash_kv.value_ptr.*).?.value_ptr.*;
                    try contents_list.append(contents);
                }
            }
            std.sort.sort(*Contents, contents_list.items, {}, Contents.hitCountLessThan);
            const best_contents = contents_list.popOrNull().?;
            if (best_contents.hit_count > 1) {
                // Put it in `any-macos-none`.
                const full_path = try fs.path.join(allocator, &[_][]const u8{ common_name, path_kv.key_ptr.* });
                try tmp.dir.makePath(fs.path.dirname(full_path).?);
                try tmp.dir.writeFile(full_path, best_contents.bytes);
                best_contents.is_generic = true;
                while (contents_list.popOrNull()) |contender| {
                    if (contender.hit_count > 1) {
                        const this_missed_bytes = contender.hit_count * contender.bytes.len;
                        missed_opportunity_bytes += this_missed_bytes;
                        std.log.warn("Missed opportunity ({}): {s}", .{
                            std.fmt.fmtIntSizeBin(this_missed_bytes),
                            path_kv.key_ptr.*,
                        });
                    } else break;
                }
            }
        }
        var hash_it = path_kv.value_ptr.*.iterator();
        while (hash_it.next()) |hash_kv| {
            const contents = &hash_to_contents.getEntry(hash_kv.value_ptr.*).?.value_ptr.*;
            if (contents.is_generic) continue;

            const target = hash_kv.key_ptr.*;
            const target_name = try target.fullName(allocator);
            const full_path = try fs.path.join(allocator, &[_][]const u8{ target_name, path_kv.key_ptr.* });
            try tmp.dir.makePath(fs.path.dirname(full_path).?);
            try tmp.dir.writeFile(full_path, contents.bytes);
        }
    }

    for (args.targets) |target| {
        const target_name = try target.target.fullName(allocator);
        try args.dest_dir.deleteTree(target_name);
    }
    try args.dest_dir.deleteTree(common_name);

    var tmp_it = tmp.dir.iterate();
    while (try tmp_it.next()) |entry| {
        switch (entry.kind) {
            .Directory => {
                const sub_dir = try tmp.dir.openDir(entry.name, .{
                    .iterate = true,
                });
                const dest_sub_dir = try args.dest_dir.makeOpenPath(entry.name, .{});
                try copyDirAll(sub_dir, dest_sub_dir);
            },
            else => {
                std.log.warn("unexpected file format: not a directory: '{s}'", .{entry.name});
            },
        }
    }

    return TargetWithPrefix{
        .prefix = args.dest_path,
        .target = output_target,
    };
}

const FindResult = struct {
    max_bytes_saved: usize = 0,
    total_bytes: usize = 0,
};

fn findDuplicates(
    target: Target,
    allocator: Allocator,
    dest_path: []const u8,
    path_table: *PathTable,
    hash_to_contents: *HashToContents,
) !FindResult {
    var result = FindResult{};

    const target_name = try target.fullName(allocator);
    const target_include_dir = try fs.path.join(allocator, &[_][]const u8{ dest_path, target_name });
    var dir_stack = std.ArrayList([]const u8).init(allocator);
    try dir_stack.append(target_include_dir);

    while (dir_stack.popOrNull()) |full_dir_name| {
        var dir = fs.cwd().openDir(full_dir_name, .{
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => break,
            error.AccessDenied => break,
            else => return err,
        };
        defer dir.close();

        var dir_it = dir.iterate();

        while (try dir_it.next()) |entry| {
            const full_path = try fs.path.join(allocator, &[_][]const u8{ full_dir_name, entry.name });
            switch (entry.kind) {
                .Directory => try dir_stack.append(full_path),
                .File => {
                    const rel_path = try fs.path.relative(allocator, target_include_dir, full_path);
                    const max_size = 2 * 1024 * 1024 * 1024;
                    const raw_bytes = try fs.cwd().readFileAlloc(allocator, full_path, max_size);
                    const trimmed = mem.trim(u8, raw_bytes, " \r\n\t");
                    result.total_bytes += raw_bytes.len;
                    const hash = try allocator.alloc(u8, 32);
                    var hasher = Blake3.init(.{});
                    hasher.update(rel_path);
                    hasher.update(trimmed);
                    hasher.final(hash);
                    const gop = try hash_to_contents.getOrPut(hash);
                    if (gop.found_existing) {
                        result.max_bytes_saved += raw_bytes.len;
                        gop.value_ptr.hit_count += 1;
                        std.log.warn("duplicate: {s} {s} ({})", .{
                            target_name,
                            rel_path,
                            std.fmt.fmtIntSizeBin(raw_bytes.len),
                        });
                    } else {
                        gop.value_ptr.* = Contents{
                            .bytes = trimmed,
                            .hit_count = 1,
                            .hash = hash,
                            .is_generic = false,
                        };
                    }
                    const path_gop = try path_table.getOrPut(rel_path);
                    const target_to_hash = if (path_gop.found_existing) path_gop.value_ptr.* else blk: {
                        const ptr = try allocator.create(TargetToHash);
                        ptr.* = TargetToHash.init(allocator);
                        path_gop.value_ptr.* = ptr;
                        break :blk ptr;
                    };
                    try target_to_hash.putNoClobber(target, hash);
                },
                else => std.log.warn("unexpected file: {s}", .{full_path}),
            }
        }
    }

    return result;
}

fn copyDirAll(source: fs.Dir, dest: fs.Dir) anyerror!void {
    var it = source.iterate();
    while (try it.next()) |next| {
        switch (next.kind) {
            .Directory => {
                var sub_dir = try dest.makeOpenPath(next.name, .{});
                var sub_source = try source.openDir(next.name, .{
                    .iterate = true,
                });
                defer {
                    sub_dir.close();
                    sub_source.close();
                }
                try copyDirAll(sub_source, sub_dir);
            },
            .File => {
                var source_file = try source.openFile(next.name, .{});
                var dest_file = try dest.createFile(next.name, .{});
                defer {
                    source_file.close();
                    dest_file.close();
                }
                const stat = try source_file.stat();
                const ncopied = try source_file.copyRangeAll(0, dest_file, 0, stat.size);
                assert(ncopied == stat.size);
            },
            else => |kind| {
                std.log.warn("unexpected file kind '{s}' will be ignored", .{kind});
            },
        }
    }
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    return mainArgs(allocator, args);
}
