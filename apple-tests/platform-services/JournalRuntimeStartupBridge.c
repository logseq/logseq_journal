#include <stdint.h>
#include <pthread.h>
#include <string.h>
#include <assert.h>
static void (*request)(const char*,int32_t); static int mode,inside,calls,reentrant;
static void (*patches)(const char*), (*wake)(void);
static pthread_t owner;
static int owner_set, pump_count, event_count, pumped, stop_count;
static pthread_mutex_t pump_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pump_ready = PTHREAD_COND_INITIALIZER;
static void check_owner(void) {
 if(mode<6)return;
 assert(!pthread_main_np());
 if(!owner_set){owner=pthread_self();owner_set=1;}
 assert(pthread_equal(owner,pthread_self()));
}
int32_t journal_ocaml_failure_reason(int32_t operation){check_owner();return 2;}
void fixture_pump_while_ui_busy(void){
 pthread_mutex_lock(&pump_lock);
 int previous=pumped;
 wake();
 while(pumped==previous)pthread_cond_wait(&pump_ready,&pump_lock);
 pthread_mutex_unlock(&pump_lock);
}
int32_t fixture_inside(void){return inside;}
int32_t fixture_calls(void){return calls;}
int32_t fixture_reentrant(void){return reentrant;}
void fixture_mode(int32_t m){mode=m;}
void fixture_emit(void){char bytes[32]={76,74,80,50,2,0,6,0};if(mode==5){request(bytes,32);memset(bytes,9,32);}else{char small[]={1,2};request(small,2);memset(small,9,2);}}
void* worker(void*x){fixture_emit();return 0;}
int32_t lui_ocaml_start(void (*patch)(const char*),int32_t p,int32_t h,const char*d,int32_t n){
 check_owner();patches=patch;
 inside=1;
 if(mode==3){pthread_t t;pthread_create(&t,0,worker,0);pthread_join(t,0);}else{fixture_emit();if(mode==4)fixture_emit();}
 patch(mode==2?"invalid":mode==6?"1":"valid");inside=0;return mode==1?0:1;
}
int32_t lui_ocaml_stop(void){
 check_owner();
 if(mode==7 && ++stop_count<3){patches("retired");return 0;}
 return 1;
}
void journal_ocaml_set_wakeup_callback(void(*f)(void)){wake=f;}
void journal_ocaml_set_platform_request_callback(void(*f)(const char*,int32_t)){request=f;}
int32_t journal_ocaml_pump(void){
 check_owner();
 if(mode==6){
  if(++pump_count==1){
   patches("2");patches("3");
  }else{patches(pump_count==2?"6":"7");}
  pthread_mutex_lock(&pump_lock);pumped=pump_count;pthread_cond_signal(&pump_ready);pthread_mutex_unlock(&pump_lock);
 }
 return 1;
}
int32_t journal_ocaml_platform_event(const char*d,int32_t n){
 check_owner();if(inside)reentrant++;
 if(mode==6){patches(event_count++==0?"4":"5");if(event_count==1)wake();}
 return 1;
}
int32_t journal_ocaml_platform_response(const char*d,int32_t n){check_owner();calls++;if(inside)reentrant++;return 1;}
int32_t journal_ocaml_platform_failure(const char*d,int32_t n){check_owner();calls++;if(inside)reentrant++;return 1;}
