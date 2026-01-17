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
    private let shadowToggleButton = UIButton(type: .system)
    private let volumeToggleButton = UIButton(type: .system)
    private let frameLabel = UILabel()
    private let lightPanelContainer = UIView()
    private let lightPanelStack = UIStackView()
    private let lightXSlider = UISlider()
    private let lightYSlider = UISlider()
    private let lightZSlider = UISlider()
    private let ambientSlider = UISlider()
    private let shadowStrengthSlider = UISlider()
    private let shadowNearSlider = UISlider()
    private let shadowFarSlider = UISlider()
    private let shadowFovSlider = UISlider()
    private let lightIntensitySlider = UISlider()
    private let lightAttenuationSlider = UISlider()
    private let lightPrevButton = UIButton(type: .system)
    private let lightNextButton = UIButton(type: .system)
    private let lightIndexLabel = UILabel()
    private let lightShadowSwitch = UISwitch()
    private var lightColorButtons: [UIButton] = []
    private let lightColorStack = UIStackView()
    private let lightXValueLabel = UILabel()
    private let lightYValueLabel = UILabel()
    private let lightZValueLabel = UILabel()
    private let ambientValueLabel = UILabel()
    private let shadowStrengthValueLabel = UILabel()
    private let shadowNearValueLabel = UILabel()
    private let shadowFarValueLabel = UILabel()
    private let shadowFovValueLabel = UILabel()
    private let lightIntensityValueLabel = UILabel()
    private let lightAttenuationValueLabel = UILabel()
    private var selectedLightIndex: Int = 0
    private let lightColorPalette: [SIMD3<Float>] = [
        SIMD3<Float>(1.0, 0.9, 0.7),
        SIMD3<Float>(1.0, 0.6, 0.3),
        SIMD3<Float>(0.3, 0.8, 1.0),
        SIMD3<Float>(0.8, 0.3, 1.0),
        SIMD3<Float>(0.6, 1.0, 0.5),
        SIMD3<Float>(1.0, 1.0, 1.0)
    ]
    private var displayLink: CADisplayLink?
    private var lastDisplayTimestamp: CFTimeInterval?
    private let debugFPS: Double = 30.0
    private var volumetricLightSystem: VolumetricLightSystem!
    private var floorRenderable: FloorRenderable?

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
                                                                 resourceExtension: modelResourceExtension) else {
            print("ModelAnimationSystem cannot be initialized")
            return
        }

        modelAnimationSystem = newModelAnimationSystem
        self.cameraSystem = cameraSystem
        self.lightSystem = lightSystem

        guard let lightManager = LightManager(metalKitView: mtkView, lightingSystem: lightSystem) else {
            print("LightManager cannot be initialized")
            return
        }
        let radius = max(modelAnimationSystem.meshRadius, 0.001)

        guard let newVolumetricLightSystem = VolumetricLightSystem(metalKitView: mtkView,
                                                                   lightSystem: lightSystem) else {
            print("VolumetricLightSystem cannot be initialized")
            return
        }
        volumetricLightSystem = newVolumetricLightSystem

        let worldCenter = SIMD3<Float>(repeating: 0)
        let floorY = -radius * 0.75
        let lightTarget = SIMD3<Float>(0, floorY, 0)
        lightSystem.target = lightTarget
        lightSystem.lightPosition = worldCenter + SIMD3<Float>(radius, radius * 1.8, radius)
        lightSystem.shadowFar = max(radius * 6.0, 10.0)
        configureColoredLights(center: worldCenter, target: lightTarget, radius: radius)

        guard let floorRenderable = FloorRenderable(metalKitView: mtkView, radius: radius * 0.75) else {
            print("FloorRenderable cannot be initialized")
            return
        }
        self.floorRenderable = floorRenderable
        
        // Configure camera based on loaded model size
        cameraSystem.setTarget(radius: modelAnimationSystem.meshRadius)

        // Create scene with camera, game systems, and render systems
        scene = SceneManager(view: mtkView,
                     cameraSystem: cameraSystem,
                     lightManager: lightManager,
                     gameSystems: [modelAnimationSystem, lightSystem],
                     renderables: [floorRenderable, modelAnimationSystem, volumetricLightSystem])
        
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
        shadowToggleButton.translatesAutoresizingMaskIntoConstraints = false
        volumeToggleButton.translatesAutoresizingMaskIntoConstraints = false

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

        shadowToggleButton.setTitle("Shadows: ON", for: .normal)
        shadowToggleButton.addTarget(self, action: #selector(toggleShadows), for: .touchUpInside)
        shadowToggleButton.backgroundColor = UIColor(white: 0.1, alpha: 0.7)
        shadowToggleButton.setTitleColor(.white, for: .normal)
        shadowToggleButton.layer.cornerRadius = 8
        shadowToggleButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        volumeToggleButton.setTitle("Volume: ON", for: .normal)
        volumeToggleButton.addTarget(self, action: #selector(toggleVolumetric), for: .touchUpInside)
        volumeToggleButton.backgroundColor = UIColor(white: 0.1, alpha: 0.7)
        volumeToggleButton.setTitleColor(.white, for: .normal)
        volumeToggleButton.layer.cornerRadius = 8
        volumeToggleButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        view.addSubview(toggleModeButton)
        view.addSubview(stepButton)
        view.addSubview(shadowToggleButton)
        view.addSubview(volumeToggleButton)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            toggleModeButton.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 12),
            toggleModeButton.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 12),

            stepButton.leadingAnchor.constraint(equalTo: toggleModeButton.trailingAnchor, constant: 12),
            stepButton.centerYAnchor.constraint(equalTo: toggleModeButton.centerYAnchor),

            shadowToggleButton.leadingAnchor.constraint(equalTo: stepButton.trailingAnchor, constant: 12),
            shadowToggleButton.centerYAnchor.constraint(equalTo: toggleModeButton.centerYAnchor),

            volumeToggleButton.leadingAnchor.constraint(equalTo: shadowToggleButton.trailingAnchor, constant: 12),
            volumeToggleButton.centerYAnchor.constraint(equalTo: toggleModeButton.centerYAnchor)
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
            frameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: volumeToggleButton.trailingAnchor, constant: 12)
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

        configureLightSelectionControls()

        configureLightSlider(lightXSlider, valueLabel: lightXValueLabel, title: "X", tag: 0)
        configureLightSlider(lightYSlider, valueLabel: lightYValueLabel, title: "Y", tag: 1)
        configureLightSlider(lightZSlider, valueLabel: lightZValueLabel, title: "Z", tag: 2)
        configureLightSlider(ambientSlider, valueLabel: ambientValueLabel, title: "Ambient", tag: 3)
        configureLightSlider(shadowStrengthSlider, valueLabel: shadowStrengthValueLabel, title: "Shadow", tag: 4)
        configureLightSlider(shadowNearSlider, valueLabel: shadowNearValueLabel, title: "Near", tag: 5)
        configureLightSlider(shadowFarSlider, valueLabel: shadowFarValueLabel, title: "Far", tag: 6)
        configureLightSlider(shadowFovSlider, valueLabel: shadowFovValueLabel, title: "FOV", tag: 7)
        configureLightSlider(lightIntensitySlider, valueLabel: lightIntensityValueLabel, title: "Intensity", tag: 8)
        configureLightSlider(lightAttenuationSlider, valueLabel: lightAttenuationValueLabel, title: "Falloff", tag: 9)

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

        let range = max(radius, 0.001) * 10.0
        lightXSlider.minimumValue = -range
        lightXSlider.maximumValue = range
        lightYSlider.minimumValue = -range
        lightYSlider.maximumValue = range
        lightZSlider.minimumValue = -range
        lightZSlider.maximumValue = range

        ambientSlider.minimumValue = 0.0
        ambientSlider.maximumValue = 1.0
        shadowStrengthSlider.minimumValue = 0.0
        shadowStrengthSlider.maximumValue = 1.0
        shadowNearSlider.minimumValue = 0.001
        shadowNearSlider.maximumValue = max(radius * 10.0, 50.0)
        shadowFarSlider.minimumValue = 0.01
        shadowFarSlider.maximumValue = max(radius * 40.0, 200.0)
        shadowFovSlider.minimumValue = 1.0
        shadowFovSlider.maximumValue = 179.0
        lightIntensitySlider.minimumValue = 0.0
        lightIntensitySlider.maximumValue = 5000.0
        lightAttenuationSlider.minimumValue = 0.0
        lightAttenuationSlider.maximumValue = 4.0

        if let lightSystem = lightSystem {
            lightXSlider.value = lightSystem.lightPosition.x
            lightYSlider.value = lightSystem.lightPosition.y
            lightZSlider.value = lightSystem.lightPosition.z
            ambientSlider.value = lightSystem.ambientIntensity
            shadowStrengthSlider.value = lightSystem.shadowStrength
            shadowNearSlider.value = lightSystem.shadowNear
            shadowFarSlider.value = lightSystem.shadowFar
            shadowFovSlider.value = lightSystem.outerConeAngle * 2.0 * 180.0 / Float.pi
            lightAttenuationSlider.value = lightSystem.attenuationPower
        }

        selectLightIndex(selectedLightIndex)
    }

    private func configureLightSelectionControls() {
        let selectLabel = UILabel()
        selectLabel.text = "Edit Light"
        selectLabel.textColor = .white
        selectLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        selectLabel.setContentHuggingPriority(.required, for: .horizontal)

        lightPrevButton.setTitle("◀︎", for: .normal)
        lightPrevButton.addTarget(self, action: #selector(selectPrevLight), for: .touchUpInside)
        lightPrevButton.setContentHuggingPriority(.required, for: .horizontal)

        lightNextButton.setTitle("▶︎", for: .normal)
        lightNextButton.addTarget(self, action: #selector(selectNextLight), for: .touchUpInside)
        lightNextButton.setContentHuggingPriority(.required, for: .horizontal)

        lightIndexLabel.text = "1/1"
        lightIndexLabel.textColor = .white
        lightIndexLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        lightIndexLabel.textAlignment = .center
        lightIndexLabel.setContentHuggingPriority(.required, for: .horizontal)

        let indexRow = UIStackView(arrangedSubviews: [lightPrevButton, lightIndexLabel, lightNextButton])
        indexRow.axis = .horizontal
        indexRow.spacing = 6
        indexRow.alignment = .center

        let selectRow = UIStackView(arrangedSubviews: [selectLabel, indexRow])
        selectRow.axis = .horizontal
        selectRow.spacing = 8
        selectRow.alignment = .center

        let shadowLabel = UILabel()
        shadowLabel.text = "Cast Shadow"
        shadowLabel.textColor = .white
        shadowLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        shadowLabel.setContentHuggingPriority(.required, for: .horizontal)

        lightShadowSwitch.addTarget(self, action: #selector(lightShadowChanged(_:)), for: .valueChanged)
        let shadowRow = UIStackView(arrangedSubviews: [shadowLabel, lightShadowSwitch])
        shadowRow.axis = .horizontal
        shadowRow.spacing = 8
        shadowRow.alignment = .center

        let colorLabel = UILabel()
        colorLabel.text = "Color"
        colorLabel.textColor = .white
        colorLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        colorLabel.setContentHuggingPriority(.required, for: .horizontal)

        lightColorStack.axis = .horizontal
        lightColorStack.spacing = 6
        lightColorStack.distribution = .fillEqually
        lightColorButtons = lightColorPalette.enumerated().map { index, color in
            let button = UIButton(type: .system)
            button.tag = index
            button.layer.cornerRadius = 6
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor(white: 1.0, alpha: 0.4).cgColor
            button.backgroundColor = UIColor(red: CGFloat(color.x),
                                             green: CGFloat(color.y),
                                             blue: CGFloat(color.z),
                                             alpha: 1.0)
            button.addTarget(self, action: #selector(lightColorTapped(_:)), for: .touchUpInside)
            return button
        }
        lightColorButtons.forEach { lightColorStack.addArrangedSubview($0) }

        let colorRow = UIStackView(arrangedSubviews: [colorLabel, lightColorStack])
        colorRow.axis = .horizontal
        colorRow.spacing = 8
        colorRow.alignment = .center

        lightPanelStack.addArrangedSubview(selectRow)
        lightPanelStack.addArrangedSubview(shadowRow)
        lightPanelStack.addArrangedSubview(colorRow)
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
        case 4:
            lightSystem.shadowStrength = sender.value
        case 5:
            lightSystem.shadowNear = sender.value
        case 6:
            lightSystem.shadowFar = sender.value
        case 7:
            let fovDegrees = sender.value
            lightSystem.outerConeAngle = radians_from_degrees(fovDegrees * 0.5)
        case 8:
            updateSelectedLight { $0.intensity = sender.value }
            if selectedLightIndex == 0 {
                lightSystem.lightIntensity = sender.value
            }
        case 9:
            lightSystem.attenuationPower = sender.value
        default:
            break
        }
        updateLightLabels()
    }

    private func updateSelectedLightControls() {
        guard let lightSystem = lightSystem, selectedLightIndex < lightSystem.lights.count else {
            return
        }
        let light = lightSystem.lights[selectedLightIndex]
        lightIntensitySlider.value = light.intensity
        lightShadowSwitch.isOn = light.castsShadow
        updateLightIndexLabel()
        updateColorSelection(for: light.color)
    }

    private func updateSelectedLight(_ update: (inout LightingSystem.SpotLight) -> Void) {
        guard let lightSystem = lightSystem, selectedLightIndex < lightSystem.lights.count else {
            return
        }
        var light = lightSystem.lights[selectedLightIndex]
        update(&light)
        lightSystem.lights[selectedLightIndex] = light
    }

    private func updateLightIndexLabel() {
        guard let lightSystem = lightSystem else { return }
        let count = max(lightSystem.lights.count, 1)
        let index = min(max(selectedLightIndex, 0), count - 1)
        lightIndexLabel.text = "\(index + 1)/\(count)"
        lightPrevButton.isEnabled = index > 0
        lightNextButton.isEnabled = index < count - 1
    }

    private func updateColorSelection(for color: SIMD3<Float>) {
        guard !lightColorButtons.isEmpty else { return }
        var bestIndex = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, candidate) in lightColorPalette.enumerated() {
            let delta = candidate - color
            let distance = simd_length(delta)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        for button in lightColorButtons {
            if button.tag == bestIndex {
                button.layer.borderWidth = 2
                button.layer.borderColor = UIColor.white.cgColor
            } else {
                button.layer.borderWidth = 1
                button.layer.borderColor = UIColor(white: 1.0, alpha: 0.4).cgColor
            }
        }
    }

    private func selectLightIndex(_ index: Int) {
        guard let lightSystem = lightSystem else { return }
        let count = max(lightSystem.lights.count, 1)
        selectedLightIndex = min(max(index, 0), count - 1)
        updateSelectedLightControls()
        updateLightLabels()
    }

    @objc private func selectPrevLight() {
        selectLightIndex(selectedLightIndex - 1)
    }

    @objc private func selectNextLight() {
        selectLightIndex(selectedLightIndex + 1)
    }

    @objc private func lightColorTapped(_ sender: UIButton) {
        let index = max(0, min(sender.tag, lightColorPalette.count - 1))
        let color = lightColorPalette[index]
        updateSelectedLight { $0.color = color }
        if selectedLightIndex == 0 {
            lightSystem?.lightColor = color
        }
        updateSelectedLightControls()
    }

    @objc private func lightShadowChanged(_ sender: UISwitch) {
        updateSelectedLight { $0.castsShadow = sender.isOn }
        if selectedLightIndex == 0 {
            lightSystem?.primaryCastsShadow = sender.isOn
        }
    }

    private func updateLightLabels() {
        lightXValueLabel.text = String(format: "%.2f", lightXSlider.value)
        lightYValueLabel.text = String(format: "%.2f", lightYSlider.value)
        lightZValueLabel.text = String(format: "%.2f", lightZSlider.value)
        ambientValueLabel.text = String(format: "%.2f", ambientSlider.value)
        shadowStrengthValueLabel.text = String(format: "%.2f", shadowStrengthSlider.value)
        shadowNearValueLabel.text = String(format: "%.3f", shadowNearSlider.value)
        shadowFarValueLabel.text = String(format: "%.2f", shadowFarSlider.value)
        shadowFovValueLabel.text = String(format: "%.1f", shadowFovSlider.value)
        lightIntensityValueLabel.text = String(format: "%.1f", lightIntensitySlider.value)
        lightAttenuationValueLabel.text = String(format: "%.2f", lightAttenuationSlider.value)
    }

    private func configureDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(renderLoop))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func configureColoredLights(center: SIMD3<Float>, target: SIMD3<Float>, radius: Float) {
        guard let lightSystem = lightSystem else { return }
        let r = max(radius, 0.001)

        lightSystem.lightColor = SIMD3<Float>(1.0, 0.9, 0.7)
        lightSystem.lightIntensity = 2.0
        lightSystem.ambientIntensity = 0.5
        lightSystem.innerConeAngle = radians_from_degrees(20)
        lightSystem.outerConeAngle = radians_from_degrees(45)
        lightSystem.primaryCastsShadow = true
        lightSystem.primaryCastsVolume = true
        lightSystem.activeLightCount = 4
        lightSystem.orbitEnabled = false
        lightSystem.orbitAffectsPrimary = false
        let primary = LightingSystem.SpotLight(position: lightSystem.lightPosition,
                                               target: target,
                                               color: SIMD3<Float>(1.0, 0.9, 0.7),
                                               intensity: lightSystem.lightIntensity,
                                               innerConeAngle: radians_from_degrees(20),
                                               outerConeAngle: radians_from_degrees(45),
                                               shadowNear: lightSystem.shadowNear,
                                               shadowFar: max(r * 6.0, 10.0),
                                               castsShadow: true,
                                               castsVolume: true)

        let warm = LightingSystem.SpotLight(position: center + SIMD3<Float>(-r, r * 1.1, r * 0.3),
                                            target: target,
                                            color: SIMD3<Float>(1.0, 0.5, 0.2),
                                            intensity: 0.85,
                                            innerConeAngle: radians_from_degrees(10),
                                            outerConeAngle: radians_from_degrees(20),
                                            shadowNear: lightSystem.shadowNear,
                                            shadowFar: max(r * 6.0, 10.0),
                                            castsShadow: false,
                                            castsVolume: true)

        let cool = LightingSystem.SpotLight(position: center + SIMD3<Float>(r * 0.6, r * 1.3, -r * 0.6),
                                            target: target,
                                            color: SIMD3<Float>(0.3, 0.8, 1.0),
                                            intensity: 0.8,
                                            innerConeAngle: radians_from_degrees(12),
                                            outerConeAngle: radians_from_degrees(22),
                                            shadowNear: lightSystem.shadowNear,
                                            shadowFar: max(r * 6.0, 10.0),
                                            castsShadow: false,
                                            castsVolume: true)

        let magenta = LightingSystem.SpotLight(position: center + SIMD3<Float>(r * 0.7, r * 0.8, r * 0.9),
                                               target: target,
                                               color: SIMD3<Float>(0.8, 0.3, 1.0),
                                               intensity: 0.75,
                                               innerConeAngle: radians_from_degrees(11),
                                               outerConeAngle: radians_from_degrees(20),
                                               shadowNear: lightSystem.shadowNear,
                                               shadowFar: max(r * 6.0, 10.0),
                                               castsShadow: false,
                                               castsVolume: true)

        lightSystem.lights = [primary, warm, cool, magenta]
        lightSystem.configureRandomOrbits(center: center, radius: r * 1.1)
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

    @objc private func toggleShadows() {
        guard let lightSystem = lightSystem else { return }
        lightSystem.shadowEnabled.toggle()
        updateDebugButtonState()
    }

    @objc private func toggleVolumetric() {
        volumetricLightSystem?.isEnabled.toggle()
        updateDebugButtonState()
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
        if let lightSystem = lightSystem {
            shadowToggleButton.setTitle(lightSystem.shadowEnabled ? "Shadows: ON" : "Shadows: OFF", for: .normal)
        }
        if let volumetricLightSystem = volumetricLightSystem {
            volumeToggleButton.setTitle(volumetricLightSystem.isEnabled ? "Volume: ON" : "Volume: OFF", for: .normal)
        }
    }
}
