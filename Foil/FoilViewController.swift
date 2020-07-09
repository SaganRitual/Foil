//
//  ViewController.swift
//  Foil
//
//  Created by Rob Bishop on 5/1/20.
//  Copyright © 2020 Boring Software. All rights reserved.
//

import Cocoa
import MetalKit

class FoilViewController: NSViewController {
    let IntelGPUInMetalDevicesArray = 0
    let RadeonGPUInMetalDevicesArray = 1

    static let frameTime: Double = 1.0 / 60.0
    static let second: Double = frameTime * 60.0
    static let metersPerSecond: Double = 600.0

    // Table with various simulation configurations.  Apps would typically load simulation parameters
    // such as these from a file or UI controls, but to simplify the sample and focus on Metal usage,
    // this table is hardcoded
    static let FoilSimulationConfigTable = [
        FoilSimulationConfig(damping: 0.9589766, softeningSqr: 0.3, numBodies: 8192, clusterScale: 0.42543644, velocityScale: 1.2444435, renderScale: 7.6108184, renderBodies: 8192, simInterval: 0.016666668, simDuration: 5.0),
        FoilSimulationConfig(damping: 0.9589766, softeningSqr: 0.2, numBodies: 8192, clusterScale: 0.42543644, velocityScale: 1.2444435, renderScale: 7.6108184, renderBodies: 8192, simInterval: 0.016666668, simDuration: 5.0),
        FoilSimulationConfig(damping: 0.9589766, softeningSqr: 0.1, numBodies: 8192, clusterScale: 0.42543644, velocityScale: 1.2444435, renderScale: 7.6108184, renderBodies: 8192, simInterval: 0.016666668, simDuration: 5.0),
        // damping softening numBodies clusterScale velocityScale renderScale renderBodies simInterval simDuration
        FoilSimulationConfig(damping: 1.0, softeningSqr: 0.500, numBodies: 8192, clusterScale: 0.70, velocityScale:                  1.0, renderScale:  100.0, renderBodies: 8192, simInterval: frameTime,      simDuration: 10.0 * second),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 0.100, numBodies: 16384, clusterScale: 0.50, velocityScale: metersPerSecond / 30, renderScale:   25.0, renderBodies: 16384, simInterval: frameTime,      simDuration: 10.0 * second),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 1.000, numBodies: 16384, clusterScale: 0.32, velocityScale: metersPerSecond / 30, renderScale:    2.5, renderBodies: 16384, simInterval: frameTime / 30, simDuration: 10.0 * second / 30),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 1.000, numBodies: 16384, clusterScale: 6.04, velocityScale:                    0, renderScale:   75.0, renderBodies: 16384, simInterval: frameTime,      simDuration: 10.0 * second),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 0.145, numBodies: 16384, clusterScale: 0.32, velocityScale: metersPerSecond / 30, renderScale:    2.5, renderBodies: 16384, simInterval: frameTime / 30, simDuration: 10.0 * second / 30),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 0.145, numBodies: 16384, clusterScale: 0.32, velocityScale: 20.0, renderScale: 2.5, renderBodies: 16384, simInterval: 0.00055555557, simDuration: 0.3333333333333333),
        FoilSimulationConfig(damping: 1.0, softeningSqr: 1.0, numBodies: 16384, clusterScale: 0.32, velocityScale: 20.0, renderScale: 2.5, renderBodies: 16384, simInterval: 0.00055555557, simDuration: 0.0004),
        FoilSimulationConfig(damping: 0.9589766, softeningSqr: 0.3, numBodies: 8192, clusterScale: 0.42543644, velocityScale: 1.2444435, renderScale: 7.6108184, renderBodies: 8192, simInterval: 0.016666668, simDuration: 5.0)
    ]

    static let FoilNumSimulationConfigs = FoilSimulationConfigTable.count
    static let FoilSecondsToPresentSimulationResults = CFTimeInterval(0.5)

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
    var viewControllerCommandQueue: MTLCommandQueue!

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

//        _view.delegate = self
    }

    override func viewDidAppear() { beginSimulation() }

    override func viewDidDisappear() {
        viewControllerispatchQueue.sync {
            // Stop simulation if on another thread
            self.simulation.halt = true

            // Indicate that simulation should not continue and results will not be needed
            self.terminateAllSimulations = true
        }
    }

    func selectDevices() {
        let availableDevices = MTLCopyAllDevices()

        precondition(!availableDevices.isEmpty, "Metal is not supported on this Mac")

        computeDevice = availableDevices[RadeonGPUInMetalDevicesArray]

        // Select renderer device
        let rendererDevice = availableDevices[RadeonGPUInMetalDevicesArray]

        renderer = FoilRenderer(self, rendererDevice)

        renderer.drawableSizeWillChange()
    }

    static var experimentalValue = Float(0.01)

    func beginSimulation() {
        simulationTime = 0

        _simulationName.stringValue = "Simulation \(configNum)"
        let c = FoilViewController.FoilSimulationConfigTable[configNum]

//        c.simDuration = 4
//        c.damping = Float.random(in: 0.7..<1.06) // FoilViewController.experimentalValue
//        c.softeningSqr = Float.random(in: 0.01..<0.04)// FoilViewController.experimentalValue
//        c.clusterScale = Float.random(in: 0.01..<0.5)
//        c.renderScale = Float.random(in: 2.5..<100)
//        c.velocityScale = Float.random(in: 1..<2)
        config = c
        print("F: ", config!)

        FoilViewController.experimentalValue *= 1.1

//        let softeningSqr = Double.random(in: 0.1..<1.0)
//        let numBodies = 4096
//        let clusterScale = Double.random(in: 0.2..<6.0)
//        let velocityScale = Double.random(in: 0..<3.0)
//        let renderScale = Double.random(in: 2.5..<200)
//        let renderBodies = 4096
//        let simInterval = FoilViewController.frameTime
//        let simDuration = 3.0 * FoilViewController.second
//
//        config = FoilSimulationConfig(
//            damping: 1.0,
//            softeningSqr: softeningSqr,
//            numBodies: numBodies,
//            clusterScale: clusterScale,
//            velocityScale: velocityScale,
//            renderScale: renderScale,
//            renderBodies: renderBodies,
//            simInterval: simInterval,
//            simDuration: simDuration
//        )

//        print("config", config!)

        simulation = FoilSimulation(computeDevice: computeDevice, config: config)

        renderer.setRenderScale(renderScale: config.renderScale)

        viewControllerCommandQueue = renderer.device.makeCommandQueue()
    }

    /// Called whenever the view needs to render
    func draw(in view: MTKView) {
        // Number of bodies to render this frame
        var numBodies = config.renderBodies

        // Handle simulations completion
        if(simulationTime >= config.simDuration) {
            // If the simulation is over, render all the bodies in the simulation to show final results
            numBodies = config.numBodies

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
                    self._simulationName.alphaValue = 1.0
                    self._simulationPercentage.alphaValue = 1.0
                }

                let blinkyBlock: (Timer) -> () = { timer in
                    NSAnimationContext.runAnimationGroup(animationGroup, completionHandler: animationCompletion)
                }

                blinker = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true, block: blinkyBlock)

                blinker.fire()

            } else if(CACurrentMediaTime() >= continuationTime) {
                // If the continuation time has been reached, select a new simulation and begin execution
                configNum = (configNum + 1) % FoilViewController.FoilNumSimulationConfigs

                continuationTime = 0

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
        guard let vcCommandQueue = self.viewControllerCommandQueue,
              let simulate_render_commandBuffer = vcCommandQueue.makeCommandBuffer()
            else { fatalError() }

        simulate_render_commandBuffer.label = "simulate_render_commandBuffer"

        // Simulate the frame and obtain the new positions for the update.  If this is the final
        // frame positionBuffer will be filled with the all positions used for the simulation
        let positionsBuffer = simulation.simulateFrame(simulate_render_commandBuffer)

        // Render the updated positions (or all positions in the case that the simulation is complete)
        renderer.draw(
            simulate_render_commandBuffer,
            positionsBuffer: positionsBuffer,
            numBodies: numBodies
        )

        simulate_render_commandBuffer.commit()

        simulationTime += Double(config.simInterval)

        var percentComplete = 0

        // Lock when using _simulationTime since it can be updated on a separate thread
        viewControllerispatchQueue.sync {
            percentComplete = Int((simulationTime / config.simDuration) * 100)
        }

        _simulationPercentage.stringValue = percentComplete < 100 ?
            "\(percentComplete)" : "Final Result"
    }
}

