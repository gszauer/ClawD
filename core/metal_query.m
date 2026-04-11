#import <Metal/Metal.h>

unsigned long metal_max_threadgroup_memory(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return 0;
    return (unsigned long)[device maxThreadgroupMemoryLength];
}
