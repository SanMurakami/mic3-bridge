#pragma once
#include <array>
#include <vector>
#include <cmath>
#include <cstdint>
namespace dji {
// 音声 callback 外で使用。20ms の実サンプル extrema、最大約5秒の未送信分。
struct WaveBin {
    double time=0,duration=0;
    std::array<float,4> low{},high{};
};
class Waveform {
    WaveBin current{};
    int64_t bucket=-1;
    std::vector<WaveBin> ready;
public:
    void flush(){if(bucket>=0&&current.duration>0){if(ready.size()>=256)ready.erase(ready.begin());ready.push_back(current);}bucket=-1;current={};}
    void append(const float *samples,unsigned frames,double start,double rate){
        for(unsigned f=0;f<frames;f++){
            double time=start+f/rate;auto next=(int64_t)std::floor(time*50);
            if(next!=bucket){flush();bucket=next;current.time=time;}
            current.duration=time-current.time+1/rate;
            for(unsigned c=0;c<4;c++){float value=samples[f*4+c];if(!std::isfinite(value))continue;
                current.low[c]=std::min(current.low[c],value);current.high[c]=std::max(current.high[c],value);}
        }
    }
    std::vector<WaveBin> take(){std::vector<WaveBin> result;result.swap(ready);return result;}
};
}
