#pragma once
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#include <functional>
namespace dji {
struct Identity {std::string serial,firmware;};
inline uint8_t crc8(const uint8_t *p,size_t n){uint8_t c=0x77;for(size_t i=0;i<n;i++){c^=p[i];for(int j=0;j<8;j++)c=c&1?(c>>1)^0x8c:c>>1;}return c;}
inline uint16_t crc16(const uint8_t *p,size_t n){uint16_t c=0x3692;for(size_t i=0;i<n;i++){c^=p[i];for(int j=0;j<8;j++)c=c&1?(c>>1)^0x8408:c>>1;}return c;}
inline bool validSerial(const std::string& serial) {
    return serial.size()>=8&&serial.size()<=32&&serial!="XSP12345678"&&
        std::all_of(serial.begin(),serial.end(),[](unsigned char c){return (c>='0'&&c<='9')||(c>='A'&&c<='Z');});
}
class IdentityParser {
    std::vector<uint8_t> buffer;
    void frame(const uint8_t *p,size_t n) {
        if(n<16||p[4]!=0x5a||p[5]!=0x02||(p[8]&0x80)||p[9]!=0x5b||p[10]!=3)return;
        const uint8_t *data=p+11;size_t size=n-13;
        if(data[0]!=3||size!=(size_t)(data[1]|(data[2]<<8))+3)return;
        Identity candidate;
        for(size_t at=3;at<size;) {
            if(size-at<6)return;
            unsigned type=data[at],length=data[at+5];
            uint32_t index=data[at+1]|((uint32_t)data[at+2]<<8)|((uint32_t)data[at+3]<<16)|((uint32_t)data[at+4]<<24);
            if(length>size-at-6)return;
            if(type==1&&index==0&&length>=12) {
                const uint8_t *value=data+at+6;
                std::string serial((const char*)value+4,length-4);while(!serial.empty()&&serial.back()==0)serial.pop_back();
                if(validSerial(serial)) {
                    candidate.serial=serial;char firmware[32];
                    snprintf(firmware,sizeof(firmware),"%02u.%02u.%02u.%02u",value[3],value[2],value[1],value[0]);candidate.firmware=firmware;
                }
            }
            at+=6+length;
        }
        if(!candidate.serial.empty())identity=candidate;
    }
public:
    Identity identity;
    std::function<void(const uint8_t*,size_t)> onFrame;
    unsigned validFrames=0,rejectedFrames=0;
    void append(const uint8_t *data,size_t size) {
        // USB の packet 境界と DUML の frame 境界は一致しない。
        for(size_t offset=0;offset<size;) {
            size_t chunk=std::min(size-offset,(size_t)2048);buffer.insert(buffer.end(),data+offset,data+offset+chunk);offset+=chunk;
            while(!buffer.empty()) {
                auto start=std::find(buffer.begin(),buffer.end(),0x55);buffer.erase(buffer.begin(),start);
                if(buffer.size()<4)break;
                size_t n=buffer[1]|((buffer[2]&3)<<8);
                if(n<13||(buffer[2]>>2)!=1||crc8(buffer.data(),3)!=buffer[3]){buffer.erase(buffer.begin());continue;}
                if(buffer.size()<n)break;
                uint16_t expected=buffer[n-2]|((uint16_t)buffer[n-1]<<8);
                if(crc16(buffer.data(),n-2)!=expected){rejectedFrames++;buffer.erase(buffer.begin());continue;}
                validFrames++;frame(buffer.data(),n);if(onFrame)onFrame(buffer.data(),n);buffer.erase(buffer.begin(),buffer.begin()+n);
            }
            if(buffer.size()>1023){buffer.clear();rejectedFrames++;}
        }
    }
};
}
