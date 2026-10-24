#pragma once
#include <cstddef>
#include <string>
namespace dji {
// 同じRXの直近操作だけを置換する。AGCなど別操作や実行中の処理は順序の境界。
template<class Jobs,class Matches>
size_t pendingReplacement(const Jobs& jobs,const std::string& serial,Matches matches){
    for(size_t i=jobs.size();i>0;--i){auto& job=jobs[i-1];if(job.serial!=serial)continue;
        return !job.started&&matches(job)?i-1:jobs.size();
    }
    return jobs.size();
}
}
