#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
void offline_init(void);
void offline_poll(void);
void offline_control(uint8_t event, uint8_t value);
void offline_owner(bool enrolled);
void offline_progress_refresh(void);
bool offline_enrollment_allowed(void);
void offline_disconnect(bool was_live);
bool offline_local_wanted(void);
bool offline_local_active(void);
bool offline_live_allowed(void);
bool offline_packet(const uint8_t *packet, size_t n);
void offline_capture_error(void);
/* BLE sync envelope: -1 malformed/not ready, 0 pending, 1 accepted. */
int offline_request(const uint8_t *p, size_t n);
void offline_subscriptions(bool result, bool progress);
void offline_connection_reset(void);
void offline_cancel_sync(void);
/* Small nonblocking BLE submission; security checked at the boundary. */
bool ble_offline_send(bool progress, const uint8_t *p, size_t n);
