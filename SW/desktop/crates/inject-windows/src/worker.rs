//! One provider job, no queue. Timeouts retain the slot until the job exits.
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU8, Ordering},
        mpsc,
    },
    time::Duration,
};
use voiceremote_core::{InsertionFailure, Result};

#[derive(Clone, Default)]
pub struct Cancellation(Arc<AtomicU8>);
impl Cancellation {
    pub fn require_active(&self) -> Result<()> {
        if self.0.load(Ordering::SeqCst) == 1 {
            return Err(InsertionFailure::NotStarted.into());
        }
        Ok(())
    }
    /// Atomically commit to input or lose to cancellation. Check immediately
    /// before SendInput; a timeout can then safely distinguish no-input from
    /// potentially queued input without a check/cancel race.
    pub fn begin_input(&self) -> Result<()> {
        match self
            .0
            .compare_exchange(0, 2, Ordering::SeqCst, Ordering::SeqCst)
        {
            Ok(_) | Err(2) => Ok(()),
            _ => Err(InsertionFailure::NotStarted.into()),
        }
    }
    fn cancel(&self) -> InsertionFailure {
        match self
            .0
            .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst)
        {
            Ok(_) | Err(1) => InsertionFailure::NotStarted,
            _ => InsertionFailure::Unconfirmed,
        }
    }
}
struct CancelOnDrop(Cancellation);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.cancel();
    }
}
#[derive(Default)]
pub struct BoundedWorker {
    busy: AtomicBool,
}
struct Slot(&'static BoundedWorker);
impl Drop for Slot {
    fn drop(&mut self) {
        self.0.busy.store(false, Ordering::SeqCst);
    }
}
impl BoundedWorker {
    pub const fn new() -> Self {
        Self {
            busy: AtomicBool::new(false),
        }
    }
    fn start(
        &'static self,
        job: impl FnOnce(Cancellation) -> Result<()> + Send + 'static,
    ) -> Result<(mpsc::Receiver<Result<()>>, CancelOnDrop)> {
        if self
            .busy
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Err(InsertionFailure::NotStarted.into());
        }
        let slot = Slot(self);
        let cancel = Cancellation::default();
        let guard = CancelOnDrop(cancel.clone());
        let (send, receive) = mpsc::channel();
        std::thread::spawn(move || {
            let _slot = slot;
            let result = job(cancel);
            let _ = send.send(result);
        });
        Ok((receive, guard))
    }
    pub fn run(
        &'static self,
        timeout: Duration,
        job: impl FnOnce(Cancellation) -> Result<()> + Send + 'static,
    ) -> Result<()> {
        let (receive, cancel) = self.start(job)?;
        receive
            .recv_timeout(timeout)
            .unwrap_or_else(|_| Err(cancel.0.cancel().into()))
    }
    pub async fn run_async(
        &'static self,
        timeout: Duration,
        job: impl FnOnce(Cancellation) -> Result<()> + Send + 'static,
    ) -> Result<()> {
        let (receive, cancel) = self.start(job)?;
        let wait = tokio::task::spawn_blocking(move || receive.recv_timeout(timeout));
        match tokio::time::timeout(timeout, wait).await {
            Ok(Ok(Ok(result))) => result,
            _ => Err(cancel.0.cancel().into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn hung_provider_does_not_block_executor_or_release_capacity_or_inject_after_timeout() {
        let worker = Box::leak(Box::new(BoundedWorker::default()));
        let (release, wait) = mpsc::channel();
        let effect = Arc::new(AtomicBool::new(false));
        let written = effect.clone();
        let result = worker
            .run_async(Duration::from_millis(20), move |cancel| {
                wait.recv().unwrap();
                cancel.begin_input()?;
                written.store(true, Ordering::SeqCst);
                Ok(())
            })
            .await;
        assert_eq!(
            result.unwrap_err().downcast_ref::<InsertionFailure>(),
            Some(&InsertionFailure::NotStarted)
        );
        let busy = worker
            .run_async(Duration::from_millis(20), |_| Ok(()))
            .await;
        assert_eq!(
            busy.unwrap_err().downcast_ref::<InsertionFailure>(),
            Some(&InsertionFailure::NotStarted)
        );
        release.send(()).unwrap();
        for _ in 0..100 {
            if !worker.busy.load(Ordering::SeqCst) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        assert!(!effect.load(Ordering::SeqCst));
        worker
            .run_async(Duration::from_secs(1), |_| Ok(()))
            .await
            .unwrap();
    }
    #[tokio::test]
    async fn timeout_after_input_commit_is_uncertain_and_retains_capacity() {
        let worker = Box::leak(Box::new(BoundedWorker::default()));
        let (release, wait) = mpsc::channel();
        let (started, observed) = mpsc::channel();
        let task = tokio::spawn(async move {
            worker
                .run_async(Duration::from_millis(100), move |cancel| {
                    cancel.begin_input()?;
                    started.send(()).unwrap();
                    wait.recv().unwrap();
                    Ok(())
                })
                .await
        });
        // Await provider start without blocking the test executor.
        tokio::task::spawn_blocking(move || observed.recv().unwrap())
            .await
            .unwrap();
        let error = task.await.unwrap().unwrap_err();
        assert_eq!(
            error.downcast_ref::<InsertionFailure>(),
            Some(&InsertionFailure::Unconfirmed)
        );
        release.send(()).unwrap();
    }
}
