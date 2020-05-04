//
//  FoilShaderTypes.h
//  Foil
//
//  Created by Rob Bishop on 5/7/20.
//  Copyright © 2020 Boring Software. All rights reserved.
//

#ifndef FoilShaderTypes_h
#define FoilShaderTypes_h

#include <simd/simd.h>

typedef enum FoilRenderBufferIndex
{
    FoilRenderBufferIndexPositions = 0,
    FoilRenderBufferIndexColors   = 1,
    FoilRenderBufferIndexUniforms = 2,
} FoilRenderBufferIndex;

typedef enum FoilTextureIndex
{
    FoilTextureIndexColorMap = 0,
} FoilTextureIndex;

typedef struct
{
    matrix_float4x4 mvpMatrix;
    float pointSize;

} FoilUniforms;


#endif /* FoilShaderTypes_h */
