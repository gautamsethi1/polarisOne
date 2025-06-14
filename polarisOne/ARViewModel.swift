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

final class ARViewModel: ObservableObject {
  @Published var shareURL: URL?
  @Published var distanceToPerson: String = "Looking for subjects..."
  @Published var detectedSubjectCount: Int = 0

  @Published var cameraHeightRelativeToEyes: String = "Eyes: N/A"
  @Published var generalCameraHeight: String = "Cam Height: N/A"
  @Published var visibleBodyPartsInfo: String = "Visible Parts: N/A"
  @Published var bodyTrackingHint: String = ""
  @Published var isBodyTrackingActive: Bool = false

  @Published var isCapturing: Bool = false
  @Published var showResponses: Bool = false

  @Published var selectedReferenceImage: ReferenceImage? = nil
  @Published var generatedImage: UIImage?
  @Published var isGeneratingPhoto: Bool = false

  
  // --- Settings ---
  @Published var showDetailedMetrics: Bool = true
  @Published var showSettings: Bool = false

  // --- New Camera/Scene Properties ---
  @Published var cameraRoll: Float?
  @Published var cameraPitch: Float?
  @Published var cameraYaw: Float?
  @Published var fieldOfViewHorizontalDeg: Float?
  @Published var ambientIntensityLux: Float?
  @Published var ambientColorTemperatureKelvin: Float?
  
  // Subject-relative camera angles
  @Published var subjectRelativePitch: Float? // Angle from horizontal plane through subject
  @Published var subjectRelativeYaw: Float?   // Angle from front-facing subject direction

  // Computed properties for display strings
  var cameraOrientationDegString: String {
    guard let roll = cameraRoll, let pitch = cameraPitch, let yaw = cameraYaw else { return "Orientation: N/A" }
    // ARCamera.eulerAngles provides: pitch (around X), yaw (around Y), roll (around Z).
    // Standard display order is often Roll, Pitch, Yaw.
    // Note: Negating roll to match expected convention (positive roll = clockwise when looking forward)
    return String(format: "R:%.0f° P:%.0f° Y:%.0f°", -roll * 180 / .pi, pitch * 180 / .pi, yaw * 180 / .pi)
  }
  var fieldOfViewDegString: String {
    guard let fov = fieldOfViewHorizontalDeg else { return "FOV H: N/A" }
    return String(format: "FOV H: %.1f°", fov)
  }
  var ambientLuxString: String {
    guard let lux = ambientIntensityLux else { return "Lux: N/A" }
    return String(format: "Lux: %.0f", lux)
  }
  var colorTempKString: String {
    guard let temp = ambientColorTemperatureKelvin else { return "Color K: N/A" }
    return String(format: "Color K: %.0f", temp)
  }
  
  var subjectRelativeOrientationString: String {
    guard let pitch = subjectRelativePitch, let yaw = subjectRelativeYaw else { return "Subject Angles: N/A" }
    return String(format: "P:%.0f° Y:%.0f°", pitch * 180 / .pi, yaw * 180 / .pi)
  }
  
  // Store the latest structured response for potential UI use
  @Published var latestStructuredGuidance: StructuredGeminiResponse? = nil
  
  // Subject detection and guidance state
  @Published var currentSubjectBounds: SubjectBounds? = nil
  @Published var activeGuidanceBox: GuidanceBox? = nil
  @Published var isGuidanceActive: Bool = false
  @Published var guidanceSubjectScreenBounds: CGRect = .zero  // 2D screen bounds of current subject position
  @Published var guidanceTargetScreenBounds: CGRect = .zero   // 2D screen bounds of target framing box
  @Published var guidanceDirections: GuidanceDirections = GuidanceDirections()
  @Published var guidanceAlignmentScore: Float = 0.0
  
  // Performance metrics
  @Published var performanceMetrics: [PerformanceMetric] = []
  @Published var safetyWarnings: [MovementSafeguards.SafetyWarning] = []
  
  private let performanceMetricsKey = "ARViewModelPerformanceMetrics"

  // var APIService = APIService()
  
  init() {
    loadPerformanceMetrics()
  }
  
  func savePerformanceMetrics() {
    if let encoded = try? JSONEncoder().encode(performanceMetrics) {
      UserDefaults.standard.set(encoded, forKey: performanceMetricsKey)
    }
  }
  
  func loadPerformanceMetrics() {
    if let data = UserDefaults.standard.data(forKey: performanceMetricsKey),
       let metrics = try? JSONDecoder().decode([PerformanceMetric].self, from: data) {
      performanceMetrics = metrics
    }
  }
  
  func clearPerformanceMetrics() {
    performanceMetrics = []
    UserDefaults.standard.removeObject(forKey: performanceMetricsKey)
  }
  
  // Calculate camera orientation relative to subject
  func calculateSubjectRelativeOrientation(cameraTransform: matrix_float4x4, subjectCenter: SIMD3<Float>) {
    let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
    
    // Vector from camera to subject
    let toSubject = subjectCenter - cameraPosition
    let horizontalDistance = sqrt(toSubject.x * toSubject.x + toSubject.z * toSubject.z)
    
    // Calculate pitch: angle from horizontal plane
    // Positive pitch = camera looking down, negative = looking up
    if horizontalDistance > 0.01 {
      let pitchRad = atan2(-toSubject.y, horizontalDistance)
      subjectRelativePitch = pitchRad
    }
    
    // Calculate yaw: horizontal angle from camera to subject
    // 0° = subject directly in front, positive = subject to the right
    let yawRad = atan2(toSubject.x, -toSubject.z)
    subjectRelativeYaw = yawRad
  }



  private func getFinalCameraHeightForPrompt() -> (stringValue: String, numericValue: Double?) {
      var cameraHeightStringValue: String = "N/A"
      var numericHeightValue: Double? = nil
      let fullHeightString = generalCameraHeight
      if fullHeightString.lowercased().contains("n/a") {
          cameraHeightStringValue = "N/A"
      } else {
          let components = fullHeightString.components(separatedBy: .whitespaces)
          if components.count >= 3 {
              let heightPart = components[2]
              let numericString = heightPart.replacingOccurrences(of: "m", with: "")
              if let numValue = Double(numericString) {
                  cameraHeightStringValue = numericString
                  numericHeightValue = numValue
              }
          }
      }
      var finalPromptString = cameraHeightStringValue
      if let numHeight = numericHeightValue, numHeight < -0.05 {
          if generalCameraHeight.lowercased().contains("low?") {
              finalPromptString = "\(cameraHeightStringValue)m (potentially low)"
          } else if numHeight < -0.19 && generalCameraHeight.lowercased().contains("origin") {
              finalPromptString = "approx. 0m (origin likely high or detection issue)"
          } else {
              finalPromptString = "\(cameraHeightStringValue)m"
          }
      } else if cameraHeightStringValue == "N/A" {
          finalPromptString = "unknown (AR not ready)"
      } else if numericHeightValue != nil {
           finalPromptString = "\(cameraHeightStringValue)m"
      }
      return (finalPromptString, numericHeightValue)
  }
  
  func capturePhotoWithMetrics() {
    guard let arView = ARMeshExporter.arView else {
      self.bodyTrackingHint = "AR system not ready for capture."
      return
    }
    
    isCapturing = true
    
    // Capture current AR view
    let renderer = UIGraphicsImageRenderer(size: arView.bounds.size)
    let capturedImage = renderer.image { ctx in
      arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
    }
    
    // Get current metrics
    let (finalCameraHeightForPrompt, _) = getFinalCameraHeightForPrompt()
    let distanceStringValue = distanceToPerson.components(separatedBy: " ")[0]
    
    // Extract eyeline distance from cameraHeightRelativeToEyes
    var eyelineDistance = ""
    if cameraHeightRelativeToEyes.contains("Cam") && cameraHeightRelativeToEyes.contains("m") {
      let components = cameraHeightRelativeToEyes.components(separatedBy: " ")
      if components.count >= 3 {
        eyelineDistance = components[2].replacingOccurrences(of: "m", with: "")
      }
    }
    
    // Create metadata with all current metrics
    let metadata = ReferenceImageMetadata(
      distanceFromCamera: distanceStringValue,
      distanceBelowEyeline: eyelineDistance,
      cameraHeight: finalCameraHeightForPrompt.replacingOccurrences(of: "m", with: "").replacingOccurrences(of: " (unknown AR not ready)", with: ""),
      cameraHeightRelativeToEyes: cameraHeightRelativeToEyes,
      visibleBodyParts: visibleBodyPartsInfo,
      detectedSubjectCount: "\(detectedSubjectCount)",
      cameraRollDeg: cameraRoll != nil ? String(format: "%.1f", -cameraRoll! * 180 / .pi) : "N/A",
      cameraPitchDeg: cameraPitch != nil ? String(format: "%.1f", cameraPitch! * 180 / .pi) : "N/A",
      cameraYawDeg: cameraYaw != nil ? String(format: "%.1f", cameraYaw! * 180 / .pi) : "N/A",
      subjectRelativePitchDeg: subjectRelativePitch != nil ? String(format: "%.1f", subjectRelativePitch! * 180 / .pi) : "N/A",
      subjectRelativeYawDeg: subjectRelativeYaw != nil ? String(format: "%.1f", subjectRelativeYaw! * 180 / .pi) : "N/A",
      cameraFOVHDeg: fieldOfViewHorizontalDeg != nil ? String(format: "%.1f", fieldOfViewHorizontalDeg!) : "N/A",
      ambientLux: ambientIntensityLux != nil ? String(format: "%.0f", ambientIntensityLux!) : "N/A",
      colorTempK: ambientColorTemperatureKelvin != nil ? String(format: "%.0f", ambientColorTemperatureKelvin!) : "N/A",
      captureDate: Date()
    )
    
    // Save to reference images
    if let savedRef = ReferenceImageManager.shared.saveImage(capturedImage, metadata: metadata) {
      DispatchQueue.main.async {
        self.selectedReferenceImage = savedRef
        self.bodyTrackingHint = "Photo captured with metrics and saved to library"
        self.isCapturing = false
        
        // Notify reference view model to reload if it exists
        NotificationCenter.default.post(name: Notification.Name("RefreshReferenceImages"), object: nil)
      }
    } else {
      DispatchQueue.main.async {
        self.bodyTrackingHint = "Failed to save captured photo"
        self.isCapturing = false
      }
    }
  }
  
  func analyzeScene() {
    guard let arView = ARMeshExporter.arView else {
      self.bodyTrackingHint = "AR system not ready."
      return
    }
    
    isCapturing = true
    
    // Start performance tracking
    let startTime = Date()
    var currentMetric = PerformanceMetric(timestamp: startTime)
    
    // Capture current AR view
    let renderer = UIGraphicsImageRenderer(size: arView.bounds.size)
    let currentImage = renderer.image { ctx in
      arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
    }
    
    // Get reference image if available
    let referenceImage: UIImage
    let hasReference = selectedReferenceImage?.image != nil
    
    if let refImageContainer = selectedReferenceImage, let refImage = refImageContainer.image {
      referenceImage = refImage
    } else {
      // Use current image as both reference and current if no reference is set
      referenceImage = currentImage
    }
    
    // Prepare metrics
    let (finalCameraHeightForPrompt, _) = getFinalCameraHeightForPrompt()
    let distanceStringValue = distanceToPerson.components(separatedBy: " ")[0]
    
    let rollDeg = cameraRoll != nil ? String(format: "%.1f", -cameraRoll! * 180 / .pi) : "N/A"
    let pitchDeg = cameraPitch != nil ? String(format: "%.1f", cameraPitch! * 180 / .pi) : "N/A"
    let yawDeg = cameraYaw != nil ? String(format: "%.1f", cameraYaw! * 180 / .pi) : "N/A"
    let orientationPrompt = "R:\(rollDeg)°, P:\(pitchDeg)°, Y:\(yawDeg)°"
    
    // Subject-relative angles
    let subjectPitchDeg = subjectRelativePitch != nil ? String(format: "%.1f", subjectRelativePitch! * 180 / .pi) : "N/A"
    let subjectYawDeg = subjectRelativeYaw != nil ? String(format: "%.1f", subjectRelativeYaw! * 180 / .pi) : "N/A"
    let subjectOrientationPrompt = "P:\(subjectPitchDeg)°, Y:\(subjectYawDeg)°"
    
    var currentMetrics: [String: String] = [
        "distance_to_person_meters": distanceStringValue,
        "camera_height_meters": finalCameraHeightForPrompt,
        "camera_height_raw_string": generalCameraHeight,
        "camera_height_relative_to_eyes": cameraHeightRelativeToEyes,
        "visible_body_parts": visibleBodyPartsInfo,
        "detected_subject_count": "\(detectedSubjectCount)",
        "camera_roll_deg": rollDeg,
        "camera_pitch_deg": pitchDeg,
        "camera_yaw_deg": yawDeg,
        "subject_relative_pitch_deg": subjectPitchDeg,
        "subject_relative_yaw_deg": subjectYawDeg,
        "camera_fov_h_deg": fieldOfViewHorizontalDeg != nil ? String(format: "%.1f", fieldOfViewHorizontalDeg!) : "N/A",
        "ambient_lux": ambientIntensityLux != nil ? String(format: "%.0f", ambientIntensityLux!) : "N/A",
        "color_temp_k": ambientColorTemperatureKelvin != nil ? String(format: "%.0f", ambientColorTemperatureKelvin!) : "N/A"
    ]
    
    // Build prompt based on whether we have a reference image
    let prompt: String
    
    if hasReference, let refImageContainer = selectedReferenceImage {
      // We have a reference image - provide comparison guidance
      let refMeta = refImageContainer.metadata
      let distCam = refMeta.distanceFromCamera.isEmpty ? "N/A" : "\(refMeta.distanceFromCamera)m"
      let camHeight = refMeta.cameraHeight.isEmpty ? "N/A" : "\(refMeta.cameraHeight)m"
      let belowEyeline = refMeta.distanceBelowEyeline.isEmpty ? "N/A" : "\(refMeta.distanceBelowEyeline)m (camera below subject's eyes)"
      
      let photo1Details = """
      - Subject distance from camera: \(distCam)
      - Camera height: \(camHeight)
      - Camera position relative to subject's eyeline: \(belowEyeline)
      - Visible body parts: \(refMeta.visibleBodyParts.isEmpty ? "N/A" : refMeta.visibleBodyParts)
      - Detected subject count: \(refMeta.detectedSubjectCount.isEmpty ? "N/A" : refMeta.detectedSubjectCount)
      - Camera Orientation (Roll, Pitch, Yaw): R:\(refMeta.cameraRollDeg)°, P:\(refMeta.cameraPitchDeg)°, Y:\(refMeta.cameraYawDeg)°
      - Subject-Relative Camera Angles (Pitch, Yaw): P:\(refMeta.subjectRelativePitchDeg)°, Y:\(refMeta.subjectRelativeYawDeg)°
      - Camera Horizontal FOV: \(refMeta.cameraFOVHDeg.isEmpty ? "N/A" : "\(refMeta.cameraFOVHDeg)°")
      - Ambient Light: \(refMeta.ambientLux.isEmpty ? "N/A" : "\(refMeta.ambientLux) lux")
      - Color Temperature: \(refMeta.colorTempK.isEmpty ? "N/A" : "\(refMeta.colorTempK)K")
      """
      
      let photo2Details = """
      - Subject distance from camera: \(distanceStringValue.isEmpty ? "N/A" : "\(distanceStringValue)m")
      - Camera height: \(finalCameraHeightForPrompt)
      - Camera height relative to subject's eyes: \(cameraHeightRelativeToEyes)
      - Visible body parts: \(visibleBodyPartsInfo)
      - Detected subject count: \(detectedSubjectCount)
      - Camera Orientation (Roll, Pitch, Yaw): \(orientationPrompt)
      - Subject-Relative Camera Angles (Pitch, Yaw): \(subjectOrientationPrompt)
      - Camera Horizontal FOV: \(self.fieldOfViewDegString)
      - Ambient Light: \(self.ambientLuxString)
      - Color Temperature: \(self.colorTempKString)
      """
      
      prompt = """
      You are an expert photography assistant specializing in portrait composition and framing. Your goal is to help adjust the camera to achieve the same composition, framing, and perspective as a reference photo.

      I will provide two images:
      1. Photo 1: The reference image showing the desired composition
      2. Photo 2: The current live camera view that needs adjustment

      Reference Photo Details (Photo 1):
      \(photo1Details)

      Current Scene Details (Photo 2):
      \(photo2Details)

      Analyze the composition differences between the photos, focusing on:
      - Subject positioning within the frame (rule of thirds, golden ratio)
      - Amount of space around the subject (headroom, lead room)
      - Subject size relative to frame
      - Camera angle and perspective
      - Overall framing and composition balance

      Provide camera movement instructions to match Photo 1's composition.
      
      IMPORTANT: Respond ONLY with valid JSON in the following exact format:
      
      {
        "adjustments": {
          "translation": {
            "x": {
              "direction": "left|right|no change",
              "magnitude": 0.5,
              "unit": "m"
            },
            "y": {
              "direction": "up|down|no change",
              "magnitude": 0.2,
              "unit": "m"
            },
            "z": {
              "direction": "forward|back|no change",
              "magnitude": 1.0,
              "unit": "m"
            }
          },
          "rotation": {
            "yaw": {
              "direction": "left|right|no change",
              "magnitude": 15,
              "unit": "deg"
            },
            "pitch": {
              "direction": "up|down|no change",
              "magnitude": 5,
              "unit": "deg"
            },
            "roll": {
              "direction": "clockwise|counter-clockwise|no change",
              "magnitude": 0,
              "unit": "deg"
            }
          },
          "framing": {
            "subject_position": "center|left_third|right_third|top_third|bottom_third",
            "composition_rule": "rule_of_thirds|golden_ratio|centered|dynamic_symmetry",
            "framing_type": "close_up|medium_shot|full_body|environmental",
            "ideal_subject_percentage": 0.3
          }
        },
        "summary": "Key adjustments for matching composition",
        "confidence": 0.85
      }
      
      Guidelines:
      - Focus on composition and framing, not just position
      - Consider how the subject fills the frame
      - Account for compositional balance and visual weight
      - Magnitude values should be realistic (0.1-3.0m for translation, 1-45° for rotation)
      - Confidence reflects how well you can determine the needed adjustments
      - ideal_subject_percentage is how much of the frame the subject should occupy (0.0-1.0)
      """
    } else {
      // No reference image - just analyze the current scene
      prompt = """
      Act like an expert ARKit scene analyst and photography coach. I will provide a photo of the current AR scene and measured values about the subject and camera.
      
      Please provide a concise analysis (≤100 words) that includes:
      1. Assessment of the current scene composition
      2. Specific suggestions for improving the photo (positioning, angle, distance)
      3. Any detected issues with tracking or visibility
      4. Tips for better photo results
      
      Scene metrics:
      - Subject distance: \(distanceStringValue) m
      - Camera height: \(finalCameraHeightForPrompt)
      - Height relative to eyes: \(cameraHeightRelativeToEyes)
      - Visible body parts: \(visibleBodyPartsInfo)
      - Detected subject count: \(detectedSubjectCount)
      - Camera Orientation (Roll, Pitch, Yaw): \(orientationPrompt)
      - Subject-Relative Camera Angles (Pitch, Yaw): \(subjectOrientationPrompt)
      - Camera Horizontal FOV: \(self.fieldOfViewDegString)
      - Ambient Light: \(self.ambientLuxString)
      - Color Temperature: \(self.colorTempKString)
      """
    }
    
    Task {
      do {
        // Track time to API call
        let apiCallStartTime = Date()
        currentMetric.buttonPressToAPICall = apiCallStartTime.timeIntervalSince(startTime)
        
        if hasReference {
          // Use structured response for reference image comparison
          let (structuredResponse, rawJSON) = try await APIService.shared.sendStructuredImageComparisonRequest(
            referenceImage: referenceImage,
            currentImage: currentImage,
            prompt: prompt,
            additionalMetrics: currentMetrics
          )
          
          // Track API response time
          let apiResponseTime = Date()
          currentMetric.apiResponseTime = apiResponseTime.timeIntervalSince(apiCallStartTime)
          
          // Format the structured response into human-readable text
          var formattedResponse = "Photo Guidance (6 DOF Adjustments):\n\n"
          
          // Translation adjustments
          formattedResponse += "POSITION ADJUSTMENTS:\n"
          formattedResponse += "• X-axis: \(structuredResponse.adjustments.translation.x.description)\n"
          formattedResponse += "• Y-axis: \(structuredResponse.adjustments.translation.y.description)\n"
          formattedResponse += "• Z-axis: \(structuredResponse.adjustments.translation.z.description)\n\n"
          
          // Rotation adjustments
          formattedResponse += "ROTATION ADJUSTMENTS:\n"
          formattedResponse += "• Yaw: \(structuredResponse.adjustments.rotation.yaw.description)\n"
          formattedResponse += "• Pitch: \(structuredResponse.adjustments.rotation.pitch.description)\n"
          formattedResponse += "• Roll: \(structuredResponse.adjustments.rotation.roll.description)\n"
          
          if let summary = structuredResponse.summary {
            formattedResponse += "\nSUMMARY: \(summary)"
          }
          
          if let confidence = structuredResponse.confidence {
            formattedResponse += "\nConfidence: \(Int(confidence * 100))%"
          }
          
          let apiResponse = APIResponse(response: formattedResponse)
          
          await MainActor.run {
            let viewModel = ResponsesViewModel()
            viewModel.saveResponse(apiResponse)
            isCapturing = false
            showResponses = true
            
            // Apply guidance with safety validation
            self.applyGuidanceWithSafeguards(structuredResponse)
            
            // Track performance metrics
            if self.currentSubjectBounds != nil {
              let boxStartTime = Date()
              currentMetric.boxPlacementTime = Date().timeIntervalSince(boxStartTime)
              currentMetric.totalTime = Date().timeIntervalSince(startTime)
              self.performanceMetrics.append(currentMetric)
              self.savePerformanceMetrics()
            } else {
              print("❌ No subject bounds available - cannot create guidance box")
              print("💡 Ensure a human subject is detected before analyzing scene")
              currentMetric.totalTime = Date().timeIntervalSince(startTime)
              self.performanceMetrics.append(currentMetric)
              self.savePerformanceMetrics()
            }
            
            // Show brief hint with key adjustment
            var keyAdjustment = "Check responses for guidance"
            if let summary = structuredResponse.summary {
              keyAdjustment = String(summary.prefix(60)) + "..."
            }
            self.bodyTrackingHint = "Photo Guidance: \(keyAdjustment)"
          }
        } else {
          // Use regular text response for scene analysis without reference
          let (responseText, _) = try await APIService.shared.sendImageGenerationRequest(
            referenceImage: referenceImage,
            currentImage: currentImage,
            prompt: prompt,
            additionalMetrics: currentMetrics
          )
          
          // Track API response time
          currentMetric.apiResponseTime = Date().timeIntervalSince(apiCallStartTime)
          
          let apiResponse = APIResponse(response: "Scene Analysis:\n\(responseText)")
          
          await MainActor.run {
            let viewModel = ResponsesViewModel()
            viewModel.saveResponse(apiResponse)
            isCapturing = false
            showResponses = true
            
            // Save metric for non-reference analysis
            currentMetric.totalTime = Date().timeIntervalSince(startTime)
            self.performanceMetrics.append(currentMetric)
            self.savePerformanceMetrics()
            
            // Show brief hint
            let previewText = responseText.prefix(60)
            self.bodyTrackingHint = "Scene Analysis: \(previewText)... (See Responses)"
          }
        }
      } catch {
        print("Error sending analysis request: \(error)")
        await MainActor.run {
          isCapturing = false
          self.bodyTrackingHint = "Analysis failed: \(error.localizedDescription)"
        }
      }
    }
  }
  
  // Activate guidance box based on LLM recommendations
  func activateGuidanceBox(for guidance: StructuredGeminiResponse, subjectBounds: SubjectBounds) {
    guard let arView = ARMeshExporter.arView else { 
      print("❌ activateGuidanceBox: ARView is nil")
      return 
    }
    
    print("✅ activateGuidanceBox called with subject at: \(subjectBounds.center)")
    print("📐 Subject size: \(subjectBounds.size)")
    
    // Get current camera transform
    guard let frame = arView.session.currentFrame else { return }
    let cameraTransform = frame.camera.transform
    
    // Calculate optimal framing position based on subject and LLM guidance
    let (targetPosition, targetDistance) = GuidanceBoxService.shared.calculateOptimalFramingPosition(
      currentSubjectBounds: subjectBounds,
      recommendations: guidance.adjustments,
      cameraTransform: cameraTransform
    )
    
    // Create guidance box data (keeping for compatibility)
    let guidanceBox = GuidanceBoxService.shared.createGuidanceBox(
      targetPosition: targetPosition,
      targetDistance: targetDistance,
      subjectBounds: subjectBounds,
      recommendations: guidance.adjustments,
      cameraTransform: cameraTransform
    )
    
    // Update state
    activeGuidanceBox = guidanceBox
    isGuidanceActive = true
    
    // Calculate 2D guidance directions from LLM recommendations
    updateGuidanceDirections(from: guidance.adjustments)
    
    // Convert subject bounds to screen coordinates
    if let screenBounds = convertToScreenBounds(worldBounds: subjectBounds, frame: frame) {
      guidanceSubjectScreenBounds = screenBounds
    }
    
    // Calculate target framing box position in screen space
    calculateTargetFramingBox(subjectBounds: subjectBounds, guidance: guidance, frame: frame)
    
    bodyTrackingHint = "Follow the arrows to align your shot"
    print("✅ 2D Guidance activated")
  }
  
  private func updateGuidanceDirections(from adjustments: DOFAdjustment) {
    var directions = GuidanceDirections()
    
    // Translation adjustments - these represent how the CAMERA should move
    if let xMag = adjustments.translation.x.magnitude, xMag > 0 {
      if adjustments.translation.x.direction.lowercased() == "left" {
        directions.moveLeft = Float(xMag)
      } else if adjustments.translation.x.direction.lowercased() == "right" {
        directions.moveRight = Float(xMag)
      }
    }
    
    if let yMag = adjustments.translation.y.magnitude, yMag > 0 {
      if adjustments.translation.y.direction.lowercased() == "up" {
        directions.moveUp = Float(yMag)
      } else if adjustments.translation.y.direction.lowercased() == "down" {
        directions.moveDown = Float(yMag)
      }
    }
    
    if let zMag = adjustments.translation.z.magnitude, zMag > 0 {
      if adjustments.translation.z.direction.lowercased() == "forward" {
        directions.moveForward = Float(zMag)
      } else if adjustments.translation.z.direction.lowercased() == "back" || 
                 adjustments.translation.z.direction.lowercased() == "backward" {
        directions.moveBack = Float(zMag)
      }
    }
    
    // Rotation adjustments
    if let yawMag = adjustments.rotation.yaw.magnitude, yawMag > 0 {
      if adjustments.rotation.yaw.direction.lowercased() == "left" {
        directions.turnLeft = Float(yawMag)
      } else if adjustments.rotation.yaw.direction.lowercased() == "right" {
        directions.turnRight = Float(yawMag)
      }
    }
    
    if let pitchMag = adjustments.rotation.pitch.magnitude, pitchMag > 0 {
      if adjustments.rotation.pitch.direction.lowercased() == "up" {
        directions.tiltUp = Float(pitchMag)
      } else if adjustments.rotation.pitch.direction.lowercased() == "down" {
        directions.tiltDown = Float(pitchMag)
      }
    }
    
    guidanceDirections = directions
  }
  
  func convertToScreenBounds(worldBounds: SubjectBounds, frame: ARFrame) -> CGRect? {
    guard let arView = ARMeshExporter.arView else { return nil }
    
    // Get screen dimensions
    let screenSize = arView.bounds.size
    
    // Project 8 corners of the 3D bounding box to screen
    let halfSize = worldBounds.size / 2
    let corners = [
      worldBounds.center + SIMD3<Float>(-halfSize.x, -halfSize.y, -halfSize.z),
      worldBounds.center + SIMD3<Float>( halfSize.x, -halfSize.y, -halfSize.z),
      worldBounds.center + SIMD3<Float>(-halfSize.x,  halfSize.y, -halfSize.z),
      worldBounds.center + SIMD3<Float>( halfSize.x,  halfSize.y, -halfSize.z),
      worldBounds.center + SIMD3<Float>(-halfSize.x, -halfSize.y,  halfSize.z),
      worldBounds.center + SIMD3<Float>( halfSize.x, -halfSize.y,  halfSize.z),
      worldBounds.center + SIMD3<Float>(-halfSize.x,  halfSize.y,  halfSize.z),
      worldBounds.center + SIMD3<Float>( halfSize.x,  halfSize.y,  halfSize.z)
    ]
    
    var minX: CGFloat = .infinity
    var maxX: CGFloat = -.infinity
    var minY: CGFloat = .infinity
    var maxY: CGFloat = -.infinity
    
    for corner in corners {
      let screenPoint = frame.camera.projectPoint(corner, 
                                                  orientation: .portrait,
                                                  viewportSize: screenSize)
      minX = min(minX, CGFloat(screenPoint.x))
      maxX = max(maxX, CGFloat(screenPoint.x))
      minY = min(minY, CGFloat(screenPoint.y))
      maxY = max(maxY, CGFloat(screenPoint.y))
    }
    
    // Ensure valid bounds
    if minX == .infinity || maxX == -.infinity || minY == .infinity || maxY == -.infinity {
      return nil
    }
    
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
  
  func calculateTargetFramingBox(subjectBounds: SubjectBounds, guidance: StructuredGeminiResponse, frame: ARFrame) {
    guard let arView = ARMeshExporter.arView else { return }
    
    let screenSize = arView.bounds.size
    let screenCenter = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
    
    // Get current subject screen bounds
    guard let currentScreenBounds = convertToScreenBounds(worldBounds: subjectBounds, frame: frame),
          currentScreenBounds != .zero else { return }
    
    // Store current subject bounds for overlay
    guidanceSubjectScreenBounds = currentScreenBounds
    
    // Debug logging
    print("📏 Screen size: \(screenSize)")
    print("📏 Subject world bounds: center=\(subjectBounds.center), size=\(subjectBounds.size)")
    print("📏 Subject screen bounds: \(currentScreenBounds)")
    print("📏 Framing type: \(guidance.adjustments.framing?.framing_type ?? "none")")
    
    // The target frame shows where we want the subject to appear in the final composition
    // Start with screen center as the default target position
    var targetCenterX = screenCenter.x
    var targetCenterY = screenCenter.y
    
    // Apply subject positioning rules FIRST (these take priority)
    if let framing = guidance.adjustments.framing {
      switch framing.subject_position {
      case "left_third":
        targetCenterX = screenSize.width / 3
      case "right_third":
        targetCenterX = screenSize.width * 2 / 3
      case "top_third":
        targetCenterY = screenSize.height / 3
      case "bottom_third":
        targetCenterY = screenSize.height * 2 / 3
      case "center":
        // Keep at screen center
        break
      default:
        break
      }
    }
    
    // Calculate desired frame size based on framing guidance
    // Start with the current subject size as a baseline
    var targetWidth = currentScreenBounds.width
    var targetHeight = currentScreenBounds.height
    var frameMultiplier: CGFloat = 1.5 // Default: frame is 1.5x subject size
    
    if let framing = guidance.adjustments.framing {
      // Calculate frame multiplier - how much larger the frame should be than the subject
      switch framing.framing_type {
      case "close_up":
        frameMultiplier = 1.2 // 20% margin around subject
      case "medium_shot":
        frameMultiplier = 1.5 // 50% margin around subject
      case "full_body":
        frameMultiplier = 1.8 // 80% margin around subject
      case "environmental":
        frameMultiplier = 2.5 // 150% margin around subject
      default:
        frameMultiplier = 1.5
      }
      
      // Override with specific percentage if provided
      if let idealPercentage = framing.ideal_subject_percentage, idealPercentage > 0 {
        // If subject should fill X% of frame, frame should be 1/X times subject size
        frameMultiplier = 1.0 / CGFloat(idealPercentage)
      }
      
      // Apply the multiplier to get target frame size
      targetWidth = currentScreenBounds.width * frameMultiplier
      targetHeight = currentScreenBounds.height * frameMultiplier
      
      // Ensure the frame doesn't exceed screen bounds
      let maxWidth = screenSize.width * 0.9  // Max 90% of screen width
      let maxHeight = screenSize.height * 0.9 // Max 90% of screen height
      
      if targetWidth > maxWidth || targetHeight > maxHeight {
        // Scale down proportionally
        let scaleFactorW = maxWidth / targetWidth
        let scaleFactorH = maxHeight / targetHeight
        let scaleFactor = min(scaleFactorW, scaleFactorH)
        targetWidth *= scaleFactor
        targetHeight *= scaleFactor
      }
    }
    
    // Create the target frame bounds at the desired position
    guidanceTargetScreenBounds = CGRect(
      x: targetCenterX - targetWidth / 2,
      y: targetCenterY - targetHeight / 2,
      width: targetWidth,
      height: targetHeight
    )
    
    print("📏 Frame multiplier: \(frameMultiplier)")
    print("📏 Target frame size: \(targetWidth) x \(targetHeight)")
    print("📏 Target frame bounds: \(guidanceTargetScreenBounds)")
    
    // Update alignment score based on how well subject fits in target frame
    updateAlignmentScore(subjectBounds: currentScreenBounds, targetBounds: guidanceTargetScreenBounds)
  }
  
  private func updateAlignmentScore(subjectBounds: CGRect, targetBounds: CGRect) {
    // Calculate overlap between subject and target bounds
    let intersection = subjectBounds.intersection(targetBounds)
    let subjectArea = subjectBounds.width * subjectBounds.height
    let targetArea = targetBounds.width * targetBounds.height
    
    // If there's no intersection, score is 0
    guard !intersection.isNull && intersection.width > 0 && intersection.height > 0 else {
      guidanceAlignmentScore = 0
      return
    }
    
    let intersectionArea = intersection.width * intersection.height
    
    // Score based on: 
    // 1. How much of subject is within target (must be fully contained for high score)
    // 2. How well centered the subject is in target
    // 3. How close the subject size is to ideal size
    
    // Coverage score - penalize heavily if subject is not fully within bounds
    let coverageRatio = intersectionArea / subjectArea
    let coverageScore: CGFloat
    if coverageRatio >= 0.99 { // Nearly fully contained
      coverageScore = 1.0
    } else if coverageRatio >= 0.95 {
      coverageScore = 0.8
    } else if coverageRatio >= 0.9 {
      coverageScore = 0.6
    } else {
      coverageScore = coverageRatio * 0.5 // Heavy penalty for partial coverage
    }
    
    // Center alignment score
    let subjectCenter = CGPoint(x: subjectBounds.midX, y: subjectBounds.midY)
    let targetCenter = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
    let maxDistance = sqrt(pow(targetBounds.width / 2, 2) + pow(targetBounds.height / 2, 2))
    let centerDistance = sqrt(pow(subjectCenter.x - targetCenter.x, 2) + pow(subjectCenter.y - targetCenter.y, 2))
    let centerScore = 1.0 - min(centerDistance / maxDistance, 1.0)
    
    // Size ratio score - subject should fill appropriate portion of frame
    let sizeRatio = subjectArea / targetArea
    let idealSizeRatio: CGFloat = 0.6 // Subject should fill about 60% of frame
    let sizeDifference = abs(sizeRatio - idealSizeRatio)
    let sizeScore = 1.0 - min(sizeDifference / idealSizeRatio, 1.0)
    
    // Combined score with heavy weight on coverage
    // Only show green (>0.8) when subject is fully contained and well-positioned
    let finalScore = Float(coverageScore * 0.5 + centerScore * 0.3 + sizeScore * 0.2)
    guidanceAlignmentScore = finalScore
  }
  
  // Toggle guidance on/off
  func toggleGuidance() {
    if isGuidanceActive {
      // Disable all guidance
      isGuidanceActive = false
      activeGuidanceBox = nil
      guidanceSubjectScreenBounds = .zero
      guidanceTargetScreenBounds = .zero
      guidanceDirections = GuidanceDirections()
      guidanceAlignmentScore = 0
      bodyTrackingHint = "Guidance disabled"
    } else {
      // Try to reactivate guidance if we have data
      if let guidance = latestStructuredGuidance,
         let subjectBounds = currentSubjectBounds {
        activateGuidanceBox(for: guidance, subjectBounds: subjectBounds)
      } else {
        bodyTrackingHint = "No guidance data available. Analyze scene first."
      }
    }
  }
  
  // Apply guidance with safety validation
  func applyGuidanceWithSafeguards(_ guidance: StructuredGeminiResponse) {
    let (safeAdjustments, warnings) = MovementSafeguards.validateAndClamp(guidance.adjustments)
    
    // Update warnings
    safetyWarnings = warnings
    
    // Apply safe adjustments
    if let validatedGuidance = createSafeGuidance(from: guidance, with: safeAdjustments) {
      latestStructuredGuidance = validatedGuidance
      
      if let subjectBounds = currentSubjectBounds {
        activateGuidanceBox(for: validatedGuidance, subjectBounds: subjectBounds)
      }
    }
    
    // Provide haptic feedback for warnings
    if !warnings.isEmpty {
      let generator = UINotificationFeedbackGenerator()
      generator.notificationOccurred(.warning)
    }
  }
  
  private func createSafeGuidance(from original: StructuredGeminiResponse, with safeAdjustments: DOFAdjustment) -> StructuredGeminiResponse? {
    return StructuredGeminiResponse(
      adjustments: safeAdjustments,
      summary: original.summary,
      confidence: original.confidence
    )
  }

}