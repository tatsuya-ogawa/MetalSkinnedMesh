//
//  GameViewController.swift
//  MetalSkinnedMesh
//
//  Created by Tatsuya Ogawa on 2025/12/28.
//

import UIKit
import MetalKit
import simd

// Our iOS specific view controller
class GameViewController: UIViewController {

    var renderer: Renderer!
    var modelAnimationSystem: ModelAnimationSystem!
    private var cameraSystem: CameraSystem!
    private var lightSystem: LightingSystem!
    private var scene: SceneManager!
    var mtkView: MTKView!
    private let modelResourceName = "robot"
    private let modelResourceExtension = "usdz"
    private let toggleModeButton = UIButton(type: .system)
    private let stepButton = UIButton(type: .system)
    private let frameLabel = UILabel()
    private let lightPanelContainer = UIView()
    private let lightPanelStack = UIStackView()
    private let lightXSlider = UISlider()
    private let lightYSlider = UISlider()
    private let lightZSlider = UISlider()
    private let ambientSlider = UISlider()
    private let lightXValueLabel = UILabel()
    private let lightYValueLabel = UILabel()
    private let lightZValueLabel = UILabel()
    private let ambientValueLabel = UILabel()
    private var displayLink: CADisplayLink?
    private var lastDisplayTimestamp: CFTimeInterval?
    private let debugFPS: Double = 30.0

    override var canBecomeFirstResponder: Bool {
        true
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputRightArrow,
                         modifierFlags: [],
                         action: #selector(stepForwardKey),
                         discoverabilityTitle: "Step Forward"),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow,
                         modifierFlags: [],
                         action: #selector(stepBackwardKey),
                         discoverabilityTitle: "Step Backward")
        ]
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let mtkView = view as? MTKView else {
            print("View of Gameview controller is not an MTKView")
            return
        }

        // Select the device to render with.  We choose the default device
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported")
            return
        }
        
        mtkView.device = defaultDevice
        mtkView.backgroundColor = UIColor.black
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false

        let cameraSystem = CameraSystem()
        let lightSystem = LightingSystem()
        guard let newModelAnimationSystem = ModelAnimationSystem(metalKitView: mtkView,
                                                                 resourceName: modelResourceName,
                                                                 resourceExtension: modelResourceExtension,
                                                                 lightSystem: lightSystem) else {
            print("ModelAnimationSystem cannot be initialized")
            return
        }

        modelAnimationSystem = newModelAnimationSystem
        self.cameraSystem = cameraSystem
        self.lightSystem = lightSystem

        let radius = max(modelAnimationSystem.meshRadius, 0.001)
        lightSystem.target = modelAnimationSystem.meshCenter
        lightSystem.lightPosition = modelAnimationSystem.meshCenter + SIMD3<Float>(radius, radius, radius)
        
        // Configure camera based on loaded model size
        cameraSystem.setTarget(radius: modelAnimationSystem.meshRadius)

        // Create scene with camera, game systems, and render systems
        scene = SceneManager(view: mtkView,
                     cameraSystem: cameraSystem,
                     gameSystems: [modelAnimationSystem, lightSystem],
                     renderSystems: [modelAnimationSystem])
        
        guard let newRenderer = Renderer(metalKitView: mtkView, scene: scene) else {
            print("Renderer cannot be initialized")
            return
        }

        renderer = newRenderer

        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)

        mtkView.delegate = renderer

        configureDebugButtons()
        configureFrameLabel()
        configureLightPanel(radius: radius)
        configureOrbitControls()
        configureDisplayLink()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    private func configureDebugButtons() {
        toggleModeButton.translatesAutoresizingMaskIntoConstraints = false
        stepButton.translatesAutoresizingMaskIntoConstraints = false

        toggleModeButton.setTitle("Auto: ON", for: .normal)
        toggleModeButton.addTarget(self, action: #selector(toggleAnimationMode), for: .touchUpInside)
        toggleModeButton.backgroundColor = UIColor(white: 0.1, alpha: 0.7)
        toggleModeButton.setTitleColor(.white, for: .normal)
        toggleModeButton.layer.cornerRadius = 8
        toggleModeButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        stepButton.setTitle("Step +", for: .normal)
        stepButton.addTarget(self, action: #selector(stepAnimation), for: .touchUpInside)
        stepButton.backgroundColor = UIColor(white: 0.1, alpha: 0.7)
        stepButton.setTitleColor(.white, for: .normal)
        stepButton.layer.cornerRadius = 8
        stepButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stepButton.isHidden = true

        view.addSubview(toggleModeButton)
        view.addSubview(stepButton)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            toggleModeButton.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 12),
            toggleModeButton.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 12),

            stepButton.leadingAnchor.constraint(equalTo: toggleModeButton.trailingAnchor, constant: 12),
            stepButton.centerYAnchor.constraint(equalTo: toggleModeButton.centerYAnchor)
        ])

        updateDebugButtonState()
    }

    private func configureFrameLabel() {
        frameLabel.translatesAutoresizingMaskIntoConstraints = false
        frameLabel.textColor = .white
        frameLabel.backgroundColor = UIColor(white: 0.1, alpha: 0.7)
        frameLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        frameLabel.layer.cornerRadius = 6
        frameLabel.layer.masksToBounds = true
        frameLabel.textAlignment = .left
        frameLabel.text = "--"
        frameLabel.setContentHuggingPriority(.required, for: .horizontal)
        frameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        view.addSubview(frameLabel)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            frameLabel.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -12),
            frameLabel.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 12),
            frameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: stepButton.trailingAnchor, constant: 12)
        ])
    }

    private func configureLightPanel(radius: Float) {
        lightPanelContainer.translatesAutoresizingMaskIntoConstraints = false
        lightPanelContainer.backgroundColor = UIColor(white: 0.1, alpha: 0.7)
        lightPanelContainer.layer.cornerRadius = 10
        lightPanelContainer.layer.masksToBounds = true

        lightPanelStack.translatesAutoresizingMaskIntoConstraints = false
        lightPanelStack.axis = .vertical
        lightPanelStack.spacing = 8

        let titleLabel = UILabel()
        titleLabel.text = "Light"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)

        lightPanelStack.addArrangedSubview(titleLabel)

        configureLightSlider(lightXSlider, valueLabel: lightXValueLabel, title: "X", tag: 0)
        configureLightSlider(lightYSlider, valueLabel: lightYValueLabel, title: "Y", tag: 1)
        configureLightSlider(lightZSlider, valueLabel: lightZValueLabel, title: "Z", tag: 2)
        configureLightSlider(ambientSlider, valueLabel: ambientValueLabel, title: "Ambient", tag: 3)

        lightPanelContainer.addSubview(lightPanelStack)
        view.addSubview(lightPanelContainer)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            lightPanelContainer.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 12),
            lightPanelContainer.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -12),
            lightPanelContainer.widthAnchor.constraint(equalToConstant: 260),

            lightPanelStack.leadingAnchor.constraint(equalTo: lightPanelContainer.leadingAnchor, constant: 12),
            lightPanelStack.trailingAnchor.constraint(equalTo: lightPanelContainer.trailingAnchor, constant: -12),
            lightPanelStack.topAnchor.constraint(equalTo: lightPanelContainer.topAnchor, constant: 12),
            lightPanelStack.bottomAnchor.constraint(equalTo: lightPanelContainer.bottomAnchor, constant: -12)
        ])

        let range = max(radius, 0.001) * 3.0
        lightXSlider.minimumValue = -range
        lightXSlider.maximumValue = range
        lightYSlider.minimumValue = -range
        lightYSlider.maximumValue = range
        lightZSlider.minimumValue = -range
        lightZSlider.maximumValue = range

        ambientSlider.minimumValue = 0.0
        ambientSlider.maximumValue = 1.0

        if let lightSystem = lightSystem {
            lightXSlider.value = lightSystem.lightPosition.x
            lightYSlider.value = lightSystem.lightPosition.y
            lightZSlider.value = lightSystem.lightPosition.z
            ambientSlider.value = lightSystem.ambientIntensity
        }

        updateLightLabels()
    }

    private func configureLightSlider(_ slider: UISlider,
                                      valueLabel: UILabel,
                                      title: String,
                                      tag: Int) {
        slider.tag = tag
        slider.addTarget(self, action: #selector(lightSliderChanged(_:)), for: .valueChanged)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = .white
        titleLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        valueLabel.textColor = .white
        valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [titleLabel, slider, valueLabel])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center

        lightPanelStack.addArrangedSubview(row)
    }

    @objc private func lightSliderChanged(_ sender: UISlider) {
        guard let lightSystem = lightSystem else { return }
        switch sender.tag {
        case 0:
            lightSystem.lightPosition.x = sender.value
        case 1:
            lightSystem.lightPosition.y = sender.value
        case 2:
            lightSystem.lightPosition.z = sender.value
        case 3:
            lightSystem.ambientIntensity = sender.value
        default:
            break
        }
        updateLightLabels()
    }

    private func updateLightLabels() {
        lightXValueLabel.text = String(format: "%.2f", lightXSlider.value)
        lightYValueLabel.text = String(format: "%.2f", lightYSlider.value)
        lightZValueLabel.text = String(format: "%.2f", lightZSlider.value)
        ambientValueLabel.text = String(format: "%.2f", ambientSlider.value)
    }

    private func configureDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(renderLoop))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func configureOrbitControls() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOrbitPan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
    }

    @objc private func handleOrbitPan(_ sender: UIPanGestureRecognizer) {
        guard let cameraSystem = cameraSystem else { return }
        let translation = sender.translation(in: view)
        sender.setTranslation(.zero, in: view)
        cameraSystem.orbit(deltaX: Float(translation.x), deltaY: Float(translation.y))
    }

    @objc private func toggleAnimationMode() {
        guard let modelAnimationSystem = modelAnimationSystem else { return }
        let newAuto = !modelAnimationSystem.isAutoAnimation
        modelAnimationSystem.setAutoAnimation(newAuto)
        updateDebugButtonState()
        updateFrameLabel()
    }

    @objc private func stepAnimation() {
        guard let modelAnimationSystem = modelAnimationSystem else { return }
        if modelAnimationSystem.isAutoAnimation {
            modelAnimationSystem.setAutoAnimation(false)
            updateDebugButtonState()
        }
        modelAnimationSystem.stepAnimation()
        renderOnce()
        updateFrameLabel()
    }

    @objc private func stepForwardKey() {
        guard let modelAnimationSystem = modelAnimationSystem else { return }
        if modelAnimationSystem.isAutoAnimation {
            modelAnimationSystem.setAutoAnimation(false)
            updateDebugButtonState()
        }
        modelAnimationSystem.stepAnimation()
        renderOnce()
        updateFrameLabel()
    }

    @objc private func stepBackwardKey() {
        guard let modelAnimationSystem = modelAnimationSystem else { return }
        if modelAnimationSystem.isAutoAnimation {
            modelAnimationSystem.setAutoAnimation(false)
            updateDebugButtonState()
        }
        modelAnimationSystem.stepAnimationBackward()
        renderOnce()
        updateFrameLabel()
    }

    @objc private func renderLoop(_ link: CADisplayLink) {
        let delta: CFTimeInterval
        if let last = lastDisplayTimestamp {
            delta = link.timestamp - last
        } else {
            delta = 0
        }
        lastDisplayTimestamp = link.timestamp
        renderFrame(deltaTime: delta)
        updateFrameLabel()
    }

    private func renderOnce() {
        renderFrame(deltaTime: 0)
    }

    private func renderFrame(deltaTime: TimeInterval) {
        guard let renderer = renderer else { return }
        let frameIndex = renderer.beginFrame()
        scene.tick(deltaTime: deltaTime, frameIndex: frameIndex)
    }

    @objc private func updateFrameLabel() {
        guard let modelAnimationSystem = modelAnimationSystem else { return }
        let info = modelAnimationSystem.animationFrameInfo(fps: debugFPS)
        let mode = modelAnimationSystem.isAutoAnimation ? "AUTO" : "STEP"
        let timeText = String(format: "%.3f", info.time)
        let frameText = String(format: "%03d/%03d", info.frame, max(info.totalFrames - 1, 0))
        frameLabel.text = " \(mode)  t=\(timeText)  f=\(frameText) "
    }

    private func updateDebugButtonState() {
        guard let modelAnimationSystem = modelAnimationSystem else { return }
        let isAuto = modelAnimationSystem.isAutoAnimation
        toggleModeButton.setTitle(isAuto ? "Auto: ON" : "Auto: OFF", for: .normal)
        stepButton.isHidden = isAuto
    }
}
