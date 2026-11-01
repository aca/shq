//! shq: a pueue-like job queue where every job runs on its own pty and can be
//! attached/detached like dtach/abduco. The daemon feeds each pty's output into
//! a libghostty-vt Terminal so a reattaching client gets the current screen.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const c = std.c;
const Allocator = std.mem.Allocator;

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const c.winsize) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
// std.c.termios is 44 bytes but glibc's struct termios is 60 (macOS: 72), so
// tcgetattr through std.c overwrites the stack. Treat it as an opaque blob.
const Termios = extern struct { buf: [128]u8 align(8) };
extern "c" fn tcgetattr(fd: c.fd_t, t: *Termios) c_int;
extern "c" fn tcsetattr(fd: c.fd_t, action: c_int, t: *const Termios) c_int;
extern "c" fn cfmakeraw(t: *Termios) void;
extern "c" fn signal(sig: c_int, handler: usize) usize;
extern "c" fn close_range(first: c_uint, last: c_uint, flags: c_int) c_int;
extern "c" fn daemon(nochdir: c_int, noclose: c_int) c_int;
extern "c" fn getdtablesize() c_int;
// std.c.ioctl takes a c_int request, too narrow for macOS's TIOCSWINSZ.
extern "c" fn ioctl(fd: c.fd_t, request: c_ulong, ...) c_int;

const SIG_DFL: usize = 0;
const SIG_IGN: usize = 1;
const SIGHUP = 1;
const SIGPIPE = 13;
const SIGWINCH = 28;

// std.posix.T lacks these on macOS.
const TIOCSCTTY = if (builtin.os.tag == .macos) 0x20007461 else std.posix.T.IOCSCTTY;
const TIOCSWINSZ = if (builtin.os.tag == .macos) 0x80087467 else std.posix.T.IOCSWINSZ;

/// Ctrl-\ detaches.
const detach_key: u8 = 0x1c;

const usage_text =
    \\usage: shq <command> [args]
    \\
    \\  add <cmd> [args...] queue a command with the current cwd + env, prints job id
    \\  ls [--json]         list jobs (default)
    \\  attach <id>         attach to a running job (detach: Ctrl-\)
    \\  log <id>            print screen + scrollback of a job
    \\  run <id>            start a queued job now, ignoring the parallel limit
    \\  kill <id> [sig]     signal a job's process group (default SIGHUP)
    \\  clean               remove finished jobs
    \\  parallel <n>        set number of concurrently running jobs
    \\  daemon              run the daemon in the foreground
    \\
    \\commands may be abbreviated to any prefix; the shortest match wins
    \\
;

const commands = [_][]const u8{ "add", "ls", "attach", "log", "run", "kill", "clean", "parallel", "daemon" };

/// Bump on any wire format change so a stale daemon is detected.
const protocol_version: u8 = 2;

/// Wire protocol: every client->daemon message is a frame
/// [u8 version][u8 type][u32 len LE][payload]. The daemon answers a request with one
/// status byte ('0' ok, '1' error) followed by a raw byte stream, then closes
/// (except for attach, where the stream lasts until detach/job exit).
const Msg = enum(u8) {
    add = 'a',
    ls = 's',
    attach = 'A',
    log = 'l',
    kill = 'k',
    run = 'r',
    clean = 'c',
    parallel = 'p',
    input = 'i',
    resize = 'w',
    _,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const cmd = if (args.len < 2) "ls" else resolveCommand(args[1]);
    const rest = if (args.len < 2) args[0..0] else args[2..];

    if (eql(cmd, "daemon")) return daemonMain(init.io, init.gpa, .{});
    proc_io = init.io;
    proc_gpa = init.gpa;

    var payload: std.ArrayList(u8) = .empty;
    if (eql(cmd, "add")) {
        if (rest.len == 0) die("add: missing command\n", .{});
        checkCommand(rest[0]);
        const ws = winsize(1);
        try appendInt(arena, &payload, u16, ws.row);
        try appendInt(arena, &payload, u16, ws.col);
        const env = std.mem.span(c.environ);
        try appendInt(arena, &payload, u32, @intCast(rest.len));
        try appendInt(arena, &payload, u32, @intCast(env.len));
        var cwd_buf: [4096]u8 = undefined;
        const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse die("getcwd failed\n", .{});
        try payload.appendSlice(arena, std.mem.span(@as([*:0]u8, @ptrCast(cwd))));
        try payload.append(arena, 0);
        for (rest) |a| try payload.appendSlice(arena, a[0 .. a.len + 1]);
        for (env) |e| {
            const kv = std.mem.span(e.?);
            try payload.appendSlice(arena, kv[0 .. kv.len + 1]);
        }
        return simpleRequest(.add, payload.items);
    } else if (eql(cmd, "ls")) {
        if (rest.len > 0 and !eql(rest[0], "--json")) die("ls: unknown option: {s}\n", .{rest[0]});
        return simpleRequest(.ls, if (rest.len > 0) "j" else "");
    } else if (eql(cmd, "log")) {
        try appendInt(arena, &payload, u32, parseId(rest));
        return simpleRequest(.log, payload.items);
    } else if (eql(cmd, "kill")) {
        try appendInt(arena, &payload, u32, parseId(rest));
        const sig: u8 = if (rest.len > 1)
            std.fmt.parseInt(u8, rest[1], 10) catch die("bad signal: {s}\n", .{rest[1]})
        else
            SIGHUP;
        try payload.append(arena, sig);
        return simpleRequest(.kill, payload.items);
    } else if (eql(cmd, "run")) {
        try appendInt(arena, &payload, u32, parseId(rest));
        return simpleRequest(.run, payload.items);
    } else if (eql(cmd, "clean")) {
        return simpleRequest(.clean, "");
    } else if (eql(cmd, "parallel")) {
        try appendInt(arena, &payload, u32, parseId(rest));
        return simpleRequest(.parallel, payload.items);
    } else if (eql(cmd, "attach")) {
        return attach(parseId(rest));
    }
    die(usage_text, .{});
}

// ---------------------------------------------------------------- client

fn simpleRequest(typ: Msg, payload: []const u8) void {
    const fd = request(typ, payload);
    defer _ = c.close(fd);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        writeAll(1, buf[0..@intCast(n)]) catch break;
    }
}

/// Connects, sends the request frame and consumes the status byte. On error
/// prints the daemon's message and exits.
fn request(typ: Msg, payload: []const u8) c.fd_t {
    const fd = connectDaemon();
    sendFrame(fd, typ, payload) catch die("send failed\n", .{});
    var status: [1]u8 = undefined;
    if (c.read(fd, &status, 1) != 1) die("daemon closed connection\n", .{});
    if (status[0] != '0') {
        var buf: [4096]u8 = undefined;
        const n = c.read(fd, &buf, buf.len);
        if (n > 0) writeAll(2, buf[0..@intCast(n)]) catch {} else
        // Pre-versioning daemons reject unknown frames without a message.
        writeAll(2, "shq: request rejected; the daemon may be an older version, restart it\n") catch {};
        std.process.exit(1);
    }
    return fd;
}

var winch_pending: std.atomic.Value(bool) = .init(false);

fn onWinch(_: c_int) callconv(.c) void {
    winch_pending.store(true, .release);
}

fn attach(id: u32) void {
    if (c.isatty(0) == 0) die("attach: stdin is not a tty\n", .{});
    const ws = winsize(1);
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], id, .little);
    std.mem.writeInt(u16, payload[4..6], ws.row, .little);
    std.mem.writeInt(u16, payload[6..8], ws.col, .little);
    const fd = request(.attach, &payload);
    defer _ = c.close(fd);

    var orig: Termios = undefined;
    _ = tcgetattr(0, &orig);
    var raw = orig;
    cfmakeraw(&raw);
    _ = tcsetattr(0, 0, &raw);
    _ = signal(SIGWINCH, @intFromPtr(&onWinch));

    var detached = false;
    var buf: [65536]u8 = undefined;
    loop: while (true) {
        if (winch_pending.swap(false, .acq_rel)) {
            const nws = winsize(1);
            var p: [4]u8 = undefined;
            std.mem.writeInt(u16, p[0..2], nws.row, .little);
            std.mem.writeInt(u16, p[2..4], nws.col, .little);
            sendFrame(fd, .resize, &p) catch break;
        }
        var fds = [_]c.pollfd{
            .{ .fd = 0, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = c.POLL.IN, .revents = 0 },
        };
        if (c.poll(&fds, fds.len, -1) < 0) continue; // EINTR from SIGWINCH

        if (fds[1].revents != 0) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            writeAll(1, buf[0..@intCast(n)]) catch break;
        }
        if (fds[0].revents != 0) {
            const n = c.read(0, &buf, buf.len);
            if (n <= 0) break;
            var in = buf[0..@intCast(n)];
            if (std.mem.indexOfScalar(u8, in, detach_key)) |i| {
                in = in[0..i];
                detached = true;
            }
            if (in.len > 0) sendFrame(fd, .input, in) catch break;
            if (detached) break :loop;
        }
    }

    _ = tcsetattr(0, 0, &orig);
    // Undo modes the job may have enabled on the outer terminal.
    writeAll(1, "\x1b[0m\x1b[?25h\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l" ++
        "\x1b[?1006l\x1b[?2004l\x1b[?1l\x1b>\x1b[<99u") catch {};
    if (detached) writeAll(1, "\n[shq] detached\n") catch {};
}

/// Fails early, like the shell would, if a bare command name isn't in PATH.
/// Names containing '/' are left for execvp to report.
fn checkCommand(name: [:0]const u8) void {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return;
    const path_env = std.mem.span(c.getenv("PATH") orelse "/usr/bin:/bin");
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        var buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }, 0) catch continue;
        if (c.access(full, 1) == 0) return; // X_OK
    }
    var buf: [4096]u8 = undefined;
    const local = std.fmt.bufPrintSentinel(&buf, "./{s}", .{name}, 0) catch die("{s}: command not found\n", .{name});
    if (c.access(local, 1) == 0) die("{s}: command not found (did you mean ./{s}?)\n", .{ name, name });
    die("{s}: command not found\n", .{name});
}

/// The server is forked from the client without exec (like tmux), so it
/// needs these from main().
var proc_io: std.Io = undefined;
var proc_gpa: Allocator = undefined;

/// Connects to the daemon, starting it if needed. Mirrors tmux's
/// client_connect: a lock file serializes server startup so two clients
/// racing can't both start one.
fn connectDaemon() c.fd_t {
    var path_buf: [108]u8 = undefined;
    const path = runtimePath(&path_buf, "shq.sock");
    var lock_buf: [108]u8 = undefined;
    const lock_path = runtimePath(&lock_buf, "shq.lock");

    var lockfd: c.fd_t = -1;
    while (true) {
        if (tryConnect(path)) |fd| {
            if (lockfd >= 0) _ = c.close(lockfd);
            return fd;
        }
        if (lockfd < 0) {
            // Retry the connect at least once after taking the lock: another
            // client may have started the server and released the lock in
            // between our connect() and flock().
            lockfd = getLock(lock_path) orelse continue;
            continue;
        }
        _ = c.unlink(path);
        const fd = startServer(lockfd, lock_path);
        _ = c.close(lockfd);
        return fd;
    }
}

/// Returns the locked fd, or null if another client held the lock (after
/// waiting for it to be released).
fn getLock(lock_path: [:0]const u8) ?c.fd_t {
    const fd = c.open(lock_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) die("open {s} failed\n", .{lock_path});
    if (c.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) == 0) return fd;
    _ = c.flock(fd, std.posix.LOCK.EX);
    _ = c.close(fd);
    return null;
}

/// Forks the server (fork + daemon(3), as tmux's proc_fork_and_daemon) and
/// returns the client end of a socketpair that is already connected to it.
fn startServer(lockfd: c.fd_t, lock_path: [:0]const u8) c.fd_t {
    var pair: [2]c.fd_t = undefined;
    // No SOCK_CLOEXEC: macOS lacks it (std.c.SOCK.CLOEXEC is only a std.posix shim).
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &pair) != 0) die("socketpair failed\n", .{});
    for (pair) |p| _ = c.fcntl(p, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));

    // Block signals across the forks so e.g. a terminal hangup can't hit the
    // server before daemon() has called setsid().
    const all = std.posix.sigfillset();
    var old: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &all, &old);

    const pid = c.fork();
    if (pid < 0) die("fork failed\n", .{});
    if (pid > 0) {
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &old, null);
        _ = c.close(pair[1]);
        // Reap the intermediate child; daemon() makes it exit right away.
        while (c.waitpid(pid, null, 0) < 0 and c.errno(@as(c_int, -1)) == .INTR) {}
        return pair[0];
    }

    _ = c.close(pair[0]);
    if (daemon(1, 0) != 0) c._exit(1);
    var log_buf: [108]u8 = undefined;
    const logfd = c.open(runtimePath(&log_buf, "shq.log"), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c.mode_t, 0o600));
    if (logfd >= 0) {
        _ = c.dup2(logfd, 2);
        _ = c.close(logfd);
    }
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &old, null);
    daemonMain(proc_io, proc_gpa, .{ .first_client = pair[1], .lockfd = lockfd, .lock_path = lock_path }) catch |err|
        std.log.err("daemon: {t}", .{err});
    c._exit(1);
}

fn tryConnect(path: [:0]const u8) ?c.fd_t {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    var addr = unixAddr(path);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

// ---------------------------------------------------------------- daemon

const Job = struct {
    id: u32,
    /// argv joined with spaces, for display only.
    cmd: []u8,
    /// Owns the NUL-terminated strings that cwd, argv and envp point into.
    strings: []u8,
    cwd: [*:0]const u8,
    argv: [:null]?[*:0]const u8,
    envp: [:null]?[*:0]const u8,
    state: enum { queued, running, done } = .queued,
    killed: bool = false,
    wait_status: c_int = 0,
    pid: c.pid_t = 0,
    master: c.fd_t = -1,
    ws: c.winsize,
    term: vt.Terminal,
    stream: vt.TerminalStream,
};

const Client = struct {
    fd: c.fd_t,
    buf: std.ArrayList(u8) = .empty,
    job: ?*Job = null,
    dead: bool = false,
};

const Daemon = struct {
    io: std.Io,
    gpa: Allocator,
    listen_fd: c.fd_t,
    sigchld_fd: c.fd_t,
    jobs: std.ArrayList(*Job) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    next_id: u32 = 0,
    parallel: u32 = 1,
};

const StartOpts = struct {
    /// Server end of the starting client's socketpair.
    first_client: c.fd_t = -1,
    /// Startup lock held by the starting client; released once listening.
    lockfd: c.fd_t = -1,
    lock_path: [:0]const u8 = "",
};

fn daemonMain(io: std.Io, gpa: Allocator, opts: StartOpts) !void {
    _ = signal(SIGPIPE, SIG_IGN);
    var path_buf: [108]u8 = undefined;
    const path = runtimePath(&path_buf, "shq.sock");
    if (opts.first_client < 0) {
        if (tryConnect(path)) |fd| {
            _ = c.close(fd);
            die("daemon already running on {s}\n", .{path});
        }
        _ = c.unlink(path);
    }

    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) die("socket failed\n", .{});
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    var addr = unixAddr(path);
    _ = c.umask(0o077);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) die("bind {s} failed\n", .{path});
    if (c.listen(fd, 16) != 0) die("listen failed\n", .{});
    if (opts.lockfd >= 0) {
        _ = c.unlink(opts.lock_path);
        _ = c.close(opts.lockfd);
    }

    // Self-pipe for SIGCHLD (signalfd is Linux-only).
    if (c.pipe(&sigchld_pipe) != 0) die("pipe failed\n", .{});
    for (sigchld_pipe) |p| {
        _ = c.fcntl(p, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        _ = c.fcntl(p, c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    }
    _ = signal(@intFromEnum(std.posix.SIG.CHLD), @intFromPtr(&onChld));

    var d: Daemon = .{ .io = io, .gpa = gpa, .listen_fd = fd, .sigchld_fd = sigchld_pipe[0] };
    if (opts.first_client >= 0) {
        const cl = try gpa.create(Client);
        cl.* = .{ .fd = opts.first_client };
        try d.clients.append(gpa, cl);
    }
    try run(&d);
}

var sigchld_pipe: [2]c.fd_t = .{ -1, -1 };

fn onChld(_: c_int) callconv(.c) void {
    _ = c.write(sigchld_pipe[1], "x", 1);
}

const Ref = union(enum) { listen, sigchld, job: *Job, client: *Client };

fn run(d: *Daemon) !void {
    var fds: std.ArrayList(c.pollfd) = .empty;
    var refs: std.ArrayList(Ref) = .empty;
    while (true) {
        fds.clearRetainingCapacity();
        refs.clearRetainingCapacity();
        try fds.append(d.gpa, .{ .fd = d.listen_fd, .events = c.POLL.IN, .revents = 0 });
        try refs.append(d.gpa, .listen);
        try fds.append(d.gpa, .{ .fd = d.sigchld_fd, .events = c.POLL.IN, .revents = 0 });
        try refs.append(d.gpa, .sigchld);
        for (d.jobs.items) |j| if (j.master >= 0) {
            try fds.append(d.gpa, .{ .fd = j.master, .events = c.POLL.IN, .revents = 0 });
            try refs.append(d.gpa, .{ .job = j });
        };
        for (d.clients.items) |cl| {
            try fds.append(d.gpa, .{ .fd = cl.fd, .events = c.POLL.IN, .revents = 0 });
            try refs.append(d.gpa, .{ .client = cl });
        }

        if (c.poll(fds.items.ptr, @intCast(fds.items.len), -1) < 0) continue;

        for (fds.items, refs.items) |pfd, ref| {
            if (pfd.revents == 0) continue;
            switch (ref) {
                .listen => {
                    const cfd = c.accept(d.listen_fd, null, null);
                    if (cfd < 0) continue;
                    _ = c.fcntl(cfd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
                    const cl = try d.gpa.create(Client);
                    cl.* = .{ .fd = cfd };
                    try d.clients.append(d.gpa, cl);
                },
                .sigchld => reapChildren(d),
                .job => |j| if (j.master >= 0 and !pumpOutput(d, j)) closeMaster(j),
                .client => |cl| if (!cl.dead) onClientReadable(d, cl),
            }
        }

        // Sweep clients closed during this iteration.
        var i: usize = 0;
        while (i < d.clients.items.len) {
            const cl = d.clients.items[i];
            if (!cl.dead) {
                i += 1;
                continue;
            }
            _ = c.close(cl.fd);
            cl.buf.deinit(d.gpa);
            d.gpa.destroy(cl);
            _ = d.clients.swapRemove(i);
        }
    }
}

/// Reads one chunk of job output. Returns false on EOF/EIO (all pty slave
/// ends closed).
fn pumpOutput(d: *Daemon, j: *Job) bool {
    var buf: [65536]u8 = undefined;
    const n = c.read(j.master, &buf, buf.len);
    if (n < 0 and c.errno(n) == .INTR) return true;
    if (n <= 0) return false;
    const data = buf[0..@intCast(n)];
    j.stream.nextSlice(data);
    for (d.clients.items) |cl| {
        if (cl.job == j and !cl.dead) writeAll(cl.fd, data) catch {
            cl.dead = true;
        };
    }
    return true;
}

fn closeMaster(j: *Job) void {
    _ = c.close(j.master);
    j.master = -1;
}

fn reapChildren(d: *Daemon) void {
    var drain: [128]u8 = undefined;
    while (c.read(d.sigchld_fd, &drain, drain.len) > 0) {}
    while (true) {
        var status: c_int = 0;
        const pid = c.waitpid(-1, &status, std.posix.W.NOHANG);
        if (pid <= 0) return;
        for (d.jobs.items) |j| {
            if (j.state == .running and j.pid == pid) finishJob(d, j, status);
        }
    }
}

fn finishJob(d: *Daemon, j: *Job, status: c_int) void {
    // Flush what the process wrote before exiting, then hang up the pty so
    // leftover background processes get SIGHUP/EIO, like closing a terminal.
    while (j.master >= 0) {
        var pfd = [_]c.pollfd{.{ .fd = j.master, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&pfd, 1, 0) <= 0 or !pumpOutput(d, j)) break;
    }
    if (j.master >= 0) closeMaster(j);
    j.wait_status = status;
    j.state = .done;

    var msg_buf: [128]u8 = undefined;
    var exit_buf: [16]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "\r\n[shq] job {d} finished: {s}\r\n", .{ j.id, exitString(j, &exit_buf) }) catch unreachable;
    for (d.clients.items) |cl| {
        if (cl.job != j) continue;
        writeAll(cl.fd, msg) catch {};
        cl.dead = true;
    }
    startQueued(d);
}

fn startQueued(d: *Daemon) void {
    var running: u32 = 0;
    for (d.jobs.items) |j| {
        if (j.state == .running) running += 1;
    }
    for (d.jobs.items) |j| {
        if (running >= d.parallel) break;
        if (j.state != .queued) continue;
        startJob(j) catch |err| {
            std.log.err("job {d}: start failed: {t}", .{ j.id, err });
            j.state = .done;
            j.wait_status = 127 << 8;
            continue;
        };
        running += 1;
    }
}

fn startJob(j: *Job) !void {
    var m: c_int = undefined;
    var s: c_int = undefined;
    if (openpty(&m, &s, null, null, &j.ws) != 0) return error.OpenPty;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(m);
        _ = c.close(s);
        return error.Fork;
    }
    if (pid == 0) {
        _ = signal(SIGPIPE, SIG_DFL);
        _ = c.setsid();
        _ = ioctl(s, TIOCSCTTY, @as(c_int, 0));
        _ = c.dup2(s, 0);
        _ = c.dup2(s, 1);
        _ = c.dup2(s, 2);
        if (builtin.os.tag == .linux) {
            _ = close_range(3, std.math.maxInt(c_uint), 0);
        } else {
            var fd: c_int = 3;
            while (fd < getdtablesize()) : (fd += 1) _ = c.close(fd);
        }
        _ = c.chdir(j.cwd);
        // Swap in the client's environment so execvp searches its PATH.
        c.environ = @ptrCast(j.envp.ptr);
        _ = execvp(j.argv[0].?, j.argv.ptr);
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "shq: exec {s}: {t}\r\n", .{ j.argv[0].?, c.errno(@as(c_int, -1)) }) catch "shq: exec failed\r\n";
        writeAll(1, msg) catch {};
        c._exit(127);
    }
    _ = c.close(s);
    _ = c.fcntl(m, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    j.pid = pid;
    j.master = m;
    j.state = .running;
}

fn resizeJob(d: *Daemon, j: *Job, rows: u16, cols: u16) void {
    if (rows == 0 or cols == 0) return;
    if (rows == j.ws.row and cols == j.ws.col) return;
    j.ws = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    j.term.resize(d.gpa, .{ .cols = cols, .rows = rows }) catch |err|
        std.log.err("job {d}: resize failed: {t}", .{ j.id, err });
    if (j.master >= 0) _ = ioctl(j.master, TIOCSWINSZ, &j.ws);
}

fn onClientReadable(d: *Daemon, cl: *Client) void {
    var buf: [65536]u8 = undefined;
    const n = c.read(cl.fd, &buf, buf.len);
    if (n <= 0) {
        cl.dead = true;
        return;
    }
    cl.buf.appendSlice(d.gpa, buf[0..@intCast(n)]) catch {
        cl.dead = true;
        return;
    };
    while (cl.buf.items.len >= 1 and !cl.dead) {
        if (cl.buf.items[0] != protocol_version) {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "1daemon (pid {d}) speaks protocol v{d}, client sent v{d}; restart it: kill {d}\n", .{ c.getpid(), protocol_version, cl.buf.items[0], c.getpid() }) catch unreachable;
            writeAll(cl.fd, msg) catch {};
            cl.dead = true;
            return;
        }
        if (cl.buf.items.len < 6) break;
        const len = std.mem.readInt(u32, cl.buf.items[2..6], .little);
        if (cl.buf.items.len < 6 + len) break;
        const typ: Msg = @enumFromInt(cl.buf.items[1]);
        handleFrame(d, cl, typ, cl.buf.items[6..][0..len]) catch |err| {
            std.log.err("client: {t}", .{err});
            cl.dead = true;
        };
        cl.buf.replaceRangeAssumeCapacity(0, 6 + len, &.{});
    }
}

fn handleFrame(d: *Daemon, cl: *Client, typ: Msg, p: []const u8) !void {
    if (cl.job) |j| {
        switch (typ) {
            .input => if (j.master >= 0) try writeAll(j.master, p),
            .resize => if (p.len == 4) resizeJob(d, j, rdInt(u16, p, 0), rdInt(u16, p, 2)),
            else => {},
        }
        return;
    }

    var out: std.Io.Writer.Allocating = .init(d.gpa);
    defer out.deinit();
    const w = &out.writer;
    const ok = handleRequest(d, cl, typ, p, w) catch |err| switch (err) {
        error.Invalid => false,
        else => return err,
    };
    try writeAll(cl.fd, if (ok) "0" else "1");
    try writeAll(cl.fd, out.written());
    if (cl.job == null) cl.dead = true;
}

/// Returns false (with a message in `w`) for user errors.
fn handleRequest(d: *Daemon, cl: *Client, typ: Msg, p: []const u8, w: *std.Io.Writer) !bool {
    switch (typ) {
        .add => {
            if (p.len < 12) return error.Invalid;
            const rows = rdInt(u16, p, 0);
            const cols = rdInt(u16, p, 2);
            const ws: c.winsize = .{
                .row = if (rows == 0) 24 else rows,
                .col = if (cols == 0) 80 else cols,
                .xpixel = 0,
                .ypixel = 0,
            };
            const strings = try d.gpa.dupe(u8, p[12..]);
            errdefer d.gpa.free(strings);
            const cwd_end = std.mem.indexOfScalar(u8, strings, 0) orelse return error.Invalid;
            var pos: usize = cwd_end + 1;
            const argv = try splitStrings(d.gpa, strings, rdInt(u32, p, 4), &pos);
            errdefer d.gpa.free(argv);
            if (argv.len == 0) return error.Invalid;
            const envp = try splitStrings(d.gpa, strings, rdInt(u32, p, 8), &pos);
            errdefer d.gpa.free(envp);
            var cmd: std.ArrayList(u8) = .empty;
            for (argv, 0..) |a, i| {
                if (i > 0) try cmd.append(d.gpa, ' ');
                try cmd.appendSlice(d.gpa, std.mem.span(a.?));
            }

            const j = try d.gpa.create(Job);
            j.* = .{
                .id = d.next_id,
                .cmd = try cmd.toOwnedSlice(d.gpa),
                .strings = strings,
                .cwd = strings[0..cwd_end :0].ptr,
                .argv = argv,
                .envp = envp,
                .ws = ws,
                .term = try .init(d.io, d.gpa, .{
                    .cols = ws.col,
                    .rows = ws.row,
                    .max_scrollback_bytes = 10 * 1024 * 1024,
                }),
                .stream = undefined,
            };
            j.stream = j.term.vtStream();
            d.next_id += 1;
            try d.jobs.append(d.gpa, j);
            startQueued(d);
            try w.print("{d}\n", .{j.id});
        },
        .ls => {
            if (p.len == 1 and p[0] == 'j') {
                try writeJobsJson(d, w);
                return true;
            }
            var cwd_width: usize = "CWD".len;
            for (d.jobs.items) |j| cwd_width = @max(cwd_width, displayCwd(j).len + 1);
            try w.print("{s:<4} {s:<8} {s:<6} CWD", .{ "ID", "STATE", "EXIT" });
            try w.splatByteAll(' ', cwd_width - "CWD".len + 1);
            try w.writeAll("COMMAND\n");
            for (d.jobs.items) |j| {
                var exit_buf: [16]u8 = undefined;
                const exit = if (j.state == .done) exitString(j, &exit_buf) else "";
                const state = if (j.killed and j.state == .done) "killed" else @tagName(j.state);
                const home = if (displayCwd(j).len < std.mem.span(j.cwd).len) "~" else "";
                const cwd = displayCwd(j);
                try w.print("{d:<4} {s:<8} {s:<6} {s}{s}", .{ j.id, state, exit, home, cwd });
                try w.splatByteAll(' ', cwd_width - home.len - cwd.len + 1);
                try w.print("{s}\n", .{j.cmd});
            }
        },
        .attach => {
            if (p.len != 8) return error.Invalid;
            const j = try findJob(d, rdInt(u32, p, 0), w);
            if (j.state != .running) {
                try w.print("job {d} is {t}\n", .{ j.id, j.state });
                return false;
            }
            resizeJob(d, j, rdInt(u16, p, 4), rdInt(u16, p, 6));
            try writeSnapshot(j, w);
            cl.job = j;
        },
        .log => {
            if (p.len != 4) return error.Invalid;
            const j = try findJob(d, rdInt(u32, p, 0), w);
            const f: vt.formatter.TerminalFormatter = .init(&j.term, .plain);
            try w.print("{f}\n", .{f});
        },
        .kill => {
            if (p.len != 5) return error.Invalid;
            const j = try findJob(d, rdInt(u32, p, 0), w);
            switch (j.state) {
                .queued => j.state = .done,
                .running => _ = c.kill(-j.pid, @fromBackingInt(p[4])),
                .done => {
                    try w.print("job {d} already finished\n", .{j.id});
                    return false;
                },
            }
            j.killed = true;
        },
        .run => {
            if (p.len != 4) return error.Invalid;
            const j = try findJob(d, rdInt(u32, p, 0), w);
            if (j.state != .queued) {
                try w.print("job {d} is {t}\n", .{ j.id, j.state });
                return false;
            }
            startJob(j) catch |err| {
                j.state = .done;
                j.wait_status = 127 << 8;
                try w.print("job {d}: start failed: {t}\n", .{ j.id, err });
                return false;
            };
        },
        .clean => {
            var i: usize = 0;
            while (i < d.jobs.items.len) {
                const j = d.jobs.items[i];
                if (j.state != .done) {
                    i += 1;
                    continue;
                }
                j.stream.deinit();
                j.term.deinit(d.gpa);
                d.gpa.free(j.cmd);
                d.gpa.free(j.strings);
                d.gpa.free(j.argv);
                d.gpa.free(j.envp);
                d.gpa.destroy(j);
                _ = d.jobs.orderedRemove(i);
            }
        },
        .parallel => {
            if (p.len != 4) return error.Invalid;
            d.parallel = @max(1, rdInt(u32, p, 0));
            startQueued(d);
        },
        else => return error.Invalid,
    }
    return true;
}

fn writeJobsJson(d: *Daemon, w: *std.Io.Writer) !void {
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginArray();
    for (d.jobs.items) |j| {
        const st = j.wait_status;
        const done = j.state == .done;
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(j.id);
        try jw.objectField("state");
        try jw.write(if (j.killed and done) "killed" else @tagName(j.state));
        try jw.objectField("exit_code");
        try jw.write(if (done and st & 0x7f == 0) (st >> 8) & 0xff else null);
        try jw.objectField("signal");
        try jw.write(if (done and st & 0x7f != 0) st & 0x7f else null);
        try jw.objectField("cwd");
        try jw.write(std.mem.span(j.cwd));
        try jw.objectField("argv");
        try jw.beginArray();
        for (j.argv) |a| try jw.write(std.mem.span(a.?));
        try jw.endArray();
        try jw.endObject();
    }
    try jw.endArray();
    try w.writeByte('\n');
}

/// Splits `n` NUL-terminated strings out of `data` starting at `pos`.
fn splitStrings(gpa: Allocator, data: []u8, n: u32, pos: *usize) ![:null]?[*:0]const u8 {
    const list = try gpa.allocSentinel(?[*:0]const u8, n, null);
    errdefer gpa.free(list);
    for (list) |*s| {
        const end = std.mem.indexOfScalarPos(u8, data, pos.*, 0) orelse return error.Invalid;
        s.* = data[pos.*..end :0].ptr;
        pos.* = end + 1;
    }
    return list;
}

fn findJob(d: *Daemon, id: u32, w: *std.Io.Writer) !*Job {
    for (d.jobs.items) |j| if (j.id == id) return j;
    try w.print("no job {d}\n", .{id});
    return error.Invalid;
}

/// Renders the job's active screen plus terminal state (modes, cursor,
/// scrolling region, ...) as VT sequences, so the client terminal ends up
/// looking like the job's terminal.
fn writeSnapshot(j: *Job, w: *std.Io.Writer) !void {
    try w.writeAll("\x1b[0m\x1b[H\x1b[2J");
    const pages = &j.term.screens.active.pages;
    var f: vt.formatter.TerminalFormatter = .init(&j.term, .{ .emit = .vt, .trim = false });
    f.extra = .all;
    // Leave the user's own palette alone.
    f.extra.palette = false;
    f.content = .{ .selection = .init(
        pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        pages.pin(.{ .active = .{ .x = j.term.cols - 1, .y = j.term.rows - 1 } }).?,
        false,
    ) };
    try f.format(w);
}

/// Job cwd with the daemon's $HOME prefix stripped (ls prints "~" for it).
fn displayCwd(j: *const Job) []const u8 {
    const cwd = std.mem.span(j.cwd);
    const home = std.mem.span(c.getenv("HOME") orelse return cwd);
    if (home.len > 1 and std.mem.startsWith(u8, cwd, home) and
        (cwd.len == home.len or cwd[home.len] == '/')) return cwd[home.len..];
    return cwd;
}

fn exitString(j: *const Job, buf: []u8) []const u8 {
    const st = j.wait_status;
    if (st & 0x7f == 0) return std.fmt.bufPrint(buf, "{d}", .{(st >> 8) & 0xff}) catch unreachable;
    return std.fmt.bufPrint(buf, "sig{d}", .{st & 0x7f}) catch unreachable;
}

// ---------------------------------------------------------------- helpers

fn sendFrame(fd: c.fd_t, typ: Msg, payload: []const u8) !void {
    var hdr: [6]u8 = undefined;
    hdr[0] = protocol_version;
    hdr[1] = @backingInt(typ);
    std.mem.writeInt(u32, hdr[2..6], @intCast(payload.len), .little);
    try writeAll(fd, &hdr);
    try writeAll(fd, payload);
}

fn writeAll(fd: c.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data[off..].ptr, data.len - off);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
}

fn appendInt(gpa: Allocator, list: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn rdInt(comptime T: type, p: []const u8, off: usize) T {
    return std.mem.readInt(T, p[off..][0..@sizeOf(T)], .little);
}

fn winsize(fd: c.fd_t) c.winsize {
    var ws: c.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    _ = ioctl(fd, std.posix.T.IOCGWINSZ, &ws);
    return ws;
}

fn runtimePath(buf: *[108]u8, name: []const u8) [:0]const u8 {
    if (c.getenv("XDG_RUNTIME_DIR")) |dir|
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ std.mem.span(dir), name }, 0) catch die("path too long\n", .{});
    return std.fmt.bufPrintSentinel(buf, "/tmp/{d}-{s}", .{ c.getuid(), name }, 0) catch die("path too long\n", .{});
}

fn unixAddr(path: [:0]const u8) c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

fn parseId(rest: []const [:0]const u8) u32 {
    if (rest.len == 0) die("missing argument\n", .{});
    return std.fmt.parseInt(u32, rest[0], 10) catch die("bad number: {s}\n", .{rest[0]});
}

/// Returns the shortest command `name` is a prefix of, or `name` unchanged.
fn resolveCommand(name: []const u8) []const u8 {
    var best: ?[]const u8 = null;
    for (commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, name) and (best == null or cmd.len < best.?.len)) best = cmd;
    }
    return best orelse name;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "shq: " ++ fmt, args) catch "shq: error\n";
    writeAll(2, msg) catch {};
    std.process.exit(1);
}
