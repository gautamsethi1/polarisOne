import SwiftUI
import CoreMotion

// MARK: - Movement Safeguards
struct MovementSafeguards {
    static let maxRotationDegrees: Float = 40.0
    static let maxPitchDegrees: Float = 30.0
    static let maxYawDegrees: Float = 45.0
    static let maxTranslationMeters: Float = 3.0
    static let warningThreshold: Float = 0.7 // Warn at 70% of max
    
    static func validateAndClamp(_ adjustment: DOFAdjustment) -> (safe: DOFAdjustment, warnings: [SafetyWarning]) {
        var warnings: [SafetyWarning] = []
        
        // Start with copies of the original adjustments
        var safeTranslation = adjustment.translation
        var safeRotation = adjustment.rotation
        let safeFraming = adjustment.framing
        
        // Validate rotations
        if let rollMag = adjustment.rotation.roll.magnitude {
            let rollMagFloat = Float(rollMag)
            if rollMagFloat > maxRotationDegrees {
                warnings.append(.excessiveRotation(axis: "roll", requested: rollMag, clamped: maxRotationDegrees))
                let clampedRoll = DirectionAdjustment(
                    direction: safeRotation.roll.direction,
                    magnitude: Double(maxRotationDegrees),
                    unit: safeRotation.roll.unit
                )
                safeRotation = RotationAdjustment(
                    yaw: safeRotation.yaw,
                    pitch: safeRotation.pitch,
                    roll: clampedRoll
                )
            } else if rollMagFloat > maxRotationDegrees * warningThreshold {
                warnings.append(.largeMovement(axis: "roll", magnitude: rollMag))
            }
        }
        
        if let pitchMag = adjustment.rotation.pitch.magnitude {
            let pitchMagFloat = Float(pitchMag)
            if pitchMagFloat > maxPitchDegrees {
                warnings.append(.excessiveRotation(axis: "pitch", requested: pitchMag, clamped: maxPitchDegrees))
                let clampedPitch = DirectionAdjustment(
                    direction: safeRotation.pitch.direction,
                    magnitude: Double(maxPitchDegrees),
                    unit: safeRotation.pitch.unit
                )
                safeRotation = RotationAdjustment(
                    yaw: safeRotation.yaw,
                    pitch: clampedPitch,
                    roll: safeRotation.roll
                )
            } else if pitchMagFloat > maxPitchDegrees * warningThreshold {
                warnings.append(.largeMovement(axis: "pitch", magnitude: pitchMag))
            }
        }
        
        if let yawMag = adjustment.rotation.yaw.magnitude {
            let yawMagFloat = Float(yawMag)
            if yawMagFloat > maxYawDegrees {
                warnings.append(.excessiveRotation(axis: "yaw", requested: yawMag, clamped: maxYawDegrees))
                let clampedYaw = DirectionAdjustment(
                    direction: safeRotation.yaw.direction,
                    magnitude: Double(maxYawDegrees),
                    unit: safeRotation.yaw.unit
                )
                safeRotation = RotationAdjustment(
                    yaw: clampedYaw,
                    pitch: safeRotation.pitch,
                    roll: safeRotation.roll
                )
            } else if yawMagFloat > maxYawDegrees * warningThreshold {
                warnings.append(.largeMovement(axis: "yaw", magnitude: yawMag))
            }
        }
        
        // Validate translations
        let translations = [
            ("x", adjustment.translation.x),
            ("y", adjustment.translation.y),
            ("z", adjustment.translation.z)
        ]
        
        for (axis, translation) in translations {
            if let mag = translation.magnitude {
                if mag > Double(maxTranslationMeters) {
                    warnings.append(.excessiveTranslation(axis: axis, requested: mag, clamped: maxTranslationMeters))
                    let clampedTranslation = DirectionAdjustment(
                        direction: translation.direction,
                        magnitude: Double(maxTranslationMeters),
                        unit: translation.unit
                    )
                    
                    switch axis {
                    case "x": 
                        safeTranslation = TranslationAdjustment(
                            x: clampedTranslation,
                            y: safeTranslation.y,
                            z: safeTranslation.z
                        )
                    case "y": 
                        safeTranslation = TranslationAdjustment(
                            x: safeTranslation.x,
                            y: clampedTranslation,
                            z: safeTranslation.z
                        )
                    case "z": 
                        safeTranslation = TranslationAdjustment(
                            x: safeTranslation.x,
                            y: safeTranslation.y,
                            z: clampedTranslation
                        )
                    default: break
                    }
                } else if mag > Double(maxTranslationMeters * warningThreshold) {
                    warnings.append(.largeMovement(axis: axis, magnitude: mag))
                }
            }
        }
        
        // Create the final safe adjustment
        let safeAdjustment = DOFAdjustment(
            translation: safeTranslation,
            rotation: safeRotation,
            framing: safeFraming
        )
        
        return (safeAdjustment, warnings)
    }
    
    enum SafetyWarning {
        case excessiveRotation(axis: String, requested: Double, clamped: Float)
        case excessiveTranslation(axis: String, requested: Double, clamped: Float)
        case largeMovement(axis: String, magnitude: Double)
        
        var message: String {
            switch self {
            case .excessiveRotation(let axis, let requested, let clamped):
                return "⚠️ \(axis.capitalized) rotation of \(Int(requested))° is too large. Limited to \(Int(clamped))°"
            case .excessiveTranslation(let axis, let requested, let clamped):
                return "⚠️ \(axis.uppercased()) movement of \(String(format: "%.1f", requested))m is too far. Limited to \(String(format: "%.1f", clamped))m"
            case .largeMovement(let axis, let magnitude):
                let unit = ["x", "y", "z"].contains(axis) ? "m" : "°"
                return "⚡ Large \(axis) adjustment: \(String(format: "%.1f", magnitude))\(unit)"
            }
        }
    }
}

// MARK: - Apple-Style Alignment View
struct AppleStyleAlignmentView: View {
    @ObservedObject var viewModel: ARViewModel
    @State private var deviceMotion = CMMotionManager()
    @State private var currentRoll: Double = 0
    @State private var currentPitch: Double = 0
    
    var body: some View {
        GeometryReader { geometry in
            if viewModel.isGuidanceActive {
                ZStack {
                    // Main alignment frame with integrated levels
                    AlignmentFrameView(
                        targetBounds: viewModel.guidanceTargetScreenBounds,
                        alignmentScore: viewModel.guidanceAlignmentScore,
                        rollOffset: calculateRollOffset(),
                        pitchOffset: calculatePitchOffset(),
                        showWarning: !viewModel.safetyWarnings.isEmpty
                    )
                    
                    // Subtle edge indicators for translation
                    TranslationEdgeIndicators(
                        directions: viewModel.guidanceDirections,
                        screenSize: geometry.size
                    )
                    
                    // Safety warnings overlay
                    if !viewModel.safetyWarnings.isEmpty {
                        SafetyWarningOverlay(warnings: viewModel.safetyWarnings)
                    }
                }
            }
        }
        .onAppear { startMotionUpdates() }
        .onDisappear { deviceMotion.stopDeviceMotionUpdates() }
    }
    
    private func startMotionUpdates() {
        guard deviceMotion.isDeviceMotionAvailable else { return }
        
        deviceMotion.deviceMotionUpdateInterval = 0.1
        deviceMotion.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let motion = motion else { return }
            currentRoll = motion.attitude.roll
            currentPitch = motion.attitude.pitch
        }
    }
    
    private func calculateRollOffset() -> CGFloat {
        // Convert LLM guidance + device motion to visual offset
        let targetRoll = viewModel.guidanceDirections.turnLeft - viewModel.guidanceDirections.turnRight
        let rollError = CGFloat(currentRoll) * 180 / .pi - CGFloat(targetRoll)
        return rollError * 2 // Scale for visibility
    }
    
    private func calculatePitchOffset() -> CGFloat {
        let targetPitch = viewModel.guidanceDirections.tiltUp - viewModel.guidanceDirections.tiltDown
        let pitchError = CGFloat(currentPitch) * 180 / .pi - CGFloat(targetPitch)
        return pitchError * 2
    }
}

// MARK: - Alignment Frame with Level Indicators
struct AlignmentFrameView: View {
    let targetBounds: CGRect
    let alignmentScore: Float
    let rollOffset: CGFloat
    let pitchOffset: CGFloat
    let showWarning: Bool
    
    private var frameColor: Color {
        if showWarning { return .orange }
        if alignmentScore > 0.8 { return .green }
        if alignmentScore > 0.5 { return .yellow }
        return .red
    }
    
    var body: some View {
        ZStack {
            // Main frame
            RoundedRectangle(cornerRadius: 12)
                .stroke(frameColor, lineWidth: 3)
                .frame(width: targetBounds.width, height: targetBounds.height)
                .position(x: targetBounds.midX, y: targetBounds.midY)
            
            // Horizontal level indicator (Apple-style)
            HorizontalLevelIndicator(
                offset: rollOffset,
                color: frameColor,
                width: targetBounds.width * 0.6
            )
            .position(x: targetBounds.midX, y: targetBounds.midY)
            
            // Vertical level indicator for pitch
            VerticalLevelIndicator(
                offset: pitchOffset,
                color: frameColor,
                height: targetBounds.height * 0.6
            )
            .position(x: targetBounds.midX, y: targetBounds.midY)
            
            // Corner markers for better visibility
            ForEach(0..<4) { index in
                Circle()
                    .fill(frameColor)
                    .frame(width: 8, height: 8)
                    .position(cornerPosition(for: index))
            }
        }
    }
    
    private func cornerPosition(for index: Int) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: targetBounds.minX, y: targetBounds.minY)
        case 1: return CGPoint(x: targetBounds.maxX, y: targetBounds.minY)
        case 2: return CGPoint(x: targetBounds.maxX, y: targetBounds.maxY)
        case 3: return CGPoint(x: targetBounds.minX, y: targetBounds.maxY)
        default: return .zero
        }
    }
}

// MARK: - Apple-Style Level Components
struct HorizontalLevelIndicator: View {
    let offset: CGFloat
    let color: Color
    let width: CGFloat
    
    var body: some View {
        ZStack {
            // Fixed center line
            Rectangle()
                .fill(color.opacity(0.3))
                .frame(width: width, height: 1)
            
            // Moving indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 30, height: 2)
                
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
            }
            .offset(x: max(-width/2 + 20, min(width/2 - 20, offset)))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: offset)
        }
    }
}

struct VerticalLevelIndicator: View {
    let offset: CGFloat
    let color: Color
    let height: CGFloat
    
    var body: some View {
        ZStack {
            // Fixed center line
            Rectangle()
                .fill(color.opacity(0.3))
                .frame(width: 1, height: height)
            
            // Moving indicator
            VStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 2, height: 30)
                
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
            }
            .offset(y: max(-height/2 + 20, min(height/2 - 20, offset)))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: offset)
        }
    }
}

// MARK: - Translation Edge Indicators
struct TranslationEdgeIndicators: View {
    let directions: GuidanceDirections
    let screenSize: CGSize
    
    var body: some View {
        ZStack {
            // Top edge (move up)
            if directions.moveUp > 0.1 {
                EdgeBar(magnitude: directions.moveUp, edge: .top, screenSize: screenSize)
            }
            
            // Bottom edge (move down)
            if directions.moveDown > 0.1 {
                EdgeBar(magnitude: directions.moveDown, edge: .bottom, screenSize: screenSize)
            }
            
            // Left edge (move left)
            if directions.moveLeft > 0.1 {
                EdgeBar(magnitude: directions.moveLeft, edge: .left, screenSize: screenSize)
            }
            
            // Right edge (move right)
            if directions.moveRight > 0.1 {
                EdgeBar(magnitude: directions.moveRight, edge: .right, screenSize: screenSize)
            }
        }
    }
}

struct EdgeBar: View {
    let magnitude: Float
    let edge: Edge
    let screenSize: CGSize
    
    enum Edge {
        case top, bottom, left, right
    }
    
    private var barLength: CGFloat {
        let maxLength: CGFloat = edge == .top || edge == .bottom ? screenSize.width * 0.3 : screenSize.height * 0.3
        return maxLength * min(CGFloat(magnitude) / 2.0, 1.0) // Scale based on magnitude
    }
    
    var body: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [Color.blue, Color.blue.opacity(0)],
                startPoint: gradientStart,
                endPoint: gradientEnd
            ))
            .frame(
                width: edge == .left || edge == .right ? 8 : barLength,
                height: edge == .top || edge == .bottom ? 8 : barLength
            )
            .position(edgePosition)
            .animation(.easeInOut(duration: 0.3), value: magnitude)
    }
    
    private var gradientStart: UnitPoint {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }
    
    private var gradientEnd: UnitPoint {
        switch edge {
        case .top: return .bottom
        case .bottom: return .top
        case .left: return .trailing
        case .right: return .leading
        }
    }
    
    private var edgePosition: CGPoint {
        switch edge {
        case .top: return CGPoint(x: screenSize.width / 2, y: 4)
        case .bottom: return CGPoint(x: screenSize.width / 2, y: screenSize.height - 4)
        case .left: return CGPoint(x: 4, y: screenSize.height / 2)
        case .right: return CGPoint(x: screenSize.width - 4, y: screenSize.height / 2)
        }
    }
}

// MARK: - Safety Warning Overlay
struct SafetyWarningOverlay: View {
    let warnings: [MovementSafeguards.SafetyWarning]
    @State private var showWarnings = true
    
    var body: some View {
        VStack {
            if showWarnings {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(warnings.prefix(3).enumerated()), id: \.offset) { _, warning in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            
                            Text(warning.message)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.8))
                        )
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation {
                            showWarnings = false
                        }
                    }
                }
            }
            
            Spacer()
        }
        .padding(.top, 100)
    }
}

