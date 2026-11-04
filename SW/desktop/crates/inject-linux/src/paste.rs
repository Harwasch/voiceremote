//! Bounded clipboard lease. A read cannot prove insertion or shorten the lease.
use std::time::Duration;
pub(crate) const RESTORE_AFTER: Duration = Duration::from_secs(30);
pub(crate) async fn wait() {
    tokio::time::sleep(RESTORE_AFTER).await;
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test(start_paused = true)]
    async fn restore_wait_is_bounded_and_does_not_end_after_manager_read() {
        let wait = wait();
        tokio::pin!(wait);
        assert!(
            tokio::time::timeout(Duration::from_millis(150), &mut wait)
                .await
                .is_err()
        );
        tokio::time::advance(Duration::from_millis(29_849)).await;
        assert!(futures_util::poll!(&mut wait).is_pending());
        tokio::time::advance(Duration::from_millis(1)).await;
        assert!(futures_util::poll!(&mut wait).is_ready());
    }
}
