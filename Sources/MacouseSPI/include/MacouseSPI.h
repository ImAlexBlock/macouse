// IOKit HID SPI declarations used by Macouse.
//
// Original declarations: PointerKit / IOKitSPIMac.h from LinearMouse
// (https://github.com/linearmouse/linearmouse), MIT License.
// Copyright (c) 2022 Linearmouse contributors. Adapted: block-based callbacks
// replaced with function pointer + context; symbols that the public SDK already
// declares (IOHIDServiceClient*, IOHIDEventSystemClientCopyServices) are taken
// from the SDK headers instead of being redeclared.

#ifndef MACOUSE_SPI_H
#define MACOUSE_SPI_H

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

#ifdef __cplusplus
extern "C" {
#endif

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);

void IOHIDEventSystemClientSetMatchingMultiple(IOHIDEventSystemClientRef client,
                                               CFArrayRef multiple);

// 第 4 个参数声明为 `void *`，不是 `IOHIDServiceClientRef`。
// 刷新通知传入的该值不是可 retain 的对象（实测崩溃报告里是 0x103）；
// 若声明成 CF/ObjC 类型，Swift 生成的 trampoline 会对其执行 objc_retain，
// 直接 SIGSEGV。回调本身不使用该参数，声明为裸指针即可。
void IOHIDEventSystemClientRegisterDeviceMatchingCallback(
    IOHIDEventSystemClientRef client,
    void (*callback)(void *context, IOReturn result, void *sender,
                     void *service),
    void *context);

void IOHIDEventSystemClientUnregisterDeviceMatchingCallback(
    IOHIDEventSystemClientRef client);

void IOHIDEventSystemClientScheduleWithDispatchQueue(IOHIDEventSystemClientRef client,
                                                     dispatch_queue_t queue);

void IOHIDEventSystemClientUnscheduleFromDispatchQueue(IOHIDEventSystemClientRef client,
                                                       dispatch_queue_t queue);

#ifdef __cplusplus
}
#endif

#endif /* MACOUSE_SPI_H */
