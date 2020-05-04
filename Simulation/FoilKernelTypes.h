/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Header containing types and enum constants shared between Metal kernels and C/ObjC source
*/
#ifndef FoilKernelTypes_h
#define FoilKernelTypes_h

#include <simd/simd.h>

typedef enum FoilComputeBufferIndex
{
    FoilComputeBufferIndexOldPosition = 0,
    FoilComputeBufferIndexOldVelocity = 1,
    FoilComputeBufferIndexNewPosition = 2,
    FoilComputeBufferIndexNewVelocity = 3,
    FoilComputeBufferIndexParams      = 4
} FoilComputeBufferIndex;

typedef struct FoilSimParams
{
    float  timestep;
    float  damping;
    float  softeningSqr;

    unsigned int numBodies;
} FoilSimParams;

#endif // FoilKernelTypes_h
