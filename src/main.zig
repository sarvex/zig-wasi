const std = @import("std");
const process = std.process;
const assert = std.debug.assert;
const fs = std.fs;
const mem = std.mem;
const wasm = std.wasm;
const wasi = std.os.wasi;
const os = std.os;
const math = std.math;
const trace_log = std.log.scoped(.trace);
const cpu_log = std.log.scoped(.cpu);
const func_log = std.log.scoped(.func);

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .cpu) return;
    //if (scope == .trace) return;
    if (scope == .func) return;
    std.debug.print(format ++ "\n", args);
    _ = level;
}

pub fn main() !void {
    const gpa = general_purpose_allocator.allocator();

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try process.argsAlloc(arena);

    const zig_lib_dir_path = args[1];
    const wasm_file = args[2];
    const vm_args = args[2..];

    const ten_moogieboogies = 10 * 1024 * 1024;
    const module_bytes = try fs.cwd().readFileAlloc(arena, wasm_file, ten_moogieboogies);

    const cwd = try fs.cwd().openDir(".", .{});
    const cache_dir = try cwd.makeOpenPath("zig1-cache", .{});
    const zig_lib_dir = try cwd.openDir(zig_lib_dir_path, .{});

    addPreopen(0, "stdin", os.STDIN_FILENO);
    addPreopen(1, "stdout", os.STDOUT_FILENO);
    addPreopen(2, "stderr", os.STDERR_FILENO);
    addPreopen(3, ".", cwd.fd);
    addPreopen(4, "/cwd", cwd.fd);
    addPreopen(5, "/cache", cache_dir.fd);
    addPreopen(6, "/lib", zig_lib_dir.fd);

    var i: u32 = 0;

    const magic = module_bytes[i..][0..4];
    i += 4;
    if (!mem.eql(u8, magic, "\x00asm")) return error.NotWasm;

    const version = mem.readIntLittle(u32, module_bytes[i..][0..4]);
    i += 4;
    if (version != 1) return error.BadWasmVersion;

    var section_starts = [1]u32{0} ** section_count;

    while (i < module_bytes.len) {
        const section_id = @intToEnum(wasm.Section, module_bytes[i]);
        i += 1;
        const section_len = readVarInt(module_bytes, &i, u32);
        section_starts[@enumToInt(section_id)] = i;
        i += section_len;
    }

    // Count the imported functions so we can correct function references.
    const imports = i: {
        i = section_starts[@enumToInt(wasm.Section.import)];
        const imports_len = readVarInt(module_bytes, &i, u32);
        const imports = try arena.alloc(Import, imports_len);
        for (imports) |*imp| {
            const mod_name = readName(module_bytes, &i);
            const sym_name = readName(module_bytes, &i);
            const desc = readVarInt(module_bytes, &i, wasm.ExternalKind);
            switch (desc) {
                .function => {
                    const type_idx = readVarInt(module_bytes, &i, u32);
                    _ = type_idx;
                },
                .table => unreachable,
                .memory => unreachable,
                .global => unreachable,
            }
            imp.* = .{
                .mod_name = mod_name,
                .sym_name = sym_name,
            };
        }
        break :i imports;
    };

    // Find _start in the exports
    const start_fn_idx = i: {
        i = section_starts[@enumToInt(wasm.Section.@"export")];
        var count = readVarInt(module_bytes, &i, u32);
        while (count > 0) : (count -= 1) {
            const name = readName(module_bytes, &i);
            const desc = readVarInt(module_bytes, &i, wasm.ExternalKind);
            const index = readVarInt(module_bytes, &i, u32);
            if (mem.eql(u8, name, "_start") and desc == .function) {
                break :i index;
            }
        }
        return error.StartFunctionNotFound;
    };

    // Map function indexes to offsets into the module and type index.
    const functions = f: {
        var code_i: u32 = section_starts[@enumToInt(wasm.Section.code)];
        var func_i: u32 = section_starts[@enumToInt(wasm.Section.function)];
        const codes_len = readVarInt(module_bytes, &code_i, u32);
        const funcs_len = readVarInt(module_bytes, &func_i, u32);
        assert(codes_len == funcs_len);
        const functions = try arena.alloc(Function, funcs_len);
        for (functions) |*func| {
            const size = readVarInt(module_bytes, &code_i, u32);
            func.* = .{
                .code = code_i,
                .type_idx = readVarInt(module_bytes, &func_i, u32),
            };
            code_i += size;
        }
        break :f functions;
    };

    // Map type indexes to offsets into the module.
    const types = t: {
        i = section_starts[@enumToInt(wasm.Section.type)];
        const types_len = readVarInt(module_bytes, &i, u32);
        const types = try arena.alloc(u32, types_len);
        for (types) |*ty| {
            ty.* = i;
            assert(module_bytes[i] == 0x60);
            i += 1;
            const param_count = readVarInt(module_bytes, &i, u32);
            i += param_count;
            const return_count = readVarInt(module_bytes, &i, u32);
            i += return_count;
        }
        break :t types;
    };

    // Allocate and initialize globals.
    const globals = g: {
        i = section_starts[@enumToInt(wasm.Section.global)];
        const globals_len = readVarInt(module_bytes, &i, u32);
        const globals = try arena.alloc(u64, globals_len);
        for (globals) |*global| {
            const content_type = readVarInt(module_bytes, &i, wasm.Valtype);
            const mutability = readVarInt(module_bytes, &i, Mutability);
            assert(mutability == .@"var");
            assert(content_type == .i32);
            const opcode = @intToEnum(wasm.Opcode, module_bytes[i]);
            i += 1;
            assert(opcode == .i32_const);
            const init = readVarInt(module_bytes, &i, i32);
            global.* = @bitCast(u32, init);
        }
        break :g globals;
    };

    // Allocate and initialize memory.
    const memory = m: {
        i = section_starts[@enumToInt(wasm.Section.memory)];
        const memories_len = readVarInt(module_bytes, &i, u32);
        if (memories_len != 1) return error.UnexpectedMemoryCount;
        const flags = readVarInt(module_bytes, &i, u32);
        _ = flags;
        const initial = readVarInt(module_bytes, &i, u32) * wasm.page_size;
        const memory = try gpa.alloc(u8, initial);
        @memset(memory.ptr, 0, memory.len);

        i = section_starts[@enumToInt(wasm.Section.data)];
        var datas_count = readVarInt(module_bytes, &i, u32);
        while (datas_count > 0) : (datas_count -= 1) {
            const mode = readVarInt(module_bytes, &i, u32);
            assert(mode == 0);
            const opcode = @intToEnum(wasm.Opcode, module_bytes[i]);
            i += 1;
            assert(opcode == .i32_const);
            const offset = readVarInt(module_bytes, &i, u32);
            const end = @intToEnum(wasm.Opcode, module_bytes[i]);
            assert(end == .end);
            i += 1;
            const bytes_len = readVarInt(module_bytes, &i, u32);
            mem.copy(u8, memory[offset..], module_bytes[i..][0..bytes_len]);
            i += bytes_len;
        }

        break :m memory;
    };

    const table = t: {
        i = section_starts[@enumToInt(wasm.Section.table)];
        const table_count = readVarInt(module_bytes, &i, u32);
        if (table_count != 1) return error.ExpectedOneTableSection;
        const element_type = readVarInt(module_bytes, &i, u32);
        const has_max = readVarInt(module_bytes, &i, u32);
        assert(has_max == 1);
        const initial = readVarInt(module_bytes, &i, u32);
        const maximum = readVarInt(module_bytes, &i, u32);
        cpu_log.debug("table element_type={x} initial={d} maximum={d}", .{
            element_type, initial, maximum,
        });

        i = section_starts[@enumToInt(wasm.Section.element)];
        const element_section_count = readVarInt(module_bytes, &i, u32);
        if (element_section_count != 1) return error.ExpectedOneElementSection;
        const flags = readVarInt(module_bytes, &i, u32);
        cpu_log.debug("flags={x}", .{flags});
        const opcode = @intToEnum(wasm.Opcode, module_bytes[i]);
        i += 1;
        assert(opcode == .i32_const);
        const offset = readVarInt(module_bytes, &i, u32);
        const end = @intToEnum(wasm.Opcode, module_bytes[i]);
        assert(end == .end);
        i += 1;
        const elem_count = readVarInt(module_bytes, &i, u32);

        cpu_log.debug("elem offset={d} count={d}", .{ offset, elem_count });

        const table = try arena.alloc(u32, maximum);
        mem.set(u32, table, 0);

        var elem_i: u32 = 0;
        while (elem_i < elem_count) : (elem_i += 1) {
            table[elem_i + offset] = readVarInt(module_bytes, &i, u32);
        }
        break :t table;
    };

    frames[0] = .{
        .fn_idx = 0,
        .pc = undefined,
        .stack_begin = undefined,
        .locals_begin = undefined,
        .labels_end = 0,
        .return_arity = 0,
    };

    var exec: Exec = .{
        .module_bytes = module_bytes,
        .stack_top = 0,
        .frames_index = 1,
        .functions = functions,
        .types = types,
        .globals = globals,
        .memory = memory,
        .imports = imports,
        .args = vm_args,
        .table = table,
    };
    exec.call(start_fn_idx);
    exec.run();
}

const section_count = @typeInfo(wasm.Section).Enum.fields.len;
var stack: [1000000]u64 = undefined;
var frames: [100000]Frame = undefined;
var labels: [100000]Label = undefined;

const Frame = struct {
    fn_idx: u32,
    /// Points directly to an instruction in module_bytes.
    pc: u32,
    stack_begin: u32,
    locals_begin: u32,
    labels_end: u32,
    return_arity: u32,
};

const Label = struct {
    /// If it's non-zero then it's a loop and this is the
    /// pc of the instruction after the loop.
    /// If it's zero then it's a block.
    loop_pc: u32,
    block_type: i32,
    stack_top: u32,
};

const Mutability = enum { @"const", @"var" };

const Function = struct {
    /// Index to start of code in module_bytes.
    code: u32,
    /// Index into types.
    type_idx: u32,
};

const Import = struct {
    sym_name: []const u8,
    mod_name: []const u8,
};

const Exec = struct {
    /// Points to one after the last stack item.
    stack_top: u32,
    frames_index: u32,
    module_bytes: []const u8,
    functions: []const Function,
    /// Type index to start of type in module_bytes.
    types: []const u32,
    globals: []u64,
    memory: []u8,
    imports: []const Import,
    args: []const []const u8,
    table: []const u32,

    fn br(e: *Exec, label_count: u32) void {
        const frame = &frames[e.frames_index];
        //cpu_log.debug("br frame.labels_end={d} label_count={d}", .{ frame.labels_end, label_count });
        const pc = &frame.pc;
        const label = labels[frame.labels_end - label_count];

        // Taking a branch unwinds the operand stack up to the height where the
        // targeted structured control instruction was entered
        if (label.block_type >= 0) {
            unreachable;
        } else if (label.block_type == -0x40) {
            // void
            e.stack_top = label.stack_top;
        } else {
            // one result value
            stack[label.stack_top] = stack[e.stack_top - 1];
            e.stack_top = label.stack_top + 1;
        }

        if (label.loop_pc != 0) {
            pc.* = label.loop_pc;
            frame.labels_end -= label_count - 1;
            return;
        }

        frame.labels_end -= label_count;

        // Skip forward past N end instructions.
        const module_bytes = e.module_bytes;
        if (label_count == 0) return;
        var end_count: u32 = label_count;
        while (true) {
            const op = @intToEnum(wasm.Opcode, module_bytes[pc.*]);
            //cpu_log.debug("skipping over pc={d} op={s}", .{ pc.*, @tagName(op) });
            pc.* += 1;
            switch (op) {
                .block, .loop => {
                    // empirically there are no non-void blocks/loops
                    assert(module_bytes[pc.*] == 0x40);
                    pc.* += 1;
                    end_count += 1;
                    continue;
                },
                .@"if" => @panic("unhandled (parse) opcode: if"),
                .@"else" => @panic("unhandled (parse) opcode: else"),
                .end => {
                    if (end_count == 1) return;
                    end_count -= 1;
                    continue;
                },

                .@"unreachable",
                .nop,
                .memory_size,
                .memory_grow,
                .i32_eqz,
                .i32_eq,
                .i32_ne,
                .i32_lt_s,
                .i32_lt_u,
                .i32_gt_s,
                .i32_gt_u,
                .i32_le_s,
                .i32_le_u,
                .i32_ge_s,
                .i32_ge_u,
                .i64_eqz,
                .i64_eq,
                .i64_ne,
                .i64_lt_s,
                .i64_lt_u,
                .i64_gt_s,
                .i64_gt_u,
                .i64_le_s,
                .i64_le_u,
                .i64_ge_s,
                .i64_ge_u,
                .f32_eq,
                .f32_ne,
                .f32_lt,
                .f32_gt,
                .f32_le,
                .f32_ge,
                .f64_eq,
                .f64_ne,
                .f64_lt,
                .f64_gt,
                .f64_le,
                .f64_ge,
                .i32_clz,
                .i32_ctz,
                .i32_popcnt,
                .i32_add,
                .i32_sub,
                .i32_mul,
                .i32_div_s,
                .i32_div_u,
                .i32_rem_s,
                .i32_rem_u,
                .i32_and,
                .i32_or,
                .i32_xor,
                .i32_shl,
                .i32_shr_s,
                .i32_shr_u,
                .i32_rotl,
                .i32_rotr,
                .i64_clz,
                .i64_ctz,
                .i64_popcnt,
                .i64_add,
                .i64_sub,
                .i64_mul,
                .i64_div_s,
                .i64_div_u,
                .i64_rem_s,
                .i64_rem_u,
                .i64_and,
                .i64_or,
                .i64_xor,
                .i64_shl,
                .i64_shr_s,
                .i64_shr_u,
                .i64_rotl,
                .i64_rotr,
                .f32_abs,
                .f32_neg,
                .f32_ceil,
                .f32_floor,
                .f32_trunc,
                .f32_nearest,
                .f32_sqrt,
                .f32_add,
                .f32_sub,
                .f32_mul,
                .f32_div,
                .f32_min,
                .f32_max,
                .f32_copysign,
                .f64_abs,
                .f64_neg,
                .f64_ceil,
                .f64_floor,
                .f64_trunc,
                .f64_nearest,
                .f64_sqrt,
                .f64_add,
                .f64_sub,
                .f64_mul,
                .f64_div,
                .f64_min,
                .f64_max,
                .f64_copysign,
                .i32_wrap_i64,
                .i32_trunc_f32_s,
                .i32_trunc_f32_u,
                .i32_trunc_f64_s,
                .i32_trunc_f64_u,
                .i64_extend_i32_s,
                .i64_extend_i32_u,
                .i64_trunc_f32_s,
                .i64_trunc_f32_u,
                .i64_trunc_f64_s,
                .i64_trunc_f64_u,
                .f32_convert_i32_s,
                .f32_convert_i32_u,
                .f32_convert_i64_s,
                .f32_convert_i64_u,
                .f32_demote_f64,
                .f64_convert_i32_s,
                .f64_convert_i32_u,
                .f64_convert_i64_s,
                .f64_convert_i64_u,
                .f64_promote_f32,
                .i32_reinterpret_f32,
                .i64_reinterpret_f64,
                .f32_reinterpret_i32,
                .f64_reinterpret_i64,
                .i32_extend8_s,
                .i32_extend16_s,
                .i64_extend8_s,
                .i64_extend16_s,
                .i64_extend32_s,
                .drop,
                .select,
                .@"return",
                => continue,

                .br,
                .br_if,
                .call,
                .local_get,
                .local_set,
                .local_tee,
                .global_get,
                .global_set,
                => {
                    _ = readVarInt(module_bytes, pc, u32);
                    continue;
                },

                .i32_load,
                .i64_load,
                .f32_load,
                .f64_load,
                .i32_load8_s,
                .i32_load8_u,
                .i32_load16_s,
                .i32_load16_u,
                .i64_load8_s,
                .i64_load8_u,
                .i64_load16_s,
                .i64_load16_u,
                .i64_load32_s,
                .i64_load32_u,
                .i32_store,
                .i64_store,
                .f32_store,
                .f64_store,
                .i32_store8,
                .i32_store16,
                .i64_store8,
                .i64_store16,
                .i64_store32,
                .call_indirect,
                => {
                    _ = readVarInt(module_bytes, pc, u32);
                    _ = readVarInt(module_bytes, pc, u32);
                    continue;
                },

                .br_table => {
                    var count = readVarInt(module_bytes, pc, u32) + 1;
                    while (count > 0) : (count -= 1) {
                        _ = readVarInt(module_bytes, pc, u32);
                    }
                    continue;
                },

                .f32_const => {
                    pc.* += 4;
                    continue;
                },
                .f64_const => {
                    pc.* += 8;
                    continue;
                },
                .i32_const => {
                    _ = readVarInt(module_bytes, pc, i32);
                    continue;
                },
                .i64_const => {
                    _ = readVarInt(module_bytes, pc, i64);
                    continue;
                },
                .prefixed => {
                    const prefixed_op = @intToEnum(wasm.PrefixedOpcode, module_bytes[pc.*]);
                    pc.* += 1;
                    switch (prefixed_op) {
                        .i32_trunc_sat_f32_s => unreachable,
                        .i32_trunc_sat_f32_u => unreachable,
                        .i32_trunc_sat_f64_s => unreachable,
                        .i32_trunc_sat_f64_u => unreachable,
                        .i64_trunc_sat_f32_s => unreachable,
                        .i64_trunc_sat_f32_u => unreachable,
                        .i64_trunc_sat_f64_s => unreachable,
                        .i64_trunc_sat_f64_u => unreachable,
                        .memory_init => unreachable,
                        .data_drop => unreachable,
                        .memory_copy => {
                            pc.* += 2;
                            continue;
                        },
                        .memory_fill => {
                            pc.* += 1;
                            continue;
                        },
                        .table_init => unreachable,
                        .elem_drop => unreachable,
                        .table_copy => unreachable,
                        .table_grow => unreachable,
                        .table_size => unreachable,
                        .table_fill => unreachable,
                        _ => unreachable,
                    }
                },

                _ => unreachable,
            }
        }
    }

    fn call(e: *Exec, fn_id: u32) void {
        if (fn_id < e.imports.len) {
            const imp = e.imports[fn_id];
            return callImport(e, imp);
        }
        const fn_idx = fn_id - @intCast(u32, e.imports.len);
        const module_bytes = e.module_bytes;
        const func = e.functions[fn_idx];
        var i: u32 = e.types[func.type_idx];
        assert(module_bytes[i] == 0x60);
        i += 1;
        const param_count = readVarInt(module_bytes, &i, u32);
        i += param_count;
        const return_arity = readVarInt(module_bytes, &i, u32);
        i += return_arity;

        const locals_begin = e.stack_top - param_count;

        i = func.code;
        var locals_count: u32 = 0;
        var local_sets_count = readVarInt(module_bytes, &i, u32);
        while (local_sets_count > 0) : (local_sets_count -= 1) {
            const current_count = readVarInt(module_bytes, &i, u32);
            const local_type = readVarInt(module_bytes, &i, u32);
            _ = local_type;
            locals_count += current_count;
        }

        func_log.debug("fn_idx: {d}, type_idx: {d}, param_count: {d}, return_arity: {d}, locals_begin: {d}, locals_count: {d}", .{
            fn_idx, func.type_idx, param_count, return_arity, locals_begin, locals_count,
        });

        // Push zeroed locals to stack
        mem.set(u64, stack[e.stack_top..][0..locals_count], 0);
        e.stack_top += locals_count;

        const prev_labels_end = frames[e.frames_index].labels_end;

        e.frames_index += 1;
        frames[e.frames_index] = .{
            .fn_idx = fn_idx,
            .return_arity = return_arity,
            .pc = i,
            .stack_begin = e.stack_top,
            .locals_begin = locals_begin,
            .labels_end = prev_labels_end,
        };
    }

    fn callImport(e: *Exec, imp: Import) void {
        if (mem.eql(u8, imp.sym_name, "fd_prestat_get")) {
            const buf = e.pop(u32);
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_fd_prestat_get(e, fd, buf)));
        } else if (mem.eql(u8, imp.sym_name, "fd_prestat_dir_name")) {
            const path_len = e.pop(u32);
            const path = e.pop(u32);
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_fd_prestat_dir_name(e, fd, path, path_len)));
        } else if (mem.eql(u8, imp.sym_name, "fd_close")) {
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_fd_close(e, fd)));
        } else if (mem.eql(u8, imp.sym_name, "fd_read")) {
            const nread = e.pop(u32);
            const iovs_len = e.pop(u32);
            const iovs = e.pop(u32);
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_fd_read(e, fd, iovs, iovs_len, nread)));
        } else if (mem.eql(u8, imp.sym_name, "fd_filestat_get")) {
            const buf = e.pop(u32);
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_fd_filestat_get(e, fd, buf)));
        } else if (mem.eql(u8, imp.sym_name, "fd_filestat_set_size")) {
            const size = e.pop(u64);
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_fd_filestat_set_size(e, fd, size)));
        } else if (mem.eql(u8, imp.sym_name, "fd_filestat_set_times")) {
            @panic("TODO implement fd_filestat_set_times");
        } else if (mem.eql(u8, imp.sym_name, "fd_fdstat_get")) {
            const buf = e.pop(u32);
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_fd_fdstat_get(e, fd, buf)));
        } else if (mem.eql(u8, imp.sym_name, "fd_readdir")) {
            @panic("TODO implement fd_readdir");
        } else if (mem.eql(u8, imp.sym_name, "fd_write")) {
            const nwritten = e.pop(u32);
            const iovs_len = e.pop(u32);
            const iovs = e.pop(u32);
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_fd_write(e, fd, iovs, iovs_len, nwritten)));
        } else if (mem.eql(u8, imp.sym_name, "fd_pwrite")) {
            const nwritten = e.pop(u32);
            const offset = e.pop(u64);
            const iovs_len = e.pop(u32);
            const iovs = e.pop(u32);
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_fd_pwrite(e, fd, iovs, iovs_len, offset, nwritten)));
        } else if (mem.eql(u8, imp.sym_name, "proc_exit")) {
            std.process.exit(@intCast(u8, e.pop(u32)));
            unreachable;
        } else if (mem.eql(u8, imp.sym_name, "args_sizes_get")) {
            const argv_buf_size = e.pop(u32);
            const argc = e.pop(u32);
            e.push(u64, @enumToInt(wasi_args_sizes_get(e, argc, argv_buf_size)));
        } else if (mem.eql(u8, imp.sym_name, "args_get")) {
            const argv_buf = e.pop(u32);
            const argv = e.pop(u32);
            e.push(u64, @enumToInt(wasi_args_get(e, argv, argv_buf)));
        } else if (mem.eql(u8, imp.sym_name, "random_get")) {
            const buf_len = e.pop(u32);
            const buf = e.pop(u32);
            e.push(u64, @enumToInt(wasi_random_get(e, buf, buf_len)));
        } else if (mem.eql(u8, imp.sym_name, "environ_sizes_get")) {
            @panic("TODO implement environ_sizes_get");
        } else if (mem.eql(u8, imp.sym_name, "environ_get")) {
            @panic("TODO implement environ_get");
        } else if (mem.eql(u8, imp.sym_name, "path_filestat_get")) {
            const buf = e.pop(u32);
            const path_len = e.pop(u32);
            const path = e.pop(u32);
            const flags = e.pop(u32);
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_path_filestat_get(e, fd, flags, path, path_len, buf)));
        } else if (mem.eql(u8, imp.sym_name, "path_create_directory")) {
            const path_len = e.pop(u32);
            const path = e.pop(u32);
            const fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_path_create_directory(e, fd, path, path_len)));
        } else if (mem.eql(u8, imp.sym_name, "path_rename")) {
            const new_path_len = e.pop(u32);
            const new_path = e.pop(u32);
            const new_fd = e.pop(i32);
            const old_path_len = e.pop(u32);
            const old_path = e.pop(u32);
            const old_fd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_path_rename(
                e,
                old_fd,
                old_path,
                old_path_len,
                new_fd,
                new_path,
                new_path_len,
            )));
        } else if (mem.eql(u8, imp.sym_name, "path_open")) {
            const fd = e.pop(u32);
            const fs_flags = e.pop(u32);
            const fs_rights_inheriting = e.pop(u64);
            const fs_rights_base = e.pop(u64);
            const oflags = e.pop(u32);
            const path_len = e.pop(u32);
            const path = e.pop(u32);
            const dirflags = e.pop(u32);
            const dirfd = e.pop(i32);
            e.push(u64, @enumToInt(wasi_path_open(
                e,
                dirfd,
                dirflags,
                path,
                path_len,
                @intCast(u16, oflags),
                fs_rights_base,
                fs_rights_inheriting,
                @intCast(u16, fs_flags),
                fd,
            )));
        } else if (mem.eql(u8, imp.sym_name, "path_remove_directory")) {
            @panic("TODO implement path_remove_directory");
        } else if (mem.eql(u8, imp.sym_name, "path_unlink_file")) {
            @panic("TODO implement path_unlink_file");
        } else if (mem.eql(u8, imp.sym_name, "clock_time_get")) {
            const timestamp = e.pop(u32);
            const precision = e.pop(u64);
            const clock_id = e.pop(u32);
            e.push(u64, @enumToInt(wasi_clock_time_get(e, clock_id, precision, timestamp)));
        } else if (mem.eql(u8, imp.sym_name, "fd_pread")) {
            @panic("TODO implement fd_pread");
        } else if (mem.eql(u8, imp.sym_name, "debug")) {
            const number = e.pop(u64);
            const text = e.pop(u32);
            wasi_debug(e, text, number);
        } else if (mem.eql(u8, imp.sym_name, "debug_slice")) {
            const len = e.pop(u32);
            const ptr = e.pop(u32);
            wasi_debug_slice(e, ptr, len);
        } else {
            std.debug.panic("unhandled import: {s}", .{imp.sym_name});
        }
    }

    fn push(e: *Exec, comptime T: type, value: T) void {
        stack[e.stack_top] = switch (T) {
            i32 => @bitCast(u32, value),
            i64 => @bitCast(u64, value),
            f32 => @bitCast(u32, value),
            f64 => @bitCast(u64, value),
            u32 => value,
            u64 => value,
            else => @compileError("bad push type"),
        };
        e.stack_top += 1;
    }

    fn pop(e: *Exec, comptime T: type) T {
        e.stack_top -= 1;
        const value = stack[e.stack_top];
        return switch (T) {
            i32 => @bitCast(i32, @truncate(u32, value)),
            i64 => @bitCast(i64, value),
            f32 => @bitCast(f32, @truncate(u32, value)),
            f64 => @bitCast(f64, value),
            u32 => @truncate(u32, value),
            u64 => value,
            else => @compileError("bad pop type"),
        };
    }

    fn run(e: *Exec) noreturn {
        const module_bytes = e.module_bytes;
        while (true) {
            const frame = &frames[e.frames_index];
            const pc = &frame.pc;
            const op = @intToEnum(wasm.Opcode, module_bytes[pc.*]);
            pc.* += 1;
            if (e.stack_top > 0) {
                cpu_log.debug("stack[{d}]={x} pc={d}, op={s}", .{
                    e.stack_top - 1, stack[e.stack_top - 1], pc.*, @tagName(op),
                });
            } else {
                cpu_log.debug("<empty> pc={d}, op={s}", .{ pc.*, @tagName(op) });
            }
            switch (op) {
                .@"unreachable" => @panic("unreachable"),
                .nop => {},
                .block => {
                    const block_type = readVarInt(module_bytes, pc, i32);
                    labels[frame.labels_end] = .{
                        .loop_pc = 0,
                        .block_type = block_type,
                        .stack_top = e.stack_top,
                    };
                    frame.labels_end += 1;
                    //cpu_log.debug("set labels_end={d}", .{frame.labels_end});
                },
                .loop => {
                    const block_type = readVarInt(module_bytes, pc, i32);
                    labels[frame.labels_end] = .{
                        .loop_pc = pc.*,
                        .block_type = block_type,
                        .stack_top = e.stack_top,
                    };
                    frame.labels_end += 1;
                    //cpu_log.debug("set labels_end={d}", .{frame.labels_end});
                },
                .@"if" => @panic("unhandled opcode: if"),
                .@"else" => @panic("unhandled opcode: else"),
                .end => {
                    const prev_frame = &frames[e.frames_index - 1];
                    //cpu_log.debug("labels_end {d}-- (base: {d}) arity={d}", .{
                    //    frame.labels_end, prev_frame.labels_end, frame.return_arity,
                    //});
                    if (frame.labels_end == prev_frame.labels_end) {
                        const n = frame.return_arity;
                        const dst = stack[frame.locals_begin..][0..n];
                        const src = stack[e.stack_top - n ..][0..n];
                        mem.copy(u64, dst, src);
                        e.stack_top = frame.locals_begin + n;
                        e.frames_index -= 1;
                    } else {
                        frame.labels_end -= 1;
                    }
                },
                .br => {
                    const label_idx = readVarInt(module_bytes, pc, u32);
                    e.br(label_idx + 1);
                },
                .br_if => {
                    const label_idx = readVarInt(module_bytes, pc, u32);
                    if (e.pop(u32) != 0) {
                        e.br(label_idx + 1);
                    }
                },
                .br_table => {
                    const labels_len = readVarInt(module_bytes, pc, u32) + 1;
                    const chosen_i = @min(e.pop(u32), labels_len - 1);
                    var i: u32 = 0;
                    var chosen_label_idx: u32 = undefined;
                    while (i < labels_len) : (i += 1) {
                        const label_idx = readVarInt(module_bytes, pc, u32);
                        if (i == chosen_i) {
                            chosen_label_idx = label_idx;
                        }
                    }
                    e.br(chosen_label_idx + 1);
                },
                .@"return" => {
                    const n = frame.return_arity;
                    const dst = stack[frame.locals_begin..][0..n];
                    const src = stack[e.stack_top - n ..][0..n];
                    mem.copy(u64, dst, src);
                    e.stack_top = frame.locals_begin + n;
                    e.frames_index -= 1;
                },
                .call => {
                    const fn_id = readVarInt(module_bytes, pc, u32);
                    e.call(fn_id);
                },
                .call_indirect => {
                    const type_idx = readVarInt(module_bytes, pc, u32);
                    const table_idx = readVarInt(module_bytes, pc, u32);
                    cpu_log.debug("table_idx={d} type_idx={d}", .{ table_idx, type_idx });
                    assert(table_idx == 0);
                    const operand = e.pop(u32);
                    const fn_id = e.table[operand];
                    e.call(fn_id);
                },
                .drop => {
                    e.stack_top -= 1;
                },
                .select => {
                    const c = e.pop(u32);
                    const b = e.pop(u64);
                    const a = e.pop(u64);
                    const result = if (c != 0) a else b;
                    e.push(u64, result);
                },
                .local_get => {
                    const idx = readVarInt(module_bytes, pc, u32);
                    //cpu_log.debug("reading local at stack[{d}]", .{idx + frame.locals_begin});
                    const val = stack[idx + frame.locals_begin];
                    e.push(u64, val);
                },
                .local_set => {
                    const idx = readVarInt(module_bytes, pc, u32);
                    //cpu_log.debug("writing local at stack[{d}]", .{idx + frame.locals_begin});
                    stack[idx + frame.locals_begin] = e.pop(u64);
                },
                .local_tee => {
                    const idx = readVarInt(module_bytes, pc, u32);
                    //cpu_log.debug("writing local at stack[{d}]", .{idx + frame.locals_begin});
                    stack[idx + frame.locals_begin] = stack[e.stack_top - 1];
                },
                .global_get => {
                    const idx = readVarInt(module_bytes, pc, u32);
                    e.push(u64, e.globals[idx]);
                },
                .global_set => {
                    const idx = readVarInt(module_bytes, pc, u32);
                    e.globals[idx] = e.pop(u64);
                },
                .i32_load => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    e.push(u32, mem.readIntLittle(u32, e.memory[offset..][0..4]));
                },
                .i64_load => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    e.push(u64, mem.readIntLittle(u64, e.memory[offset..][0..8]));
                },
                .f32_load => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    const int = mem.readIntLittle(u32, e.memory[offset..][0..4]);
                    e.push(u32, int);
                },
                .f64_load => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    const int = mem.readIntLittle(u64, e.memory[offset..][0..8]);
                    e.push(u64, int);
                },
                .i32_load8_s => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    e.push(i32, @bitCast(i8, e.memory[offset]));
                },
                .i32_load8_u => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32);
                    const arg = e.pop(u32);
                    e.push(u32, e.memory[offset + arg]);
                },
                .i32_load16_s => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    const int = mem.readIntLittle(i16, e.memory[offset..][0..2]);
                    e.push(i32, int);
                },
                .i32_load16_u => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    const int = mem.readIntLittle(u16, e.memory[offset..][0..2]);
                    e.push(u32, int);
                },
                .i64_load8_s => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    e.push(i64, @bitCast(i8, e.memory[offset]));
                },
                .i64_load8_u => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    e.push(u64, e.memory[offset]);
                },
                .i64_load16_s => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    const int = mem.readIntLittle(i16, e.memory[offset..][0..2]);
                    e.push(i64, int);
                },
                .i64_load16_u => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    const int = mem.readIntLittle(u16, e.memory[offset..][0..2]);
                    e.push(u64, int);
                },
                .i64_load32_s => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    const int = mem.readIntLittle(i32, e.memory[offset..][0..4]);
                    e.push(i64, int);
                },
                .i64_load32_u => {
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    const int = mem.readIntLittle(u32, e.memory[offset..][0..4]);
                    e.push(u64, int);
                },
                .i32_store => {
                    const operand = e.pop(u32);
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    mem.writeIntLittle(u32, e.memory[offset..][0..4], operand);
                },
                .i64_store => {
                    const operand = e.pop(u64);
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    mem.writeIntLittle(u64, e.memory[offset..][0..8], operand);
                },
                .f32_store => {
                    const int = @bitCast(u32, e.pop(f32));
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    mem.writeIntLittle(u32, e.memory[offset..][0..4], int);
                },
                .f64_store => {
                    const int = @bitCast(u64, e.pop(f64));
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    mem.writeIntLittle(u64, e.memory[offset..][0..8], int);
                },
                .i32_store8 => {
                    const small = @truncate(u8, e.pop(u32));
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    e.memory[offset] = small;
                },
                .i32_store16 => {
                    const small = @truncate(u16, e.pop(u32));
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    mem.writeIntLittle(u16, e.memory[offset..][0..2], small);
                },
                .i64_store8 => {
                    const operand = @truncate(u8, e.pop(u64));
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    e.memory[offset] = operand;
                },
                .i64_store16 => {
                    const small = @truncate(u16, e.pop(u64));
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    mem.writeIntLittle(u16, e.memory[offset..][0..2], small);
                },
                .i64_store32 => {
                    const small = @truncate(u32, e.pop(u64));
                    const alignment = readVarInt(module_bytes, pc, u32);
                    _ = alignment;
                    const offset = readVarInt(module_bytes, pc, u32) + e.pop(u32);
                    mem.writeIntLittle(u32, e.memory[offset..][0..4], small);
                },
                .memory_size => {
                    pc.* += 1; // skip 0x00 byte
                    const page_count = @intCast(u32, e.memory.len / wasm.page_size);
                    e.push(u32, page_count);
                },
                .memory_grow => {
                    pc.* += 1; // skip 0x00 byte
                    const gpa = general_purpose_allocator.allocator();
                    const page_count = e.pop(u32);
                    const old_page_count = @intCast(u32, e.memory.len / wasm.page_size);
                    const new_len = e.memory.len + page_count * wasm.page_size;
                    e.memory = gpa.realloc(e.memory, new_len) catch @panic("out of memory");
                    e.push(u32, old_page_count);
                },
                .i32_const => {
                    const x = readVarInt(module_bytes, pc, i32);
                    e.push(i32, x);
                },
                .i64_const => {
                    const x = readVarInt(module_bytes, pc, i64);
                    e.push(i64, x);
                },
                .f32_const => {
                    const x = readFloat32(module_bytes, pc);
                    e.push(f32, x);
                },
                .f64_const => {
                    const x = readFloat64(module_bytes, pc);
                    e.push(f64, x);
                },
                .i32_eqz => {
                    const lhs = e.pop(u32);
                    e.push(u64, @boolToInt(lhs == 0));
                },
                .i32_eq => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u64, @boolToInt(lhs == rhs));
                },
                .i32_ne => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u64, @boolToInt(lhs != rhs));
                },
                .i32_lt_s => {
                    const rhs = e.pop(i32);
                    const lhs = e.pop(i32);
                    e.push(u64, @boolToInt(lhs < rhs));
                },
                .i32_lt_u => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u64, @boolToInt(lhs < rhs));
                },
                .i32_gt_s => {
                    const rhs = e.pop(i32);
                    const lhs = e.pop(i32);
                    e.push(u64, @boolToInt(lhs > rhs));
                },
                .i32_gt_u => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u64, @boolToInt(lhs > rhs));
                },
                .i32_le_s => {
                    const rhs = e.pop(i32);
                    const lhs = e.pop(i32);
                    e.push(u64, @boolToInt(lhs <= rhs));
                },
                .i32_le_u => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u64, @boolToInt(lhs <= rhs));
                },
                .i32_ge_s => {
                    const rhs = e.pop(i32);
                    const lhs = e.pop(i32);
                    e.push(u64, @boolToInt(lhs >= rhs));
                },
                .i32_ge_u => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u64, @boolToInt(lhs >= rhs));
                },
                .i64_eqz => {
                    const lhs = e.pop(u64);
                    e.push(u64, @boolToInt(lhs == 0));
                },
                .i64_eq => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, @boolToInt(lhs == rhs));
                },
                .i64_ne => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, @boolToInt(lhs != rhs));
                },
                .i64_lt_s => {
                    const rhs = e.pop(i64);
                    const lhs = e.pop(i64);
                    e.push(u64, @boolToInt(lhs < rhs));
                },
                .i64_lt_u => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, @boolToInt(lhs < rhs));
                },
                .i64_gt_s => {
                    const rhs = e.pop(i64);
                    const lhs = e.pop(i64);
                    e.push(u64, @boolToInt(lhs > rhs));
                },
                .i64_gt_u => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, @boolToInt(lhs > rhs));
                },
                .i64_le_s => {
                    const rhs = e.pop(i64);
                    const lhs = e.pop(i64);
                    e.push(u64, @boolToInt(lhs <= rhs));
                },
                .i64_le_u => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, @boolToInt(lhs <= rhs));
                },
                .i64_ge_s => {
                    const rhs = e.pop(i64);
                    const lhs = e.pop(i64);
                    e.push(u64, @boolToInt(lhs >= rhs));
                },
                .i64_ge_u => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, @boolToInt(lhs >= rhs));
                },
                .f32_eq => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(u64, @boolToInt(lhs == rhs));
                },
                .f32_ne => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(u64, @boolToInt(lhs != rhs));
                },
                .f32_lt => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(u64, @boolToInt(lhs < rhs));
                },
                .f32_gt => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(u64, @boolToInt(lhs > rhs));
                },
                .f32_le => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(u64, @boolToInt(lhs <= rhs));
                },
                .f32_ge => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(u64, @boolToInt(lhs >= rhs));
                },
                .f64_eq => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(u64, @boolToInt(lhs == rhs));
                },
                .f64_ne => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(u64, @boolToInt(lhs != rhs));
                },
                .f64_lt => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(u64, @boolToInt(lhs <= rhs));
                },
                .f64_gt => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(u64, @boolToInt(lhs > rhs));
                },
                .f64_le => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(u64, @boolToInt(lhs <= rhs));
                },
                .f64_ge => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(u64, @boolToInt(lhs >= rhs));
                },

                .i32_clz => {
                    const operand = e.pop(u32);
                    e.push(u32, @clz(operand));
                },
                .i32_ctz => {
                    const operand = e.pop(u32);
                    e.push(u32, @ctz(operand));
                },
                .i32_popcnt => {
                    const operand = e.pop(u32);
                    e.push(u32, @popCount(operand));
                },
                .i32_add => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, lhs +% rhs);
                },
                .i32_sub => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, lhs -% rhs);
                },
                .i32_mul => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, lhs *% rhs);
                },
                .i32_div_s => {
                    const rhs = e.pop(i32);
                    const lhs = e.pop(i32);
                    e.push(i32, @divTrunc(lhs, rhs));
                },
                .i32_div_u => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, @divTrunc(lhs, rhs));
                },
                .i32_rem_s => {
                    const rhs = e.pop(i32);
                    const lhs = e.pop(i32);
                    e.push(i32, @rem(lhs, rhs));
                },
                .i32_rem_u => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, @rem(lhs, rhs));
                },
                .i32_and => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, lhs & rhs);
                },
                .i32_or => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, lhs | rhs);
                },
                .i32_xor => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, lhs ^ rhs);
                },
                .i32_shl => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, lhs << @truncate(u5, rhs));
                },
                .i32_shr_s => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(i32);
                    e.push(i32, lhs >> @truncate(u5, rhs));
                },
                .i32_shr_u => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, lhs >> @truncate(u5, rhs));
                },
                .i32_rotl => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, math.rotl(u32, lhs, rhs % 32));
                },
                .i32_rotr => {
                    const rhs = e.pop(u32);
                    const lhs = e.pop(u32);
                    e.push(u32, math.rotr(u32, lhs, rhs % 32));
                },

                .i64_clz => {
                    const operand = e.pop(u64);
                    e.push(u64, @clz(operand));
                },
                .i64_ctz => {
                    const operand = e.pop(u64);
                    e.push(u64, @ctz(operand));
                },
                .i64_popcnt => {
                    const operand = e.pop(u64);
                    e.push(u64, @popCount(operand));
                },
                .i64_add => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, lhs +% rhs);
                },
                .i64_sub => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, lhs -% rhs);
                },
                .i64_mul => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, lhs *% rhs);
                },
                .i64_div_s => {
                    const rhs = e.pop(i64);
                    const lhs = e.pop(i64);
                    e.push(i64, @divTrunc(lhs, rhs));
                },
                .i64_div_u => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, @divTrunc(lhs, rhs));
                },
                .i64_rem_s => {
                    const rhs = e.pop(i64);
                    const lhs = e.pop(i64);
                    e.push(i64, @rem(lhs, rhs));
                },
                .i64_rem_u => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, @rem(lhs, rhs));
                },
                .i64_and => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, lhs & rhs);
                },
                .i64_or => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, lhs | rhs);
                },
                .i64_xor => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, lhs ^ rhs);
                },
                .i64_shl => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, lhs << @truncate(u6, rhs));
                },
                .i64_shr_s => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(i64);
                    e.push(i64, lhs >> @truncate(u6, rhs));
                },
                .i64_shr_u => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, lhs >> @truncate(u6, rhs));
                },
                .i64_rotl => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, math.rotl(u64, lhs, rhs % 64));
                },
                .i64_rotr => {
                    const rhs = e.pop(u64);
                    const lhs = e.pop(u64);
                    e.push(u64, math.rotr(u64, lhs, rhs % 64));
                },

                .f32_abs => {
                    e.push(f32, @fabs(e.pop(f32)));
                },
                .f32_neg => {
                    e.push(f32, -e.pop(f32));
                },
                .f32_ceil => {
                    e.push(f32, @ceil(e.pop(f32)));
                },
                .f32_floor => {
                    e.push(f32, @floor(e.pop(f32)));
                },
                .f32_trunc => {
                    e.push(f32, @trunc(e.pop(f32)));
                },
                .f32_nearest => {
                    e.push(f32, @round(e.pop(f32)));
                },
                .f32_sqrt => {
                    e.push(f32, @sqrt(e.pop(f32)));
                },
                .f32_add => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(f32, lhs + rhs);
                },
                .f32_sub => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(f32, lhs - rhs);
                },
                .f32_mul => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(f32, lhs * rhs);
                },
                .f32_div => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(f32, lhs / rhs);
                },
                .f32_min => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(f32, @min(lhs, rhs));
                },
                .f32_max => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(f32, @max(lhs, rhs));
                },
                .f32_copysign => {
                    const rhs = e.pop(f32);
                    const lhs = e.pop(f32);
                    e.push(f32, math.copysign(lhs, rhs));
                },
                .f64_abs => {
                    e.push(f64, @fabs(e.pop(f64)));
                },
                .f64_neg => {
                    e.push(f64, -e.pop(f64));
                },
                .f64_ceil => {
                    e.push(f64, @ceil(e.pop(f64)));
                },
                .f64_floor => {
                    e.push(f64, @floor(e.pop(f64)));
                },
                .f64_trunc => {
                    e.push(f64, @trunc(e.pop(f64)));
                },
                .f64_nearest => {
                    e.push(f64, @round(e.pop(f64)));
                },
                .f64_sqrt => {
                    e.push(f64, @sqrt(e.pop(f64)));
                },
                .f64_add => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(f64, lhs + rhs);
                },
                .f64_sub => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(f64, lhs - rhs);
                },
                .f64_mul => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(f64, lhs * rhs);
                },
                .f64_div => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(f64, lhs / rhs);
                },
                .f64_min => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(f64, @min(lhs, rhs));
                },
                .f64_max => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(f64, @max(lhs, rhs));
                },
                .f64_copysign => {
                    const rhs = e.pop(f64);
                    const lhs = e.pop(f64);
                    e.push(f64, math.copysign(lhs, rhs));
                },

                .i32_wrap_i64 => {
                    const operand = e.pop(i64);
                    e.push(i32, @truncate(i32, operand));
                },
                .i32_trunc_f32_s => {
                    const operand = e.pop(f32);
                    e.push(i32, @floatToInt(i32, @trunc(operand)));
                },
                .i32_trunc_f32_u => {
                    const operand = e.pop(f32);
                    e.push(u32, @floatToInt(u32, @trunc(operand)));
                },
                .i32_trunc_f64_s => {
                    const operand = e.pop(f64);
                    e.push(i32, @floatToInt(i32, @trunc(operand)));
                },
                .i32_trunc_f64_u => {
                    const operand = e.pop(f64);
                    e.push(u32, @floatToInt(u32, @trunc(operand)));
                },
                .i64_extend_i32_s => {
                    const operand = e.pop(i64);
                    e.push(i64, @truncate(i32, operand));
                },
                .i64_extend_i32_u => {
                    const operand = e.pop(u64);
                    e.push(u64, @truncate(u32, operand));
                },
                .i64_trunc_f32_s => {
                    const operand = e.pop(f32);
                    e.push(i64, @floatToInt(i64, @trunc(operand)));
                },
                .i64_trunc_f32_u => {
                    const operand = e.pop(f32);
                    e.push(u64, @floatToInt(u64, @trunc(operand)));
                },
                .i64_trunc_f64_s => {
                    const operand = e.pop(f64);
                    e.push(i64, @floatToInt(i64, @trunc(operand)));
                },
                .i64_trunc_f64_u => {
                    const operand = e.pop(f64);
                    e.push(u64, @floatToInt(u64, @trunc(operand)));
                },
                .f32_convert_i32_s => {
                    e.push(f32, @intToFloat(f32, e.pop(i32)));
                },
                .f32_convert_i32_u => {
                    e.push(f32, @intToFloat(f32, e.pop(u32)));
                },
                .f32_convert_i64_s => {
                    e.push(f32, @intToFloat(f32, e.pop(i64)));
                },
                .f32_convert_i64_u => {
                    e.push(f32, @intToFloat(f32, e.pop(u64)));
                },
                .f32_demote_f64 => {
                    e.push(f32, @floatCast(f32, e.pop(f64)));
                },
                .f64_convert_i32_s => {
                    e.push(f64, @intToFloat(f64, e.pop(i32)));
                },
                .f64_convert_i32_u => {
                    e.push(f64, @intToFloat(f64, e.pop(u32)));
                },
                .f64_convert_i64_s => {
                    e.push(f64, @intToFloat(f64, e.pop(i64)));
                },
                .f64_convert_i64_u => {
                    e.push(f64, @intToFloat(f64, e.pop(u64)));
                },
                .f64_promote_f32 => {
                    e.push(f64, e.pop(f32));
                },
                .i32_reinterpret_f32 => {
                    e.push(u32, @bitCast(u32, e.pop(f32)));
                },
                .i64_reinterpret_f64 => {
                    e.push(u64, @bitCast(u64, e.pop(f64)));
                },
                .f32_reinterpret_i32 => {
                    e.push(f32, @bitCast(f32, e.pop(u32)));
                },
                .f64_reinterpret_i64 => {
                    e.push(f64, @bitCast(f64, e.pop(u64)));
                },

                .i32_extend8_s => {
                    e.push(i32, @truncate(i8, e.pop(i32)));
                },
                .i32_extend16_s => {
                    e.push(i32, @truncate(i16, e.pop(i32)));
                },
                .i64_extend8_s => {
                    e.push(i64, @truncate(i8, e.pop(i64)));
                },
                .i64_extend16_s => {
                    e.push(i64, @truncate(i16, e.pop(i64)));
                },
                .i64_extend32_s => {
                    e.push(i64, @truncate(i32, e.pop(i64)));
                },
                .prefixed => {
                    const prefixed_op = @intToEnum(wasm.PrefixedOpcode, module_bytes[pc.*]);
                    pc.* += 1;
                    switch (prefixed_op) {
                        .i32_trunc_sat_f32_s => unreachable,
                        .i32_trunc_sat_f32_u => unreachable,
                        .i32_trunc_sat_f64_s => unreachable,
                        .i32_trunc_sat_f64_u => unreachable,
                        .i64_trunc_sat_f32_s => unreachable,
                        .i64_trunc_sat_f32_u => unreachable,
                        .i64_trunc_sat_f64_s => unreachable,
                        .i64_trunc_sat_f64_u => unreachable,
                        .memory_init => unreachable,
                        .data_drop => unreachable,
                        .memory_copy => {
                            pc.* += 2;
                            const n = e.pop(u32);
                            const src = e.pop(u32);
                            const dest = e.pop(u32);
                            assert(dest + n <= e.memory.len);
                            assert(src + n <= e.memory.len);
                            assert(src + n <= dest or dest + n <= src); // overlapping
                            @memcpy(e.memory.ptr + dest, e.memory.ptr + src, n);
                        },
                        .memory_fill => {
                            pc.* += 1;
                            const n = e.pop(u32);
                            const value = @truncate(u8, e.pop(u32));
                            const dest = e.pop(u32);
                            assert(dest + n <= e.memory.len);
                            @memset(e.memory.ptr + dest, value, n);
                        },
                        .table_init => unreachable,
                        .elem_drop => unreachable,
                        .table_copy => unreachable,
                        .table_grow => unreachable,
                        .table_size => unreachable,
                        .table_fill => unreachable,
                        _ => unreachable,
                    }
                },
                _ => unreachable,
            }
        }
    }
};

const SectionPos = struct {
    index: usize,
    len: usize,
};

fn readVarInt(bytes: []const u8, i: *u32, comptime T: type) T {
    switch (@typeInfo(T)) {
        .Enum => |info| {
            const int_result = readVarInt(bytes, i, info.tag_type);
            return @intToEnum(T, int_result);
        },
        else => {},
    }
    const readFn = switch (@typeInfo(T).Int.signedness) {
        .signed => std.leb.readILEB128,
        .unsigned => std.leb.readULEB128,
    };
    var fbs = std.io.fixedBufferStream(bytes);
    fbs.pos = i.*;
    const result = readFn(T, fbs.reader()) catch unreachable;
    i.* = @intCast(u32, fbs.pos);
    return result;
}

fn readName(bytes: []const u8, i: *u32) []const u8 {
    const len = readVarInt(bytes, i, u32);
    const result = bytes[i.*..][0..len];
    i.* += len;
    return result;
}

fn readFloat32(bytes: []const u8, i: *u32) f32 {
    const result_ptr = @ptrCast(*align(1) const f32, bytes[i.*..][0..4]);
    i.* += 4;
    return result_ptr.*;
}

fn readFloat64(bytes: []const u8, i: *u32) f64 {
    const result_ptr = @ptrCast(*align(1) const f64, bytes[i.*..][0..8]);
    i.* += 8;
    return result_ptr.*;
}

/// fn args_sizes_get(argc: *usize, argv_buf_size: *usize) errno_t;
fn wasi_args_sizes_get(e: *Exec, argc: u32, argv_buf_size: u32) wasi.errno_t {
    trace_log.debug("wasi_args_sizes_get argc={d} argv_buf_size={d}", .{ argc, argv_buf_size });
    mem.writeIntLittle(u32, e.memory[argc..][0..4], @intCast(u32, e.args.len));
    var buf_size: usize = 0;
    for (e.args) |arg| {
        buf_size += arg.len + 1;
    }
    mem.writeIntLittle(u32, e.memory[argv_buf_size..][0..4], @intCast(u32, buf_size));
    return .SUCCESS;
}

/// extern fn args_get(argv: [*][*:0]u8, argv_buf: [*]u8) errno_t;
fn wasi_args_get(e: *Exec, argv: u32, argv_buf: u32) wasi.errno_t {
    trace_log.debug("wasi_args_get argv={d} argv_buf={d}", .{ argv, argv_buf });
    var argv_buf_i: usize = 0;
    for (e.args) |arg, arg_i| {
        // Write the arg to the buffer.
        const argv_ptr = argv_buf + argv_buf_i;
        mem.copy(u8, e.memory[argv_buf + argv_buf_i ..], arg);
        e.memory[argv_buf + argv_buf_i + arg.len] = 0;
        argv_buf_i += arg.len + 1;

        mem.writeIntLittle(u32, e.memory[argv + 4 * arg_i ..][0..4], @intCast(u32, argv_ptr));
    }
    return .SUCCESS;
}

/// extern fn random_get(buf: [*]u8, buf_len: usize) errno_t;
fn wasi_random_get(e: *Exec, buf: u32, buf_len: u32) wasi.errno_t {
    const host_buf = e.memory[buf..][0..buf_len];
    std.crypto.random.bytes(host_buf);
    trace_log.debug("random_get {x}", .{std.fmt.fmtSliceHexLower(host_buf)});
    return .SUCCESS;
}

var preopens_buffer: [10]Preopen = undefined;
var preopens_len: usize = 0;

const Preopen = struct {
    wasi_fd: wasi.fd_t,
    name: []const u8,
    host_fd: os.fd_t,
};

fn addPreopen(wasi_fd: wasi.fd_t, name: []const u8, host_fd: os.fd_t) void {
    preopens_buffer[preopens_len] = .{
        .wasi_fd = wasi_fd,
        .name = name,
        .host_fd = host_fd,
    };
    preopens_len += 1;
}

fn findPreopen(wasi_fd: wasi.fd_t) ?Preopen {
    for (preopens_buffer[0..preopens_len]) |preopen| {
        if (preopen.wasi_fd == wasi_fd) {
            return preopen;
        }
    }
    return null;
}

fn toHostFd(wasi_fd: wasi.fd_t) os.fd_t {
    const preopen = findPreopen(wasi_fd) orelse return wasi_fd;
    return preopen.host_fd;
}

/// fn fd_prestat_get(fd: fd_t, buf: *prestat_t) errno_t;
/// const prestat_t = extern struct {
///     pr_type: u8,
///     u: usize,
/// };
fn wasi_fd_prestat_get(e: *Exec, fd: wasi.fd_t, buf: u32) wasi.errno_t {
    trace_log.debug("wasi_fd_prestat_get fd={d} buf={d}", .{ fd, buf });
    const preopen = findPreopen(fd) orelse return .BADF;
    mem.writeIntLittle(u32, e.memory[buf + 0 ..][0..4], 0);
    mem.writeIntLittle(u32, e.memory[buf + 4 ..][0..4], @intCast(u32, preopen.name.len));
    return .SUCCESS;
}

/// fn fd_prestat_dir_name(fd: fd_t, path: [*]u8, path_len: usize) errno_t;
fn wasi_fd_prestat_dir_name(e: *Exec, fd: wasi.fd_t, path: u32, path_len: u32) wasi.errno_t {
    trace_log.debug("wasi_fd_prestat_dir_name fd={d} path={d} path_len={d}", .{ fd, path, path_len });
    const preopen = findPreopen(fd) orelse return .BADF;
    assert(path_len == preopen.name.len);
    mem.copy(u8, e.memory[path..], preopen.name);
    return .SUCCESS;
}

/// extern fn fd_close(fd: fd_t) errno_t;
fn wasi_fd_close(e: *Exec, fd: wasi.fd_t) wasi.errno_t {
    trace_log.debug("wasi_fd_close fd={d}", .{fd});
    _ = e;
    const host_fd = toHostFd(fd);
    os.close(host_fd);
    return .SUCCESS;
}

fn wasi_fd_read(
    e: *Exec,
    fd: wasi.fd_t,
    iovs: u32, // [*]const iovec_t
    iovs_len: u32, // usize
    nread: u32, // *usize
) wasi.errno_t {
    trace_log.debug("wasi_fd_read fd={d} iovs={d} iovs_len={d} nread={d}", .{
        fd, iovs, iovs_len, nread,
    });
    const host_fd = toHostFd(fd);
    var i: u32 = 0;
    var total_read: usize = 0;
    while (i < iovs_len) : (i += 1) {
        const ptr = mem.readIntLittle(u32, e.memory[iovs + i * 8 + 0 ..][0..4]);
        const len = mem.readIntLittle(u32, e.memory[iovs + i * 8 + 4 ..][0..4]);
        const buf = e.memory[ptr..][0..len];
        const read = os.read(host_fd, buf) catch |err| return toWasiError(err);
        trace_log.debug("read {d} bytes out of {d}", .{ read, buf.len });
        total_read += read;
        if (read != buf.len) break;
    }
    mem.writeIntLittle(u32, e.memory[nread..][0..4], @intCast(u32, total_read));
    return .SUCCESS;
}

/// extern fn fd_write(fd: fd_t, iovs: [*]const ciovec_t, iovs_len: usize, nwritten: *usize) errno_t;
/// const ciovec_t = extern struct {
///     base: [*]const u8,
///     len: usize,
/// };
fn wasi_fd_write(e: *Exec, fd: wasi.fd_t, iovs: u32, iovs_len: u32, nwritten: u32) wasi.errno_t {
    trace_log.debug("wasi_fd_write fd={d} iovs={d} iovs_len={d} nwritten={d}", .{
        fd, iovs, iovs_len, nwritten,
    });
    const host_fd = toHostFd(fd);
    var i: u32 = 0;
    var total_written: usize = 0;
    while (i < iovs_len) : (i += 1) {
        const ptr = mem.readIntLittle(u32, e.memory[iovs + i * 8 + 0 ..][0..4]);
        const len = mem.readIntLittle(u32, e.memory[iovs + i * 8 + 4 ..][0..4]);
        const buf = e.memory[ptr..][0..len];
        const written = os.write(host_fd, buf) catch |err| return toWasiError(err);
        total_written += written;
        if (written != buf.len) break;
    }
    mem.writeIntLittle(u32, e.memory[nwritten..][0..4], @intCast(u32, total_written));
    return .SUCCESS;
}

fn wasi_fd_pwrite(
    e: *Exec,
    fd: wasi.fd_t,
    iovs: u32, // [*]const ciovec_t
    iovs_len: u32, // usize
    offset: wasi.filesize_t,
    written_ptr: u32, // *usize
) wasi.errno_t {
    trace_log.debug("wasi_fd_write fd={d} iovs={d} iovs_len={d} offset={d} written_ptr={d}", .{
        fd, iovs, iovs_len, offset, written_ptr,
    });
    const host_fd = toHostFd(fd);
    var i: u32 = 0;
    var written: usize = 0;
    while (i < iovs_len) : (i += 1) {
        const ptr = mem.readIntLittle(u32, e.memory[iovs + i * 8 + 0 ..][0..4]);
        const len = mem.readIntLittle(u32, e.memory[iovs + i * 8 + 4 ..][0..4]);
        const buf = e.memory[ptr..][0..len];
        const w = os.pwrite(host_fd, buf, offset + written) catch |err| return toWasiError(err);
        written += w;
        if (w != buf.len) break;
    }
    mem.writeIntLittle(u32, e.memory[written_ptr..][0..4], @intCast(u32, written));
    return .SUCCESS;
}

///extern fn path_open(
///    dirfd: fd_t,
///    dirflags: lookupflags_t,
///    path: [*]const u8,
///    path_len: usize,
///    oflags: oflags_t,
///    fs_rights_base: rights_t,
///    fs_rights_inheriting: rights_t,
///    fs_flags: fdflags_t,
///    fd: *fd_t,
///) errno_t;
fn wasi_path_open(
    e: *Exec,
    dirfd: wasi.fd_t,
    dirflags: wasi.lookupflags_t,
    path: u32,
    path_len: u32,
    oflags: wasi.oflags_t,
    fs_rights_base: wasi.rights_t,
    fs_rights_inheriting: wasi.rights_t,
    fs_flags: wasi.fdflags_t,
    fd: u32,
) wasi.errno_t {
    const sub_path = e.memory[path..][0..path_len];
    trace_log.debug("wasi_path_open dirfd={d} dirflags={d} path={s} oflags={d} fs_rights_base={d} fs_rights_inheriting={d} fs_flags={d} fd={d}", .{
        dirfd, dirflags, sub_path, oflags, fs_rights_base, fs_rights_inheriting, fs_flags, fd,
    });
    const host_fd = toHostFd(dirfd);
    var flags: u32 = @as(u32, if (oflags & wasi.O.CREAT != 0) os.O.CREAT else 0) |
        @as(u32, if (oflags & wasi.O.DIRECTORY != 0) os.O.DIRECTORY else 0) |
        @as(u32, if (oflags & wasi.O.EXCL != 0) os.O.EXCL else 0) |
        @as(u32, if (oflags & wasi.O.TRUNC != 0) os.O.TRUNC else 0) |
        @as(u32, if (fs_flags & wasi.FDFLAG.APPEND != 0) os.O.APPEND else 0) |
        @as(u32, if (fs_flags & wasi.FDFLAG.DSYNC != 0) os.O.DSYNC else 0) |
        @as(u32, if (fs_flags & wasi.FDFLAG.NONBLOCK != 0) os.O.NONBLOCK else 0) |
        @as(u32, if (fs_flags & wasi.FDFLAG.SYNC != 0) os.O.SYNC else 0);
    if ((fs_rights_base & wasi.RIGHT.FD_READ != 0) and
        (fs_rights_base & wasi.RIGHT.FD_WRITE != 0))
    {
        flags |= os.O.RDWR;
    } else if (fs_rights_base & wasi.RIGHT.FD_WRITE != 0) {
        flags |= os.O.WRONLY;
    } else if (fs_rights_base & wasi.RIGHT.FD_READ != 0) {
        flags |= os.O.RDONLY; // no-op because O_RDONLY is 0
    }
    const mode = 0o644;
    const res_fd = os.openat(host_fd, sub_path, flags, mode) catch |err| return toWasiError(err);
    mem.writeIntLittle(i32, e.memory[fd..][0..4], res_fd);
    return .SUCCESS;
}

fn wasi_path_filestat_get(
    e: *Exec,
    fd: wasi.fd_t,
    flags: wasi.lookupflags_t,
    path: u32, // [*]const u8
    path_len: u32, // usize
    buf: u32, // *filestat_t
) wasi.errno_t {
    const sub_path = e.memory[path..][0..path_len];
    trace_log.debug("wasi_path_filestat_get fd={d} flags={d} path={s} buf={d}", .{
        fd, flags, sub_path, buf,
    });
    const host_fd = toHostFd(fd);
    const dir: fs.Dir = .{ .fd = host_fd };
    const stat = dir.statFile(sub_path) catch |err| return toWasiError(err);
    return finishWasiStat(e, buf, stat);
}

/// extern fn path_create_directory(fd: fd_t, path: [*]const u8, path_len: usize) errno_t;
fn wasi_path_create_directory(e: *Exec, fd: wasi.fd_t, path: u32, path_len: u32) wasi.errno_t {
    const sub_path = e.memory[path..][0..path_len];
    trace_log.debug("wasi_path_create_directory fd={d} path={s}", .{ fd, sub_path });
    const host_fd = toHostFd(fd);
    const dir: fs.Dir = .{ .fd = host_fd };
    dir.makeDir(sub_path) catch |err| return toWasiError(err);
    return .SUCCESS;
}

fn wasi_path_rename(
    e: *Exec,
    old_fd: wasi.fd_t,
    old_path_ptr: u32, // [*]const u8
    old_path_len: u32, // usize
    new_fd: wasi.fd_t,
    new_path_ptr: u32, // [*]const u8
    new_path_len: u32, // usize
) wasi.errno_t {
    const old_path = e.memory[old_path_ptr..][0..old_path_len];
    const new_path = e.memory[new_path_ptr..][0..new_path_len];
    trace_log.debug("wasi_path_rename old_fd={d} old_path={s} new_fd={d} new_path={s}", .{
        old_fd, old_path, new_fd, new_path,
    });
    const old_host_fd = toHostFd(old_fd);
    const new_host_fd = toHostFd(new_fd);
    os.renameat(old_host_fd, old_path, new_host_fd, new_path) catch |err| return toWasiError(err);
    return .SUCCESS;
}

/// extern fn fd_filestat_get(fd: fd_t, buf: *filestat_t) errno_t;
fn wasi_fd_filestat_get(e: *Exec, fd: wasi.fd_t, buf: u32) wasi.errno_t {
    trace_log.debug("wasi_fd_filestat_get fd={d} buf={d}", .{ fd, buf });
    const host_fd = toHostFd(fd);
    const file = fs.File{ .handle = host_fd };
    const stat = file.stat() catch |err| return toWasiError(err);
    return finishWasiStat(e, buf, stat);
}

fn wasi_fd_filestat_set_size(e: *Exec, fd: wasi.fd_t, size: wasi.filesize_t) wasi.errno_t {
    _ = e;
    trace_log.debug("wasi_fd_filestat_set_size fd={d} size={d}", .{ fd, size });
    const host_fd = toHostFd(fd);
    os.ftruncate(host_fd, size) catch |err| return toWasiError(err);
    return .SUCCESS;
}

/// pub extern "wasi_snapshot_preview1" fn fd_fdstat_get(fd: fd_t, buf: *fdstat_t) errno_t;
/// pub const fdstat_t = extern struct {
///     fs_filetype: filetype_t, u8
///     fs_flags: fdflags_t, u16
///     fs_rights_base: rights_t, u64
///     fs_rights_inheriting: rights_t, u64
/// };
fn wasi_fd_fdstat_get(e: *Exec, fd: wasi.fd_t, buf: u32) wasi.errno_t {
    trace_log.debug("wasi_fd_fdstat_get fd={d} buf={d}", .{ fd, buf });
    const host_fd = toHostFd(fd);
    const file = fs.File{ .handle = host_fd };
    const stat = file.stat() catch |err| return toWasiError(err);
    mem.writeIntLittle(u16, e.memory[buf + 0x00 ..][0..2], @enumToInt(toWasiFileType(stat.kind)));
    mem.writeIntLittle(u16, e.memory[buf + 0x02 ..][0..2], 0); // flags
    mem.writeIntLittle(u64, e.memory[buf + 0x08 ..][0..8], math.maxInt(u64)); // rights_base
    mem.writeIntLittle(u64, e.memory[buf + 0x10 ..][0..8], math.maxInt(u64)); // rights_inheriting
    return .SUCCESS;
}

/// extern fn clock_time_get(clock_id: clockid_t, precision: timestamp_t, timestamp: *timestamp_t) errno_t;
fn wasi_clock_time_get(e: *Exec, clock_id: wasi.clockid_t, precision: wasi.timestamp_t, timestamp: u32) wasi.errno_t {
    //const host_clock_id = toHostClockId(clock_id);
    _ = precision;
    _ = clock_id;
    const wasi_ts = toWasiTimestamp(std.time.nanoTimestamp());
    mem.writeIntLittle(u64, e.memory[timestamp..][0..8], wasi_ts);
    return .SUCCESS;
}

///pub extern "wasi_snapshot_preview1" fn debug(string: [*:0]const u8, x: u64) void;
fn wasi_debug(e: *Exec, text: u32, n: u64) void {
    const s = mem.sliceTo(e.memory[text..], 0);
    trace_log.debug("wasi_debug: '{s}' number={d} {x}", .{ s, n, n });
}

/// pub extern "wasi_snapshot_preview1" fn debug_slice(ptr: [*]const u8, len: usize) void;
fn wasi_debug_slice(e: *Exec, ptr: u32, len: u32) void {
    const s = e.memory[ptr..][0..len];
    trace_log.debug("wasi_debug_slice: '{s}'", .{s});
}

fn toWasiTimestamp(ns: i128) u64 {
    return @intCast(u64, ns);
}

fn toWasiError(err: anyerror) wasi.errno_t {
    trace_log.warn("wasi error: {s}", .{@errorName(err)});
    return switch (err) {
        error.AccessDenied => .ACCES,
        error.DiskQuota => .DQUOT,
        error.InputOutput => .IO,
        error.FileTooBig => .FBIG,
        error.NoSpaceLeft => .NOSPC,
        error.BrokenPipe => .PIPE,
        error.NotOpenForWriting => .BADF,
        error.SystemResources => .NOMEM,
        error.FileNotFound => .NOENT,
        error.PathAlreadyExists => .EXIST,
        else => std.debug.panic("unexpected error: {s}", .{@errorName(err)}),
    };
}

fn toWasiFileType(kind: fs.File.Kind) wasi.filetype_t {
    return switch (kind) {
        .BlockDevice => .BLOCK_DEVICE,
        .CharacterDevice => .CHARACTER_DEVICE,
        .Directory => .DIRECTORY,
        .SymLink => .SYMBOLIC_LINK,
        .File => .REGULAR_FILE,
        .Unknown => .UNKNOWN,

        .NamedPipe,
        .UnixDomainSocket,
        .Whiteout,
        .Door,
        .EventPort,
        => .UNKNOWN,
    };
}

/// const filestat_t = extern struct {
///     dev: device_t, u64
///     ino: inode_t, u64
///     filetype: filetype_t, u8
///     nlink: linkcount_t, u64
///     size: filesize_t, u64
///     atim: timestamp_t, u64
///     mtim: timestamp_t, u64
///     ctim: timestamp_t, u64
/// };
fn finishWasiStat(e: *Exec, buf: u32, stat: fs.File.Stat) wasi.errno_t {
    mem.writeIntLittle(u64, e.memory[buf + 0x00 ..][0..8], 0); // device
    mem.writeIntLittle(u64, e.memory[buf + 0x08 ..][0..8], stat.inode);
    mem.writeIntLittle(u64, e.memory[buf + 0x10 ..][0..8], @enumToInt(toWasiFileType(stat.kind)));
    mem.writeIntLittle(u64, e.memory[buf + 0x18 ..][0..8], 1); // nlink
    mem.writeIntLittle(u64, e.memory[buf + 0x20 ..][0..8], stat.size);
    mem.writeIntLittle(u64, e.memory[buf + 0x28 ..][0..8], toWasiTimestamp(stat.atime));
    mem.writeIntLittle(u64, e.memory[buf + 0x30 ..][0..8], toWasiTimestamp(stat.mtime));
    mem.writeIntLittle(u64, e.memory[buf + 0x38 ..][0..8], toWasiTimestamp(stat.ctime));
    return .SUCCESS;
}
