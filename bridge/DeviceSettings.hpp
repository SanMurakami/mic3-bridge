#pragma once
#include <map>
#include <string>
#include <cstdint>
#include <cstddef>
namespace dji {
struct DeviceSetting { const char *key; unsigned tlv; bool tx; unsigned byte, shift, mask; bool recordingSensitive; };
inline const DeviceSetting deviceSettings[]={
    {"mute",0x09,true,0,2,1,false},
    {"float_recording",0x0c,true,3,3,1,true},
    {"auto_record",0x2e,true,2,7,1,false},
    {"low_power_record",0x2b,true,5,4,1,false},
    {"loop_record",0x2a,true,5,3,1,true},
    {"noise_button",0x0f,true,0,7,1,false},
    {"record_button",0x0b,true,5,5,1,false},
    {"vibration",0x04,true,3,0,1,false},
    {"auto_off",0x10,true,0,4,1,false},
    {"auto_off",0x10,false,1,0,1,false},
    {"camera_power",0x20,false,0,7,1,false}
};
inline const DeviceSetting *deviceSetting(const std::string& key,bool tx){for(auto& s:deviceSettings)if(s.tx==tx&&key==s.key)return &s;return nullptr;}
inline std::map<std::string,int> decodeSettings(const uint8_t *v,size_t len,bool tx){
    std::map<std::string,int> result;
    for(auto& s:deviceSettings)if(s.tx==tx&&s.byte<len)result[s.key]=(v[s.byte]>>s.shift)&s.mask;
    if(tx&&len>=26){result["led_raw"]=v[0]&3;result["file_type_raw"]=(v[25]>>6)&3;result["signal_raw"]=v[6]>>4;result["storage_mounted"]=(v[2]>>1)&1;}
    if(!tx&&len>=8){result["monitor_gain_raw"]=(int8_t)v[7];result["monitor_channels_raw"]=v[3]|uint32_t(v[4])<<8|uint32_t(v[5])<<16|uint32_t(v[6])<<24;result["channel_mode_raw"]=(v[1]>>1)&7;result["environment_raw"]=v[0]&3;}
    return result;
}
}
