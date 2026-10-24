#include "../bridge/Waveform.hpp"
#include <cassert>
#include <limits>
#include <iostream>
int main(){
    dji::Waveform wave;float samples[4*960]={};
    samples[4*123]=-0.7f;samples[4*124]=0.9f;samples[4*200+1]=std::numeric_limits<float>::quiet_NaN();
    wave.append(samples,960,1.0,48000);wave.flush();auto bins=wave.take();
    assert(bins.size()==1&&bins[0].low[0]==-0.7f&&bins[0].high[0]==0.9f);
    assert(bins[0].low[1]==0&&bins[0].high[1]==0);
    assert(std::abs(bins[0].duration-.02)<1e-8);assert(wave.take().empty());
    wave.append(samples,480,2,48000);wave.append(samples,480,2.01,48000);wave.flush();assert(wave.take().size()==1);
    wave.append(samples,480,3,48000);wave.append(samples,480,4,48000);wave.flush();bins=wave.take();
    assert(bins.size()==2&&bins[0].duration<.011&&bins[1].time==4); // 欠落区間を捏造しない
    for(int i=0;i<400;i++)wave.append(samples,480,5+i*.03,48000);
    wave.flush();assert(wave.take().size()==256); // IPC が遅れても有界
    std::cout<<"waveform: extrema, gaps, finite values, bounded backlog passed\n";
}
