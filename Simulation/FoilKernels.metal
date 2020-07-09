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

static float3 computeAccelerations(const uint numThreadsInGroup,
                                   const float3 startingAcceleration,
                                   threadgroup float4* sharedPosition,
                                   const float4 currentPosition,
                                   const float softeningSqr)
{
    float3 acceleration = startingAcceleration;

    for(uint i = 0; i < numThreadsInGroup; i++)
    {
        acceleration += computeAcceleration(sharedPosition[i], currentPosition, softeningSqr);
    }

    return acceleration;
}

static float3 computeForBody(device float4* oldPosition,
                             const uint numThreadsInGroup,
                             const uint threadInGroup,
                             const uint threadInGrid,
                             const uint numBodies,
                             threadgroup float4* sharedPosition,
                             const float softeningSqr)
{
    float4 currentPosition = oldPosition[threadInGrid];
    float3 acceleration = 0.0f;
    uint sourcePosition = threadInGroup;

    // For each particle / body
    for(uint i = 0; i < numBodies; i += numThreadsInGroup)
    {
        // Because sharedPosition uses the threadgroup address space, 'numThreadsInGroup' elements
        // of sharedPosition will be initialized at once (not just one element at lid as it
        // may look like)
        sharedPosition[threadInGroup] = oldPosition[sourcePosition];

        acceleration = computeAccelerations(numThreadsInGroup, acceleration, sharedPosition, currentPosition, softeningSqr);
        sourcePosition += numThreadsInGroup;
    }

    return acceleration;
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
    float3 const acceleration = computeForBody(
        oldPosition, numThreadsInGroup, threadInGroup, threadInGrid,
        params.numBodies, sharedPosition, params.softeningSqr
    );

    float4 currentVelocity = oldVelocity[threadInGrid];
    currentVelocity.xyz += acceleration * params.timestep;
    currentVelocity.xyz *= params.damping;

    float4 currentPosition = oldPosition[threadInGrid];
    currentPosition.xyz += currentVelocity.xyz * params.timestep;

    newPosition[threadInGrid] = currentPosition;
    newVelocity[threadInGrid] = currentVelocity;
} // NBodyIntegrateSystem
