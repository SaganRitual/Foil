import Foundation
import MetalKit

let FoilNumUpdateBuffersStored = 1

// Parameters to perform the N-Body simulation
struct FoilSimulationConfig {

    init(
        damping: Double, softeningSqr: Double, numBodies: Int, clusterScale: Double,
        velocityScale: Double, renderScale: Double, renderBodies: Int, simInterval: Double,
        simDuration: CFAbsoluteTime
    ) {
        self.damping = Float(damping)
        self.softeningSqr = Float(softeningSqr)
        self.numBodies = numBodies
        self.clusterScale = Float(clusterScale)
        self.velocityScale = Float(velocityScale)
        self.renderScale = Float(renderScale)
        self.renderBodies = renderBodies
        self.simInterval = Float(simInterval)
        self.simDuration = simDuration
    }

    let damping: Float;             // Factor for reducing simulation instability
    let softeningSqr: Float;        // Factor for simulating collisions
    let numBodies: Int              // Number of bodies in the simulations
    let clusterScale: Float;        // Factor for grouping the initial set of bodies
    let velocityScale: Float;       // Scaling of  each body's speed
    let renderScale: Float;         // The scale of the viewport to render the results
    let renderBodies: Int;          // Number of bodies to transfer and render for an intermediate update
    let simInterval: Float;         // The "time" (in "simulation time" units) of each frame of the simulation
    let simDuration: CFAbsoluteTime // The "duration" (in "simulation time" units) for the simulation
}

class FoilSimulation {
    let device: MTLDevice
    var commandQueue: MTLCommandQueue!
    var computePipeline: MTLComputePipelineState!

    // Metal buffer backed with memory wrapped in an NSData object for updating client (renderer)
    var updateBuffer: MTLBuffer!

    // Wrapper for system memory used to transfer to client (renderer)
    var updateData: NSData!

    // Two buffers to hold positions and velocity.  One will hold data for the previous/initial
    // frame while the other will hold data for the current frame, which is generated using data
    // from the previous frame.
    var positions = [MTLBuffer]()
    var velocities = [MTLBuffer]()

    var dispatchExecutionSize = MTLSize()
    var threadsPerThreadgroup = MTLSize()
    var threadgroupMemoryLength = 0

    // Indices into the positions and velocities array to track which buffer holds data for
    // the previous frame and which holds the data for the new frame.
    var oldBufferIndex = 0
    var newBufferIndex = 0

    var simulationParams: MTLBuffer!

    // Current time of the simulation
    var simulationTime: CFAbsoluteTime!

    let config: FoilSimulationConfig

    let simulationDispatchQueue = DispatchQueue(
        label: "simulator.q", qos: .default, attributes: [/*serial*/],
        target: DispatchQueue.global(qos: .default)
    )

    // When set to true, stop an asynchronously executed simulation
    var halt = false

    // Block executed by simulation when run asynchronously whenever simulation has made forward
    // progress.  Provides an array of vector_float4 elements representing a summary of positions
    // calculated by the simulation at the given simulation time
    typealias FoilDataUpdateHandler = (NSData, CFAbsoluteTime) -> Void

    // Block executed by asynchronous simulation simulation is complete or has been halted (such as
    // when the simulation device has been ejected).  Provides all data at the given simulation time so
    // that it can be rendered (if the simulation time is greater than the configuration's duration)
    // or continued on another device (if the simulation time is less than the configuration's duration)
    typealias FoilFullDatasetProvider = (NSData, NSData, CFAbsoluteTime) -> Void

    // Initializer used to start a simulation already from the beginning
    init(computeDevice: MTLDevice, config: FoilSimulationConfig) {
        self.device = computeDevice
        self.config = config
        self.simulationTime = 0
        self.createMetalObjectsAndMemory()
        self.initializeData()
    }

    // Initializer used to continue a simulation already begun on another device
    init(
        computeDevice: MTLDevice, config: FoilSimulationConfig,
        positionData: NSData, velocityData: NSData, simulationTime: CFAbsoluteTime
    ) {
        self.device = computeDevice
        self.config = config
        self.simulationTime = simulationTime

        self.createMetalObjectsAndMemory()

        self.setPositionData(
            positionData: positionData, velocityData: velocityData, forSimulationTime: simulationTime
        )
    }

    // Execute simulation on another thread, providing updates and final results with supplied blocks
    func runAsyncWithUpdateHandler(
        updateHandler: @escaping FoilDataUpdateHandler
    ) {
        simulationDispatchQueue.async {
            self.commandQueue = self.device.makeCommandQueue()

            self.runAsyncLoopWithUpdateHandler(updateHandler: updateHandler)
        }
    }

    // Execute a single frame of the simulation (on the current thread)
    func simulateFrame(commandBuffer: MTLCommandBuffer) -> MTLBuffer {
        commandBuffer.pushDebugGroup("Simulation")

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder()
            else { fatalError() }

        computeEncoder.label = "Compute Encoder"

        computeEncoder.setComputePipelineState(computePipeline)

        computeEncoder.setBuffer(positions[newBufferIndex],  offset: 0, index: Int(FoilComputeBufferIndexNewPosition.rawValue))
        computeEncoder.setBuffer(velocities[newBufferIndex], offset: 0, index: Int(FoilComputeBufferIndexNewVelocity.rawValue))
        computeEncoder.setBuffer(positions[oldBufferIndex],  offset: 0, index: Int(FoilComputeBufferIndexOldPosition.rawValue))
        computeEncoder.setBuffer(velocities[oldBufferIndex], offset: 0, index: Int(FoilComputeBufferIndexOldVelocity.rawValue))
        computeEncoder.setBuffer(simulationParams,           offset: 0, index: Int(FoilComputeBufferIndexParams.rawValue))

        computeEncoder.setThreadgroupMemoryLength(threadgroupMemoryLength, index: 0)
        computeEncoder.dispatchThreads(dispatchExecutionSize, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        // Swap indices to use data generated this frame at newBufferIndex to generate data for the
        // next frame and write it to the buffer at oldBufferIndex
        let tmpIndex = oldBufferIndex
        oldBufferIndex = newBufferIndex
        newBufferIndex = tmpIndex

        commandBuffer.popDebugGroup()

        self.simulationTime += Double(config.simInterval)

        return positions[newBufferIndex]
    }

    /// Initialize Metal objects and set simulation parameters
    func createMetalObjectsAndMemory() {
        // Create compute pipeline for simulation
        // Load all the shader files with a .metal file extension in the project
        guard let defaultLibrary = device.makeDefaultLibrary(),
              let nbodySimulation = defaultLibrary.makeFunction(name: "NBodySimulation"),
              let cp = try? device.makeComputePipelineState(function: nbodySimulation) else {
            fatalError("Failed to create compute pipeline state")
        }

        computePipeline = cp

        // Calculate parameters to efficiently execute the simulation kernel
        threadsPerThreadgroup = MTLSizeMake(computePipeline.threadExecutionWidth, 1, 1)
        dispatchExecutionSize =  MTLSizeMake(config.numBodies, 1, 1)
        threadgroupMemoryLength = computePipeline.threadExecutionWidth * MemoryLayout<vector_float4>.stride

        // Create buffers to hold our simulation data and generate initial data set
        let bufferSize = MemoryLayout<vector_float3>.stride * config.numBodies

        // Create 2 buffers for both positions and velocities since we'll need to preserve previous
        // frames data while computing the next frame
        for i in 0..<2 {
            guard let p = device.makeBuffer(length: bufferSize, options: .storageModeManaged),
                  let v = device.makeBuffer(length: bufferSize, options: .storageModeManaged)
                else { fatalError() }

            p.label = "Positions[\(i)]";  positions.append(p)
            v.label = "Velocities[\(i)]"; velocities.append(v)
        }

        // Setup buffer of simulation parameters to pass to compute kernel
        let length = MemoryLayout<FoilSimParams>.stride
        guard let sp = device.makeBuffer(length: length, options: .storageModeManaged)
            else { fatalError() }

        sp.label = "Simulation Params"
        simulationParams = sp

        let c_ = UnsafeMutableRawPointer(mutating: sp.contents())

        var c = c_.assumingMemoryBound(to: FoilSimParams.self).pointee
        c.timestep = config.simInterval
        c.damping = config.damping
        c.softeningSqr = config.softeningSqr
        c.numBodies = UInt32(config.numBodies)

        simulationParams.didModifyRange(0..<sp.length)

        // Create buffers to transfer data to our client (i.e. the renderer)
        let updateDataSize = Int(config.renderBodies * MemoryLayout<vector_float3>.stride)

        (updateBuffer, updateData) = makeBufferForRenderBodiesVectors(
            bufferSizeInBytes: updateDataSize, label: "Update Buffer"
        )
    }

    private func makeBufferForRenderBodiesVectors(
        bufferSizeInBytes: Int, label: String
    ) -> (MTLBuffer, NSData) {
        let mem_ = UnsafeMutableRawPointer.allocate(byteCount: bufferSizeInBytes, alignment: 1 << 12)
        let mem = mem_.bindMemory(to: vm_address_t.self, capacity: bufferSizeInBytes)

        guard vm_allocate(
            mach_task_self_, mem, vm_size_t(bufferSizeInBytes), VM_FLAGS_ANYWHERE
        ) == KERN_SUCCESS else { fatalError() }

        guard let buffer = device.makeBuffer(
            bytesNoCopy: mem, length: bufferSizeInBytes,
            options: .storageModeShared, deallocator: nil
        ) else { fatalError() }

        buffer.label = label

        // Wrap the memory allocated with vm_allocate with an NSData object which will allow
        // us to rely on ObjC ARC (or even MMR) to manage the memory's lifetime

        // Create a data object to wrap system memory and pass a deallocator to free the
        // memory allocated with vm_allocate when the data object has been released
        let data = NSData(
            bytesNoCopy: buffer.contents(), length: bufferSizeInBytes
        ) {
            let bytes = $0.assumingMemoryBound(to: vm_address_t.self)
            let length = $1
            vm_deallocate(mach_task_self_, bytes.pointee, vm_address_t(length))
        }

        return (buffer, data)
    }

    /// Set the initial positions and velocities of the simulation based upon the simulation's config
    func initializeData() {
        let pscale = config.clusterScale
        let vscale = config.velocityScale * pscale
        let inner  = 2.5 * pscale
        let outer  = 4.0 * pscale
        let length = outer - inner

        oldBufferIndex = 0
        newBufferIndex = 1

        let positions = self.positions[oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities = self.velocities[oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)

        for i in 0..<config.numBodies {
            let nrpos    = FoilMath.generateRandomNormalizedVector(-1.0, 1.0, 1.0)
            let rpos     = FoilMath.generateRandomVector(0.0, 1.0)
            let position = nrpos * (inner + (length * rpos))

            var p = positions[i]
            p.x = position.x; p.y = position.x; p.z = position.z
            p.w = 1

            var axis = vector_float3(0.0, 0.0, 1.0)
            let scalar = simd_dot(nrpos, axis)

            if((1 - scalar) < 1e-6) {
                axis.x = nrpos.y
                axis.y = nrpos.x

                axis = simd_normalize(axis)
            }

            let velocity = simd_cross(position, axis)

            var v = velocities[i]
            v.x = velocity.x * vscale
            v.y = velocity.y * vscale
            v.z = velocity.z * vscale
        }

        let fullPRange = 0..<self.positions[oldBufferIndex].length
        self.positions[oldBufferIndex].didModifyRange(fullPRange)

        let fullVRange = 0..<self.velocities[oldBufferIndex].length
        self.velocities[oldBufferIndex].didModifyRange(fullVRange)
    }

    /// Set simulation data for a simulation that was begun elsewhere (i.e. on another device)
    func setPositionData(
        positionData: NSData, velocityData: NSData, forSimulationTime: CFAbsoluteTime
    ) {
        oldBufferIndex = 0
        newBufferIndex = 1

        let positions = self.positions[oldBufferIndex].contents()
        let velocities = self.velocities[oldBufferIndex].contents()

        assert(self.positions[oldBufferIndex].length == positionData.length)
        assert(self.velocities[oldBufferIndex].length == velocityData.length)

        memcpy(positions, positionData.bytes, positionData.length)
        memcpy(velocities, velocityData.bytes, velocityData.length)

        let fullPRange = 0..<self.positions[oldBufferIndex].length
        self.positions[oldBufferIndex].didModifyRange(fullPRange)

        let fullVRange = 0..<self.velocities[oldBufferIndex].length
        self.velocities[oldBufferIndex].didModifyRange(fullVRange)

        self.simulationTime = forSimulationTime
    }

    /// Blit a subset of the positions data for this frame and provide them to the client
    /// to show a summary of the simulation's progress
    func fillUpdateBufferWithPositionBuffer(
        buffer: MTLBuffer, usingCommandBuffer commandBuffer: MTLCommandBuffer
    ) {
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { fatalError() }

        blitEncoder.label = "Position Update Blit Encoder"
        blitEncoder.pushDebugGroup("Position Update Blit Commands")

        blitEncoder.copy(
            from: buffer, sourceOffset: 0,
            to: updateBuffer, destinationOffset: 0,
            size: updateBuffer.length
        )

        blitEncoder.popDebugGroup()
        blitEncoder.endEncoding()
    }

    private func blitRenderBodiesVectors(
        _ encoder: MTLBlitCommandEncoder,
        _ vectorSet: [MTLBuffer],
        _ buffer: MTLBuffer,
        _ debugString: String
    ) {
        encoder.pushDebugGroup(debugString)

        encoder.copy(
            from: vectorSet[oldBufferIndex], sourceOffset: 0,
            to: buffer, destinationOffset: 0,
            size: buffer.length
        )

        encoder.popDebugGroup()
    }

    /// Blit all positions and velocities and provide them to the client either to show final results
    /// or continue the simulation on another device
    func provideFullData(
        dataProvider: FoilFullDatasetProvider, forSimulationTime time: CFAbsoluteTime
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { fatalError() }
        commandBuffer.label = "Full Transfer Command Buffer"

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { fatalError() }
        blitEncoder.label = "Full Transfer Blits"

        let (positionsBuffer, positionsData) = makeBufferForRenderBodiesVectors(
            bufferSizeInBytes: positions[oldBufferIndex].length,
            label: "Final positions buffer"
        )

        let (velocitiesBuffer, velocitiesData) = makeBufferForRenderBodiesVectors(
            bufferSizeInBytes: velocities[oldBufferIndex].length,
            label: "Final veocities buffer"
        )

        blitRenderBodiesVectors(blitEncoder, positions, positionsBuffer, "Full Position Data Blit")
        blitRenderBodiesVectors(blitEncoder, velocities, velocitiesBuffer, "Full Velocity Data Blit")

        blitEncoder.endEncoding()

        commandBuffer.commit()

        dataProvider(positionsData, velocitiesData, time)
    }

    /// Run the asynchronous simulation loop
    func runAsyncLoopWithUpdateHandler(updateHandler: @escaping FoilDataUpdateHandler) {
        var loopCounter = 0

        repeat {
            defer { loopCounter += 1 }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else
                { fatalError() }

            let positionBuffer = simulateFrame(commandBuffer: commandBuffer)

            fillUpdateBufferWithPositionBuffer(
                buffer: positionBuffer, usingCommandBuffer: commandBuffer
            )

            // Pass data back to client to update it with a summary of progress
            guard let updateSimulationTime = simulationTime else { fatalError() }

            addCommandCompletionHandler(commandBuffer, loopCounter) {
                updateHandler(self.updateData, updateSimulationTime)
            }

            commandBuffer.commit()

        } while(simulationTime < config.simDuration && !halt)
    }

    func addCommandCompletionHandler(
        _ commandBuffer: MTLCommandBuffer, _ loopCounter: Int, _ updateHandler: @escaping () -> Void
    ) {
        commandBuffer.addCompletedHandler { _ in updateHandler() }
    }
}
