#include "include/FilmProfileEngine.h"
#include "look.h"
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
static pthread_once_t cfp_tables_once=PTHREAD_ONCE_INIT;
static void cfp_init_tables(void) { se_stock stock;se_look look;se_stock_init(&stock);se_look_from_stock(&stock,1,&look); }
void cfp_engine_prepare(void) { pthread_once(&cfp_tables_once,cfp_init_tables); }
int cfp_bake(const char *text,size_t bytes,uint8_t out[904]) {
 if(!text || !out || !bytes || bytes>8192 || sizeof(se_look)!=904)return -1;
 cfp_engine_prepare();
 se_stock s;se_stock_init(&s);if(se_stock_parse(text,bytes,&s))return -2;
 se_look look;se_look_from_stock(&s,1,&look);memcpy(out,&look,904);return 0;
}
typedef struct { uint8_t *next; int remaining; } cfp_output;
static int cfp_emit(void *context,const uint8_t *row,int width) {
 cfp_output *o=context;
 if(o->remaining<=0)return -1;
 memcpy(o->next,row,(size_t)width*3);o->next+=(size_t)width*3;o->remaining--;return 0;
}
int cfp_render_effects(const uint8_t body[904],const uint8_t *rgb,int width,int height,int shading,int sharpness,int clarity,int mixer,uint8_t *out) {
 if(!body||!rgb||!out||width<1||width>8192||height<1||height>8192||shading<-4||shading>4||sharpness<-4||sharpness>4||clarity<-4||clarity>4||(mixer!=0&&mixer!=1))return -1;
 if((shading||sharpness||clarity||mixer)&&(width>4096||height>4096))return -1;
 cfp_engine_prepare();
 se_look lk;memcpy(&lk,body,904);
 if(lk.hal_amount!=0||lk.grain_cell<1||lk.grain_cell>9||lk.grain<0||lk.grain>100)return -2;
 if(mixer){if(lk.sat)return -2;for(int i=0;i<3;i++)if(lk.hal_tint[i]<-200||lk.hal_tint[i]>200)return -2;}
 size_t bytes=se_look_bytes(&lk,width);
 if(sharpness||clarity)bytes+=(size_t)width*(clarity?52:12)+256;
 if(bytes>327680)return -3;
 void *mem=malloc(bytes);if(!mem)return -3;
 se_arena arena;se_arena_init(&arena,mem,bytes);se_look_run *run=NULL;
 cfp_output o={out,height};int rc=se_look_begin(&run,&lk,width,&arena);
 se_detail controls={shading,sharpness,clarity,mixer};
 if(!rc&&(shading||sharpness||clarity||mixer))rc=se_look_detail(run,&controls,height,&arena);
 if(!rc)rc=se_look_rows(run,rgb,height,cfp_emit,&o);
 if(!rc)rc=se_look_end(run,cfp_emit,&o);
 free(mem);return rc ? rc:(o.remaining ? -4:0);
}
int cfp_render(const uint8_t body[904],const uint8_t *rgb,int width,int height,uint8_t *out) {
 return cfp_render_effects(body,rgb,width,height,0,0,0,0,out);
}
int cfp_render_color(const uint8_t body[904],const uint8_t *rgb,int width,int height,int mixer,uint8_t *out) {
 if(!body||sizeof(se_look)!=904)return -1;
 se_look look;memcpy(&look,body,sizeof look);
 look.grain=0;
 return cfp_render_effects((const uint8_t *)&look,rgb,width,height,0,0,0,mixer,out);
}
