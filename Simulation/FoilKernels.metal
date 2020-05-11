#include <metal_stdlib>
using namespace metal;

#include <simd/simd.h>
#include "FoilKernelTypes.h"

static float3 computeAcceleration(const float4 vsPosition,
                                  const float4 oldPosition,
                                  const float  softeningSqr)
{
    float3 r = vsPosition.xyz - oldPosition.xyz;

    float distSqr = distance_squared(vsPosition.xyz, oldPosition.xyz);

    distSqr += softeningSqr;

    float invDist  = rsqrt(distSqr);
    float invDist3 = invDist * invDist * invDist;

    float s = vsPosition.w * invDist3;

    return r * s;
}

kernel void NBodySimulation(device float4*           newPosition       [[ buffer(FoilComputeBufferIndexNewPosition) ]],
                            device float4*           newVelocity       [[ buffer(FoilComputeBufferIndexNewVelocity) ]],
                            device float4*           oldPosition       [[ buffer(FoilComputeBufferIndexOldPosition) ]],
                            device float4*           oldVelocity       [[ buffer(FoilComputeBufferIndexOldVelocity) ]],
                            constant FoilSimParams & params            [[ buffer(FoilComputeBufferIndexParams)      ]],
                            threadgroup float4     * sharedPosition    [[ threadgroup(0)                            ]],
                            const uint               threadInGrid      [[ thread_position_in_grid                   ]],
                            const uint               threadInGroup     [[ thread_position_in_threadgroup            ]],
                            const uint               numThreadsInGroup [[ threads_per_threadgroup                   ]])
{

    float4 currentPosition = oldPosition[threadInGrid];
    float3 acceleration = 0.0f;
    uint i, j;

    const float softeningSqr = params.softeningSqr;

    uint sourcePosition = threadInGroup;

    // For each particle / body
    for(i = 0; i < params.numBodies; i += numThreadsInGroup)
    {
        // Because sharedPosition uses the threadgroup address space, 'numThreadsInGroup' elements
        // of sharedPosition will be initialized at once (not just one element at lid as it
        // may look like)
        sharedPosition[threadInGroup] = oldPosition[sourcePosition];

        j = 0;

        while(j < numThreadsInGroup)
        {
            acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
            acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
            acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
            acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
            acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
            acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
            acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
            acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
        } // while

        sourcePosition += numThreadsInGroup;
    } // for

    float4 currentVelocity = oldVelocity[threadInGrid];

    currentVelocity.xyz += acceleration * params.timestep;
    currentVelocity.xyz *= params.damping;
    currentPosition.xyz += currentVelocity.xyz * params.timestep;

    newPosition[threadInGrid] = currentPosition;
    newVelocity[threadInGrid] = currentVelocity;
} // NBodyIntegrateSystem
