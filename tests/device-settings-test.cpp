#include <cassert>
#include <vector>
#include <cstdio>
#include "../bridge/DeviceSettings.hpp"
int main(){
    // 各bitの独立性・長さ境界・RX/TXの同名キーを実際のrecordレイアウトで確認。
    for(bool tx:{false,true})for(auto& spec:dji::deviceSettings)if(spec.tx==tx){
        std::vector<uint8_t> data(32);
        data[spec.byte]=uint8_t(1u<<spec.shift);
        auto decoded=dji::decodeSettings(data.data(),data.size(),tx);
        assert(decoded.at(spec.key)==1);
        data[spec.byte]=uint8_t(~(1u<<spec.shift));
        assert(dji::decodeSettings(data.data(),data.size(),tx).at(spec.key)==0);
        assert(!dji::decodeSettings(data.data(),spec.byte,tx).count(spec.key));
        assert(dji::deviceSetting(spec.key,tx)==&spec);
    }
    assert(!dji::deviceSetting("format",true));assert(!dji::deviceSetting("camera_power",true));
    assert(!dji::deviceSetting("float_recording",false));assert(!dji::deviceSetting("file_type_raw",true));
    uint8_t data[32]={};data[7]=uint8_t(-12);data[3]=15;data[1]=8;
    auto rx=dji::decodeSettings(data,32,false);assert(rx.at("monitor_gain_raw")==-12&&rx.at("monitor_channels_raw")==15&&rx.at("channel_mode_raw")==4);
    puts("device settings OK");
}
