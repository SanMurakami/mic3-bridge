#include <cstdio>
#include <cassert>
#include "../bridge/Resolver.hpp"
int main(){
    using namespace dji;
    const std::string prefix="AppleUSBAudioEngine:DJI Technology Co., Ltd.:Wireless Mic Rx:";
    std::vector<USB> usb={{0x1100000,"XSP12345678"},{0x2100000,"XSP12345678"}};
    auto first=resolve(usb,{{301,prefix+"1100000:1"},{292,prefix+"XSP12345678:1"}});
    assert(first.size()==2&&first.at(0x1100000).id==301&&first.at(0x2100000).id==292);
    // 接続順が反転し、serial UID の所有者が入れ替わったケース。
    auto reversed=resolve(usb,{{400,prefix+"XSP12345678:1"},{401,prefix+"2100000:1"}});
    assert(reversed.at(0x1100000).id==400&&reversed.at(0x2100000).id==401);
    auto disconnected=resolve({usb[1]},{{500,prefix+"XSP12345678:1"}});
    assert(disconnected.size()==1&&disconnected.at(0x2100000).id==500);
    auto ambiguous=resolve(usb,{{600,prefix+"XSP12345678:1"}});assert(ambiguous.empty());
    auto none=resolve(usb,{});assert(none.empty());
    // どちらも位置で区別される OS の場合も列挙順に依存しない。
    auto both=resolve(usb,{{701,prefix+"2100000:1"},{700,prefix+"1100000:1"}});
    assert(both.at(0x1100000).id==700&&both.at(0x2100000).id==701);
    puts("resolver: 接続順反転・片側切断・再接続 ID 変更・曖昧さの拒否 OK");
}
