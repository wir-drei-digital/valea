// valea-spawn (windows-support spec B2): Job-Object process shim.
//
// Erlang Ports can neither separate stderr nor kill a Windows process tree;
// this binary does both. valea-server spawns every agent through it, so the
// contract below is load-bearing for the backend's ProcessAdapter:
//
//   argv         `valea-spawn <cmd> [args…]` — no flags of its own.
//   env          VALEA_SPAWN_STDERR_FILE is REQUIRED (missing => exit 64).
//   stdin        passed through to the child; EOF is the kill switch.
//   stdout       passed through verbatim (the agent's NDJSON stream).
//   stderr       the child's stderr goes to VALEA_SPAWN_STDERR_FILE, capped.
//   exit code    the child's, mirrored; 120 when our own stdin hit EOF;
//                64 for a usage/contract violation (see `run`).
//
// Do NOT copy main.rs's `windows_subsystem = "windows"` attribute here: this is
// a console binary and must stay one. A GUI-subsystem build starts with no
// stdio handles at all, which would silently turn every pump below into a
// no-op.
//
// Non-Windows builds get a stub so `cargo check` stays green on every host —
// the module below is still parsed there, just not compiled.
#[cfg(not(windows))]
fn main() {
    eprintln!("valea-spawn is Windows-only");
    std::process::exit(64);
}

#[cfg(windows)]
fn main() {
    std::process::exit(win::run());
}

#[cfg(windows)]
mod win {
    use std::io::{copy, Read, Write};
    use std::os::windows::io::AsRawHandle;
    use std::process::{Command, Stdio};
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::JobObjects::*;

    const CAP: u64 = 1024 * 1024; // 1 MiB stderr cap (spec B2)
    const TRUNCATED: &[u8] = b"\n[truncated]\n";

    /// Exit code when our own stdin reaches EOF, i.e. the owning Port closed.
    /// Distinct from any plausible agent exit code on purpose.
    const EXIT_STDIN_EOF: i32 = 120;
    /// Exit code for a contract violation: no command argument, no
    /// VALEA_SPAWN_STDERR_FILE, or an unquotable arg for a batch target.
    const EXIT_USAGE: i32 = 64;

    pub fn run() -> i32 {
        let mut args = std::env::args_os().skip(1);
        let Some(cmd) = args.next() else {
            return EXIT_USAGE;
        };
        // Required, not defaulted: a silently-dropped stderr stream is how
        // agent misconfiguration turns into an unexplainable hang.
        let Ok(stderr_path) = std::env::var("VALEA_SPAWN_STDERR_FILE") else {
            return EXIT_USAGE;
        };

        // Job first, child second, assign before any pumping. The Job handle
        // is deliberately non-inheritable (default SECURITY_ATTRIBUTES), so
        // this process holds the only reference: when we exit — cleanly,
        // panicking, or force-killed — the handle closes and
        // KILL_ON_JOB_CLOSE reaps everything the agent spawned.
        //
        // In production this is a NESTED Job: the shim itself already runs
        // inside the sidecar's Job (spec E1, see src/winjob.rs). Nesting needs
        // Windows 8 or later, which the app requires anyway; either Job closing
        // kills the agent, which is the intent both times.
        let job = unsafe { CreateJobObjectW(None, None) }.expect("create job object");
        let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        unsafe {
            SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const core::ffi::c_void,
                std::mem::size_of_val(&info) as u32,
            )
            .expect("set job limits");
        }

        // Spec B2: CreateProcess cannot execute .cmd/.bat directly — batch
        // targets route through COMSPEC, and the shim owns the quoting.
        let mut command = match build_command(&cmd, args) {
            Some(c) => c,
            // Embedded-quote arg to a batch target: unquotable for cmd.exe.
            None => return EXIT_USAGE,
        };
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn child");
        // Assign-after-spawn leaves a sub-millisecond window in which a
        // grandchild would escape the Job. Closing it would mean
        // CREATE_SUSPENDED + ResumeThread, which std::process::Child does not
        // expose a thread handle for; no agent runtime forks that fast, and
        // the alternative (putting *this* process in the Job before spawning)
        // trades the race for a hard dependency on nested-job support.
        unsafe {
            AssignProcessToJobObject(job, HANDLE(child.as_raw_handle() as _))
                .expect("assign to job");
        }

        let mut child_stdin = child.stdin.take().expect("child stdin");
        let mut child_stdout = child.stdout.take().expect("child stdout");
        let mut child_stderr = child.stderr.take().expect("child stderr");

        // Pump 1: our stdin -> child stdin. EOF here = the owner closed the
        // Port = shutdown. Exiting closes the job handle, which kills the
        // tree; that is the ONLY teardown signal the backend needs to send.
        std::thread::Builder::new()
            .name("stdin-pump".into())
            .spawn(move || {
                let _ = copy(&mut std::io::stdin().lock(), &mut child_stdin);
                std::process::exit(EXIT_STDIN_EOF);
            })
            .expect("spawn stdin pump");

        // Pump 2: child stdout -> our stdout (NDJSON passthrough). Stdout is
        // line-buffered, so each complete line reaches the Port promptly.
        let out = std::thread::Builder::new()
            .name("stdout-pump".into())
            .spawn(move || {
                let _ = copy(&mut child_stdout, &mut std::io::stdout().lock());
            })
            .expect("spawn stdout pump");

        // Pump 3: child stderr -> capped file. Created share-read (Rust's
        // default) so the backend can tail it while the agent still runs.
        let err = std::thread::Builder::new()
            .name("stderr-pump".into())
            .spawn(move || {
                let mut f = std::fs::File::create(&stderr_path).expect("create stderr file");
                let mut buf = [0u8; 8192];
                let mut written: u64 = 0;
                loop {
                    match child_stderr.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            // Past the cap we keep draining the pipe (so the
                            // child never blocks on a full stderr) but stop
                            // writing.
                            if written < CAP {
                                let take = ((CAP - written).min(n as u64)) as usize;
                                let _ = f.write_all(&buf[..take]);
                                written += take as u64;
                                if written >= CAP {
                                    let _ = f.write_all(TRUNCATED);
                                }
                            }
                        }
                    }
                }
            })
            .expect("spawn stderr pump");

        let status = child.wait().expect("wait for child");
        let _ = out.join();
        let _ = err.join();
        // A Windows process always has an exit code; unwrap_or is belt only.
        status.code().unwrap_or(1)
        // The job handle goes out of scope here, but nothing closes it until
        // the process exits — which is exactly when the tree should die.
    }

    /// Direct spawn for real executables; `cmd.exe /d /s /c "<one quoted
    /// line>"` for .cmd/.bat (via raw_arg — the only reliable quoting for
    /// cmd.exe). Returns None for args containing `"` when the target is a
    /// batch file: there is no safe way to quote those for cmd.exe, and the
    /// agent argv never legitimately contains them — fail loud (exit 64).
    fn build_command(
        cmd: &std::ffi::OsString,
        args: impl Iterator<Item = std::ffi::OsString>,
    ) -> Option<Command> {
        use std::os::windows::process::CommandExt;

        let is_batch = std::path::Path::new(cmd)
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"))
            .unwrap_or(false);

        if !is_batch {
            let mut c = Command::new(cmd);
            c.args(args);
            return Some(c);
        }

        // `/s` makes cmd.exe strip exactly the outermost quote pair and take
        // the rest verbatim, which is what lets paths and args with spaces
        // survive; `/d` skips AutoRun registry hooks.
        let mut line = String::from("/d /s /c \"");
        line.push('"');
        line.push_str(cmd.to_str()?);
        line.push('"');
        for a in args {
            let a = a.to_str()?.to_string();
            if a.contains('"') {
                return None;
            }
            line.push_str(" \"");
            line.push_str(&a);
            line.push('"');
        }
        line.push('"');

        let comspec = std::env::var_os("COMSPEC").unwrap_or_else(|| "cmd.exe".into());
        let mut c = Command::new(comspec);
        c.raw_arg(line);
        Some(c)
    }
}
