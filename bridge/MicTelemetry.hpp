#pragma once
#include "MicIdentity.hpp"
#include <map>
#include <chrono>
namespace dji {
struct TransmitterState {
    unsigned index=0;std::string serial,noise="unknown";
    int gain=-1000,agc=-1,agcMode=-1,agcEnabled=-1;
    int battery=-1,total=-1,remaining=-1;bool charging=false,recording=false;
};
struct Telemetry {
    double observedHostSeconds=0;
    bool known=false,tcEnabled=false,allRecording=false,charging=false;
    int fps=-1,output=-1,battery=-1,lossless=-1,gain=-1000;
    std::string timecode;
    std::map<unsigned,TransmitterState> transmitters;
};
class TelemetryParser {
    static unsigned le16(const uint8_t *v){return v[0]|unsigned(v[1])<<8;}
public:
    Telemetry state;
    void frame(const uint8_t *f,size_t n){
        if(n<16||f[4]!=0x5a||f[5]!=2||(f[8]&128)||f[9]!=0x5b||f[10]!=3||f[11]!=3)return;
        const uint8_t *p=f+11;size_t size=n-13;if(size!=le16(p+1)+3)return;
        // record全体を検証してから反映する。
        for(size_t at=3;at<size;){if(size-at<6||p[at+5]>size-at-6)return;at+=6+p[at+5];}
        for(size_t at=3;at<size;){unsigned type=p[at],len=p[at+5];uint32_t index=p[at+1]|uint32_t(p[at+2])<<8|uint32_t(p[at+3])<<16|uint32_t(p[at+4])<<24;auto v=p+at+6;
            if(type==1&&index>=1&&index<=4&&len>=12){std::string serial((const char*)v+4,len-4);while(!serial.empty()&&serial.back()==0)serial.pop_back();if(validSerial(serial)){auto& tx=state.transmitters[index];tx.index=index;tx.serial=serial;}}
            if(type==2&&index>=1&&index<=4&&len>=26){auto& tx=state.transmitters[index];tx.index=index;unsigned w=le16(v)|uint32_t(le16(v+2))<<16;
                tx.noise=!(w&256)?"none":((w>>5)&3)==0?"basic":((w>>5)&3)==1?"strong":"unknown";
                tx.gain=(int8_t)v[7];tx.agcMode=le16(v+4)>>14;tx.agcEnabled=(w>>18)&1;tx.agc=!tx.agcEnabled?0:(tx.agcMode==1||tx.agcMode==2)?tx.agcMode:-1;
                tx.battery=(w>>10)&7;tx.charging=(w>>9)&1;tx.recording=(w>>28)&1;tx.total=le16(v+8);tx.remaining=le16(v+10);
            }
            if(type==3&&index==0&&len>=32){state.known=true;unsigned w=le16(v);state.battery=(w>>13)&7;state.charging=(w>>12)&1;state.allRecording=(w>>6)&1;
                state.lossless=(w>>2)&1;state.gain=(int8_t)v[2];
                state.tcEnabled=(v[8]>>4)&1;state.fps=v[17]<=7?v[17]:-1;state.output=v[19]<=3?v[19]:-1;
                if(v[13]<24&&v[14]<60&&v[15]<60&&v[16]<60){char tc[20];snprintf(tc,sizeof(tc),"%02u:%02u:%02u:%02u",v[13],v[14],v[15],v[16]);state.timecode=tc;}
            }
            at+=6+len;
        }
    }
};
}
