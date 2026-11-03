/* Purpose: production BLE security, cache delivery and offline handoff regressions.
 * Inputs: synthetic NimBLE events/NVS/phone bytes. Verified on host only; iPhone
 * caching and real pairing interoperability remain untested. */
#define VR_BLE_HOST_TEST 1
#include "../app/ble.c"
#include <stdio.h>
vr_state_t remote_state;
SemaphoreHandle_t remote_mutex;
static struct ble_gap_conn_desc desc;
static struct ble_store_value_sec bond;
static int peer_count, clear_rc;
static bool owner, link_was_live, recently, enrollment_allowed=true;
static unsigned announcements, layout_saved, refreshes, snapshots, terminated;
static uint32_t stored_layout, fake_now=1000;
static const board_info_t board={.operational=true,.capabilities=128};
uint32_t remote_now(void) { return fake_now; }
BaseType_t xSemaphoreTakeRecursive(SemaphoreHandle_t h,TickType_t t) { (void)h;(void)t;return pdTRUE; }
BaseType_t xSemaphoreGiveRecursive(SemaphoreHandle_t h) { (void)h;return pdTRUE; }
const board_info_t *board_info(void) { return &board; }
void ui_refresh(void) {}
void ui_link(const char *p) { (void)p; }
void ui_pair_hide(void) {}
void ui_pair_number(uint32_t n) { (void)n; }
bool ui_phone(const vr_phone_t *p) { (void)p;return true; }
void audio_reset(void) {}
void audio_sync(void) {}
void audio_fault(void) {}
void audio_notify_failed(void) {}
bool audio_recently_live(void) { return recently; }
bool audio_input_allowed(void) { return true; }
void offline_owner(bool v) { owner=v; }
void offline_disconnect(bool v) { link_was_live=v; }
void offline_connection_reset(void) {}
void offline_progress_refresh(void) { refreshes++; }
void offline_subscriptions(bool r,bool p) { (void)r;(void)p; }
bool offline_enrollment_allowed(void) { return enrollment_allowed; }
bool offline_prepare_enrollment(void) { return true; }
int offline_request(const uint8_t *p,size_t n) { (void)p;(void)n;return 0; }
int nvs_open(const char *s,int m,nvs_handle_t *h) { (void)s;(void)m;*h=1;return 0; }
int nvs_get_u32(nvs_handle_t h,const char *k,uint32_t *v) { (void)h;*v=!strcmp(k,"gatt_layout")?VR_GATT_LAYOUT:stored_layout;return 0; }
int nvs_set_u32(nvs_handle_t h,const char *k,uint32_t v) { (void)h;assert(!strcmp(k,"gatt_acked"));stored_layout=v;layout_saved++;return 0; }
int nvs_commit(nvs_handle_t h) { (void)h;return 0; }
void nvs_close(nvs_handle_t h) { (void)h; }
void ble_svc_gatt_changed(uint16_t a,uint16_t b) { assert(a==1 && b==65535);announcements++; }
int ble_gatts_find_chr(const ble_uuid_t *s,const ble_uuid_t *c,uint16_t *d,uint16_t *v)
{ assert(((const ble_uuid16_t *)s)->value==0x1801 && ((const ble_uuid16_t *)c)->value==0x2a05);(void)d;*v=7;return 0; }
int ble_gap_conn_find(uint16_t h,struct ble_gap_conn_desc *d) { (void)h;*d=desc;return 0; }
int ble_store_util_bonded_peers(ble_addr_t *p,int *n,int max) { assert(max==1);memset(p,0,sizeof *p);*n=peer_count;return 0; }
int ble_store_read_our_sec(const struct ble_store_key_sec *k,struct ble_store_value_sec *v) { (void)k;*v=bond;return 0; }
int ble_store_clear(void) { if(!clear_rc) peer_count=0;return clear_rc; }
int ble_gap_adv_set_fields(const struct ble_hs_adv_fields *f) { (void)f;return 0; }
const char *ble_svc_gap_device_name(void) { return "Synthetic"; }
int ble_gap_adv_rsp_set_fields(const struct ble_hs_adv_fields *f) { (void)f;return 0; }
int ble_gap_adv_start(uint8_t a,const void *b,int t,const struct ble_gap_adv_params *p,int (*cb)(struct ble_gap_event *,void *),void *arg)
{ (void)a;(void)b;(void)t;(void)p;(void)cb;(void)arg;return 0; }
struct os_mbuf *ble_hs_mbuf_from_flat(const void *p,size_t n) { static struct os_mbuf m;m.n=n;memcpy(m.bytes,p,n);return &m; }
int ble_gatts_notify_custom(uint16_t h,uint16_t a,struct os_mbuf *m) { (void)h;(void)a;if(m->n==14) snapshots++;return 0; }
int os_mbuf_append(struct os_mbuf *m,const void *p,size_t n) { memcpy(m->bytes+m->n,p,n);m->n+=n;return 0; }
int ble_hs_mbuf_to_flat(struct os_mbuf *m,void *p,size_t n,uint16_t *out) { assert(m->n<=n);memcpy(p,m->bytes,m->n);if(out) *out=m->n;return 0; }
uint16_t ble_att_mtu(uint16_t h) { (void)h;return 247; }
int ble_gap_terminate(uint16_t h,int r) { (void)h;(void)r;terminated++;return 0; }
int ble_gap_security_initiate(uint16_t h) { (void)h;return 0; }
int ble_gap_update_params(uint16_t h,const struct ble_gap_upd_params *p) { (void)h;(void)p;return 0; }
int ble_gattc_exchange_mtu(uint16_t h,void *a,void *b) { (void)h;(void)a;(void)b;return 0; }
int ble_sm_inject_io(uint16_t h,const struct ble_sm_io *i) { (void)h;(void)i;return 0; }
int ble_hs_util_ensure_addr(int v) { (void)v;return 0; }
int ble_hs_id_infer_auto(int v,uint8_t *p) { (void)v;*p=0;return 0; }
void nimble_port_run(void) {}
void nimble_port_freertos_deinit(void) {}
int nimble_port_init(void) { return 0; }
void ble_svc_gap_init(void) {}
void ble_svc_gatt_init(void) {}
int ble_svc_gap_device_name_set(const char *s) { (void)s;return 0; }
int ble_gatts_count_cfg(const struct ble_gatt_svc_def *s) { (void)s;return 0; }
int ble_gatts_add_svcs(const struct ble_gatt_svc_def *s) { (void)s;return 0; }
void ble_store_config_init(void) {}
void nimble_port_freertos_init(void (*f)(void *)) { (void)f; }
static void reset(void)
{
    fake_now=1000; connection=1; layout_handle=0; layout_pending=false; synced=true; enrollment=comparison_pending=comparison_accepted=known_connection=enrollment_connection=revoke_pending=false;
    remote_state=(vr_state_t){0}; desc=(struct ble_gap_conn_desc){.sec_state={true,true,true,16}};
    peer_count=1; bond=(struct ble_store_value_sec){.authenticated=true,.sc=true,.ltk_present=true,.key_size=16};
    owner=link_was_live=recently=false; clear_rc=0;
    announcements=layout_saved=refreshes=snapshots=terminated=stored_layout=0;
}
static void event(int type) { struct ble_gap_event e={.type=type};gap_event(&e,NULL); }
static void connect_unknown(bool enroll)
{
    reset(); owner=!enroll; peer_count=enroll?0:1; enrollment=enroll; enrollment_started=fake_now;
    desc.peer_id_addr.val[0]=1; /* Existing owner address is all zero in the store. */
    struct ble_gap_event e={.type=BLE_GAP_EVENT_CONNECT,.connect={.conn_handle=1}};
    gap_event(&e,NULL); assert(!known_connection);
    if(enroll) peer_count=1; /* SM persisted the new enrollment keys before ENC_CHANGE. */
}
static void enrollment_scope(void)
{
    connect_unknown(false); assert(terminated);
    struct ble_gap_event e={.type=BLE_GAP_EVENT_ENC_CHANGE,.enc_change={.status=1}};
    gap_event(&e,NULL);
    assert(peer_count==1 && owner && !revoke_pending); /* stranger cannot revoke */
    connect_unknown(true); gap_event(&e,NULL);
    assert(!peer_count && !owner);
    connect_unknown(true); fake_now+=60001; ble_poll(fake_now); assert(!enrollment);
    gap_event(&e,NULL); assert(!peer_count && !owner); /* captured at CONNECT */
}
static void rejected_enrollment(void)
{
    connect_unknown(true); desc.sec_state.authenticated=false;
    event(BLE_GAP_EVENT_ENC_CHANGE);
    assert(!owner && !peer_count && !remote_state.secure && terminated);
    /* Power loss before rejection still must not promote a Just Works bond. */
    reset(); bond.authenticated=false; on_sync(); assert(!owner && !peer_count);
    reset(); bond.authenticated=false; clear_rc=1; on_sync(); assert(!owner && revoke_pending);
    clear_rc=0; event(BLE_GAP_EVENT_DISCONNECT); assert(!peer_count && !revoke_pending);
    reset(); bond.sc=false; on_sync(); assert(!owner && !peer_count);
    reset(); bond.key_size=7; on_sync(); assert(!owner && !peer_count);
    reset(); bond.ltk_present=false; on_sync(); assert(!owner && !peer_count);
    reset(); on_sync(); assert(owner && peer_count==1);
    reset(); comparison_accepted=true; event(BLE_GAP_EVENT_ENC_CHANGE); assert(owner && remote_state.secure);
}
static void gatt_delivery(void)
{
    reset(); known_connection=true; event(BLE_GAP_EVENT_ENC_CHANGE);
    assert(announcements==1 && !layout_saved);
    struct ble_gap_event e={.type=BLE_GAP_EVENT_SUBSCRIBE,.subscribe={.attr_handle=7,.cur_indicate=true}};
    gap_event(&e,NULL); assert(announcements==2 && !layout_saved);
    e=(struct ble_gap_event){.type=BLE_GAP_EVENT_NOTIFY_TX,.notify_tx={.conn_handle=1,.attr_handle=7,.indication=true,.status=0}};
    gap_event(&e,NULL); assert(!layout_saved); /* sent != acknowledged */
    e.notify_tx.status=1;gap_event(&e,NULL);assert(!layout_saved);
    e.notify_tx.status=BLE_HS_EDONE;gap_event(&e,NULL);assert(layout_saved==1 && stored_layout==VR_GATT_LAYOUT);
}
static void recent_link_loss(void)
{
    reset(); recently=true; remote_state.has_phone=true; remote_state.phone.recording=1;
    event(BLE_GAP_EVENT_DISCONNECT);assert(link_was_live);
    reset(); recently=true; remote_state.has_phone=true; remote_state.phone.recording=2;
    on_reset(0);assert(!link_was_live); /* pause remains authoritative */
    reset(); recently=true;remote_state.has_phone=true;remote_state.phone.recording=1;
    on_reset(0);assert(link_was_live);
}
static void snapshot_flag(void)
{
    reset(); remote_state.secure=remote_state.info_read=remote_state.input_sub=true;
    static const uint8_t logical[]={1,0,0,0,1,0,0,0,0,0,4,'A','u','t','o',2,'P','C',0,0};
    uint8_t bytes[6+sizeof logical];vr_put16(bytes,1);vr_put16(bytes+2,sizeof logical);vr_put16(bytes+4,0);memcpy(bytes+6,logical,sizeof logical);
    struct os_mbuf m={.n=sizeof bytes};memcpy(m.bytes,bytes,sizeof bytes);
    struct ble_gatt_access_ctxt ctx={.op=BLE_GATT_ACCESS_OP_WRITE_CHR,.om=&m};
    assert(!access_value(1,0,&ctx,(void *)3));assert(refreshes==1 && snapshots==1);
    bytes[6]=0;vr_put16(bytes,2);memcpy(m.bytes,bytes,sizeof bytes);
    assert(!access_value(1,0,&ctx,(void *)3));assert(refreshes==1 && snapshots==1);
}
int main(int argc,char **argv)
{
    if(argc>1 && !strcmp(argv[1],"enrollment")) { enrollment_scope(); return 0; }
    if(argc>1 && !strcmp(argv[1],"gatt")) { gatt_delivery();return 0; }
    enrollment_scope();rejected_enrollment();gatt_delivery();recent_link_loss();snapshot_flag();
    puts("BLE: rejected bond cleanup/boot ownership, acknowledged layout delivery, recent loss and snapshot flag pass");
}
