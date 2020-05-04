/*

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

 */
enum FoilComputeBufferIndex: Int {
    case oldPosition, oldVelocity, newPosition, newVelocity, params
}

struct FoilSimParams {
    var timestep: Float
    var damping: Float
    var softeningSqr: Float

    var numBodies: Int
}
