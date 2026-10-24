#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include <set>
#include "MicTelemetry.hpp"
#include "USBControlLock.hpp"
// 例外・抜去・早期returnでも元のalternate settingと所有権を返す。
struct InterfaceScope {
    IOUSBHostInterface *iface; unsigned previous;
    ~InterfaceScope(){if(previous!=1)[iface selectAlternateSetting:previous error:nil];[iface destroy];}
};
struct IteratorScope { io_iterator_t value=0; ~IteratorScope(){if(value)IOObjectRelease(value);} };
static NSDictionary *jsonStatus(const dji::Telemetry& s){
    NSMutableArray *tx=[NSMutableArray array];for(auto& [index,t]:s.transmitters)[tx addObject:@{@"index":@(index),@"serial":@(t.serial.c_str()),@"noise_mode":@(t.noise.c_str()),@"gain_db":@(t.gain),@"agc":@(t.agc),@"agc_enabled":@(t.agcEnabled),@"agc_mode_raw":@(t.agcMode),@"battery_code":@(t.battery),@"charging":@(t.charging),@"recording":@(t.recording),@"total":@(t.total),@"remaining":@(t.remaining)}];
    return @{@"known":@(s.known),@"lossless":@(s.lossless),@"gain_db":@(s.gain),@"tc_enabled":@(s.tcEnabled),@"fps":@(s.fps),@"output":@(s.output),@"timecode":@(s.timecode.c_str()),@"battery_code":@(s.battery),@"transmitters":tx};
}
int main(int argc,const char *argv[]){@autoreleasepool{
    bool success=false;std::string message="指定したレシーバーの状態を取得できませんでした。";dji::Telemetry finalState;NSMutableArray *events=[NSMutableArray array];
    try {
        if(argc<3)throw std::runtime_error("操作と本体シリアルが必要です。");
        std::string op=argv[1],serial=argv[2];if(!dji::validSerial(serial))throw std::runtime_error("本体シリアルが不正です。");
        unsigned target=0,enabled=0,fps=0,output=0;int gain=0,lossless=-1,agc=-1;std::string mode,txSerial;
        auto number=[](const char *s,unsigned limit){std::string v=s;if(v.empty()||!std::all_of(v.begin(),v.end(),[](char c){return c>='0'&&c<='9';}))throw std::runtime_error("設定値が不正です。");auto n=std::stoul(v);if(n>limit)throw std::runtime_error("設定値が範囲外です。");return unsigned(n);};
        auto signedNumber=[](const char *s,int low,int high){std::string v=s;size_t offset=0;int n;try{n=std::stoi(v,&offset);}catch(...){throw std::runtime_error("設定値が不正です。");}if(offset!=v.size()||n<low||n>high)throw std::runtime_error("設定値が範囲外です。");return n;};
        if((op=="--gain"||op=="--agc")&&argc==6){target=number(argv[3],4);txSerial=argv[4];if(!target||!dji::validSerial(txSerial))throw std::runtime_error("送信機のシリアルが必要です。");if(op=="--gain")gain=signedNumber(argv[5],-12,12);else agc=number(argv[5],2);}
        else if(op=="--lossless"&&argc==4){lossless=number(argv[3],1);}
        else if(op=="--profile"&&argc==6){lossless=signedNumber(argv[3],-1,1);agc=signedNumber(argv[4],-1,2);mode=argv[5];if(mode!="keep"&&mode!="none"&&mode!="basic"&&mode!="strong")throw std::runtime_error("ノイキャン設定が不正です。");if(lossless<0&&agc<0&&mode=="keep")throw std::runtime_error("変更する設定がありません。");}
        else if(op=="--tc"&&argc==6){enabled=number(argv[3],1);fps=number(argv[4],7);output=number(argv[5],3);}
        else if(op=="--record"&&argc==4){enabled=number(argv[3],1);}
        else if(op=="--set"&&argc==5){target=number(argv[3],4);mode=argv[4];if(target<1||(mode!="none"&&mode!="basic"&&mode!="strong"))throw std::runtime_error("送信機またはノイキャン設定が不正です。");}
        else if(op!="--status"||argc!=3)throw std::runtime_error("許可された操作だけ使用できます。");
        dji::USBControlLock guard(4000);if(!guard)throw std::runtime_error("USB 制御が使用中です。もう一度操作してください。");
        IteratorScope iteratorScope;auto& iterator=iteratorScope.value;IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostInterface"),&iterator);io_service_t service;
        while((service=IOIteratorNext(iterator))){
            CFMutableDictionaryRef raw=nullptr;IORegistryEntryCreateCFProperties(service,&raw,kCFAllocatorDefault,0);NSDictionary *p=CFBridgingRelease(raw);
            bool wanted=[p[@"idVendor"] unsignedIntValue]==0x2ca3&&[p[@"idProduct"] unsignedIntValue]==0x4115&&[p[@"bInterfaceNumber"] unsignedIntValue]==4&&[p[@"bInterfaceClass"] unsignedIntValue]==255;
            if(!wanted){IOObjectRelease(service);continue;}
            NSError *error=nil;IOUSBHostInterface *iface=[[IOUSBHostInterface alloc] initWithIOService:service options:0 queue:nil error:&error interestHandler:nil];IOObjectRelease(service);if(!iface)continue;
            unsigned previous=iface.interfaceDescriptor?iface.interfaceDescriptor->bAlternateSetting:0;
            if(previous!=1&&![iface selectAlternateSetting:1 error:&error]){[iface destroy];continue;}
            InterfaceScope interfaceScope{iface,previous};
            IOUSBHostPipe *in=[iface copyPipeWithAddress:0x81 error:&error],*out=[iface copyPipeWithAddress:1 error:&error];
            dji::IdentityParser parser;dji::TelemetryParser telemetry;std::set<uint16_t> acknowledgements;
            parser.onFrame=[&](const uint8_t *f,size_t n){telemetry.frame(f,n);if(n==14&&f[4]==0x5a&&f[5]==2&&(f[8]&128)&&f[9]==0x5b&&f[10]==1){unsigned seq=f[6]|unsigned(f[7])<<8;[events addObject:@{@"sequence":@(seq),@"result":@(f[11])}];if(f[11]==0)acknowledgements.insert(seq);}};
            auto readFor=[&](double seconds){auto start=std::chrono::steady_clock::now();while(in&&std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()<seconds){NSMutableData *data=[NSMutableData dataWithLength:2048];NSUInteger count=0;NSError *e=nil;BOOL ok=[in sendIORequestWithData:data bytesTransferred:&count completionTimeout:.15 error:&e];if(count)parser.append((const uint8_t*)data.bytes,count);if(!ok&&e.code!=(NSInteger)kIOReturnTimeout)break;}};
            readFor(.65);if(parser.identity.serial.empty())readFor(1);
            if(parser.identity.serial==serial&&telemetry.state.known&&in&&out){
                auto initial=telemetry.state;uint16_t sequence=0x7800;
                auto send=[&](unsigned setting,unsigned value,auto matches){
                    
                    if(setting!=0x27&&setting!=0x24&&setting!=0x2c&&setting!=0x39&&setting!=0x32&&setting!=0x34&&setting!=0x35&&setting!=0x36&&setting!=0x37&&setting!=0x38)return false;
                    for(int attempt=0;attempt<2;attempt++){uint16_t seq=sequence++;std::vector<uint8_t> f(22,0);f[0]=0x55;f[1]=22;f[2]=4;f[3]=dji::crc8(f.data(),3);f[4]=2;f[5]=0x5a;f[6]=seq&255;f[7]=seq>>8;f[8]=0x40;f[9]=0x5b;f[10]=1;f[11]=2;f[12]=target&255;f[16]=setting&255;f[17]=setting>>8;f[18]=1;f[19]=value&255;auto crc=dji::crc16(f.data(),20);f[20]=crc&255;f[21]=crc>>8;
                        NSMutableData *data=[NSMutableData dataWithBytes:f.data() length:f.size()];NSUInteger sent=0;NSError *e=nil;BOOL ok=[out sendIORequestWithData:data bytesTransferred:&sent completionTimeout:.5 error:&e];[events addObject:@{@"setting":@(setting),@"value":@(value),@"sequence":@(seq),@"sent":@(sent)}];readFor(.8);if(ok&&sent==22&&acknowledgements.count(seq)&&matches(telemetry.state))return true;
                    }return false;
                };
                auto selectTX=[&](){auto t=initial.transmitters.find(target);if(t==initial.transmitters.end()||t->second.serial!=txSerial)throw std::runtime_error("送信機が入れ替わりました。状態を更新して操作してください。");return t->second;};
                auto applyAGC=[&](unsigned index,int active,int rawMode){target=index;bool ok=true;if(active)ok=send(0x2c,rawMode,[&](auto& s){return s.transmitters.count(index)&&s.transmitters.at(index).agcMode==rawMode;});return ok&&send(0x24,active,[&](auto& s){return s.transmitters.count(index)&&s.transmitters.at(index).agcEnabled==active;});};
                auto applyNoise=[&](unsigned index,const std::string& desired){target=index;bool level=true;if(desired!="none")level=send(0x37,desired=="strong",[](auto&){return true;});return level&&send(0x38,desired!="none",[&](auto& s){return s.transmitters.count(index)&&s.transmitters.at(index).noise==desired;});};
                if(op=="--status")success=true;
                else if(op=="--gain"){
                    auto tx=selectTX();if(tx.agc!=0)throw std::runtime_error("自動ゲインをOFFにしてから手動ゲインを変更してください。");
                    success=send(0x39,unsigned(gain),[&](auto& s){return s.transmitters.count(target)&&s.transmitters.at(target).gain==gain;});
                    if(!success){bool restored=send(0x39,unsigned(tx.gain),[&](auto& s){return s.transmitters.count(target)&&s.transmitters.at(target).gain==tx.gain;});message=restored?"ゲインを確認できず元へ戻しました。":"ゲインの復元を確認できません。実機を確認してください。";}
                }else if(op=="--agc"){
                    auto tx=selectTX();success=applyAGC(target,agc!=0,agc);
                    if(!success){bool restored=applyAGC(tx.index,tx.agcEnabled,tx.agcMode);message=restored?"自動ゲインを確認できず元へ戻しました。":"自動ゲインの復元を確認できません。実機を確認してください。";}
                }else if(op=="--lossless"){
                    target=0;success=send(0x27,lossless,[&](auto& s){return s.lossless==lossless;});
                    if(!success){bool restored=send(0x27,initial.lossless,[&](auto& s){return s.lossless==initial.lossless;});message=restored?"ロスレスを確認できず元へ戻しました。":"ロスレスの復元を確認できません。実機を確認してください。";}
                }else if(op=="--profile"){
                    success=true;bool touchedLossless=false;std::vector<unsigned> touched;
                    if(lossless>=0){target=0;touchedLossless=true;success=send(0x27,lossless,[&](auto& s){return s.lossless==lossless;});}
                    for(auto& [index,tx]:initial.transmitters){if(!success)break;if(agc<0&&mode=="keep")break;
                        if(tx.agcEnabled<0||tx.agcMode<0||(mode!="keep"&&tx.noise=="unknown")){success=false;break;}touched.push_back(index);
                        if(agc>=0)success=applyAGC(index,agc!=0,agc);
                        if(success&&mode!="keep")success=applyNoise(index,mode);
                    }
                    if(!success){bool restored=true;for(auto index:touched){auto& tx=initial.transmitters.at(index);if(agc>=0)restored=applyAGC(index,tx.agcEnabled,tx.agcMode)&&restored;if(mode!="keep")restored=applyNoise(index,tx.noise)&&restored;}
                        if(touchedLossless){target=0;restored=send(0x27,initial.lossless,[&](auto& s){return s.lossless==initial.lossless;})&&restored;}message=restored?"一括設定を確認できず、このRXを元へ戻しました。":"一部設定の復元を確認できません。実機を確認してください。";}
                }
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
                if(success)message=op=="--tc"?"TC設定を更新":op=="--record"?(enabled?"本体録音を開始":"本体録音を停止"):op=="--set"?"ノイズキャンセリングを更新":op=="--gain"?"ゲインを更新":op=="--agc"?"自動ゲインを更新":op=="--lossless"?"ロスレスを更新":op=="--profile"?(initial.transmitters.empty()?(lossless>=0?"ロスレスを確認・送信機設定は対象なし":"送信機なし・スキップ"):"音声設定を更新"):"状態を取得";
                break;
            }
        }
    }catch(const std::exception& e){message=e.what();}
    NSDictionary *result=@{@"success":@(success),@"message":@(message.c_str()),@"status":jsonStatus(finalState),@"events":events};NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];fwrite(data.bytes,1,data.length,stdout);putchar('\n');return success?0:2;
}}
