//! Windows process-tree containment. Create suspended, assign to kill-on-close
//! job, then resume its initial thread. No child executes before assignment.
use std::{
    ffi::c_void,
    mem::{size_of, zeroed},
    ptr::null_mut,
    time::Duration,
};
type Handle = *mut c_void;
#[repr(C)]
struct BasicLimits {
    process_time: i64,
    job_time: i64,
    flags: u32,
    min_working: usize,
    max_working: usize,
    active_limit: u32,
    affinity: usize,
    priority: u32,
    scheduling: u32,
}
#[repr(C)]
struct IoCounters {
    read_ops: u64,
    write_ops: u64,
    other_ops: u64,
    read_bytes: u64,
    write_bytes: u64,
    other_bytes: u64,
}
#[repr(C)]
struct ExtendedLimits {
    basic: BasicLimits,
    io: IoCounters,
    process_memory: usize,
    job_memory: usize,
    peak_process: usize,
    peak_job: usize,
}
#[repr(C)]
struct Accounting {
    user_time: i64,
    kernel_time: i64,
    period_user: i64,
    period_kernel: i64,
    faults: u32,
    total: u32,
    active: u32,
    terminated: u32,
}
#[repr(C)]
struct ThreadEntry {
    size: u32,
    usage: u32,
    id: u32,
    owner: u32,
    base_priority: i32,
    delta_priority: i32,
    flags: u32,
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> Handle;
    fn SetInformationJobObject(job: Handle, class: i32, info: *const c_void, length: u32) -> i32;
    fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
    fn TerminateJobObject(job: Handle, code: u32) -> i32;
    fn QueryInformationJobObject(
        job: Handle,
        class: i32,
        info: *mut c_void,
        length: u32,
        returned: *mut u32,
    ) -> i32;
    fn CloseHandle(handle: Handle) -> i32;
    fn CreateToolhelp32Snapshot(flags: u32, process: u32) -> Handle;
    fn Thread32First(snapshot: Handle, entry: *mut ThreadEntry) -> i32;
    fn Thread32Next(snapshot: Handle, entry: *mut ThreadEntry) -> i32;
    fn OpenThread(access: u32, inherit: i32, thread: u32) -> Handle;
    fn ResumeThread(thread: Handle) -> u32;
}
pub(crate) struct Job(Handle);
// Handle remains owned and is only used by the task; Win32 job APIs are thread-safe.
unsafe impl Send for Job {}
unsafe impl Sync for Job {}
impl Job {
    pub fn new() -> std::io::Result<Self> {
        unsafe {
            let job = Self(CreateJobObjectW(std::ptr::null(), std::ptr::null()));
            if job.0.is_null() {
                return Err(std::io::Error::last_os_error());
            }
            let mut limits: ExtendedLimits = zeroed();
            limits.basic.flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. No breakaway.
            if SetInformationJobObject(
                job.0,
                9,
                &limits as *const _ as _,
                size_of::<ExtendedLimits>() as u32,
            ) == 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(job)
        }
    }
    pub fn assign_and_resume(&self, process: Handle, pid: u32) -> std::io::Result<()> {
        unsafe {
            if AssignProcessToJobObject(self.0, process) == 0 {
                return Err(std::io::Error::last_os_error());
            }
            let snapshot = CreateToolhelp32Snapshot(4, 0); // TH32CS_SNAPTHREAD
            if snapshot == -1isize as Handle {
                return Err(std::io::Error::last_os_error());
            }
            let mut entry: ThreadEntry = zeroed();
            entry.size = size_of::<ThreadEntry>() as u32;
            let mut found = Thread32First(snapshot, &mut entry);
            let mut resumed = false;
            while found != 0 {
                if entry.owner == pid {
                    let thread = OpenThread(2, 0, entry.id); // THREAD_SUSPEND_RESUME
                    if !thread.is_null() {
                        resumed = ResumeThread(thread) != u32::MAX;
                        CloseHandle(thread);
                    }
                    break;
                }
                found = Thread32Next(snapshot, &mut entry);
            }
            CloseHandle(snapshot);
            if resumed {
                Ok(())
            } else {
                Err(std::io::Error::other("initial thread resume failed"))
            }
        }
    }
    pub async fn terminate(&self) -> bool {
        unsafe {
            if TerminateJobObject(self.0, 1) == 0 {
                return false;
            }
        }
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            let mut accounting: Accounting = unsafe { zeroed() };
            let ok = unsafe {
                QueryInformationJobObject(
                    self.0,
                    1,
                    &mut accounting as *mut _ as _,
                    size_of::<Accounting>() as u32,
                    null_mut(),
                )
            };
            if ok == 0 {
                return false;
            }
            if accounting.active == 0 {
                return true;
            }
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}
impl Drop for Job {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn closing_last_job_handle_kills_owned_process() -> std::io::Result<()> {
        let job = Job::new()?;
        let mut child = tokio::process::Command::new("cmd.exe")
            .args(["/d", "/c", "ping -n 60 127.0.0.1 >nul"])
            .creation_flags(4)
            .kill_on_drop(true)
            .spawn()?;
        job.assign_and_resume(child.raw_handle().unwrap(), child.id().unwrap())?;
        drop(job);
        let status = tokio::time::timeout(Duration::from_secs(3), child.wait()).await??;
        assert!(!status.success());
        Ok(())
    }
    #[tokio::test]
    async fn suspended_child_and_descendants_are_in_job() -> std::io::Result<()> {
        use tokio::process::Command;
        let job = Job::new()?;
        let mut child = Command::new("cmd.exe")
            .args(["/d", "/c", "ping -n 60 127.0.0.1 >nul"])
            .creation_flags(4)
            .kill_on_drop(true)
            .spawn()?;
        job.assign_and_resume(child.raw_handle().unwrap(), child.id().unwrap())?;
        assert!(job.terminate().await);
        assert!(!child.wait().await?.success());
        Ok(())
    }
}
