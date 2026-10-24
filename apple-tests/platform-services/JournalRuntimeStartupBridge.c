#include <stdint.h>
#include <pthread.h>
#include <string.h>
int32_t journal_ocaml_failure_reason(int32_t operation){return 2;}
static void (*request)(const char*,int32_t); static int mode,inside,calls,reentrant;
int32_t fixture_inside(void){return inside;}
int32_t fixture_calls(void){return calls;}
int32_t fixture_reentrant(void){return reentrant;}
void fixture_mode(int32_t m){mode=m;}
void fixture_emit(void){char bytes[32]={76,74,80,50,2,0,6,0};if(mode==5){request(bytes,32);memset(bytes,9,32);}else{char small[]={1,2};request(small,2);memset(small,9,2);}}
void* worker(void*x){fixture_emit();return 0;}
int32_t lui_ocaml_start(void (*patch)(const char*),int32_t p,int32_t h,const char*d,int32_t n){
 inside=1;
 if(mode==3){pthread_t t;pthread_create(&t,0,worker,0);pthread_join(t,0);}else{fixture_emit();if(mode==4)fixture_emit();}
 patch(mode==2?"invalid":"valid");inside=0;return mode==1?0:1;
}
int32_t lui_ocaml_stop(void){return 1;}
void journal_ocaml_set_wakeup_callback(void(*f)(void)){}
void journal_ocaml_set_platform_request_callback(void(*f)(const char*,int32_t)){request=f;}
int32_t journal_ocaml_pump(void){return 1;}
int32_t journal_ocaml_platform_event(const char*d,int32_t n){if(inside)reentrant++;return 1;}
int32_t journal_ocaml_platform_response(const char*d,int32_t n){calls++;if(inside)reentrant++;return 1;}
int32_t journal_ocaml_platform_failure(const char*d,int32_t n){calls++;if(inside)reentrant++;return 1;}
