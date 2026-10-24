#pragma once
#include <stdint.h>
#define DJI_CHANNELS 4
#define DJI_SAMPLE_RATE 48000.0
#define DJI_MAX_PACKET_FRAMES 2048
#define DJI_RING_FRAMES 32768
#define DJI_DELAY_FRAMES 4096
#define DJI_PACKET_SELECTOR ((uint32_t)0x646a6970) /* djip */
#define DJI_RESET_SELECTOR ((uint32_t)0x646a6972)  /* djir */
#define DJI_DEVICES_SELECTOR ((uint32_t)0x646a6963) /* djic: 登録済みの個体一覧 */
#define DJI_REMOVE_SELECTOR ((uint32_t)0x646a6978) /* djix: 明示的な登録解除 */
#define DJI_STATUS_SELECTOR ((uint32_t)0x646a6973) /* djis */
#define DJI_BUS_UID "local.dji-mic.input.matrix"
typedef struct {
    uint32_t version, frames, channels, reserved;
    uint64_t hostTime;
    double sourceRate, rateScalar;
    float samples[DJI_MAX_PACKET_FRAMES * DJI_CHANNELS];
} DJIPacket;
typedef struct {
    uint64_t packets, frames, lastHostTime, resets;
} DJIStatus;
