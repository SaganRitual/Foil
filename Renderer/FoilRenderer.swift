import Foundation
import MetalKit

class FoilRenderer: NSObject {
    // The point size (in pixels) of rendered bodies
    static let bodyPointSize: Float = 15;

    // Size of gaussian map to create rounded smooth points
    static let GaussianMapSize = 64

    let gaussianMap: MTLTexture

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!

    var colorsBuffer: MTLBuffer?

    // Metal objects
    var depthState: MTLDepthStencilState!
    var dynamicUniformBuffers = [MTLBuffer]()
    var positionsBuffer: MTLBuffer!
    var renderPipeline: MTLRenderPipelineState!

    // Current buffer to fill with dynamic uniform data and set for the current frame
    var currentBufferIndex = 0

    // Projection matrix calculated as a function of view size
    var projectionMatrix: matrix_float4x4!

    var renderScale: Float = 0

    let rendererDispatchQueue = DispatchQueue(
        label: "renderer.q", qos: .default, attributes: [/*serial*/],
        target: DispatchQueue.global(qos: .default)
    )

    /// Initialize with the MetalKit view with the Metal device used to render.  This MetalKit view
    /// object will also be used to set the pixelFormat and other properties of the drawable
    init(_ mtkView: MTKView) {
        self.device = mtkView.device!
        self.commandQueue = self.device.makeCommandQueue()!

        self.gaussianMap = FoilRenderer.generateGaussianMap(self.device)

        super.init()

        self.loadMetal(mtkView: mtkView)
    }

    /// Update the projection matrix with a new drawable size
    func drawableSizeWillChange(size: CGSize) { updateProjectionMatrix(with: size) }

    /// Draw particles at the supplied positions using the given command buffer to the given view
    func drawWithCommandBuffer(
        commandBuffer: MTLCommandBuffer,
        positionsBuffer: MTLBuffer,
        numBodies: Int,
        view: MTKView
    ) {
        commandBuffer.pushDebugGroup("Draw Simulation Data")

        setNumRenderBodies(numBodies)
        updateState()

        // Obtain a renderPassDescriptor generated from the view's drawable textures
        // If a renderPassDescriptor has been obtained, render to the drawable, otherwise skip
        // any rendering this frame because there is no drawable to draw to
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
            else { fatalError() }

        renderEncoder.label = "Render Commands";
        renderEncoder.setRenderPipelineState(renderPipeline)

        // In objective-c, this was "if(positionsBuffer)" -- not sure what to make of it
        precondition(positionsBuffer.length > 0)

        // Synchronize since positions buffer may be created on another thread
        rendererDispatchQueue.sync {
            renderEncoder.setVertexBuffer(
                positionsBuffer, offset: 0, index: FoilRenderBufferIndex.positions.rawValue
            )
        }

        renderEncoder.setVertexBuffer(
            colorsBuffer, offset: 0, index: FoilRenderBufferIndex.colors.rawValue
        )

        renderEncoder.setVertexBuffer(
            dynamicUniformBuffers[currentBufferIndex],
            offset: 0, index: FoilRenderBufferIndex.uniforms.rawValue
        )

        renderEncoder.setFragmentTexture(
            gaussianMap, index: FoilTextureIndex.colorMap.rawValue
        )

        renderEncoder.drawPrimitives(
            type: MTLPrimitiveType.point, vertexStart: 0,
            vertexCount: numBodies, instanceCount: 1
        )

        renderEncoder.endEncoding()
        commandBuffer.present(view.currentDrawable!)

        commandBuffer.popDebugGroup()
    }

    /// Generates a texture to make rounded points for particles
    static func generateGaussianMap(_ device: MTLDevice) -> MTLTexture {
        let textureDescriptor = MTLTextureDescriptor()

        textureDescriptor.textureType = .type2D
        textureDescriptor.pixelFormat = .r8Unorm
        textureDescriptor.width = FoilRenderer.GaussianMapSize
        textureDescriptor.height = FoilRenderer.GaussianMapSize
        textureDescriptor.mipmapLevelCount = 1
        textureDescriptor.cpuCacheMode = .defaultCache
        textureDescriptor.usage = .shaderRead

        let gaussianMap = device.makeTexture(descriptor: textureDescriptor)

        // Calculate the size of a RGBA8Unorm texture's data and allocate system memory buffer
        // used to fill the texture's memory
        let dataSize = textureDescriptor.width * textureDescriptor.height

        let nDelta: vector_float2 = [2.0 / Float(textureDescriptor.width), 2.0 / Float(textureDescriptor.height)]

        var texelData = [UInt8](repeating: 0, count: dataSize)

        var SNormCoordinate = vector_float2(repeating: -1)

        var i = 0

        // Procedurally generate data to fill the texture's buffer
        for y in 0..<textureDescriptor.height {
            SNormCoordinate.y = -1.0 + Float(y) * nDelta.y;

            for x in 0..<textureDescriptor.width {
                SNormCoordinate.x = -1.0 + Float(x) * nDelta.x;

                let distance = sqrt(SNormCoordinate.x * SNormCoordinate.x + SNormCoordinate.y * SNormCoordinate.y)
                let t = (distance  < 1.0) ? distance : 1.0;

                // Hermite interpolation where u = {1, 0} and v = {0, 0}
                let color = ((2.0 * t - 3.0) * t * t + 1.0);

                texelData[i] = UInt8(Float(0xFF) * color)

                i += 1
            }
        }

        let origin = MTLOrigin(x: 0, y: 0, z: 0)
        let size = MTLSize(width: textureDescriptor.width, height: textureDescriptor.height, depth: 1)
        let region = MTLRegion(origin: origin, size: size)

        gaussianMap!.replace(
            region: region, mipmapLevel: 0, withBytes: texelData,
            bytesPerRow: textureDescriptor.width * MemoryLayout<UInt8>.stride
        )

        gaussianMap!.label = "Gaussian Map"

        return gaussianMap!
    }

    func loadMetal(mtkView: MTKView) {
        // Load all the shader files with a .metal file extension in the project
        guard let defaultLibrary = device.makeDefaultLibrary() else { fatalError() }

        // Load the vertex function from the library
        let vertexFunction = defaultLibrary.makeFunction(name: "vertexShader")

        // Load the fragment function from the library
        let fragmentFunction = defaultLibrary.makeFunction(name: "fragmentShader")

        mtkView.depthStencilPixelFormat = MTLPixelFormat.depth32Float_stencil8
        mtkView.colorPixelFormat = MTLPixelFormat.bgra8Unorm;
        mtkView.sampleCount = 1;

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline";
        pipelineDescriptor.sampleCount = mtkView.sampleCount;
        pipelineDescriptor.vertexFunction = vertexFunction;
        pipelineDescriptor.fragmentFunction = fragmentFunction;
        pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat;
        pipelineDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat;
        pipelineDescriptor.stencilAttachmentPixelFormat = mtkView.depthStencilPixelFormat;
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true;
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperation.add;
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperation.add;
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactor.sourceAlpha;
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor  = MTLBlendFactor.sourceAlpha;
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactor.one;
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactor.one;

        guard let rp = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            else { fatalError("Failed to create render pipeline state") }

        self.renderPipeline = rp

        let depthStateDesc = MTLDepthStencilDescriptor()
        depthStateDesc.depthCompareFunction = MTLCompareFunction.less;
        depthStateDesc.isDepthWriteEnabled = true;
        depthState = device.makeDepthStencilState(descriptor: depthStateDesc)

        // Indicate shared storage so that both the  CPU can access the buffers
        let storageMode = MTLResourceOptions.storageModeShared
        let stride = MemoryLayout<FoilUniform>.stride
        guard let dub = device.makeBuffer(length: stride, options: storageMode)
            else { fatalError() }

        dub.label = "UniformBuffer"
        dynamicUniformBuffers.append(dub)

        // Initialize number of bodies to render
        setNumRenderBodies(64 * 1024)

        commandQueue = device.makeCommandQueue()
    }

    /// Update any render state (including updating dynamically changing Metal buffers)
    func updateState() {
        let uniforms = dynamicUniformBuffers[currentBufferIndex].contents()
        var u = uniforms.assumingMemoryBound(to: FoilUniform.self).pointee

        u.pointSize = FoilRenderer.bodyPointSize
        u.mvpMatrix = projectionMatrix
    }

    func providePositionData(data: NSData) {
        rendererDispatchQueue.sync {
            // Cast from 'const void *' to 'void *' which is okay in this case since updateData was
            // created with -[NSData initWithBytesNoCopy:length:deallocator:] and underlying memory was
            // allocated with vm_allocate
            let vmAllocatedAddress = UnsafeMutableRawPointer(mutating: data.bytes)

            // Create a MTLBuffer with out copying the data
            guard let positionsBuffer = device.makeBuffer(
                bytesNoCopy: vmAllocatedAddress, length: data.length,
                options: .storageModeManaged, deallocator: nil
            ) else { fatalError() }

            positionsBuffer.label = "Provided Positions";
            positionsBuffer.didModifyRange(0..<data.length)

            self.positionsBuffer = positionsBuffer;
        }
    }

    func setNumRenderBodies(_ numBodies: Int) {
        if colorsBuffer == nil || ((colorsBuffer!.length / MemoryLayout<vector_uchar4>.stride) < numBodies) {

            // If the number of colors stored is less than the number of bodies, recreate the color buffer

            let bufferSize = numBodies * MemoryLayout<vector_uchar4>.stride

            colorsBuffer = device.makeBuffer(length: bufferSize, options: .storageModeManaged)

            colorsBuffer!.label = "Colors";

            let colors = colorsBuffer!.contents().bindMemory(to: vector_uchar4.self, capacity: numBodies)

            for i in 0..<numBodies {
                let randomVector: vector_float3 = FoilMath.generateRandomVector(0, 1);

                colors[i].x = UInt8(Float(0xFF) * randomVector.x)
                colors[i].y = UInt8(Float(0xFF) * randomVector.y)
                colors[i].z = UInt8(Float(0xFF) * randomVector.z)
                colors[i].w = 0xFF
            }

            colorsBuffer!.didModifyRange(0..<bufferSize)
        }
    }

    func drawProvidedPositionDataWithNumBodies(
        numParticles: Int, inView: MTKView
    ) {
        // Create a new command buffer for each render pass to the current drawable
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { fatalError() }
        commandBuffer.label = "Render Command Buffer"

        drawWithCommandBuffer(
            commandBuffer: commandBuffer, positionsBuffer: positionsBuffer,
            numBodies: numParticles, view: inView
        )

        // Finalize rendering here & push the command buffer to the GPU
        commandBuffer.commit()
    }

    func setRenderScale(renderScale: Float, drawableSize: CGSize) {
        self.renderScale = renderScale;
        updateProjectionMatrix(with: drawableSize)
    }

    func updateProjectionMatrix(with size: CGSize) {
        // React to resize of the draw rect.  In particular update the perspective matrix.
        // Update the aspect ratio and projection matrix since the view orientation or size has changed
        let aspect: Float = Float(size.height) / Float(size.width)
        let left: Float   = renderScale;
        let right: Float  = -renderScale;
        let bottom: Float = renderScale * aspect;
        let top: Float    = -renderScale * aspect;
        let near: Float   = 5000;
        let far: Float    = -5000;

        projectionMatrix = FoilMath.matrixOrthoLeftHand(
            left: left, right: right, bottom: bottom, top: top, nearZ: near, farZ: far
        );
    }
}
