#pragma once
#include <cstdio>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <cstdint>
namespace dji {
struct USB {uint32_t location;std::string serial;};
struct Audio {uint32_t id;std::string uid;};
/* location を含む UID を先に確定し、同一 serial の残りが一対一の場合だけ対応づける。 */
inline std::map<uint32_t,Audio> resolve(const std::vector<USB>& usb,const std::vector<Audio>& audio) {
    std::map<uint32_t,Audio> result;std::set<uint32_t> used;
    for(const auto& a:audio) {
        auto end=a.uid.rfind(':');if(end==std::string::npos)continue;
        auto begin=a.uid.rfind(':',end-1);if(begin==std::string::npos)continue;
        auto token=a.uid.substr(begin+1,end-begin-1);
        for(const auto& u:usb) {
            char hex[16];snprintf(hex,sizeof(hex),"%x",u.location);
            if(token==hex&&!result.count(u.location)&&!used.count(a.id)){result[u.location]=a;used.insert(a.id);}
        }
    }
    for(const auto& a:audio) {
        if(used.count(a.id))continue;
        std::vector<USB> candidates;
        auto end=a.uid.rfind(':'),begin=end==std::string::npos?end:a.uid.rfind(':',end-1);
        if(begin==std::string::npos)continue;
        auto token=a.uid.substr(begin+1,end-begin-1);
        for(const auto& u:usb)if(!result.count(u.location)&&u.serial==token)candidates.push_back(u);
        if(candidates.size()==1){result[candidates[0].location]=a;used.insert(a.id);}
    }
    return result;
}
}
