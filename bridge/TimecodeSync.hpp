#pragma once
#include "MicIdentity.hpp"
#include <array>
#include <cmath>
#include <ctime>
#include <stdexcept>
namespace dji {
inline double tcRate(int fps){static const double rates[]={24000./1001,24,25,30000./1001,30000./1001,30,50,60};if(fps<0||fps>7)throw std::runtime_error("TC FPSが不正です。");return rates[fps];}
inline int tcFrames(const std::string& value,int fps){
    int h,m,s,f;char tail;if(sscanf(value.c_str(),"%d:%d:%d:%d%c",&h,&m,&s,&f,&tail)!=4)return -1;
    int n=int(std::round(tcRate(fps)));if(h<0||h>23||m<0||m>59||s<0||s>59||f<0||f>=n||(fps==4&&m%10&&s==0&&f<2))return -1;
    int minutes=h*60+m;return ((h*3600+m*60+s)*n+f)-(fps==4?2*(minutes-minutes/10):0);
}
inline double tcDelta(double a,double b,int fps){double day=fps==4?2589408:std::round(tcRate(fps))*86400;return std::remainder(a-b,day);}
inline std::array<uint8_t,8> tcWallClock(time_t second,int fps,uint8_t zone=0){
    (void)tcRate(fps);tm local{};localtime_r(&second,&local);
    if(local.tm_year<100||local.tm_year>199)throw std::runtime_error("TCの日付は2000〜2099年に対応しています。");
    // DFの毎10分以外の分頭では00/01を使わない。
    return {zone,uint8_t(local.tm_year-100),uint8_t(local.tm_mon+1),uint8_t(local.tm_mday),uint8_t(local.tm_hour),uint8_t(local.tm_min),uint8_t(local.tm_sec),uint8_t(fps==4&&local.tm_min%10&&local.tm_sec==0?2:0)};
}
inline std::string tcText(const std::array<uint8_t,8>& clock){char value[16];snprintf(value,sizeof(value),"%02u:%02u:%02u:%02u",clock[4],clock[5],clock[6],clock[7]);return value;}
inline std::vector<uint8_t> tcPacket(uint16_t sequence,unsigned setting,const std::vector<uint8_t>& value){
    if(!((setting==0x33&&value.size()==8)||((setting==0x32||setting==0x35||setting==0x2f)&&value.size()==1)))throw std::runtime_error("TC同期コマンドが不正です。");
    std::vector<uint8_t> f(21+value.size(),0);f[0]=0x55;f[1]=uint8_t(f.size());f[2]=4;f[3]=crc8(f.data(),3);f[4]=2;f[5]=0x5a;f[6]=sequence&255;f[7]=sequence>>8;f[8]=0x40;f[9]=0x5b;f[10]=1;f[11]=2;f[16]=setting&255;f[17]=setting>>8;f[18]=uint8_t(value.size());std::copy(value.begin(),value.end(),f.begin()+19);auto c=crc16(f.data(),f.size()-2);f[f.size()-2]=c&255;f.back()=c>>8;return f;
}
}
