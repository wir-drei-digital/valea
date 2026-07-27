//! valea-spawn contract tests (windows-support spec B2).
//!
//! Everything asserted here is Job-Object and cmd.exe behaviour, so the suite
//! is Windows-only — on other hosts the crate-level `cfg` empties the file and
//! `cargo test --test spawn_shim` compiles a suite with zero cases (which still
//! parses this file, so a syntax error cannot hide until CI). The real evidence
//! comes from the `windows-bringup` lane, where this is a gating step.
//!
//! The contract under test, as Task 6's ProcessAdapter consumes it:
//!   - argv is `valea-spawn <cmd> [args…]`
//!   - VALEA_SPAWN_STDERR_FILE is required; missing => exit 64
//!   - stdout is a verbatim passthrough, stderr goes to that file, capped
//!   - the shim's exit code is the child's; stdin EOF exits 120 and kills the
//!     whole tree, including processes `start /b` detached out of it
#![cfg(windows)]

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

/// Cargo builds the `valea-spawn` bin for this integration test and hands us
/// its path, so the suite always exercises the binary from this tree.
const SHIM: &str = env!("CARGO_BIN_EXE_valea-spawn");

const CAP: usize = 1024 * 1024;
const TRUNCATED: &str = "\n[truncated]\n";
const EXIT_USAGE: i32 = 64;
const EXIT_STDIN_EOF: i32 = 120;

// -- (a) exit-code passthrough ----------------------------------------------

#[test]
fn mirrors_the_child_exit_code() {
    let dir = scratch("exit-code");
    let err = dir.join("stderr.log");

    let (code, out) = run_shim(&dir, Some(&err), &["cmd.exe", "/c", "exit", "42"]);

    assert_eq!(code, 42, "the shim must mirror the child's exit code");
    assert!(out.is_empty(), "unexpected stdout: {out:?}");
    cleanup(&dir);
}

// -- (b) bulk stdout passthrough --------------------------------------------

#[test]
fn passes_50mb_of_stdout_through_unchanged() {
    let dir = scratch("stdout-bulk");
    let payload = ascii_payload(50 * 1024 * 1024);
    fs::write(dir.join("big.txt"), &payload).expect("write payload");
    let err = dir.join("stderr.log");

    let (code, out) = run_shim(&dir, Some(&err), &["cmd.exe", "/c", "type", "big.txt"]);

    assert_eq!(code, 0, "`type` failed");
    // A length mismatch here almost certainly means line-ending translation
    // crept in, so call that out rather than dumping 50 MB of diff.
    assert_eq!(
        out.len(),
        payload.len(),
        "stdout length changed — bytes are not passing through verbatim"
    );
    assert!(out == payload, "stdout bytes differ from the source file");
    cleanup(&dir);
}

// -- (c) capped stderr file -------------------------------------------------

#[test]
fn caps_the_stderr_file_and_marks_it_truncated() {
    let dir = scratch("stderr-cap");
    let payload = ascii_payload(2 * 1024 * 1024);
    fs::write(dir.join("big.txt"), &payload).expect("write payload");
    let err = dir.join("stderr.log");

    let (code, out) = run_shim(
        &dir,
        Some(&err),
        &["cmd.exe", "/c", "type", "big.txt", "1>&2"],
    );

    assert_eq!(code, 0, "`type` failed");
    assert!(out.is_empty(), "the payload belongs on stderr, not stdout");

    let logged = fs::read(&err).expect("stderr file must exist");
    assert_eq!(
        logged.len(),
        CAP + TRUNCATED.len(),
        "the stderr file must stop at the 1 MiB cap plus the marker"
    );
    assert!(
        logged.ends_with(TRUNCATED.as_bytes()),
        "truncation must be visible in the file"
    );
    assert_eq!(
        &logged[..CAP],
        &payload[..CAP],
        "the kept prefix must be the child's real stderr"
    );
    cleanup(&dir);
}

// -- (d) stdin EOF kills the tree -------------------------------------------

#[test]
fn stdin_eof_kills_the_whole_tree() {
    let dir = scratch("tree-kill");
    let err = dir.join("stderr.log");

    // The grandchild is detached with `start /b`, so it is orphaned the moment
    // the direct child goes away — exactly what a plain kill() would leave
    // running. It holds `lock.txt` open for its whole life, which makes "no
    // survivor" checkable without pattern-matching tasklist output: Windows
    // refuses to delete a file while a handle to it is open.
    fs::write(
        dir.join("tree.cmd"),
        "@echo off\r\n\
         start /b \"\" cmd /c \"ping -n 300 127.0.0.1 > lock.txt\"\r\n\
         ping -n 300 127.0.0.1 > nul\r\n",
    )
    .expect("write tree.cmd");

    let mut child = spawn_shim(&dir, Some(&err), &["cmd.exe", "/c", "tree.cmd"]);
    let stdin = child.stdin.take().expect("shim stdin");
    // Drain stdout on a thread so the shim can never block on a full pipe
    // while we are waiting on the filesystem.
    let mut stdout = child.stdout.take().expect("shim stdout");
    let drain = std::thread::spawn(move || {
        let mut sink = Vec::new();
        let _ = stdout.read_to_end(&mut sink);
    });

    let lock = dir.join("lock.txt");
    assert!(
        wait_until(Duration::from_secs(30), || lock.exists()),
        "the detached grandchild never created lock.txt"
    );

    // The kill switch, and the only shutdown signal the backend ever sends.
    drop(stdin);

    let status = child.wait().expect("wait for shim");
    assert_eq!(
        status.code(),
        Some(EXIT_STDIN_EOF),
        "stdin EOF must exit the shim"
    );
    let _ = drain.join();

    assert!(
        wait_until(Duration::from_secs(30), || fs::remove_file(&lock).is_ok()),
        "lock.txt is still held open — a process from the tree survived stdin EOF"
    );
    cleanup(&dir);
}

// -- (e) missing required env ------------------------------------------------

#[test]
fn missing_stderr_file_env_exits_64() {
    let dir = scratch("no-stderr-env");

    let (code, out) = run_shim(&dir, None, &["cmd.exe", "/c", "exit", "0"]);

    assert_eq!(
        code, EXIT_USAGE,
        "a missing VALEA_SPAWN_STDERR_FILE must fail immediately, not default"
    );
    assert!(out.is_empty(), "nothing should have been spawned");
    cleanup(&dir);
}

// -- (f) batch target via COMSPEC, spaces intact -----------------------------

#[test]
fn routes_batch_targets_through_comspec_with_spaces_intact() {
    let dir = scratch("batch-spaces");
    let nested = dir.join("dir with spaces");
    fs::create_dir_all(&nested).expect("nested dir");
    let script = nested.join("echo args.cmd");
    fs::write(&script, "@echo off\r\necho [%~1]\r\necho [%~2]\r\n").expect("write script");
    let err = dir.join("stderr.log");

    let (code, out) = run_shim(
        &dir,
        Some(&err),
        &[
            script.to_str().expect("utf-8 script path"),
            "hello world",
            "plain",
        ],
    );

    let text = String::from_utf8_lossy(&out);
    assert_eq!(code, 0, "batch target failed; stdout was: {text}");
    assert!(
        text.contains("[hello world]"),
        "the spaced argument was mangled: {text}"
    );
    assert!(
        text.contains("[plain]"),
        "the second argument was lost: {text}"
    );
    cleanup(&dir);
}

// -- (g) the documented unquotable bound -------------------------------------

#[test]
fn embedded_quote_arg_to_a_batch_target_exits_64() {
    let dir = scratch("batch-quote");
    let script = dir.join("echo args.cmd");
    fs::write(&script, "@echo off\r\necho [%~1]\r\n").expect("write script");
    let err = dir.join("stderr.log");

    let (code, out) = run_shim(
        &dir,
        Some(&err),
        &[script.to_str().expect("utf-8 script path"), "say \"hi\""],
    );

    assert_eq!(
        code, EXIT_USAGE,
        "an arg cmd.exe cannot be handed safely must fail loud"
    );
    assert!(out.is_empty());
    // VALEA_SPAWN_STDERR_FILE *was* set here, so 64 can only have come from
    // the quoting check — and the file is absent because nothing was spawned.
    assert!(
        !err.exists(),
        "a child was spawned despite the unquotable argument"
    );
    cleanup(&dir);
}

// -- helpers ----------------------------------------------------------------

static NEXT_SCRATCH: AtomicU32 = AtomicU32::new(0);

fn scratch(tag: &str) -> PathBuf {
    let n = NEXT_SCRATCH.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("valea-spawn-{}-{n}-{tag}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// Best-effort: a failing assertion above leaves the directory behind on
/// purpose, and the tree-kill case can only be cleaned once the tree is dead.
fn cleanup(dir: &Path) {
    let _ = fs::remove_dir_all(dir);
}

/// Spawns the shim with its stdin PIPED — and the caller must keep that pipe
/// open for the whole run. stdin EOF is the shim's kill switch (spec B2), so
/// `Stdio::null()` here would make every exit-code assertion read 120.
fn spawn_shim(cwd: &Path, stderr_file: Option<&Path>, args: &[&str]) -> Child {
    let mut cmd = Command::new(SHIM);
    cmd.current_dir(cwd)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        // Inherited rather than piped: the shim's own stderr only ever carries
        // panic messages, and losing those to a never-read pipe would make a
        // CI failure unreadable.
        .stderr(Stdio::inherit());
    if let Some(path) = stderr_file {
        cmd.env("VALEA_SPAWN_STDERR_FILE", path);
    } else {
        cmd.env_remove("VALEA_SPAWN_STDERR_FILE");
    }
    cmd.spawn().expect("spawn valea-spawn")
}

/// Runs the shim to completion, returning its exit code and captured stdout.
fn run_shim(cwd: &Path, stderr_file: Option<&Path>, args: &[&str]) -> (i32, Vec<u8>) {
    let mut child = spawn_shim(cwd, stderr_file, args);
    // Held until after `wait`: see `spawn_shim`.
    let stdin = child.stdin.take().expect("shim stdin");
    let mut out = Vec::new();
    child
        .stdout
        .take()
        .expect("shim stdout")
        .read_to_end(&mut out)
        .expect("read shim stdout");
    let status = child.wait().expect("wait for shim");
    drop(stdin);
    (status.code().expect("shim exit code"), out)
}

/// Deterministic printable-ASCII lines: no CR (so nothing can be mistaken for
/// pre-normalised CRLF) and no 0x1A (which legacy text paths treat as EOF), to
/// keep `type` an honest byte copy.
fn ascii_payload(len: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(len + 64);
    let mut n: u64 = 0;
    while out.len() < len {
        out.extend_from_slice(format!("{n:>12} valea-spawn passthrough probe\n").as_bytes());
        n += 1;
    }
    out.truncate(len);
    out
}

fn wait_until(limit: Duration, mut cond: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + limit;
    loop {
        if cond() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}
