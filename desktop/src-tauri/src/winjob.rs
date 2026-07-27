//! Windows Job Object ownership for the sidecar (windows-support spec E1).
//!
//! On Windows the Burrito wrapper cannot `exec()` the BEAM the way it does on
//! Unix — it launches it as a child — so the pid Tauri hands back belongs to a
//! launcher whose real server outlives `CommandChild::kill()`. A kill-on-close
//! Job Object is the only reliable tree reaper: every process in the Job dies
//! the moment the last handle to it closes, and process teardown closes
//! handles whether we exited cleanly, panicked, or were force-quit.
//!
//! `main.rs` is the only consumer. `src/bin/valea_spawn.rs` (spec B2) keeps its
//! own copy of these three calls because it is a separate binary; a shared
//! crate for twenty lines of FFI would cost more than it saves.
//!
//! Inner `cfg` rather than `#[cfg(windows)] mod winjob;` at the use site: this
//! way the file is still *parsed* on non-Windows hosts, so a syntax error here
//! cannot survive a macOS `cargo check`.
#![cfg(windows)]

use windows::core::Result;
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows::Win32::System::Threading::{OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE};

/// An owned handle to a kill-on-close Job Object.
///
/// Dropping it CLOSES the handle, which terminates every process in the Job.
/// That is the whole point — but it means a `Job` must be stored somewhere
/// that lives as long as the processes it owns (see `SidecarJob` in
/// `main.rs`). A `Job` left as a temporary kills its target immediately.
pub struct Job(HANDLE);

// A Win32 HANDLE is a process-wide kernel-object reference, not a thread-
// affine pointer: creating it on the setup thread and closing it on the exit
// thread is exactly what the API is for. `windows` models HANDLE as a raw
// pointer newtype, which is why the auto traits need saying out loud.
unsafe impl Send for Job {}
unsafe impl Sync for Job {}

impl Job {
    /// Creates a kill-on-close Job Object and puts `pid` — plus, from now on,
    /// everything `pid` spawns — into it.
    pub fn assign_kill_on_close(pid: u32) -> Result<Self> {
        // Wrap the handle before anything else can fail, so an error below
        // still closes it. Nothing is assigned yet, so that close is harmless.
        let handle = unsafe { CreateJobObjectW(None, None) }?;
        let job = Job(handle);

        let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const core::ffi::c_void,
                std::mem::size_of_val(&info) as u32,
            )?;
        }

        // PROCESS_SET_QUOTA | PROCESS_TERMINATE is the documented minimum for
        // AssignProcessToJobObject.
        let process = unsafe { OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, pid) }?;
        let assigned = unsafe { AssignProcessToJobObject(job.0, process) };
        // Our process handle was only needed for the assignment; the Job keeps
        // its own reference. Close it before propagating any failure.
        unsafe {
            let _ = CloseHandle(process);
        }
        assigned?;

        Ok(job)
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        // Closing the last handle is what fires
        // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. Nothing to report: by the time
        // this runs the app is on its way out.
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}
