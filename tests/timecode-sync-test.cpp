#include "../bridge/TimecodeSync.hpp"
#include <cassert>
#include <cstdlib>
#include <cstdio>
int main(){
 setenv("TZ","Asia/Tokyo",1);tzset();
 auto clock=dji::tcWallClock(1792901349,3);assert((clock==std::array<uint8_t,8>{0,26,10,25,13,9,9,0}));
 auto packet=dji::tcPacket(31211,0x33,{clock.begin(),clock.end()});
 // 実機で受理された29byteのcaptureと比較。長さ/TLV/date/CRCの取り違えを防ぐ。
 const uint8_t capture[]={0x55,0x1d,0x04,0xdf,0x02,0x5a,0xeb,0x79,0x40,0x5b,0x01,0x02,0,0,0,0,0x33,0,8,0,26,10,25,13,9,9,0,0xa1,0x42};
 assert(packet==std::vector<uint8_t>(std::begin(capture),std::end(capture)));
 auto reset=dji::tcPacket(1,0x2f,{1});assert(reset.size()==22&&reset[10]==1&&reset[12]==0&&reset[16]==0x2f&&reset[18]==1);
 assert(dji::tcFrames("00:01:00:00",4)==-1&&dji::tcFrames("00:01:00:01",4)==-1);
 assert(dji::tcFrames("00:01:00:02",4)==1800&&dji::tcFrames("00:10:00:00",4)==17982);
 assert(dji::tcFrames("23:59:59:29",4)==2589407&&dji::tcDelta(0,2589407,4)==1);
 assert(dji::tcFrames("23:59:59:29",3)==2591999&&dji::tcDelta(0,2591999,3)==1);
 assert(dji::tcFrames("00:00:00:24",0)==-1&&dji::tcFrames("24:00:00:00",3)==-1&&dji::tcFrames("00:00:00:00x",3)==-1);
 for(int fps=0;fps<8;fps++)assert(dji::tcRate(fps)>0&&dji::tcFrames(dji::tcText(clock),fps)>=0);
 // DFの存在しないラベルをMacの分頭から生成しない。
 tm date{};date.tm_year=126;date.tm_mon=9;date.tm_mday=25;date.tm_hour=13;date.tm_min=1;auto boundary=timegm(&date);
 assert(dji::tcWallClock(boundary,4)[7]==2&&dji::tcWallClock(boundary,3)[7]==0);
 date.tm_min=10;assert(dji::tcWallClock(timegm(&date),4)[7]==0);
 bool rejected=false;try{dji::tcPacket(1,0x25,{1});}catch(...){rejected=true;}assert(rejected);
 rejected=false;try{dji::tcPacket(1,0x33,{1});}catch(...){rejected=true;}assert(rejected);
 puts("TC同期: 実capture、RX限定packet、FPS、DF欠番、日跨ぎ、未知コマンド拒否 OK");
}
