#include <cassert>
#include <cstdio>
#include "../bridge/MicIdentity.hpp"
static std::vector<uint8_t> bytes(const char *hex){std::vector<uint8_t> r;for(;*hex;hex+=2){unsigned b;sscanf(hex,"%2x",&b);r.push_back(b);}return r;}
int main(){
 auto frame=bytes("553404ac5a02aa73005b03032400010000000012010b000254455354303030303030303030320400000000063336363064669055");
 for(size_t split=0;split<=frame.size();split++){
  dji::IdentityParser p;p.append(frame.data(),split);p.append(frame.data()+split,frame.size()-split);
  assert(p.identity.serial=="TEST0000000002"&&p.identity.firmware=="02.00.11.01");
 }
 for(size_t i=0;i<frame.size();i++){auto broken=frame;broken[i]^=1;dji::IdentityParser p;p.append(broken.data(),broken.size());assert(p.identity.serial.empty());}
 auto tx=frame;tx[15]=1;auto crc=dji::crc16(tx.data(),tx.size()-2);tx[tx.size()-2]=crc&255;tx.back()=crc>>8;
 dji::IdentityParser p;p.append(tx.data(),tx.size());assert(p.identity.serial.empty());
 assert(!dji::validSerial("XSP12345678")&&!dji::validSerial("../../invalid")&&!dji::validSerial("tiny"));
 puts("identity: 実機 frame、全分割境界、CRC 破損、TX の誤採用拒否 OK");
}
