import simd

/*
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

*/
enum FoilRenderBufferIndex: Int { case positions = 0, colors = 1, uniforms = 2 }

enum FoilTextureIndex: Int { case colorMap = 0 }

struct FoilUniform {
    var mvpMatrix: matrix_float4x4
    var pointSize: Float
}
