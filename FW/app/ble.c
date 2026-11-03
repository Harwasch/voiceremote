#include "runtime.h"
#include "offline.h"
#include "board.h"
#include "esp_log.h"
#ifdef VR_BLE_HOST_TEST
#include "ble_test_platform.h"
#else
#include "host/ble_hs.h"
#include "host/ble_sm.h"
#include "host/util/util.h"
void ble_store_config_init(void);
#include "host/ble_store.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "store/config/ble_store_config.h"
#include "nvs.h"
#endif
#include <string.h>
/* NimBLE UUID128_INIT uses Bluetooth little-endian byte arrays. Generate from
   canonical UUID text, reversing bytes once at this API boundary only. */
static ble_uuid128_t uuids[8];
static uint16_t connection=BLE_HS_CONN_HANDLE_NONE, input_handle, audio_handle, result_handle, progress_handle;
static bool result_subscribed, progress_subscribed;
static uint8_t own_address;
static unsigned audio_pending;
static uint32_t audio_sent_at;
static bool synced, enrollment, comparison_pending, comparison_accepted, known_connection, enrollment_connection, revoke_pending;
static uint32_t enrollment_started, comparison_started;
/* Bump when characteristics change. Bonded phones cache the layout, so they must be told. */
#define VR_GATT_LAYOUT 2
/* Ignore the old gatt_layout key: older firmware saved it without delivery. */
static uint16_t layout_handle;
static bool layout_pending;
static void announce_gatt_layout(void)
{
    const ble_uuid16_t service=BLE_UUID16_INIT(0x1801), changed=BLE_UUID16_INIT(0x2a05);
    if(ble_gatts_find_chr(&service.u,&changed.u,NULL,&layout_handle)) return;
    nvs_handle_t h; uint32_t stored=0;
    if(nvs_open("remote",NVS_READWRITE,&h)) return;
    nvs_get_u32(h,"gatt_acked",&stored); nvs_close(h);
    if(stored!=VR_GATT_LAYOUT) {
        layout_pending=true;
        ble_svc_gatt_changed(0x0001,0xffff);
        ESP_LOGI("ble","GATT layout %lu -> %d pending acknowledgment",(unsigned long)stored,VR_GATT_LAYOUT);
    }
}
static void layout_delivered(void)
{
    nvs_handle_t h;
    if(!layout_pending || nvs_open("remote",NVS_READWRITE,&h)) return;
    if(!nvs_set_u32(h,"gatt_acked",VR_GATT_LAYOUT) && !nvs_commit(h)) layout_pending=false;
    nvs_close(h);
}
/* NimBLE can persist Just Works keys before ENC_CHANGE. A reboot must not
 * turn an unauthenticated bond into offline ownership. */
static bool trusted_bond(const ble_addr_t *peer)
{
    struct ble_store_key_sec key={.peer_addr=*peer}; struct ble_store_value_sec value;
    return !ble_store_read_our_sec(&key,&value) && value.ltk_present &&
        value.authenticated && value.sc && value.key_size==16;
}
static int gap_event(struct ble_gap_event *e,void *arg);
static void lock(void) { xSemaphoreTakeRecursive(remote_mutex,portMAX_DELAY); }
static void unlock(void) { xSemaphoreGiveRecursive(remote_mutex); }
static bool secure(uint16_t h)
{
    struct ble_gap_conn_desc d;
    return h==connection && !ble_gap_conn_find(h,&d) && d.sec_state.encrypted &&
        d.sec_state.authenticated && d.sec_state.bonded && d.sec_state.key_size==16 && remote_state.secure;
}
static bool known_peer(uint16_t h)
{
    struct ble_gap_conn_desc d; ble_addr_t peers[1]; int n=0;
    if(ble_gap_conn_find(h,&d) || ble_store_util_bonded_peers(peers,&n,1)) return false;
    return n==1 && !memcmp(&peers[0],&d.peer_id_addr,sizeof peers[0]);
}
static void advertise(void)
{
    if(!synced || connection!=BLE_HS_CONN_HANDLE_NONE) return;
    struct ble_hs_adv_fields f={0};
    f.flags=BLE_HS_ADV_F_DISC_GEN|BLE_HS_ADV_F_BREDR_UNSUP;
    f.uuids128=&uuids[0]; f.num_uuids128=1; f.uuids128_is_complete=1;
    int rc=ble_gap_adv_set_fields(&f);
    struct ble_hs_adv_fields scan={0};
    const char *name=ble_svc_gap_device_name(); scan.name=(uint8_t*)name; scan.name_len=strlen(name); scan.name_is_complete=1;
    if(!rc) rc=ble_gap_adv_rsp_set_fields(&scan);
    struct ble_gap_adv_params p={.conn_mode=BLE_GAP_CONN_MODE_UND,.disc_mode=BLE_GAP_DISC_MODE_GEN};
    if(!rc) rc=ble_gap_adv_start(own_address,NULL,BLE_HS_FOREVER,&p,gap_event,NULL);
    if(rc) ESP_LOGE("ble","advertising failed: %d",rc);
}
void ble_emit(uint8_t event,uint32_t sampled)
{
    if(!audio_input_allowed() || !remote_state.input_sub || !secure(connection)) return;
    vr_input_t input=vr_prepare_input(&remote_state,event,sampled); uint8_t bytes[14];
    if(!vr_input_encode(&input,bytes)) return;
    struct os_mbuf *om=ble_hs_mbuf_from_flat(bytes,sizeof bytes);
    int rc=om?ble_gatts_notify_custom(connection,input_handle,om):BLE_HS_ENOMEM;
    vr_input_sent(&remote_state,&input,!rc);
    if(rc) ui_link("Input unavailable; request snapshot");
}
static int access_value(uint16_t h,uint16_t attr,struct ble_gatt_access_ctxt *ctxt,void *arg)
{
    (void)attr; unsigned which=(uintptr_t)arg;
    lock(); int rc=0;
    if(!secure(h)) { rc=BLE_ATT_ERR_INSUFFICIENT_AUTHEN; goto done; }
    if(which==1 && ctxt->op==BLE_GATT_ACCESS_OP_READ_CHR) {
        const board_info_t *b=board_info();
        vr_info_t info={.board=b->id,.caps=b->capabilities,.width=b->operational?b->width:0,
            .height=b->operational?b->height:0,.max_packet=VR_MAX_PACKET,.fw={0,3,0},.mics=1,.slider=b->virtual_sliders?1:0};
        uint8_t bytes[20];
        if(!vr_info_encode(&info,bytes) || os_mbuf_append(ctxt->om,bytes,sizeof bytes)) rc=BLE_ATT_ERR_INSUFFICIENT_RES;
        else remote_state.info_read=true;
    } else if(which==3 && ctxt->op==BLE_GATT_ACCESS_OP_WRITE_CHR) {
        uint16_t n=OS_MBUF_PKTLEN(ctxt->om); uint8_t bytes[518];
        vr_phone_t phone;
        if(n>sizeof bytes || n>(unsigned)(ble_att_mtu(h)-3) || ble_hs_mbuf_to_flat(ctxt->om,bytes,sizeof bytes,NULL)) {
            remote_state.fragments.active=false; rc=BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN; goto done;
        }
        int result=vr_state_fragment(&remote_state,bytes,n,&phone);
        if(result<0) rc=BLE_ATT_ERR_VALUE_NOT_ALLOWED;
        else if(result==1) {
            /* Render candidate before publishing control state or sending final ATT response. */
            if(!ui_phone(&phone) || !secure(h)) {
                ui_refresh();
                remote_state.armed=false; rc=BLE_ATT_ERR_UNLIKELY;
            } else {
                vr_apply_phone(&remote_state,&phone);
                audio_sync();
                if(phone.flags&1) { offline_progress_refresh(); ble_emit(VR_SNAPSHOT,remote_now()); }
            }
        }
    } else if(which==5 && ctxt->op==BLE_GATT_ACCESS_OP_WRITE_CHR) {
        uint16_t n=OS_MBUF_PKTLEN(ctxt->om); uint8_t bytes[27];
        if(n>sizeof bytes || n>(unsigned)(ble_att_mtu(h)-3) || ble_hs_mbuf_to_flat(ctxt->om,bytes,sizeof bytes,NULL) || offline_request(bytes,n)<0)
            rc=BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    } else rc=BLE_ATT_ERR_READ_NOT_PERMITTED;
done:
    unlock(); return rc;
}
#define READ_SECURITY (BLE_GATT_CHR_F_READ_ENC|BLE_GATT_CHR_F_READ_AUTHEN|BLE_GATT_CHR_F_READ_AUTHOR)
#define WRITE_SECURITY (BLE_GATT_CHR_F_WRITE_ENC|BLE_GATT_CHR_F_WRITE_AUTHEN|BLE_GATT_CHR_F_WRITE_AUTHOR)
#define SUB_SECURITY (BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC|BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHEN|BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHOR)
static struct ble_gatt_chr_def characteristics[]={
    {.uuid=&uuids[1].u,.access_cb=access_value,.arg=(void*)1,.flags=BLE_GATT_CHR_F_READ|READ_SECURITY,.min_key_size=16},
    {.uuid=&uuids[2].u,.access_cb=access_value,.arg=(void*)2,.flags=BLE_GATT_CHR_F_NOTIFY|SUB_SECURITY,.val_handle=&input_handle,.min_key_size=16},
    {.uuid=&uuids[3].u,.access_cb=access_value,.arg=(void*)3,.flags=BLE_GATT_CHR_F_WRITE|WRITE_SECURITY,.min_key_size=16},
    {.uuid=&uuids[4].u,.access_cb=access_value,.arg=(void*)4,.flags=BLE_GATT_CHR_F_NOTIFY|SUB_SECURITY,.val_handle=&audio_handle,.min_key_size=16},
    {.uuid=&uuids[5].u,.access_cb=access_value,.arg=(void*)5,.flags=BLE_GATT_CHR_F_WRITE|WRITE_SECURITY,.min_key_size=16},
    {.uuid=&uuids[6].u,.access_cb=access_value,.arg=(void*)6,.flags=BLE_GATT_CHR_F_NOTIFY|SUB_SECURITY,.val_handle=&result_handle,.min_key_size=16},
    {.uuid=&uuids[7].u,.access_cb=access_value,.arg=(void*)7,.flags=BLE_GATT_CHR_F_NOTIFY|SUB_SECURITY,.val_handle=&progress_handle,.min_key_size=16},
    {0}
};
static const struct ble_gatt_svc_def services[]={
    {.type=BLE_GATT_SVC_TYPE_PRIMARY,.uuid=&uuids[0].u,.characteristics=characteristics}, {0}
};
static void disconnect(void)
{
    remote_state.secure=false; remote_state.armed=false; audio_reset();
    if(connection!=BLE_HS_CONN_HANDLE_NONE) ble_gap_terminate(connection,BLE_ERR_REM_USER_CONN_TERM);
}
static int gap_event(struct ble_gap_event *e,void *arg)
{
    (void)arg; lock();
    switch(e->type) {
    case BLE_GAP_EVENT_CONNECT:
        if(e->connect.status) { advertise(); break; }
        audio_reset(); audio_pending=false;
        offline_connection_reset(); result_subscribed=progress_subscribed=false;
        connection=e->connect.conn_handle; layout_pending=false; vr_session_reset(&remote_state);
        comparison_pending=false; comparison_accepted=false;
        known_connection=known_peer(connection);
        /* Enrollment may expire before SM reports failure; preserve origin until
         * disconnect so a rejected stranger cannot erase the owner's bond. */
        enrollment_connection=enrollment && !known_connection;
        if(revoke_pending) { disconnect(); break; }
        if(!known_connection && !enrollment) { disconnect(); break; }
        ui_link("Securing Bluetooth");
        if(ble_gap_security_initiate(connection)) disconnect();
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        if(revoke_pending) {
            int rc=ble_store_clear();
            revoke_pending=rc!=0;
            if(rc) ESP_LOGE("ble","bond removal failed: %d",rc);
        }
        offline_disconnect(remote_state.input.streaming || vr_capture_gate(&remote_state) ||
            (audio_recently_live() && remote_state.has_phone && remote_state.phone.recording==1));
        result_subscribed=progress_subscribed=false;
        connection=BLE_HS_CONN_HANDLE_NONE; audio_pending=false; audio_reset(); vr_session_reset(&remote_state);
        comparison_pending=false; comparison_accepted=false; enrollment_connection=false;
        ui_pair_hide(); ui_refresh(); ui_link("Disconnected"); advertise(); break;
    case BLE_GAP_EVENT_ENC_CHANGE: {
        struct ble_gap_conn_desc d;
        bool good=!e->enc_change.status && !ble_gap_conn_find(connection,&d) &&
            d.sec_state.encrypted && d.sec_state.authenticated && d.sec_state.bonded && d.sec_state.key_size==16 &&
            (known_connection || comparison_accepted);
        if(!good) {
            if(enrollment_connection) {
                offline_owner(false); enrollment=false; comparison_pending=false;
                /* Single-owner enrollment has no previous bond to preserve. */
                int rc=ble_store_clear(); revoke_pending=rc!=0;
                if(rc) ESP_LOGE("ble","rejected enrollment bond removal failed: %d",rc);
            }
            disconnect(); break;
        }
        announce_gatt_layout();
        offline_owner(true);
        remote_state.secure=true; enrollment=false; comparison_pending=false;
        ui_pair_hide(); ui_link("Bond secured");
        /* Apple QA1931: 15–30 ms, no latency, supervision 4 s. OS chooses. */
        struct ble_gap_upd_params params={.itvl_min=12,.itvl_max=24,.latency=0,.supervision_timeout=400};
        int update=ble_gap_update_params(connection,&params);
        int mtu=ble_gattc_exchange_mtu(connection,NULL,NULL);
        ESP_LOGI("ble","connection request=%d MTU request=%d",update,mtu);
        /* CCCDs can be restored from a bond before encryption. Still send a fresh snapshot. */
        if(remote_state.input_sub) ble_emit(VR_SNAPSHOT,remote_now());
        break;
    }
    case BLE_GAP_EVENT_PASSKEY_ACTION:
        if(enrollment && !known_connection && e->passkey.params.action==BLE_SM_IOACT_NUMCMP &&
            (uint32_t)(remote_now()-enrollment_started)<60000) {
            comparison_pending=true; comparison_started=remote_now();
            ui_pair_number(e->passkey.params.numcmp);
        } else disconnect(); /* No display-only passkey, Just Works, OOB or legacy fallback. */
        break;
    case BLE_GAP_EVENT_REPEAT_PAIRING:
        unlock(); return BLE_GAP_REPEAT_PAIRING_IGNORE; /* Explicit local revoke first. */
    case BLE_GAP_EVENT_AUTHORIZE:
        e->authorize.out_response=secure(e->authorize.conn_handle)?BLE_GAP_AUTHORIZE_ACCEPT:BLE_GAP_AUTHORIZE_REJECT;
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if(e->subscribe.attr_handle==layout_handle && e->subscribe.cur_indicate && secure(connection)) announce_gatt_layout();
        if(e->subscribe.attr_handle==input_handle) {
            remote_state.input_sub=e->subscribe.cur_notify;
            if(remote_state.input_sub && secure(connection)) ble_emit(VR_SNAPSHOT,remote_now());
            else { remote_state.armed=false; remote_state.snapshot_sent=false; }
        } else if(e->subscribe.attr_handle==audio_handle) {
            remote_state.audio_sub=e->subscribe.cur_notify;
            if(!remote_state.audio_sub) remote_state.armed=false;
        }
        if(e->subscribe.attr_handle==result_handle) result_subscribed=e->subscribe.cur_notify;
        if(e->subscribe.attr_handle==progress_handle) progress_subscribed=e->subscribe.cur_notify;
        offline_subscriptions(result_subscribed,progress_subscribed);
        break;
    case BLE_GAP_EVENT_MTU:
        ESP_LOGI("ble","negotiated ATT MTU=%u",e->mtu.value);
        break;
    case BLE_GAP_EVENT_NOTIFY_TX:
        if(e->notify_tx.conn_handle==connection && e->notify_tx.attr_handle==layout_handle &&
           e->notify_tx.indication && e->notify_tx.status==BLE_HS_EDONE && secure(connection)) layout_delivered();
        if(e->notify_tx.conn_handle==connection && e->notify_tx.attr_handle==audio_handle) {
            if(audio_pending) audio_pending--;
            if(e->notify_tx.status) audio_notify_failed();
        }
        if(e->notify_tx.conn_handle==connection && e->notify_tx.attr_handle==input_handle && e->notify_tx.status) {
            remote_state.armed=false; remote_state.snapshot_sent=false;
            ui_link("Input transport failed; resync");
        }
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE: advertise(); break;
    default: break;
    }
    audio_sync();
    unlock(); return 0;
}
void ble_pair_start(void)
{
    if(!synced || revoke_pending || !board_info()->operational) return;
    ble_addr_t peer[1]; int n=0;
    if(ble_store_util_bonded_peers(peer,&n,1) || n) { ui_link("Revoke existing bond before pairing"); return; }
    /* Never expose a previous owner's retained recordings to a new bond.
     * Explicit local data erase (documented maintenance) precedes re-enrollment. */
    if(!offline_enrollment_allowed()) { ESP_LOGE("offline","enrollment blocked: retained records require explicit local erase"); return; }
    if(!offline_prepare_enrollment()) {
        ESP_LOGE("offline","cannot persist storage hold for enrollment"); return;
    }
    enrollment=true; enrollment_started=remote_now(); comparison_accepted=false;
    ui_link("Pairing open for 60 seconds"); advertise();
}
void ble_pair_answer(bool accept)
{
    if(!comparison_pending) return;
    struct ble_sm_io io={.action=BLE_SM_IOACT_NUMCMP,.numcmp_accept=accept};
    if((uint32_t)(remote_now()-comparison_started)>=30000) io.numcmp_accept=0;
    comparison_accepted=io.numcmp_accept; comparison_pending=false;
    int rc=ble_sm_inject_io(connection,&io);
    ui_pair_hide();
    if(rc || !comparison_accepted) { enrollment=false; disconnect(); ui_link("Pairing rejected"); }
}
void ble_revoke(void)
{
    offline_owner(false); audio_sync();
    enrollment=false; comparison_pending=false; comparison_accepted=false;
    revoke_pending=connection!=BLE_HS_CONN_HANDLE_NONE;
    disconnect();
    int rc=ble_store_clear();
    if(rc) revoke_pending=true;
    ui_pair_hide(); vr_session_reset(&remote_state); ui_refresh();
    ui_link(rc?"Bond removal failed":"Bond revoked; tap Pair to enroll");
}
void ble_poll(uint32_t now)
{
    if(comparison_pending && (uint32_t)(now-comparison_started)>=30000) ble_pair_answer(false);
    if(enrollment && (uint32_t)(now-enrollment_started)>=60000) {
        enrollment=false; if(!remote_state.secure) disconnect(); ui_pair_hide(); ui_link("Pairing timed out");
    }
}
static void on_sync(void)
{
    lock(); int rc=ble_hs_util_ensure_addr(0);
    if(!rc) rc=ble_hs_id_infer_auto(0,&own_address);
    if(!rc) {
        ble_addr_t peers[1]; int count=0;
        offline_owner(false);
        if(!ble_store_util_bonded_peers(peers,&count,1) && count==1) {
            if(trusted_bond(&peers[0])) offline_owner(true);
            else {
                int removed=ble_store_clear(); revoke_pending=removed!=0;
                if(removed) ESP_LOGE("ble","untrusted boot bond removal failed: %d",removed);
            }
        }
        synced=true; advertise();
    }
    else ESP_LOGE("ble","identity setup failed: %d",rc);
    unlock();
}
static void on_reset(int reason)
{
    (void)reason; lock(); synced=false; connection=BLE_HS_CONN_HANDLE_NONE;
    offline_disconnect(remote_state.input.streaming || vr_capture_gate(&remote_state) ||
            (audio_recently_live() && remote_state.has_phone && remote_state.phone.recording==1));
    result_subscribed=progress_subscribed=false; audio_pending=0; audio_reset();
    vr_session_reset(&remote_state); comparison_pending=false; enrollment=false; enrollment_connection=false;
    ui_pair_hide(); ui_refresh(); ui_link("Bluetooth reset"); unlock();
}
static void host_task(void *arg) { (void)arg; nimble_port_run(); nimble_port_freertos_deinit(); }
void ble_start(void)
{
    const char *strings[]={VR_SERVICE_UUID,VR_INFO_UUID,VR_INPUT_UUID,VR_PHONE_UUID,VR_AUDIO_UUID,VR_OFFLINE_CONTROL_UUID,VR_OFFLINE_RESULT_UUID,VR_OFFLINE_PROGRESS_UUID};
    for(unsigned i=0;i<8;i++) {
        uint8_t canonical[16]; unsigned k=0,high=0; bool half=false;
        for(const char *p=strings[i];*p;p++) {
            if(*p=='-') continue;
            unsigned v=*p<='9'?*p-'0':*p-'a'+10;
            if(!half) high=v; else canonical[k++]=(high<<4)|v;
            half=!half;
        }
        uuids[i].u.type=BLE_UUID_TYPE_128;
        for(unsigned j=0;j<16;j++) uuids[i].value[j]=canonical[15-j];
    }
    if(!(board_info()->capabilities&128)) memset(&characteristics[4],0,sizeof characteristics[4]);
    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.sync_cb=on_sync; ble_hs_cfg.reset_cb=on_reset;
    ble_hs_cfg.sm_io_cap=BLE_HS_IO_DISPLAY_YESNO;
    ble_hs_cfg.sm_bonding=1; ble_hs_cfg.sm_mitm=1; ble_hs_cfg.sm_sc=1; ble_hs_cfg.sm_sc_only=1;
    ble_hs_cfg.sm_our_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_svc_gap_init(); ble_svc_gatt_init();
    configASSERT(!ble_svc_gap_device_name_set("Voice Remote"));
    configASSERT(!ble_gatts_count_cfg(services)); configASSERT(!ble_gatts_add_svcs(services));
    ble_store_config_init();
    nimble_port_freertos_init(host_task);
}

uint16_t ble_audio_mtu(void) { return connection==BLE_HS_CONN_HANDLE_NONE?23:ble_att_mtu(connection); }
bool ble_audio_ready(void)
{
    if(audio_pending && (uint32_t)(remote_now()-audio_sent_at)>200) audio_fault();
    return !audio_pending && remote_state.audio_sub && secure(connection);
}
static bool audio_send(const uint8_t *value,size_t size,bool end)
{
    if(!remote_state.audio_sub || !secure(connection) || audio_pending>=(end?2u:1u) ||
       size>(unsigned)(ble_audio_mtu()-3)) return false;
    struct os_mbuf *om=ble_hs_mbuf_from_flat(value,size);
    if(!om) return false;
    audio_pending++; audio_sent_at=remote_now();
    if(ble_gatts_notify_custom(connection,audio_handle,om)) { audio_pending--; return false; }
    return true;
}
bool ble_audio_send(const uint8_t *value,size_t size) { return audio_send(value,size,false); }
bool ble_audio_end(const uint8_t *value,size_t size) { return audio_send(value,size,true); }
void ble_audio_disconnect(void) { disconnect(); }

bool ble_offline_send(bool progress,const uint8_t *p,size_t n)
{
    if(!secure(connection) || n>(unsigned)(ble_audio_mtu()-3)) return false;
    uint16_t handle=progress?progress_handle:result_handle;
    if(!(progress?progress_subscribed:result_subscribed)) return false;
    struct os_mbuf *om=ble_hs_mbuf_from_flat(p,n);
    return om && ble_gatts_notify_custom(connection,handle,om)==0;
}
