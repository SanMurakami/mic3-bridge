#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include <set>
#include "MicTelemetry.hpp"
#include "USBControlLock.hpp"
static NSDictionary *jsonStatus(const dji::Telemetry& s){
    NSMutableArray *tx=[NSMutableArray array];for(auto& [index,t]:s.transmitters)[tx addObject:@{@"index":@(index),@"serial":@(t.serial.c_str()),@"noise_mode":@(t.noise.c_str()),@"battery_code":@(t.battery),@"charging":@(t.charging),@"recording":@(t.recording),@"total":@(t.total),@"remaining":@(t.remaining)}];
    return @{@"known":@(s.known),@"tc_enabled":@(s.tcEnabled),@"fps":@(s.fps),@"output":@(s.output),@"timecode":@(s.timecode.c_str()),@"battery_code":@(s.battery),@"transmitters":tx};
}
int main(int argc,const char *argv[]){@autoreleasepool{
    bool success=false;std::string message="指定したレシーバーの状態を取得できませんでした。";dji::Telemetry finalState;NSMutableArray *events=[NSMutableArray array];
    try {
        if(argc<3)throw std::runtime_error("操作と本体シリアルが必要です。");
        std::string op=argv[1],serial=argv[2];if(!dji::validSerial(serial))throw std::runtime_error("本体シリアルが不正です。");
        unsigned target=0,enabled=0,fps=0,output=0;std::string mode;
        auto number=[](const char *s,unsigned limit){std::string v=s;if(v.empty()||!std::all_of(v.begin(),v.end(),[](char c){return c>='0'&&c<='9';}))throw std::runtime_error("設定値が不正です。");auto n=std::stoul(v);if(n>limit)throw std::runtime_error("設定値が範囲外です。");return unsigned(n);};
        if(op=="--tc"&&argc==6){enabled=number(argv[3],1);fps=number(argv[4],7);output=number(argv[5],3);}
        else if(op=="--record"&&argc==4){enabled=number(argv[3],1);}
        else if(op=="--set"&&argc==5){target=number(argv[3],4);mode=argv[4];if(target<1||(mode!="none"&&mode!="basic"&&mode!="strong"))throw std::runtime_error("送信機またはノイキャン設定が不正です。");}
        else if(op!="--status"||argc!=3)throw std::runtime_error("許可された操作だけ使用できます。");
        dji::USBControlLock guard(4000);if(!guard)throw std::runtime_error("USB 制御が使用中です。もう一度操作してください。");
        io_iterator_t iterator=0;IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostInterface"),&iterator);io_service_t service;
        while((service=IOIteratorNext(iterator))){
            CFMutableDictionaryRef raw=nullptr;IORegistryEntryCreateCFProperties(service,&raw,kCFAllocatorDefault,0);NSDictionary *p=CFBridgingRelease(raw);
            bool wanted=[p[@"idVendor"] unsignedIntValue]==0x2ca3&&[p[@"idProduct"] unsignedIntValue]==0x4115&&[p[@"bInterfaceNumber"] unsignedIntValue]==4&&[p[@"bInterfaceClass"] unsignedIntValue]==255;
            if(!wanted){IOObjectRelease(service);continue;}
            NSError *error=nil;IOUSBHostInterface *iface=[[IOUSBHostInterface alloc] initWithIOService:service options:0 queue:nil error:&error interestHandler:nil];IOObjectRelease(service);if(!iface)continue;
            unsigned previous=iface.interfaceDescriptor?iface.interfaceDescriptor->bAlternateSetting:0;
            if(previous!=1&&![iface selectAlternateSetting:1 error:&error]){[iface destroy];continue;}
            IOUSBHostPipe *in=[iface copyPipeWithAddress:0x81 error:&error],*out=[iface copyPipeWithAddress:1 error:&error];
            dji::IdentityParser parser;dji::TelemetryParser telemetry;std::set<uint16_t> acknowledgements;
            parser.onFrame=[&](const uint8_t *f,size_t n){telemetry.frame(f,n);if(n==14&&f[4]==0x5a&&f[5]==2&&(f[8]&128)&&f[9]==0x5b&&f[10]==1){unsigned seq=f[6]|unsigned(f[7])<<8;[events addObject:@{@"sequence":@(seq),@"result":@(f[11])}];if(f[11]==0)acknowledgements.insert(seq);}};
            auto readFor=[&](double seconds){auto start=std::chrono::steady_clock::now();while(in&&std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()<seconds){NSMutableData *data=[NSMutableData dataWithLength:2048];NSUInteger count=0;NSError *e=nil;BOOL ok=[in sendIORequestWithData:data bytesTransferred:&count completionTimeout:.15 error:&e];if(count)parser.append((const uint8_t*)data.bytes,count);if(!ok&&e.code!=(NSInteger)kIOReturnTimeout)break;}};
            readFor(.65);if(parser.identity.serial.empty())readFor(1);
            if(parser.identity.serial==serial&&telemetry.state.known&&in&&out){
                auto initial=telemetry.state;uint16_t sequence=0x7800;
                auto send=[&](unsigned setting,unsigned value,auto matches){
                    
                    if(setting!=0x32&&setting!=0x34&&setting!=0x35&&setting!=0x36&&setting!=0x37&&setting!=0x38)return false;
                    for(int attempt=0;attempt<2;attempt++){uint16_t seq=sequence++;std::vector<uint8_t> f(22,0);f[0]=0x55;f[1]=22;f[2]=4;f[3]=dji::crc8(f.data(),3);f[4]=2;f[5]=0x5a;f[6]=seq&255;f[7]=seq>>8;f[8]=0x40;f[9]=0x5b;f[10]=1;f[11]=2;f[12]=target&255;f[16]=setting&255;f[17]=setting>>8;f[18]=1;f[19]=value;auto crc=dji::crc16(f.data(),20);f[20]=crc&255;f[21]=crc>>8;
                        NSMutableData *data=[NSMutableData dataWithBytes:f.data() length:f.size()];NSUInteger sent=0;NSError *e=nil;BOOL ok=[out sendIORequestWithData:data bytesTransferred:&sent completionTimeout:.5 error:&e];[events addObject:@{@"setting":@(setting),@"value":@(value),@"sequence":@(seq),@"sent":@(sent)}];readFor(.8);if(ok&&sent==22&&acknowledgements.count(seq)&&matches(telemetry.state))return true;
                    }return false;
                };
                if(op=="--status")success=true;
                else if(op=="--tc"){
                    if(initial.fps<0||initial.output<0)message="元の TC 設定を確認できないため変更しませんでした。";
                    else {success=send(0x32,fps,[&](auto& s){return s.fps==int(fps);})&&send(0x34,output,[&](auto& s){return s.output==int(output);})&&send(0x35,enabled,[&](auto& s){return s.tcEnabled==bool(enabled);});
                        if(!success){bool restored=send(0x32,initial.fps,[&](auto& s){return s.fps==initial.fps;});restored=send(0x34,initial.output,[&](auto& s){return s.output==initial.output;})&&restored;restored=send(0x35,initial.tcEnabled,[&](auto& s){return s.tcEnabled==initial.tcEnabled;})&&restored;message=restored?"TC の適用を確認できず、元の設定に戻しました。":"TC の適用と復元を確認できません。実機の設定を確認してください。";}}
                }else if(op=="--record"){
                    if(initial.transmitters.empty())message="接続中の送信機がありません。";
                    else {success=send(0x36,enabled,[&](auto& s){for(auto& [i,t]:initial.transmitters){auto it=s.transmitters.find(i);if(it==s.transmitters.end()||it->second.recording!=bool(enabled))return false;}return true;});if(!success)message="本体録音の状態を確認できません。各送信機の REC 表示を確認してください。";}
                }else {
                    auto tx=initial.transmitters.find(target);
                    if(tx==initial.transmitters.end()||tx->second.noise=="unknown")message="送信機の現在のノイキャン状態を確認できません。";
                    else {auto setNoise=[&](const std::string& desired){bool level=true;if(desired!="none")level=send(0x37,desired=="strong",[](auto&){return true;});return send(0x38,desired!="none",[&](auto& s){return s.transmitters.count(target)&&s.transmitters.at(target).noise==desired;})&&level;};success=setNoise(mode);if(!success){bool restored=setNoise(tx->second.noise);message=restored?"ノイキャンの適用を確認できず、元へ戻しました。":"ノイキャンの状態を確認できません。実機を確認してください。";}}
                }
                finalState=telemetry.state;
                if(success)message=op=="--tc"?"TC設定を更新":op=="--record"?(enabled?"本体録音を開始":"本体録音を停止"):op=="--set"?"ノイズキャンセリングを更新":"状態を取得";
                if(previous!=1)[iface selectAlternateSetting:previous error:nil];[iface destroy];break;
            }
            if(previous!=1)[iface selectAlternateSetting:previous error:nil];[iface destroy];
        }
        IOObjectRelease(iterator);
    }catch(const std::exception& e){message=e.what();}
    NSDictionary *result=@{@"success":@(success),@"message":@(message.c_str()),@"status":jsonStatus(finalState),@"events":events};NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];fwrite(data.bytes,1,data.length,stdout);putchar('\n');return success?0:2;
}}
