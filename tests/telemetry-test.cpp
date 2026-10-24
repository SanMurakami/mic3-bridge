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
 // signed gain / AGC OFF・AUTO・DYN・未知enum / RX losslessを独立に検証。
 for(int mode=0;mode<4;mode++)for(int enabled=0;enabled<2;enabled++){
  std::vector<uint8_t> data(26);data[2]=enabled?4:0;data[5]=uint8_t(mode<<6);data[7]=uint8_t(-12);
  std::vector<uint8_t> payload={3,32,0,2,2,0,0,0,26};payload.insert(payload.end(),data.begin(),data.end());auto packet=frame(payload);
  dji::TelemetryParser state;state.frame(packet.data(),packet.size());auto t=state.state.transmitters.at(2);
  assert(t.gain==-12&&t.agcEnabled==enabled&&t.agcMode==mode);
  assert(t.agc==(!enabled?0:(mode==1||mode==2)?mode:-1));
 }
 for(int lossless=0;lossless<2;lossless++){
  std::vector<uint8_t> data(32);data[0]=lossless?4:0;data[2]=uint8_t(-1);
  std::vector<uint8_t> payload={3,38,0,3,0,0,0,0,32};payload.insert(payload.end(),data.begin(),data.end());auto packet=frame(payload);
  dji::TelemetryParser state;state.frame(packet.data(),packet.size());assert(state.state.lossless==lossless&&state.state.gain==-1);
 }
 // 送信機IDは連番ではなくone-hot: CH3=4、CH4=8。接続maskで消し込み、断片の欠落をOFFLINEへ誤変換しない。
 for(unsigned ch=1;ch<=4;ch++){
  unsigned wire=1u<<(ch-1);assert(dji::txWireTarget(ch)==wire&&dji::txChannel(wire)==ch);
  std::vector<uint8_t> status(26);status[7]=3;
  std::vector<uint8_t> first={3,32,0,2,uint8_t(wire),0,0,0,26};first.insert(first.end(),status.begin(),status.end());auto packet=frame(first);
  dji::TelemetryParser parser;parser.frame(packet.data(),packet.size());assert(parser.state.transmitters.count(ch));
  std::vector<uint8_t> rxStatus(32);rxStatus[24]=wire;
  std::vector<uint8_t> payload={3,38,0,3,0,0,0,0,32};payload.insert(payload.end(),rxStatus.begin(),rxStatus.end());packet=frame(payload);parser.frame(packet.data(),packet.size());
  assert(parser.state.connectedMask==int(wire)&&parser.state.transmitters.size()==1&&parser.state.transmitters.at(ch).gain==3);
  payload[9+24]=0;packet=frame(payload);parser.frame(packet.data(),packet.size());assert(parser.state.transmitters.empty());
  payload[9+24]=wire;packet=frame(payload);parser.frame(packet.data(),packet.size());
  assert(parser.state.transmitters.size()==1&&parser.state.transmitters.at(ch).gain==-1000&&!dji::completeTelemetry(parser.state));
 }
 assert(dji::txChannel(3)==0&&dji::txChannel(0)==0&&dji::txChannel(16)==0);
 // wire4のTXはUSB CH3に対応し、RX接続maskが4となるpacketを検証。
 {
  auto txValue=bytes("b0248471007850003d023c02d0001a0a19031729070300030000");
  auto rxValue=bytes("c839000f00000000d0001a0a19031729070300030f0000000400000000000000");
  auto identity=bytes("010b00025445535430303030303030303037");
  std::vector<uint8_t> payload={3,0,0,2,4,0,0,0,uint8_t(txValue.size())};payload.insert(payload.end(),txValue.begin(),txValue.end());
  payload.insert(payload.end(),{1,4,0,0,0,uint8_t(identity.size())});payload.insert(payload.end(),identity.begin(),identity.end());
  payload.insert(payload.end(),{3,0,0,0,0,uint8_t(rxValue.size())});payload.insert(payload.end(),rxValue.begin(),rxValue.end());payload[1]=payload.size()-3;
  auto packet=frame(payload);dji::TelemetryParser parser;parser.frame(packet.data(),packet.size());
  assert(dji::completeTelemetry(parser.state)&&parser.state.connectedMask==4&&parser.state.transmitters.size()==1);
  auto t=parser.state.transmitters.at(3);assert(t.serial=="TEST0000000007"&&t.recording&&t.gain==0&&t.agc==1&&t.noise=="none");assert(!parser.state.transmitters.count(4));
 }
 // 途切れた record、破損した CRC を事実として反映しない。
 p.back()=0;p.pop_back();p[1]--;auto truncated=frame(p);dji::TelemetryParser t;t.frame(truncated.data(),truncated.size());assert(!t.state.known);
 f.back()^=1;dji::IdentityParser parser;parser.onFrame=[&](auto data,auto n){t.frame(data,n);};parser.append(f.data(),f.size());assert(!t.state.known);
 puts("telemetry: 実機V3、全分割、TC/電池/録音/容量、部分recordとCRC破損の拒否 OK");
}
