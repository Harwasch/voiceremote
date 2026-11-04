#pragma once
/* Purpose: synthetic NimBLE/NVS API boundary for production ble.c host tests.
 * Inputs: only fields/API used by the app; verified against local IDF builds. */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#define ESP_ERROR_CHECK(x) assert(!(x))
#define configASSERT(x) assert(x)
#define BLE_HS_CONN_HANDLE_NONE 65535
#define BLE_HS_ENOMEM 6
#define BLE_HS_EDONE 14
#define BLE_HS_FOREVER -1
#define BLE_HS_IO_DISPLAY_YESNO 1
#define BLE_HS_ADV_F_DISC_GEN 2
#define BLE_HS_ADV_F_BREDR_UNSUP 4
#define BLE_GAP_CONN_MODE_UND 0
#define BLE_GAP_DISC_MODE_GEN 0
#define BLE_ERR_REM_USER_CONN_TERM 19
#define BLE_ATT_ERR_INSUFFICIENT_AUTHEN 5
#define BLE_ATT_ERR_INSUFFICIENT_RES 17
#define BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN 13
#define BLE_ATT_ERR_VALUE_NOT_ALLOWED 19
#define BLE_ATT_ERR_UNLIKELY 14
#define BLE_ATT_ERR_READ_NOT_PERMITTED 2
#define BLE_GATT_ACCESS_OP_READ_CHR 0
#define BLE_GATT_ACCESS_OP_WRITE_CHR 1
#define BLE_GATT_CHR_F_READ_ENC 1
#define BLE_GATT_CHR_F_READ_AUTHEN 2
#define BLE_GATT_CHR_F_READ_AUTHOR 4
#define BLE_GATT_CHR_F_WRITE_ENC 8
#define BLE_GATT_CHR_F_WRITE_AUTHEN 16
#define BLE_GATT_CHR_F_WRITE_AUTHOR 32
#define BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC 64
#define BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHEN 128
#define BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHOR 256
#define BLE_GATT_CHR_F_READ 512
#define BLE_GATT_CHR_F_WRITE 1024
#define BLE_GATT_CHR_F_NOTIFY 2048
#define BLE_GATT_SVC_TYPE_PRIMARY 1
#define BLE_UUID_TYPE_128 128
#define BLE_GAP_REPEAT_PAIRING_IGNORE 0
#define BLE_GAP_AUTHORIZE_ACCEPT 1
#define BLE_GAP_AUTHORIZE_REJECT 0
#define BLE_SM_IOACT_NUMCMP 4
#define BLE_SM_PAIR_KEY_DIST_ENC 1
#define BLE_SM_PAIR_KEY_DIST_ID 2
#define NVS_READWRITE 1
#define BLE_UUID16_INIT(v) {.u={16},.value=(v)}
typedef struct { uint8_t type; } ble_uuid_t;
typedef struct { ble_uuid_t u; uint8_t value[16]; } ble_uuid128_t;
typedef struct { ble_uuid_t u; uint16_t value; } ble_uuid16_t;
typedef struct { uint8_t type,val[6]; } ble_addr_t;
struct os_mbuf { uint16_t n; uint8_t bytes[518]; };
#define OS_MBUF_PKTLEN(p) ((p)->n)
struct ble_gatt_access_ctxt { int op; struct os_mbuf *om; };
struct ble_gatt_chr_def { const ble_uuid_t *uuid; int (*access_cb)(uint16_t,uint16_t,struct ble_gatt_access_ctxt *,void *); void *arg; unsigned flags; uint16_t *val_handle; uint8_t min_key_size; };
struct ble_gatt_svc_def { int type; const ble_uuid_t *uuid; const struct ble_gatt_chr_def *characteristics; };
struct ble_gap_conn_desc { struct { bool encrypted,authenticated,bonded; uint8_t key_size; } sec_state; ble_addr_t peer_id_addr; };
struct ble_gap_adv_params { int conn_mode,disc_mode; };
struct ble_hs_adv_fields { int flags; ble_uuid128_t *uuids128; int num_uuids128,uuids128_is_complete; uint8_t *name; size_t name_len; int name_is_complete; };
struct ble_gap_upd_params { int itvl_min,itvl_max,latency,supervision_timeout; };
struct ble_sm_io { int action,numcmp_accept; };
enum { BLE_GAP_EVENT_CONNECT=1,BLE_GAP_EVENT_DISCONNECT,BLE_GAP_EVENT_ENC_CHANGE,BLE_GAP_EVENT_PASSKEY_ACTION,BLE_GAP_EVENT_REPEAT_PAIRING,BLE_GAP_EVENT_AUTHORIZE,BLE_GAP_EVENT_SUBSCRIBE,BLE_GAP_EVENT_MTU,BLE_GAP_EVENT_NOTIFY_TX,BLE_GAP_EVENT_ADV_COMPLETE };
struct ble_gap_event {
 int type;
 struct { int status; uint16_t conn_handle; } connect,enc_change;
 struct { struct { int action; uint32_t numcmp; } params; } passkey;
 struct { uint16_t conn_handle; int out_response; } authorize;
 struct { uint16_t attr_handle; bool cur_notify,cur_indicate; } subscribe;
 struct { uint16_t value; } mtu;
 struct { uint16_t conn_handle,attr_handle; int status; bool indication; } notify_tx;
};
struct ble_store_key_sec { ble_addr_t peer_addr; uint8_t idx; };
struct ble_store_value_sec { bool authenticated,sc,ltk_present; uint8_t key_size; };
typedef unsigned nvs_handle_t;
struct { void (*sync_cb)(void); void (*reset_cb)(int); int sm_io_cap,sm_bonding,sm_mitm,sm_sc,sm_sc_only,sm_our_key_dist,sm_their_key_dist; } ble_hs_cfg;
int nvs_open(const char *,int,nvs_handle_t *);
int nvs_get_u32(nvs_handle_t,const char *,uint32_t *);
int nvs_set_u32(nvs_handle_t,const char *,uint32_t);
int nvs_commit(nvs_handle_t);
void nvs_close(nvs_handle_t);
void ble_svc_gatt_changed(uint16_t,uint16_t);
int ble_gatts_find_chr(const ble_uuid_t *,const ble_uuid_t *,uint16_t *,uint16_t *);
int ble_gap_conn_find(uint16_t,struct ble_gap_conn_desc *);
int ble_store_util_bonded_peers(ble_addr_t *,int *,int);
int ble_store_read_our_sec(const struct ble_store_key_sec *,struct ble_store_value_sec *);
int ble_store_clear(void);
int ble_gap_adv_set_fields(const struct ble_hs_adv_fields *);
const char *ble_svc_gap_device_name(void);
int ble_gap_adv_rsp_set_fields(const struct ble_hs_adv_fields *);
int ble_gap_adv_start(uint8_t,const void *,int,const struct ble_gap_adv_params *,int (*)(struct ble_gap_event *,void *),void *);
struct os_mbuf *ble_hs_mbuf_from_flat(const void *,size_t);
int ble_gatts_notify_custom(uint16_t,uint16_t,struct os_mbuf *);
int os_mbuf_append(struct os_mbuf *,const void *,size_t);
int ble_hs_mbuf_to_flat(struct os_mbuf *,void *,size_t,uint16_t *);
uint16_t ble_att_mtu(uint16_t);
int ble_gap_terminate(uint16_t,int);
int ble_gap_security_initiate(uint16_t);
int ble_gap_update_params(uint16_t,const struct ble_gap_upd_params *);
int ble_gattc_exchange_mtu(uint16_t,void *,void *);
int ble_sm_inject_io(uint16_t,const struct ble_sm_io *);
int ble_hs_util_ensure_addr(int);
int ble_hs_id_infer_auto(int,uint8_t *);
void nimble_port_run(void);
void nimble_port_freertos_deinit(void);
int nimble_port_init(void);
void ble_svc_gap_init(void);
void ble_svc_gatt_init(void);
int ble_svc_gap_device_name_set(const char *);
int ble_gatts_count_cfg(const struct ble_gatt_svc_def *);
int ble_gatts_add_svcs(const struct ble_gatt_svc_def *);
void ble_store_config_init(void);
void nimble_port_freertos_init(void (*)(void *));
