#pragma once
#include "Protocol.h"
#include <stdatomic.h>
#include <math.h>
#include <stddef.h>
#include <string.h>
/* 読み手ごとの消費位置を持たず、絶対 host time で参照する。複数クライアントも同じ音を読む。 */
typedef struct { _Atomic uint64_t tag; _Atomic uint32_t samples[DJI_CHANNELS]; } DJIFrame;
typedef struct { DJIFrame frames[DJI_RING_FRAMES]; } DJITimeline;
static inline void DJIReset(DJITimeline *ring) {
    for (unsigned i=0;i<DJI_RING_FRAMES;i++) atomic_store_explicit(&ring->frames[i].tag,0,memory_order_seq_cst);
}
static inline int DJIValidPacket(const DJIPacket *p, uint32_t bytes) {
    if (bytes < offsetof(DJIPacket,samples) || p->version!=1 || p->channels!=DJI_CHANNELS ||
        !p->frames || p->frames>DJI_MAX_PACKET_FRAMES || !p->hostTime ||
        !isfinite(p->sourceRate) || p->sourceRate<8000 || p->sourceRate>192000 ||
        !isfinite(p->rateScalar) || p->rateScalar<0.95 || p->rateScalar>1.05) return 0;
    return bytes == offsetof(DJIPacket,samples)+p->frames*DJI_CHANNELS*sizeof(float);
}
static inline void DJIWrite(DJITimeline *ring,const DJIPacket *p,double hostFrequency) {
    const double first=(double)p->hostTime*DJI_SAMPLE_RATE/hostFrequency;
    const double scale=p->sourceRate*p->rateScalar/DJI_SAMPLE_RATE;
    const uint64_t begin=(uint64_t)ceil(first), end=(uint64_t)ceil(first+p->frames/scale);
    for (uint64_t frame=begin;frame<end;frame++) {
        double pos=((double)frame-first)*scale;
        uint32_t lo=(uint32_t)pos;
        if(lo>=p->frames) lo=p->frames-1;
        uint32_t hi=lo+1<p->frames?lo+1:lo;
        double alpha=fmin(1.0,fmax(0.0,pos-lo));
        DJIFrame *cell=&ring->frames[frame%DJI_RING_FRAMES];
        atomic_store_explicit(&cell->tag,0,memory_order_seq_cst);
        for(unsigned ch=0;ch<DJI_CHANNELS;ch++) {
            float a=p->samples[lo*DJI_CHANNELS+ch],b=p->samples[hi*DJI_CHANNELS+ch];
            float value=isfinite(a)&&isfinite(b)?(float)(a+(b-a)*alpha):0;
            uint32_t bits;memcpy(&bits,&value,sizeof(bits));
            atomic_store_explicit(&cell->samples[ch],bits,memory_order_seq_cst);
        }
        atomic_store_explicit(&cell->tag,frame+1,memory_order_seq_cst);
    }
}
static inline void DJIRead(DJITimeline *ring,uint64_t begin,uint32_t count,float *out) {
    for(uint32_t i=0;i<count;i++) {
        uint64_t frame=begin+i,tag=frame+1;
        DJIFrame *cell=&ring->frames[frame%DJI_RING_FRAMES];
        float *dst=out+i*DJI_CHANNELS;
        memset(dst,0,DJI_CHANNELS*sizeof(float));
        if(atomic_load_explicit(&cell->tag,memory_order_seq_cst)!=tag) continue;
        for(unsigned ch=0;ch<DJI_CHANNELS;ch++) {
            uint32_t bits=atomic_load_explicit(&cell->samples[ch],memory_order_seq_cst);
            memcpy(dst+ch,&bits,sizeof(bits));
        }
        if(atomic_load_explicit(&cell->tag,memory_order_seq_cst)!=tag) memset(dst,0,DJI_CHANNELS*sizeof(float));
    }
}
