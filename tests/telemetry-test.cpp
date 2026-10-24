#include <cassert>
#include <cstdio>
#include "../bridge/MicTelemetry.hpp"
static std::vector<uint8_t> bytes(const char *hex){std::vector<uint8_t> r;for(;*hex;hex+=2){unsigned v;sscanf(hex,"%2x",&v);r.push_back(v);}return r;}
static std::vector<uint8_t> frame(std::vector<uint8_t> payload){unsigned n=payload.size()+13;std::vector<uint8_t> f={0x55,uint8_t(n),uint8_t(4|(n>>8)),0,0x5a,2,0,0,0,0x5b,3};f[3]=dji::crc8(f.data(),3);f.insert(f.end(),payload.begin(),payload.end());auto crc=dji::crc16(f.data(),f.size());f.push_back(crc&255);f.push_back(crc>>8);return f;}
int main(){
 auto rx=bytes("e039000f00000000d0001a0a19001b22080300010f0000000200000000000000");
 auto tx=bytes("90258c3000b850001e0116019000190101000000000300010000");
 std::vector<uint8_t> p={3,70,0,3,0,0,0,0,32};p.insert(p.end(),rx.begin(),rx.end());p.insert(p.end(),{2,2,0,0,0,26});p.insert(p.end(),tx.begin(),tx.end());auto f=frame(p);
 for(size_t split=0;split<=f.size();split++){dji::TelemetryParser state;dji::IdentityParser parser;parser.onFrame=[&](auto data,auto n){state.frame(data,n);};parser.append(f.data(),split);parser.append(f.data()+split,f.size()-split);
  assert(state.state.known&&state.state.tcEnabled&&state.state.fps==3&&state.state.output==1);
  assert(state.state.timecode=="00:27:34:08");assert(state.state.battery==1);
  auto t=state.state.transmitters.at(2);assert(t.recording&&t.noise=="basic"&&t.total==286&&t.remaining==278&&t.battery==1);
 }
 // 途切れた record、破損した CRC を事実として反映しない。
 p.back()=0;p.pop_back();p[1]--;auto truncated=frame(p);dji::TelemetryParser t;t.frame(truncated.data(),truncated.size());assert(!t.state.known);
 f.back()^=1;dji::IdentityParser parser;parser.onFrame=[&](auto data,auto n){t.frame(data,n);};parser.append(f.data(),f.size());assert(!t.state.known);
 puts("telemetry: 実機V3、全分割、TC/電池/録音/容量、部分recordとCRC破損の拒否 OK");
}
