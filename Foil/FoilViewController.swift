//
//  ViewController.swift
//  Foil
//
//  Created by Rob Bishop on 5/1/20.
//  Copyright © 2020 Boring Software. All rights reserved.
//

import Cocoa
import MetalKit

class FoilViewController: NSViewController, MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        assert(false)
    }

    let IntelGPUInMetalDevicesArray = 0
    let RadeonGPUInMetalDevicesArray = 1

    static let frameTime: Double = 1.0 / 60.0
    static let second: Double = frameTime * 60.0
    static let metersPerSecond: Double = 600.0

    // Table with various simulation configurations.  Apps would typically load simulation parameters
    // such as these from a file or UI controls, but to simplify the sample and focus on Metal usage,
    // this table is hardcoded
    static let FoilSimulationConfigTable = [
        // damping softening numBodies clusterScale velocityScale renderScale renderBodies simInterval simDuration
        FoilSimulationConfig(damping: 1.0, softeningSqr: 1.000, numBodies: 4096, clusterScale: 0.32, velocityScale: metersPerSecond / 30, renderScale:    2.5, renderBodies: 4096, simInterval: frameTime / 30, simDuration: 10.0 * second / 30),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 1.000, numBodies: 4096, clusterScale: 6.04, velocityScale:                    0, renderScale:   75.0, renderBodies: 4096, simInterval: frameTime,      simDuration: 10.0 * second),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 0.145, numBodies: 4096, clusterScale: 0.32, velocityScale: metersPerSecond / 30, renderScale:    2.5, renderBodies: 4096, simInterval: frameTime / 30, simDuration: 10.0 * second / 30),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 1.000, numBodies: 4096, clusterScale: 1.54, velocityScale: metersPerSecond / 30, renderScale:   75.0, renderBodies: 4096, simInterval: frameTime,      simDuration: 10.0 * second),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 0.100, numBodies: 4096, clusterScale: 0.68, velocityScale: metersPerSecond / 30, renderScale: 1000.0, renderBodies: 4096, simInterval: frameTime,      simDuration: 10.0 * second),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 1.000, numBodies: 4096, clusterScale: 1.54, velocityScale: metersPerSecond / 30, renderScale:   75.0, renderBodies: 4096, simInterval: frameTime,      simDuration: 10.0 * second)
    ]

    static let FoilNumSimulationConfigs = FoilSimulationConfigTable.count

//    var _view: MTKView { guard let v = self.view as? MTKView else { fatalError() }; return v }
    var _view: MTKView { (self.view as? MTKView)! }
    var renderer: FoilRenderer!
    var simulation: FoilSimulation!

    // The current time (in simulation time units) that the simulation has processed
    var simulationTime: CFAbsoluteTime = 0

    // When rendering is paused (such as immediately after a simulation has completed), the time
    // to unpause and continue simulations.
    var continuationTime: CFAbsoluteTime = 0

    var computeDevice: MTLDevice!

    // Index of the current simulation config in the simulation config table
    var configNum = 0

    // Currently running simulation config
    var config: FoilSimulationConfig!

    // Command queue used when simulation and renderer are using the same device.
    // Set to nil when using different devices
    var commandQueue: MTLCommandQueue!

    // When true, stop running any more simulations (such as when the window closes).
    var terminateAllSimulations = false

    // When true, restart the current simulation if it was interrupted and data could not
    // be retrieved
    var restartSimulation = false

    // UI showing current simulation name and percentage complete
    @IBOutlet var _simulationName: NSTextField!
    @IBOutlet var _simulationPercentage: NSTextField!

    // Timer used to make the text fields blink when results have been completed
    var blinker: Timer!

    let viewControllerispatchQueue = DispatchQueue(
        label: "viewController.q", qos: .default, attributes: [/*serial*/],
        target: DispatchQueue.global(qos: .default)
    )

    let dataUpdateDispatchQueue = DispatchQueue(
        label: "dataUpdate.q", qos: .default, attributes: [/*serial*/],
        target: DispatchQueue.global(qos: .default)
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        selectDevices()

        _view.delegate = self
    }

    override func viewDidAppear() { beginSimulation() }

    override func viewDidDisappear() {
        viewControllerispatchQueue.sync {
            // Stop simulation if on another thread
            self.simulation.halt = true;

            // Indicate that simulation should not continue and results will not be needed
            self.terminateAllSimulations = true;
        }
    }

    func selectDevices() {
        let availableDevices = MTLCopyAllDevices()

        precondition(!availableDevices.isEmpty, "Metal is not supported on this Mac")

        computeDevice = availableDevices[IntelGPUInMetalDevicesArray]
        NSLog("Selected compute device: \(computeDevice.name)")

        // Select renderer device
        let rendererDevice = availableDevices[IntelGPUInMetalDevicesArray]

        if rendererDevice !== _view.device {
            _view.device = rendererDevice;

            NSLog("New render device: '\(rendererDevice.name)', drawableSize \(_view.drawableSize)")

            renderer = FoilRenderer(_view)
            renderer.drawableSizeWillChange(size: _view.drawableSize)
        }
    }

    func beginSimulation() {
        simulationTime = 0;

        _simulationName.stringValue = "Simulation \(configNum)"
        config = FoilViewController.FoilSimulationConfigTable[configNum]

        simulation = FoilSimulation(computeDevice: computeDevice, config: config)

        renderer.setRenderScale(renderScale: config.renderScale, drawableSize: _view.drawableSize)

        NSLog("Starting Simulation Config: \(configNum)");

        if computeDevice === renderer.device {
            // If the device used for rendering and compute are the same, create a command queue shared
            // by both components
            commandQueue = renderer.device.makeCommandQueue()
        } else {
            // If the device used for rendering is different than that used for compute, run the
            // the simulation asynchronously on the compute device
            runSimulationOnAlternateDevice()
        }
    }

    // Asynchronously begins or continues a simulation on a different than the device used for rendering
    func runSimulationOnAlternateDevice() {
        assert(computeDevice !== renderer.device)

        commandQueue = nil;

        let updateHandler: (NSData, CFAbsoluteTime) -> () = {
            // Update the renderer's position data so that it can show forward progress
            self.updateWithNewPositionData(updateData: $0, forSimulationTime: $1)
        }

        let dataProvider: (NSData, NSData, CFAbsoluteTime) -> () = {
            self.handleFullyProvidedSetOfPositionData(positionData: $0, velocityData: $1, forSimulationTime: $2)
        }

        simulation.runAsyncWithUpdateHandler(updateHandler: updateHandler, dataProvider: dataProvider)
    }

    /// Receive and update of new positions for the simulation time given.
    func updateWithNewPositionData(updateData: NSData, forSimulationTime simulationTime: CFAbsoluteTime) {
        // Lock with updateData so thus thread does not update data during an update on another thread
        dataUpdateDispatchQueue.sync {
            // Update the renderer's position data so that it can show forward progress
            self.renderer.providePositionData(data: updateData)
        }

        viewControllerispatchQueue.sync {
            // Lock around _simulation time since it will be accessed on another thread
            self.simulationTime = simulationTime;
        }
    }

    // Handle the passing of full data set from asynchronous simulation executed on device different
    // the the device used for rendering
    func handleFullyProvidedSetOfPositionData(
        positionData: NSData, velocityData: NSData,
        forSimulationTime simulationTime: CFAbsoluteTime
    ) {
        viewControllerispatchQueue.sync {
            if self.terminateAllSimulations {
                NSLog("Terminating all simulations")
                return
            }

            self.simulationTime = simulationTime;

            if simulationTime >= config.simDuration {
                NSLog("Simulation Config \(configNum) Complete")

                // If the simulation is complete, provide all the final positions to render
                renderer.providePositionData(data: positionData)
            } else {
                NSLog("Simulation Config \(configNum) Cannot complete with current simulation object")

                // If the simulation is not complete, this indicates that compute device cannot complete
                // the simulation, so data has been transferred from that device so the app can continue
                // the simulation on another device

                // Reselect a new device to continue the simulation
                selectDevices()

                // Create a new simulation object with the data provided
                self.simulation = FoilSimulation(
                    computeDevice: computeDevice, config: config,
                    positionData: positionData, velocityData: velocityData,
                    simulationTime: simulationTime
                )

                if computeDevice === renderer.device {
                    // If the device used for rendering and compute are the same, create a command queue shared
                    // by both components
                    commandQueue = renderer.device.makeCommandQueue()
                } else {
                    // If the device used for rendering is different than that used for compute, run the
                    // the simulation asynchronously on the compute device
                    runSimulationOnAlternateDevice()
                }
            }
        }
    }

    /// Called whenever view changes orientation or layout is changed
    func drawableSizeWillChange(size: CGSize) { renderer.drawableSizeWillChange(size: size) }

    static let FoilSecondsToPresentSimulationResults = CFTimeInterval(4.0)

    /// Called whenever the view needs to render
    func draw(in view: MTKView) {
        // Number of bodies to render this frame
        var numBodies = config.renderBodies;

        // Handle simulations completion
        if(simulationTime >= config.simDuration) {
            // If the simulation is over, render all the bodies in the simulation to show final results
            numBodies = config.numBodies;

            if(continuationTime == 0) {
                continuationTime = CACurrentMediaTime() + FoilViewController.FoilSecondsToPresentSimulationResults

                // Make text blink while showing final results (so it doesn't look like the app hung)
                _simulationName.stringValue = "Simulation \(configNum) Complete"

                let animationGroup: (NSAnimationContext) -> () = { context in
                    context.duration = 0.55
                    self._simulationName.animator().alphaValue = 0.0
                    self._simulationPercentage.animator().alphaValue = 0.0
                }

                let animationCompletion: () -> () = {
                    self._simulationName.alphaValue = 1.0;
                    self._simulationPercentage.alphaValue = 1.0;
                }

                let blinkyBlock: (Timer) -> () = { timer in
                    NSAnimationContext.runAnimationGroup(animationGroup, completionHandler: animationCompletion)
                }

                blinker = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true, block: blinkyBlock)

                blinker.fire()

            } else if(CACurrentMediaTime() >= continuationTime) {
                // If the continuation time has been reached, select a new simulation and begin execution
                configNum = (configNum + 1) % FoilViewController.FoilNumSimulationConfigs;

                continuationTime = 0;

                blinker.invalidate()
                blinker = nil

                selectDevices()
                beginSimulation()
            } else {
                // If showing final results, don't unnecessarily redraw
                return
            }
        }

        // If the simulation and device are using the same device _commandQueue will be set
        // Create a command buffer to both execute a simulation frame and render an update
        if let commandQueue = self.commandQueue,
           let commandBuffer = commandQueue.makeCommandBuffer() {
            commandBuffer.pushDebugGroup("Controller Frame")

            // Simulate the frame and obtain the new positions for the update.  If this is the final
            // frame positionBuffer will be filled with the all positions used for the simulation
            let positionBuffer = simulation.simulateFrame(commandBuffer: commandBuffer)

            // Render the updated positions (or all positions in the case that the simulation is complete)
            renderer.drawWithCommandBuffer(
                commandBuffer: commandBuffer, positionsBuffer: positionBuffer,
                numBodies: numBodies, view: _view
            )

            commandBuffer.commit()

            commandBuffer.popDebugGroup()

            simulationTime += Double(config.simInterval)
        } else {
            renderer.drawProvidedPositionDataWithNumBodies(numParticles: numBodies, inView: _view)
        }

        var percentComplete = 0

        // Lock when using _simulationTime since it can be updated on a separate thread
        viewControllerispatchQueue.sync {
            percentComplete = Int((simulationTime / config.simDuration) * 100)
        }

        _simulationPercentage.stringValue = percentComplete < 100 ?
            "\(percentComplete)" : "Final Result"
    }
}

