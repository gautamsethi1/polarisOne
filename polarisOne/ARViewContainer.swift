import SwiftUI
import UIKit // UIActivityViewController, UIImage
import ARKit // plane / body / mesh detection
import RealityKit // ARView, debug overlays
import ModelIO // USDZ export helpers
import Metal // For MTLVertexFormat
import MetalKit // MTKMeshBufferAllocator
import Foundation // URL, Date, FileManager
import simd // simd_float4x4
import Combine
import AVFoundation // Added for AVCaptureDevice
import Vision // For ML-based human detection

struct ARViewContainer: UIViewRepresentable {
  @ObservedObject var viewModel: ARViewModel
  @ObservedObject var boxVM: BoxPlacementViewModel

  func makeUIView(context: Context) -> ARView {
    let view = ARView(frame: .zero)
    ARMeshExporter.arView = view
    context.coordinator.arView = view
    view.session.delegate = context.coordinator

    context.coordinator.fetchInitialCameraFOV()

    if ARBodyTrackingConfiguration.isSupported {
      let configuration = ARBodyTrackingConfiguration()
      configuration.automaticSkeletonScaleEstimationEnabled = true
      configuration.planeDetection = [.horizontal]
      configuration.isLightEstimationEnabled = true // Enable light estimation
      view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
      DispatchQueue.main.async {
        self.viewModel.bodyTrackingHint = "Body Tracking Active"
        self.viewModel.isBodyTrackingActive = true
        ARMeshExporter.hasMesh = false
      }
      print("✅ ARBodyTrackingConfiguration enabled.")
    } else {
      DispatchQueue.main.async {
        self.viewModel.bodyTrackingHint = "ARBodyTracking Not Supported. Limited features."
        self.viewModel.isBodyTrackingActive = false
      }
      print("⚠️ ARBodyTrackingConfiguration not supported. Falling back to WorldTracking.")
      let configuration = ARWorldTrackingConfiguration()
      configuration.planeDetection = [.horizontal]
      configuration.sceneReconstruction = .mesh
      configuration.isLightEstimationEnabled = true // Enable light estimation
      view.session.run(configuration)
      ARMeshExporter.hasMesh = true
    }
    let coach = ARCoachingOverlayView()
    coach.session = view.session
    coach.goal = .tracking
    coach.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    coach.frame = view.bounds
    view.addSubview(coach)
    return view
  }

  func updateUIView(_ uiView: ARView, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(vm: viewModel, boxVM: boxVM)
  }

  final class Coordinator: NSObject, ARSessionDelegate {
    private var vm: ARViewModel
    private var boxVM: BoxPlacementViewModel
    weak var arView: ARView?
    private var currentBodyAnchor: ARBodyAnchor?
    private var currentARFrame: ARFrame?
    private var cancellables: Set<AnyCancellable> = []
    private var boxAnchors: [UUID: AnchorEntity] = [:]
    
    // Smoothing buffers for measurements
    private var distanceBuffer: [Float] = []
    private var heightBuffer: [Float] = []
    private let bufferSize = 3 // Reduced for more responsive updates
    
    // Validation cache for fast human detection
    private var validationCache: [UUID: Bool] = [:]
     
    init(vm: ARViewModel, boxVM: BoxPlacementViewModel) {
      self.vm = vm
      self.boxVM = boxVM
      super.init()
      boxVM.$boxes.sink { [weak self] boxes in self?.syncBoxes(boxes) }.store(in: &cancellables)
      print("Coordinator Initialized")
    }
      
    func fetchInitialCameraFOV() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Accessing AVCaptureDevice directly for ARKit's active format is not straightforward.
            // This is a best-effort attempt; ARKit might use different settings.
            // For a more accurate FOV used by ARKit, one might need to rely on camera intrinsics
            // or other ARFrame properties if available and convert them.
            // `AVCaptureDevice.activeFormat.videoFieldOfView` gives the FoV for the *current* active format
            // of the default video device, which ARKit *likely* uses or configures similarly.
            if let device = AVCaptureDevice.default(for: .video) {
                let fov = device.activeFormat.videoFieldOfView // This is Float
                DispatchQueue.main.async {
                    self.vm.fieldOfViewHorizontalDeg = fov
                }
            } else {
                DispatchQueue.main.async {
                    self.vm.fieldOfViewHorizontalDeg = nil
                }
            }
        }
    }

      
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
      currentARFrame = frame
      calculateGeneralCameraHeight(cameraTransform: frame.camera.transform, frame: frame)
      
      // Update camera orientation (eulerAngles are in radians: pitch, yaw, roll)
      let eulerAngles = frame.camera.eulerAngles
      let newPitchRad = eulerAngles.x // Pitch around X-axis
      let newYawRad = eulerAngles.y   // Yaw around Y-axis
      let newRollRad = eulerAngles.z  // Roll around Z-axis

      // Update light estimates
      var newAmbientLux: Float? = nil
      var newColorTempK: Float? = nil
      if let lightEstimate = frame.lightEstimate {
          // CORRECTED: Cast CGFloat to Float
          newAmbientLux = Float(lightEstimate.ambientIntensity)
          newColorTempK = Float(lightEstimate.ambientColorTemperature)
      }
      
      // Enhanced subject detection combining ARKit and Vision
      updateSubjectDetection(frame: frame)

      DispatchQueue.main.async {
          // Update ViewModel properties if they changed
          // Values are stored in radians in VM, converted to degrees in computed string
          if self.vm.cameraPitch != newPitchRad { self.vm.cameraPitch = newPitchRad }
          if self.vm.cameraYaw != newYawRad { self.vm.cameraYaw = newYawRad }
          if self.vm.cameraRoll != newRollRad { self.vm.cameraRoll = newRollRad }
          
          if self.vm.ambientIntensityLux != newAmbientLux { self.vm.ambientIntensityLux = newAmbientLux }
          if self.vm.ambientColorTemperatureKelvin != newColorTempK { self.vm.ambientColorTemperatureKelvin = newColorTempK }
      }

      guard let bodyAnchor = self.currentBodyAnchor, vm.isBodyTrackingActive else {
        if vm.detectedSubjectCount > 0 && vm.isBodyTrackingActive {
            DispatchQueue.main.async {
                self.vm.detectedSubjectCount = 0
                self.vm.distanceToPerson = "Looking for humans..."
                self.vm.cameraHeightRelativeToEyes = "Eyes: N/A"
                self.vm.visibleBodyPartsInfo = "Visible Parts: N/A"
            }
            // Clear smoothing buffers when tracking is lost
            distanceBuffer.removeAll()
        } else if !vm.isBodyTrackingActive {
            DispatchQueue.main.async {
                self.vm.distanceToPerson = "Body tracking N/A"
                self.vm.cameraHeightRelativeToEyes = "Eyes: N/A"
                self.vm.visibleBodyPartsInfo = "Visible Parts: N/A"
            }
        }
        return
      }
      let cameraTransform = frame.camera.transform
      let cameraPosition = cameraTransform.translation
      
      // Calculate distance using multiple body joints for better accuracy
      var distances: [Float] = []
      
      // Try to get hip/root position (most stable)
      if let hipTransform = bodyAnchor.skeleton.modelTransform(for: .root) {
        let hipWorldPos = (bodyAnchor.transform * hipTransform).translation
        distances.append(simd_distance(cameraPosition, hipWorldPos))
      }
      
      // Also consider left and right shoulder for averaging (forms chest center)
      if let leftShoulderTransform = bodyAnchor.skeleton.modelTransform(for: .leftShoulder),
         let rightShoulderTransform = bodyAnchor.skeleton.modelTransform(for: .rightShoulder) {
        let leftShoulderPos = (bodyAnchor.transform * leftShoulderTransform).translation
        let rightShoulderPos = (bodyAnchor.transform * rightShoulderTransform).translation
        // Calculate chest center as midpoint between shoulders
        let chestCenter = SIMD3<Float>(
          (leftShoulderPos.x + rightShoulderPos.x) / 2,
          (leftShoulderPos.y + rightShoulderPos.y) / 2,
          (leftShoulderPos.z + rightShoulderPos.z) / 2
        )
        distances.append(simd_distance(cameraPosition, chestCenter))
      }
      
      // Fall back to body anchor transform if no joints available
      if distances.isEmpty {
        let bodyPosition = bodyAnchor.transform.translation
        distances.append(simd_distance(cameraPosition, bodyPosition))
      }
      
      // Average the distances for more stable measurement
      let averageDistance = distances.reduce(0, +) / Float(distances.count)
      
      // Add to smoothing buffer
      distanceBuffer.append(averageDistance)
      if distanceBuffer.count > bufferSize {
        distanceBuffer.removeFirst()
      }
      
      // Calculate smoothed distance
      let smoothedDistance = distanceBuffer.reduce(0, +) / Float(distanceBuffer.count)
      
      // Format distance with appropriate precision
      let distanceString: String
      if smoothedDistance < 1.0 {
        distanceString = String(format: "%.2f m", smoothedDistance) // More precision for close distances
      } else {
        distanceString = String(format: "%.1f m", smoothedDistance)
      }
      
      calculateCameraHeightRelativeToEyes(bodyAnchor: bodyAnchor, cameraTransform: cameraTransform)
      determineVisibleBodyParts(bodyAnchor: bodyAnchor, frame: frame)
      
      // Calculate subject bounds from ARKit body tracking
      if let subjectBounds = SubjectDetectionService.shared.calculateARSubjectBounds(from: bodyAnchor) {
        let updateWorldTrackingDataAndGuidance: () -> Void = { [weak self] () -> Void in
          guard let self = self else { return }
          self.vm.currentSubjectBounds = subjectBounds
          
          // Calculate subject-relative camera orientation
          if let frame = self.currentARFrame {
            self.vm.calculateSubjectRelativeOrientation(
              cameraTransform: frame.camera.transform,
              subjectCenter: subjectBounds.center
            )
          }
          
          // Update guidance for 2D overlay if active
          if self.vm.isGuidanceActive,
             let _ = self.arView,
             let currentFrame = self.currentARFrame {
            // Update 2D screen bounds for subject
            if let screenBounds = self.vm.convertToScreenBounds(worldBounds: subjectBounds, frame: currentFrame) {
              self.vm.guidanceSubjectScreenBounds = screenBounds
            }
            
            // Update target framing box position if guidance is active
            if let guidance = self.vm.latestStructuredGuidance {
              self.vm.calculateTargetFramingBox(subjectBounds: subjectBounds, guidance: guidance, frame: currentFrame)
            }
          }
        }
        
        DispatchQueue.main.async(execute: updateWorldTrackingDataAndGuidance)

      }
      
      DispatchQueue.main.async {
        // Always update for fresh values
        self.vm.distanceToPerson = distanceString
      }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { processAnchors(anchors, session: session, event: "Added") }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { processAnchors(anchors, session: session, event: "Updated") }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
      var bodyAnchorRemoved = false
      if let currentId = self.currentBodyAnchor?.identifier, anchors.contains(where: { $0.identifier == currentId }) {
        self.currentBodyAnchor = nil; bodyAnchorRemoved = true
        print("Tracked body anchor \(currentId) removed.")
      }
      
      // Clean up validation cache for removed anchors
      for anchor in anchors {
        validationCache.removeValue(forKey: anchor.identifier)
      }
      if let currentFrame = session.currentFrame {
         let bodyAnchorsInFrame = currentFrame.anchors.compactMap { $0 as? ARBodyAnchor }
         DispatchQueue.main.async {
           if self.vm.detectedSubjectCount != bodyAnchorsInFrame.count { self.vm.detectedSubjectCount = bodyAnchorsInFrame.count }
           if bodyAnchorRemoved && bodyAnchorsInFrame.isEmpty {
                self.vm.distanceToPerson = "Looking for humans..."; self.vm.cameraHeightRelativeToEyes = "Eyes: N/A"; self.vm.visibleBodyPartsInfo = "Visible Parts: N/A"
           } else if bodyAnchorRemoved && !bodyAnchorsInFrame.isEmpty {
               self.currentBodyAnchor = bodyAnchorsInFrame.first
               print("Switched to new body anchor: \(self.currentBodyAnchor?.identifier.uuidString ?? "None") after removal.")
           }
         }
      }
    }

    private func processAnchors(_ anchors: [ARAnchor], session: ARSession, event: String) {
      for anchor in anchors where anchor is ARMeshAnchor {
          print("----> Found MESH ANCHOR on \(event)")
          DispatchQueue.main.async { ARMeshExporter.hasMesh = true }
      }
      
      // Filter body anchors to only include validated humans
      let bodyAnchors = anchors.compactMap { $0 as? ARBodyAnchor }
      let validatedHumanAnchors = bodyAnchors.filter { validateHumanBody($0) }
      
      if !validatedHumanAnchors.isEmpty {
        print("----> Found \(validatedHumanAnchors.count) VALIDATED HUMAN(s) on \(event)!")
        if self.currentBodyAnchor == nil || !anchors.contains(where: { $0.identifier == self.currentBodyAnchor!.identifier }) {
          self.currentBodyAnchor = validatedHumanAnchors.first
           print("----> Now Tracking human body anchor: \(self.currentBodyAnchor!.identifier)")
        }
      }
      
      if let currentFrame = session.currentFrame {
         let allBodyAnchorsInFrame = currentFrame.anchors.compactMap { $0 as? ARBodyAnchor }
         let validatedHumansInFrame = allBodyAnchorsInFrame.filter { validateHumanBody($0) }
         
         DispatchQueue.main.async {
          if self.vm.detectedSubjectCount != validatedHumansInFrame.count {
            self.vm.detectedSubjectCount = validatedHumansInFrame.count
            print("----> Updated Human Subject Count: \(validatedHumansInFrame.count)")
          }
          if validatedHumansInFrame.isEmpty && self.currentBodyAnchor != nil {
              self.currentBodyAnchor = nil
              print("----> No validated human bodies in frame. Cleared currentBodyAnchor.")
          }
         }
      }
    }
    
    // Validate that a body anchor represents a real human - FAST & PRACTICAL
    private func validateHumanBody(_ bodyAnchor: ARBodyAnchor) -> Bool {
      // Trust ARKit completely - it already filters for humans
      let trustARKitCompletely = true
      
      if trustARKitCompletely {
        // ARKit body tracking only detects humans, so any body anchor is valid
        return true
      }
      
      // Optional validation (disabled by default for speed)
      // Cache validation results to avoid repeated checks
      if let cachedResult = validationCache[bodyAnchor.identifier] {
        return cachedResult
      }
      
      let skeleton = bodyAnchor.skeleton
      
      // Fast check: Just verify we have at least 2 joints
      var jointCount = 0
      let minJoints = 2
      
      // Check only the most important joints first
      if skeleton.modelTransform(for: .head) != nil { jointCount += 1 }
      if jointCount >= minJoints { 
        validationCache[bodyAnchor.identifier] = true
        return true 
      }
      
      if skeleton.modelTransform(for: .root) != nil { jointCount += 1 }
      if jointCount >= minJoints { 
        validationCache[bodyAnchor.identifier] = true
        return true 
      }
      
      if skeleton.modelTransform(for: .leftShoulder) != nil { jointCount += 1 }
      if jointCount >= minJoints { 
        validationCache[bodyAnchor.identifier] = true
        return true 
      }
      
      if skeleton.modelTransform(for: .rightShoulder) != nil { jointCount += 1 }
      
      let isValid = jointCount >= minJoints
      validationCache[bodyAnchor.identifier] = isValid
      
      if !isValid {
        print("Body validation failed: Only \(jointCount) joints tracked")
      }
      
      return isValid
    }

    func calculateCameraHeightRelativeToEyes(bodyAnchor: ARBodyAnchor, cameraTransform: matrix_float4x4) {
      // Try to get head joint first
      guard let headJointTransform = bodyAnchor.skeleton.modelTransform(for: .head) else {
        // Fallback: try to estimate from shoulders
        if let leftShoulderTransform = bodyAnchor.skeleton.modelTransform(for: .leftShoulder),
           let rightShoulderTransform = bodyAnchor.skeleton.modelTransform(for: .rightShoulder) {
          let leftShoulderPos = (bodyAnchor.transform * leftShoulderTransform).translation
          let rightShoulderPos = (bodyAnchor.transform * rightShoulderTransform).translation
          let shoulderCenter = SIMD3<Float>(
            (leftShoulderPos.x + rightShoulderPos.x) / 2,
            (leftShoulderPos.y + rightShoulderPos.y) / 2,
            (leftShoulderPos.z + rightShoulderPos.z) / 2
          )
          let cameraWorldPosition = cameraTransform.translation
          // Estimate eye position from shoulder center (typically ~25-30cm above shoulders)
          let estimatedEyeWorldY = shoulderCenter.y + 0.28
          let heightDifference = cameraWorldPosition.y - estimatedEyeWorldY
          let directionText = heightDifference > 0.05 ? "Above" : (heightDifference < -0.05 ? "Below" : "Level with")
          let text = String(format: "Eyes: Cam %.2fm %@ Subject", abs(heightDifference), directionText)
          DispatchQueue.main.async {
            // Always update for fresh values
            self.vm.cameraHeightRelativeToEyes = text
          }
          return
        }
        DispatchQueue.main.async { self.vm.cameraHeightRelativeToEyes = "Eyes: Head Joint N/A" }
        return
      }
      
      let headWorldTransform = bodyAnchor.transform * headJointTransform
      let headWorldPosition = headWorldTransform.translation
      let cameraWorldPosition = cameraTransform.translation
      
      // More accurate eye offset estimation based on head joint
      // Head joint is typically at the center of the head, eyes are ~5-8cm below and forward
      let estimatedEyeYOffset: Float = -0.07 // Refined offset from head joint center to eye level
      let estimatedEyeWorldY = headWorldPosition.y + estimatedEyeYOffset
      
      let heightDifference = cameraWorldPosition.y - estimatedEyeWorldY
      let directionText: String
      if abs(heightDifference) < 0.05 {
        directionText = "Level with"
      } else if heightDifference > 0 {
        directionText = "Above"
      } else {
        directionText = "Below"
      }
      
      let text = String(format: "Eyes: Cam %.2fm %@ Subject", abs(heightDifference), directionText)
      DispatchQueue.main.async {
        // Always update for fresh values
        self.vm.cameraHeightRelativeToEyes = text
      }
    }

    func calculateGeneralCameraHeight(cameraTransform: matrix_float4x4, frame: ARFrame) {
        let cameraWorldY = cameraTransform.translation.y
        var text: String
        
        // Simple approach - find the lowest horizontal plane (floor or table)
        let floorPlanes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal && ($0.classification == .floor || $0.classification == .table) }
        
        if let floorPlane = floorPlanes.min(by: { abs($0.transform.translation.y) < abs($1.transform.translation.y) }) {
            let height = cameraWorldY - floorPlane.transform.translation.y
            if height < -0.1 {
                text = String(format: "Cam Height: %.2fm (Low?)", height)
            } else {
                text = String(format: "Cam Height: %.2fm (\(floorPlane.classification == .floor ? "Floor" : "Table"))", height)
            }
        } else {
            // No classified floor/table, try any horizontal plane
            let horizontalPlanes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
                .filter { $0.alignment == .horizontal }
            
            if let anyHorizontalPlane = horizontalPlanes.min(by: { abs($0.transform.translation.y) < abs($1.transform.translation.y) }) {
                let height = cameraWorldY - anyHorizontalPlane.transform.translation.y
                if height < -0.1 {
                    text = String(format: "Cam Height: %.2fm (Plane - Low?)", height)
                } else {
                    text = String(format: "Cam Height: %.2fm (Plane)", height)
                }
            } else {
                // No planes detected, height relative to origin
                text = String(format: "Cam Height: %.2fm (Origin)", cameraWorldY)
            }
        }
        
        DispatchQueue.main.async {
            // Always update to ensure fresh values
            self.vm.generalCameraHeight = text
        }
    }

    func determineVisibleBodyParts(bodyAnchor: ARBodyAnchor, frame: ARFrame) {
      guard let arView = self.arView else { DispatchQueue.main.async { self.vm.visibleBodyPartsInfo = "Visible Parts: ARView N/A" }; return }
      var visibleJointsDescriptions: [String] = []
      let jointsOfInterest: [ARKit.ARSkeleton.JointName] = [.head, .leftShoulder, .leftHand, .rightShoulder, .rightHand, .leftFoot, .rightFoot, .root] // .root is hip/pelvis area
      for jointName in jointsOfInterest {
        guard let jointModelTransform = bodyAnchor.skeleton.modelTransform(for: jointName) else { continue }
        let jointWorldPosition = (bodyAnchor.transform * jointModelTransform).translation
        
        // Project point to screen space
        if let screenPoint = arView.project(jointWorldPosition) {
          // Check if point is in front of camera (z < 0 in camera space) and within screen bounds
          let pointInCameraSpace = frame.camera.transform.inverse * SIMD4<Float>(jointWorldPosition.x, jointWorldPosition.y, jointWorldPosition.z, 1.0)
          if pointInCameraSpace.z < 0 && // Point is in front of the camera
             screenPoint.x >= arView.bounds.minX && screenPoint.x <= arView.bounds.maxX &&
             screenPoint.y >= arView.bounds.minY && screenPoint.y <= arView.bounds.maxY { // Point is within screen bounds
            visibleJointsDescriptions.append(jointName.rawValue.replacingOccurrences(of: "_joint", with: "").replacingOccurrences(of: "_", with: " ").capitalizedFirst())
          }
        }
      }
      let text = !visibleJointsDescriptions.isEmpty ? "Visible: " + visibleJointsDescriptions.prefix(5).joined(separator: ", ") + (visibleJointsDescriptions.count > 5 ? "..." : "") : (vm.detectedSubjectCount > 0 ? "Visible Parts: Subject Occluded/Out of View" : "Visible Parts: N/A")
      DispatchQueue.main.async {
        // Always update for fresh values
        self.vm.visibleBodyPartsInfo = text
      }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
      print("❌ AR Session Failed: \(error.localizedDescription)")
      DispatchQueue.main.async { self.vm.bodyTrackingHint = "AR Session Failed: \(error.localizedDescription.prefix(50))" }
    }
    func sessionWasInterrupted(_ session: ARSession) {
      print("⏸️ AR Session Interrupted")
      DispatchQueue.main.async { self.vm.bodyTrackingHint = "AR Session Interrupted. Trying to resume..." }
    }
    func sessionInterruptionEnded(_ session: ARSession) {
      print("▶️ AR Session Interruption Ended. Resetting session.")
      if let configuration = session.configuration {
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.async {
          self.vm.bodyTrackingHint = self.vm.isBodyTrackingActive ? "Body Tracking Active" : "World Tracking Active"
          self.vm.distanceToPerson = "Looking for subjects..."
          self.fetchInitialCameraFOV() // Re-fetch FOV as session restarted
        }
      } else { DispatchQueue.main.async { self.vm.bodyTrackingHint = "Session resumed, but config lost." } }
    }
    
    // Enhanced subject detection combining ARKit and Vision
    private func updateSubjectDetection(frame: ARFrame) {
        // Get ARKit body tracking bounds if available  
        var arSubjectBounds: SubjectBounds? = nil
        if let bodyAnchor = currentBodyAnchor, validateHumanBody(bodyAnchor) {
            arSubjectBounds = SubjectDetectionService.shared.calculateARSubjectBounds(from: bodyAnchor)
        } else if currentBodyAnchor != nil {
            // Clear invalid body anchor
            currentBodyAnchor = nil
            print("Cleared invalid body anchor in updateSubjectDetection")
        }
        
        // Perform Vision-based detection (throttled to avoid performance issues)
        if frame.timestamp.truncatingRemainder(dividingBy: 0.5) < 0.1 { // Run every ~0.5 seconds
            SubjectDetectionService.shared.detectHumanSubjects(
                in: frame.capturedImage,
                cameraTransform: frame.camera.transform
            ) { [weak self] visionBounds in
                guard let self = self else { return }
                
                // Combine ARKit and Vision data
                let hybridBounds = SubjectDetectionService.shared.hybridSubjectDetection(
                    arBounds: arSubjectBounds,
                    visionBounds: visionBounds
                )
                
                DispatchQueue.main.async {
                    self.vm.currentSubjectBounds = hybridBounds
                    
                    // Update guidance box if active and subject moved significantly
                    if let bounds = hybridBounds,
                       let activeGuidance = self.vm.activeGuidanceBox,
                       self.vm.isGuidanceActive {
                        
                        // Check if subject moved significantly (>10cm)
                        let movement = simd_distance(bounds.center, activeGuidance.targetPosition)
                        if movement > 0.1, let guidance = self.vm.latestStructuredGuidance {
                            // Update guidance box position
                            self.vm.activateGuidanceBox(for: guidance, subjectBounds: bounds)
                        }
                    }
                }
            }
        } else if let arBounds = arSubjectBounds {
            // Update with ARKit-only data when not running Vision
            DispatchQueue.main.async {
                self.vm.currentSubjectBounds = arBounds
            }
        }
    }
    
    private func syncBoxes(_ boxes: [PlacedBox]) { /* ... (Existing box syncing logic can be added here) ... */ }
  }
}