/* OpenSSL >= 3.5 third-party QUIC TLS callbacks. All TLS/X.509 decisions stay
 * in the shared OpenSSL session. Callback buffers are copied into bounded
 * native queues; no borrowed MoonBit byte array survives an FFI call. */
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef struct ssl_st SSL;
typedef struct { int function_id; void (*function)(void); } QDispatch;
extern void *moon_http_tls_ssl_handle(void *);
extern void *moon_http_tls_library_handle(void);
extern void *moon_http_tls_symbol(const char *);
extern void moon_http_tls_close(void *);
typedef struct QNode { struct QNode *next; size_t length; int kind, level, direction; unsigned char data[]; } QNode;
typedef struct {
  void *owner;
  SSL *ssl;
  QNode *input[4], *input_tail[4], *active, *events, *events_tail;
  size_t input_bytes, event_bytes, total_input[4], limit;
  unsigned int event_count;
  unsigned char *local_params, *peer_params;
  size_t peer_params_len;
  int read_level, write_level, available, ready, failed, alert;
} HttpQuicTls;

static void qfree_node(QNode *node) {
  if (node) { volatile unsigned char *p = node->data; for (size_t i=0;i<node->length;i++) p[i]=0; free(node); }
}
static void qfree_queue(QNode *node) { while (node) { QNode *next=node->next; qfree_node(node); node=next; } }
static void qclose(void *object) {
  HttpQuicTls *q=object;
  if (q->owner) { moon_http_tls_close(q->owner); moonbit_decref(q->owner); q->owner=NULL; }
  for (int i=0;i<4;i++) { qfree_queue(q->input[i]); q->input[i]=q->input_tail[i]=NULL; }
  qfree_queue(q->events); q->events=q->events_tail=NULL; q->active=NULL;
  free(q->local_params); free(q->peer_params); q->local_params=q->peer_params=NULL;
  q->ssl=NULL; q->ready=0;
}
static QNode *qnode(const unsigned char *data,size_t n,int kind,int level,int direction) {
  QNode *node=malloc(sizeof(*node)+n); if (!node) return NULL;
  node->next=NULL; node->length=n; node->kind=kind; node->level=level; node->direction=direction;
  if(n) memcpy(node->data,data,n); return node;
}
static int qevent(HttpQuicTls *q,const unsigned char *data,size_t n,int kind,int level,int direction) {
  if(q->failed || n>q->limit-q->event_bytes || q->event_count>=256) {q->failed=1;return 0;}
  QNode *node=qnode(data,n,kind,level,direction); if(!node) {q->failed=1;return 0;}
  if(q->events_tail) q->events_tail->next=node; else q->events=node;
  q->events_tail=node; q->event_bytes+=n; q->event_count++; return 1;
}
static int qsend(SSL *ssl,const unsigned char *data,size_t n,size_t *consumed,void *arg) {
  (void)ssl; HttpQuicTls *q=arg; *consumed=0;
  if(!qevent(q,data,n,1,q->write_level,0))return 0; *consumed=n; return 1;
}
static int qrecv(SSL *ssl,const unsigned char **data,size_t *n,void *arg) {
  (void)ssl; HttpQuicTls *q=arg;
  if(q->failed)return 0;
  if(!q->active) q->active=q->input[q->read_level];
  *data=q->active?q->active->data:NULL; *n=q->active?q->active->length:0; return 1;
}
static int qrelease(SSL *ssl,size_t n,void *arg) {
  (void)ssl; HttpQuicTls *q=arg; QNode *node=q->active;
  if(!node)return n==0;
  if(n!=node->length){q->failed=1;return 0;}
  int level=node->level; q->input[level]=node->next;
  if(!q->input[level])q->input_tail[level]=NULL;
  q->input_bytes-=n; q->active=NULL; qfree_node(node); return 1;
}
static int qsecret(SSL *ssl,uint32_t level,int direction,const unsigned char *data,size_t n,void *arg) {
  (void)ssl; HttpQuicTls *q=arg;
  if((level!=2 && level!=3)||(direction!=0&&direction!=1)){q->failed=1;return 0;}
  if(!qevent(q,data,n,2,(int)level,direction))return 0;
  if(direction)q->write_level=(int)level;else q->read_level=(int)level; return 1;
}
static int qparams(SSL *ssl,const unsigned char *data,size_t n,void *arg) {
  (void)ssl; HttpQuicTls *q=arg;
  if(q->peer_params || n>65535){q->failed=1;return 0;}
  q->peer_params=malloc(n?n:1); if(!q->peer_params){q->failed=1;return 0;}
  if(n)memcpy(q->peer_params,data,n);q->peer_params_len=n;return 1;
}
static int qalert(SSL *ssl,unsigned char alert,void *arg) {
  (void)ssl; HttpQuicTls *q=arg;q->alert=alert;q->failed=1;return 1;
}
static const QDispatch callbacks[]={
  {2001,(void(*)(void))qsend},{2002,(void(*)(void))qrecv},
  {2003,(void(*)(void))qrelease},{2004,(void(*)(void))qsecret},
  {2005,(void(*)(void))qparams},{2006,(void(*)(void))qalert},{0,NULL}
};

MOONBIT_FFI_EXPORT HttpQuicTls *moon_http_quic_tls_new(void *owner,moonbit_bytes_t params,int limit) {
  HttpQuicTls *q=moonbit_make_external_object(qclose,sizeof(*q));memset(q,0,sizeof(*q));
  q->limit=limit>0?(size_t)limit:0;
  void *lib=moon_http_tls_library_handle();
  if(!lib || limit<4 || Moonbit_array_length(params)>65535)return q;
  (void)lib;
  int (*set_cbs)(SSL *,const QDispatch *,void *)=(int(*)(SSL*,const QDispatch*,void*))moon_http_tls_symbol("SSL_set_quic_tls_cbs");
  int (*set_params)(SSL *,const unsigned char *,size_t)=(int(*)(SSL*,const unsigned char*,size_t))moon_http_tls_symbol("SSL_set_quic_tls_transport_params");
  int (*set_early)(SSL *,int)=(int(*)(SSL*,int))moon_http_tls_symbol("SSL_set_quic_tls_early_data_enabled");
  int (*set_ciphers)(SSL *,const char *)=(int(*)(SSL*,const char*))moon_http_tls_symbol("SSL_set_ciphersuites");
  if(!set_cbs||!set_params||!set_early||!set_ciphers)return q;
  q->available=1; q->ssl=moon_http_tls_ssl_handle(owner); if(!q->ssl)return q;
  q->owner=owner;moonbit_incref(owner);
  size_t n=Moonbit_array_length(params);q->local_params=malloc(n?n:1);if(!q->local_params)return q;
  if(n)memcpy(q->local_params,params,n);
  if(set_ciphers(q->ssl,"TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384")!=1 ||
     set_cbs(q->ssl,callbacks,q)!=1 || set_early(q->ssl,0)!=1 ||
     set_params(q->ssl,q->local_params,n)!=1)return q;
  q->ready=1;
  return q;
}
MOONBIT_FFI_EXPORT int moon_http_quic_tls_ready(HttpQuicTls *q){return q->ready&&!q->failed;}
MOONBIT_FFI_EXPORT int moon_http_quic_tls_available(HttpQuicTls *q){return q->available;}
MOONBIT_FFI_EXPORT int moon_http_quic_tls_alert(HttpQuicTls *q){return q->alert;}
MOONBIT_FFI_EXPORT void moon_http_quic_tls_close(HttpQuicTls *q){qclose(q);}
MOONBIT_FFI_EXPORT int moon_http_quic_tls_feed(HttpQuicTls *q,int level,moonbit_bytes_t bytes) {
  size_t n=Moonbit_array_length(bytes);
  if(!q->ready||q->failed||(level!=0&&level!=2&&level!=3)||n>q->limit-q->input_bytes||n>q->limit-q->total_input[level])return 0;
  QNode *node=qnode(bytes,n,0,level,0);if(!node)return 0;
  if(q->input_tail[level])q->input_tail[level]->next=node;else q->input[level]=node;
  q->input_tail[level]=node;q->input_bytes+=n;q->total_input[level]+=n;return 1;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moon_http_quic_tls_event(HttpQuicTls *q) {
  QNode *node=q->events;if(!node)return moonbit_make_bytes(0,0);
  moonbit_bytes_t out=moonbit_make_bytes((int)node->length+3,0);
  out[0]=node->kind;out[1]=node->level;out[2]=node->direction;
  memcpy(out+3,node->data,node->length);q->events=node->next;if(!q->events)q->events_tail=NULL;
  q->event_bytes-=node->length;q->event_count--;qfree_node(node);return out;
}
MOONBIT_FFI_EXPORT int moon_http_quic_tls_has_params(HttpQuicTls *q){return q->peer_params!=NULL;}
MOONBIT_FFI_EXPORT moonbit_bytes_t moon_http_quic_tls_params(HttpQuicTls *q) {
  moonbit_bytes_t out=moonbit_make_bytes((int)q->peer_params_len,0);
  if(q->peer_params_len)memcpy(out,q->peer_params,q->peer_params_len);return out;
}
